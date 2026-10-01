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
///
/// One thread at a time, and a thread is numbered (`generation`): one whose number is no longer
/// the loop's is on its way out, whatever it is doing. That is how a link is replaced when the
/// orb moves to another scene, and how a thread whose run loop ended by itself is told from one
/// that was asked to end.
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
    private var generation = 0
    /// Counts the orders given (`run`, `drawStill`, `rest`), so that a tick can tell whether
    /// the one it acted on still stands.
    private var orders = 0
    /// The scene the orb is shown on. Main thread only.
    private weak var scene: UIWindowScene?

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
        orders &+= 1
        stateLock.unlock()
        wake()
    }

    /// Draw one frame of what the orb is now (a paused orb, Reduce Motion), then rest.
    func drawStill() {
        stateLock.lock()
        guard !isInvalid else { stateLock.unlock(); return }
        isRunning = false
        owesStill = true
        orders &+= 1
        stateLock.unlock()
        wake()
    }

    /// Stop drawing. The last frame stays on the layer.
    func rest() {
        stateLock.lock()
        isRunning = false
        owesStill = false
        orders &+= 1
        stateLock.unlock()
    }

    /// The orb is gone: the thread ends.
    func invalidate() {
        stateLock.lock()
        isInvalid = true
        isRunning = false
        owesStill = false
        orders &+= 1
        stateLock.unlock()
        retireThread()
    }

    /// The scene the orb is on now (nil: in no window). Its display link comes from the scene
    /// where the system offers one, so a link made for another scene is retired here and the
    /// next `run()` or `drawStill()` makes one for this scene. Main thread.
    func setScene(_ scene: UIWindowScene?) {
        guard self.scene !== scene else { return }
        self.scene = scene
        stateLock.lock()
        let hadThread = thread != nil
        stateLock.unlock()
        if hadThread { retireThread() }
    }

    /// Ends the thread there is, if any, without waiting for it: its link goes, its run loop
    /// is told to stop, and its number is no longer the loop's. May be called from any thread.
    private func retireThread() {
        stateLock.lock()
        generation &+= 1
        let link = self.link
        let runLoop = self.runLoop
        self.link = nil
        self.runLoop = nil
        thread = nil
        stateLock.unlock()
        // A loop waiting on its one source does not notice that source going, so it is told
        // to stop as well.
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

    /// Main thread: the link is made here (a scene's link is the scene's to make).
    private func wake() {
        stateLock.lock()
        let link = self.link
        let needsThread = thread == nil && !isInvalid
        var number = 0
        if needsThread {
            generation &+= 1
            number = generation
        }
        stateLock.unlock()
        guard needsThread else {
            link?.isPaused = false
            return
        }
        let made = makeLink()
        let thread = Thread { [self] in runThread(link: made, number: number) }
        thread.name = "ThinkingOrbs.render"
        thread.qualityOfService = .userInteractive
        stateLock.lock()
        // Called off meanwhile (`invalidate()` may come from any thread).
        guard !isInvalid, generation == number else {
            stateLock.unlock()
            made.invalidate()
            return
        }
        self.thread = thread
        stateLock.unlock()
        thread.start()
    }

    /// The orb's display link, not yet on a run loop. From the scene where the system offers
    /// one (iOS 27): that link follows the scene from one display to another (a foldable's
    /// cover and inner displays), where `CADisplayLink(target:selector:)` is the main
    /// display's whichever display the orb is on.
    private func makeLink() -> CADisplayLink {
        var made: CADisplayLink?
        #if compiler(>=6.4)
        if #available(iOS 27.0, *), let scene {
            made = scene.displayLink(target: self, selector: #selector(tick(_:)))
        }
        #endif
        let link = made ?? CADisplayLink(target: self, selector: #selector(tick(_:)))
        if let cap = OrbMetalRenderer.shared.maximumFramesPerSecond {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(Swift.min(cap, 30)), maximum: Float(cap), preferred: Float(cap))
        } else {
            // The display's own rate, up to ProMotion's 120 Hz where the app has opted in
            // (`CADisableMinimumFrameDurationOnPhone`), as `TimelineView(.animation)` runs.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        }
        return link
    }

    // MARK: Render thread

    private func runThread(link: CADisplayLink, number: Int) {
        // On the run loop before anyone else can reach it: a link invalidated first and added
        // after might still be scheduled, and this thread would then never end.
        link.add(to: .current, forMode: .default)
        stateLock.lock()
        guard !isInvalid, generation == number else {
            stateLock.unlock()
            link.invalidate()
            return
        }
        self.link = link
        runLoop = CFRunLoopGetCurrent()
        stateLock.unlock()
        // Runs until the link is taken away and the loop stopped (`retireThread`).
        while true {
            let ran = autoreleasepool { RunLoop.current.run(mode: .default, before: .distantFuture) }
            stateLock.lock()
            let done = isInvalid || generation != number
            stateLock.unlock()
            if done || !ran { break }
        }
        link.invalidate()
        // Still the loop's thread, so its run loop ended by itself (the link was its one
        // source). Its place is given up, which is also what lets go of the thread's hold on
        // this loop, and another is started if there is drawing owed.
        stateLock.lock()
        var owed = false
        if generation == number {
            self.link = nil
            runLoop = nil
            thread = nil
            owed = !isInvalid && (isRunning || owesStill)
        }
        stateLock.unlock()
        if owed {
            DispatchQueue.main.async { [weak self] in self?.wake() }
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        stateLock.lock()
        let drawing = self.drawing
        let running = isRunning
        let still = owesStill && !running
        let order = orders
        owesStill = false
        // Paused under the lock, where `isRunning` was read: a `run()` that comes now takes
        // the lock after this and unpauses after it.
        if !running { link.isPaused = true }
        stateLock.unlock()
        guard running || still else { return }
        // The instant the frame will be shown at, on the wall clock every orb shares.
        let lead = Swift.max(0, link.targetTimestamp - CACurrentMediaTime())
        let drew = autoreleasepool {
            draw(drawing, wallTime: Date.timeIntervalSinceReferenceDate + lead)
        }
        // A still is owed until it has been drawn: one that found no drawable yet, or the
        // pipeline still compiling, is tried again on the next tick. Only while the order it
        // was drawn for stands (a `rest()` since calls it off), and never for a pipeline that
        // failed to build, which no later tick can help.
        guard still, !drew, OrbMetalRenderer.shared.isAvailable else { return }
        stateLock.lock()
        if orders == order, !isInvalid {
            owesStill = true
            link.isPaused = false
        }
        stateLock.unlock()
    }

    /// False when nothing was drawn: no pipeline yet, no size, no drawable.
    @discardableResult
    private func draw(_ drawing: OrbDrawing, wallTime: Double) -> Bool {
        guard let device = OrbMetalRenderer.shared.device,
              let resources = OrbMetalRenderer.shared.resources() else { return false }
        let time = drawing.stillTime ?? wallTime * drawing.speed
        let frame = orbFrame(drawing.preset, size: drawing.presetSide, t: time)

        drawLock.lock()
        defer { drawLock.unlock() }
        let size = layer.drawableSize
        guard size.width >= 1, size.height >= 1,
              // Nil after the layer's timeout: it is not being shown. Nothing to draw into.
              let drawable = layer.nextDrawable(),
              let commands = resources.queue.makeCommandBuffer() else { return false }

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
        return true
    }
}
#endif
