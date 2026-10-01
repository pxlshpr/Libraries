// One orb's render loop: a thread, a display link, and the Metal layer they draw into.
//
// Each orb has a render thread of its own rather than a share of one. `nextDrawable()` blocks
// (for up to a second) on a layer the system is not compositing: one scrolled out of view, or
// under a sheet. On a shared thread that would freeze every other orb with it; on its own it
// costs a sleeping thread, and the orb picks up within a frame of being shown again.

#if canImport(UIKit) && canImport(Metal)
import Foundation
import Metal
import QuartzCore
import UIKit

/// One orb's Metal layer, what to draw in it, and the thread that draws it.
///
/// The view owns it on the main thread; the thread is started the first time the orb is asked
/// to draw and parked (its display link paused) whenever it is not, until `invalidate()`.
///
/// Two locks, never held together by the main thread: `stateLock` guards the small values
/// (taken for nanoseconds on both sides); `drawLock` is held by the render thread for the
/// whole of a draw and by the main thread only to resize the drawable, as Apple's custom
/// Metal view sample serialises the two.
final class OrbRenderLoop: NSObject, @unchecked Sendable {

    let layer: CAMetalLayer

    private let stateLock = NSLock()
    private var drawing: OrbDrawing
    private var isRunning = false
    private var owesStill = false
    private var isInvalid = false
    private var link: CADisplayLink?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    private let drawLock = NSLock()
    // Render thread only, under `drawLock`.
    private var buffers: [MTLBuffer?] = [nil, nil, nil]
    private var frameIndex = 0

    init(layer: CAMetalLayer, drawing: OrbDrawing) {
        self.layer = layer
        self.drawing = drawing
    }

    // MARK: Main thread

    func update(_ drawing: OrbDrawing) {
        stateLock.lock()
        self.drawing = drawing
        stateLock.unlock()
    }

    /// Draw every frame from now on.
    func run() {
        stateLock.lock()
        guard !isInvalid else { stateLock.unlock(); return }
        isRunning = true
        owesStill = false
        stateLock.unlock()
        wake()
    }

    /// Draw one frame of what the orb is now (a paused orb, Reduce Motion), then rest.
    func drawStill() {
        stateLock.lock()
        guard !isInvalid else { stateLock.unlock(); return }
        isRunning = false
        owesStill = true
        stateLock.unlock()
        wake()
    }

    /// Stop drawing. The last frame stays on the layer.
    func rest() {
        stateLock.lock()
        isRunning = false
        owesStill = false
        stateLock.unlock()
    }

    /// The orb is gone: the thread ends.
    func invalidate() {
        stateLock.lock()
        isInvalid = true
        isRunning = false
        owesStill = false
        let link = self.link
        let runLoop = self.runLoop
        self.link = nil
        self.runLoop = nil
        stateLock.unlock()
        // `invalidate()` may be called from any thread; a loop waiting on its one source does
        // not notice that source going, so it is told to stop as well.
        link?.invalidate()
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
    }

    /// The drawable's size in pixels. Never waits: false while a draw is in flight (a fraction
    /// of a millisecond, or up to a second on a layer the system is not showing), and the
    /// caller tries again shortly.
    func setDrawableSize(_ size: CGSize) -> Bool {
        guard layer.drawableSize != size else { return true }
        guard drawLock.try() else { return false }
        layer.drawableSize = size
        drawLock.unlock()
        return true
    }

    private func wake() {
        stateLock.lock()
        let link = self.link
        let needsThread = thread == nil && !isInvalid
        if needsThread {
            let thread = Thread { [self] in runThread() }
            thread.name = "ThinkingOrbs.render"
            thread.qualityOfService = .userInteractive
            self.thread = thread
            stateLock.unlock()
            thread.start()
        } else {
            stateLock.unlock()
            link?.isPaused = false
        }
    }

    // MARK: Render thread

    private func runThread() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        if let cap = OrbMetalRenderer.shared.maximumFramesPerSecond {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(Swift.min(cap, 30)), maximum: Float(cap), preferred: Float(cap))
        } else {
            // The display's own rate, up to ProMotion's 120 Hz where the app has opted in
            // (`CADisableMinimumFrameDurationOnPhone`), as `TimelineView(.animation)` runs.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        }
        stateLock.lock()
        if isInvalid {
            stateLock.unlock()
            link.invalidate()
            return
        }
        self.link = link
        runLoop = CFRunLoopGetCurrent()
        stateLock.unlock()
        link.add(to: .current, forMode: .default)
        // Runs until `invalidate()` takes the link away and stops the loop.
        while true {
            let ran = autoreleasepool { RunLoop.current.run(mode: .default, before: .distantFuture) }
            stateLock.lock()
            let done = isInvalid
            stateLock.unlock()
            if done || !ran { break }
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        stateLock.lock()
        let drawing = self.drawing
        let draws = isRunning || owesStill
        owesStill = false
        if !isRunning { link.isPaused = true }
        stateLock.unlock()
        guard draws else { return }
        // The instant the frame will be shown at, on the wall clock every orb shares.
        let lead = Swift.max(0, link.targetTimestamp - CACurrentMediaTime())
        autoreleasepool {
            draw(drawing, wallTime: Date.timeIntervalSinceReferenceDate + lead)
        }
    }

    private func draw(_ drawing: OrbDrawing, wallTime: Double) {
        guard let device = OrbMetalRenderer.shared.device,
              let resources = OrbMetalRenderer.shared.resources() else { return }
        let time = drawing.stillTime ?? wallTime * drawing.speed
        let frame = orbFrame(drawing.preset, size: drawing.presetSide, t: time)

        drawLock.lock()
        defer { drawLock.unlock() }
        let size = layer.drawableSize
        guard size.width >= 1, size.height >= 1,
              // Nil after the layer's timeout: it is not being shown. Nothing to draw into.
              let drawable = layer.nextDrawable(),
              let commands = resources.queue.makeCommandBuffer() else { return }

        let count = frame.lines.count + frame.dots.count
        let stride = MemoryLayout<OrbMetalRenderer.Instance>.stride
        // A buffer the GPU may still be reading is never written: three take turns.
        let slot = frameIndex % buffers.count
        frameIndex &+= 1
        if count > 0, (buffers[slot]?.length ?? 0) < count * stride {
            // Room to grow into, so a mode whose mark count wanders does not reallocate.
            buffers[slot] = device.makeBuffer(length: Swift.max(64, count * 2) * stride, options: .storageModeShared)
        }
        if count > 0, let buffer = buffers[slot] {
            // Engine units to pixels: the Canvas zooms the preset's square to the view's.
            OrbMetalRenderer.write(
                frame, ink: drawing.ink, unit: Float(drawable.texture.width) / Float(drawing.presetSide),
                to: buffer.contents().bindMemory(to: OrbMetalRenderer.Instance.self, capacity: count))
        }
        OrbMetalRenderer.encode(into: commands, texture: drawable.texture, pipeline: resources.pipeline,
                                buffer: buffers[slot], count: count)
        commands.present(drawable)
        commands.commit()
    }
}
#endif
