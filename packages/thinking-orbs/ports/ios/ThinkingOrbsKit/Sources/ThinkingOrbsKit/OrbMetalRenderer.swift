// The low-level orb renderer: Metal, drawn from a thread of its own.
//
// `ThinkingOrb`'s first renderer is a SwiftUI `TimelineView` driving a `Canvas`, which builds
// every frame on the MAIN thread: the engine's geometry, a display list of a few hundred
// fills, and the rasteriser's commit, at the display's rate (120 Hz on ProMotion) for as long
// as an orb is on screen. That is fine on a still screen and costly under a scroll, where the
// same frame also has rows to configure and lay out.
//
// This one draws the same frame (the same engine, the same marks in the same order, the same
// inks) into a `CAMetalLayer` from a render thread with its own display link. A drawable
// presented outside a transaction never waits on the main thread's commit, so an animating orb
// costs the main thread nothing at all.
//
// Three things keep it faithful to the Canvas:
// - **The geometry is the engine's own** (`orbFrame`), so the golden vectors still describe it.
// - **Coverage is the Canvas's own rule**, measured off SwiftUI's rasteriser one shape at a
//   time (discs of every size and offset, strokes of every width and slope, through
//   `ImageRenderer`): an edge is a ramp one pixel wide along its normal, `0.5 − d / w`, where
//   `w` is the distance's screen-space derivative (`fwidth`; `|n.x| + |n.y|` on a straight
//   edge), smoothstepped for a fill and for a stroke wider than 2.5 pixels, plain for a
//   thinner stroke, and a stroke under a pixel wide is drawn a pixel wide and that much
//   fainter. That model reproduces the Canvas's discs to about one level of 255. Every mark
//   is one quad whose fragment shader evaluates it. No MSAA.
// - **Blending is the Canvas's**: straight source-over in sRGB-encoded 8-bit, marks in the
//   engine's draw order (edges first, then the z-sorted dots).
//
// The shaders are compiled from source at first use, off the main thread, so the kit needs no
// `.metal` resource and builds the same vendored, as a package, or under `swift build`.

#if canImport(Metal)
import CoreGraphics
import Foundation
import Metal

// MARK: - Ink

/// The colour a mark is drawn in, from its ink value and alpha.
public enum OrbInk: Equatable, Sendable {
    /// The tuned greys: ink on paper in light, mirrored in dark.
    case greys(isDark: Bool)
    /// One colour (straight sRGB, alpha last), each mark at the strength its grey would have
    /// on paper: `alpha × (1 − white)`. What `ThinkingOrb(tint:)` draws.
    case tint(SIMD4<Float>)
    /// One colour, each mark at its own alpha whatever its grey: what masking a fill of that
    /// colour with the orb comes to.
    case mask(SIMD4<Float>)

    /// A mark's colour, premultiplied.
    func color(white: Double, alpha: Double) -> SIMD4<Float> {
        let w = Swift.min(1, Swift.max(0, white))
        switch self {
        case .greys(let isDark):
            // Quantised to 8 bits exactly as the Canvas painter does.
            let g = Float(((isDark ? 1 - w : w) * 255).rounded(.toNearestOrAwayFromZero) / 255)
            let a = Float(alpha)
            return SIMD4(g * a, g * a, g * a, a)
        case .tint(let c):
            let a = c.w * Float(alpha * (1 - w))
            return SIMD4(c.x * a, c.y * a, c.z * a, a)
        case .mask(let c):
            let a = c.w * Float(alpha)
            return SIMD4(c.x * a, c.y * a, c.z * a, a)
        }
    }
}

/// Everything a render thread needs to draw one orb. A value, copied across under a lock.
struct OrbDrawing {
    var preset: ResolvedPreset
    /// The preset's own side (64 or 20): the engine's coordinate space.
    var presetSide: Double
    /// The preset's speed times the caller's.
    var speed: Double
    var ink: OrbInk
    /// A fixed engine time: one still frame. Nil runs on the wall clock every orb shares.
    var stillTime: Double?
}

// MARK: - Shared Metal objects

/// The device, command queue and pipeline every orb draws with.
public final class OrbMetalRenderer: @unchecked Sendable {

    public static let shared = OrbMetalRenderer()

    /// A cap on the orbs' frame rate, or nil for the display's own (as the Canvas runs). Read
    /// when an orb's render thread starts.
    public var maximumFramesPerSecond: Int?

    /// Whether this process can draw orbs with Metal at all. False sends `ThinkingOrb` back to
    /// its Canvas: no Metal device, or the shaders did not compile.
    public var isAvailable: Bool {
        guard device != nil else { return false }
        stateLock.lock(); defer { stateLock.unlock() }
        return !pipelineFailed
    }

    let device: MTLDevice?
    private let stateLock = NSLock()
    /// Serialises the compile, which takes tens of milliseconds; never taken on the main thread.
    private let compileLock = NSLock()
    private var pipeline: MTLRenderPipelineState?
    private var commandQueue: MTLCommandQueue?
    private var pipelineFailed = false

    private init() {
        device = MTLCreateSystemDefaultDevice()
    }

    /// Compiles the shaders now, off the main thread, so the first orb on screen does not wait
    /// for them. Safe to call from anywhere, any number of times.
    public func prewarm() {
        guard device != nil else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            _ = resources()
        }
    }

    /// The pipeline and queue, compiled on first use. Never call on the main thread: the first
    /// call compiles.
    func resources() -> (pipeline: MTLRenderPipelineState, queue: MTLCommandQueue)? {
        if let ready = readyResources() { return ready }
        guard let device else { return nil }
        compileLock.lock()
        defer { compileLock.unlock() }
        if let ready = readyResources() { return ready }
        stateLock.lock()
        let failed = pipelineFailed
        stateLock.unlock()
        guard !failed else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "orb_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "orb_fragment")
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            // Premultiplied source-over, as the Canvas composites its marks.
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            let built = try device.makeRenderPipelineState(descriptor: descriptor)
            guard let queue = device.makeCommandQueue() else { throw OrbMetalError.noCommandQueue }
            stateLock.lock()
            pipeline = built
            commandQueue = queue
            stateLock.unlock()
            return (built, queue)
        } catch {
            stateLock.lock()
            pipelineFailed = true
            stateLock.unlock()
            // Orbs already on screen chose Metal before this was known: tell them.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didFailNotification, object: nil)
            }
            assertionFailure("ThinkingOrbs: the Metal pipeline did not build: \(error)")
            return nil
        }
    }

    private func readyResources() -> (pipeline: MTLRenderPipelineState, queue: MTLCommandQueue)? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let pipeline, let commandQueue else { return nil }
        return (pipeline, commandQueue)
    }

    private enum OrbMetalError: Error { case noCommandQueue }

    /// Posted on the main thread when the pipeline turns out not to build: `isAvailable` is
    /// false from then on, and a SwiftUI `ThinkingOrb` already drawn by Metal falls back to
    /// its Canvas on hearing it.
    public static let didFailNotification = Notification.Name("ThinkingOrbs.metalRendererDidFail")

    /// 8-bit and not sRGB-decoding, so marks blend in encoded space as the Canvas's
    /// `.nonLinear` colour mode does.
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    // MARK: Encoding a frame

    /// One mark. Matches `OrbInstance` in the shader source below, field for field.
    struct Instance {
        /// A dot: centre x, y, radius, 0. An edge: x1, y1, x2, y2. In pixels.
        var geometry: SIMD4<Float>
        /// x: an edge's half width in pixels. y: 0 for a dot, 1 for an edge.
        var style: SIMD4<Float>
        /// Premultiplied.
        var color: SIMD4<Float>
    }

    struct Uniforms {
        var viewport: SIMD2<Float>
    }

    /// Writes a frame's marks, in draw order, at `unit` pixels to an engine unit.
    static func write(_ frame: OrbFrame, ink: OrbInk, unit: Float, to instances: UnsafeMutablePointer<Instance>) {
        var index = 0
        // Edges first, so nodes sit on top of them; dots are already z-sorted into draw order.
        for line in frame.lines {
            // Under a pixel wide, the Canvas draws a stroke a pixel wide and that much fainter.
            let width = Float(line.w) * unit
            let color = ink.color(white: line.white, alpha: line.a)
            instances[index] = Instance(
                geometry: SIMD4(Float(line.x1) * unit, Float(line.y1) * unit,
                                Float(line.x2) * unit, Float(line.y2) * unit),
                style: SIMD4(Swift.max(width, 1) * 0.5, 1, 0, 0),
                color: width < 1 ? color * width : color)
            index += 1
        }
        for dot in frame.dots {
            instances[index] = Instance(
                geometry: SIMD4(Float(dot.x) * unit, Float(dot.y) * unit, Float(dot.r) * unit, 0),
                style: SIMD4(0, 0, 0, 0),
                color: ink.color(white: dot.white, alpha: dot.a))
            index += 1
        }
    }

    /// Encodes one pass that clears `texture` and draws `count` marks from `buffer`.
    static func encode(into commands: MTLCommandBuffer, texture: MTLTexture, pipeline: MTLRenderPipelineState,
                       buffer: MTLBuffer?, count: Int) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        if count > 0, let buffer {
            var uniforms = Uniforms(viewport: SIMD2(Float(texture.width), Float(texture.height)))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        encoder.endEncoding()
    }

    // MARK: Offscreen (the parity check)

    /// One frame drawn offscreen and read back, as premultiplied BGRA bytes, `pixels` to a
    /// side: the pipeline the layers use, for comparing against the Canvas. Blocks while the
    /// GPU draws, so not for the main thread of anything but a bench.
    public func renderBitmap(state: OrbState, size: OrbSize, time: Double, pixels: Int, ink: OrbInk) -> [UInt8]? {
        guard pixels > 0, let device, let resources = resources() else { return nil }
        let frame = orbFrame(state: state, size: size, t: time)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: pixels, height: pixels, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        // Readable from the CPU: shared where memory is unified, else managed and synchronised.
        let isShared = device.hasUnifiedMemory
        #if os(macOS)
        descriptor.storageMode = isShared ? .shared : .managed
        #else
        descriptor.storageMode = .shared
        #endif
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commands = resources.queue.makeCommandBuffer() else { return nil }
        let count = frame.lines.count + frame.dots.count
        var buffer: MTLBuffer?
        if count > 0 {
            buffer = device.makeBuffer(length: count * MemoryLayout<Instance>.stride, options: .storageModeShared)
            guard let buffer else { return nil }
            Self.write(frame, ink: ink, unit: Float(pixels) / Float(size.value),
                       to: buffer.contents().bindMemory(to: Instance.self, capacity: count))
        }
        Self.encode(into: commands, texture: texture, pipeline: resources.pipeline, buffer: buffer, count: count)
        #if os(macOS)
        if !isShared, let blit = commands.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        #endif
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        texture.getBytes(&bytes, bytesPerRow: pixels * 4,
                         from: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0)
        return bytes
    }

    // MARK: Shaders

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct OrbInstance {
        float4 geometry;
        float4 style;
        float4 color;
    };

    struct OrbUniforms {
        float2 viewport;
    };

    struct OrbVertex {
        float4 position [[position]];
        float2 local;
        float2 extent [[flat]];
        float2 axis [[flat]];
        float kind [[flat]];
        float4 color [[flat]];
    };

    vertex OrbVertex orb_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                const device OrbInstance *instances [[buffer(0)]],
                                constant OrbUniforms &uniforms [[buffer(1)]]) {
        OrbInstance mark = instances[iid];
        float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
        OrbVertex out;
        float2 pixel;
        if (mark.style.y < 0.5) {
            // A dot: a square a pixel wider than the disc all round.
            float radius = mark.geometry.z;
            out.local = corner * (radius + 1.0);
            out.extent = float2(radius, 0.0);
            out.axis = float2(1.0, 0.0);
            pixel = mark.geometry.xy + out.local;
        } else {
            // An edge: a butt-capped stroke, so a rectangle along the segment.
            float2 from = mark.geometry.xy;
            float2 to = mark.geometry.zw;
            float2 delta = to - from;
            float len = length(delta);
            float2 along = len > 0.00001 ? delta / len : float2(1.0, 0.0);
            float2 across = float2(-along.y, along.x);
            float halfLength = len * 0.5;
            float halfWidth = mark.style.x;
            out.local = float2(corner.x * (halfLength + 1.0), corner.y * (halfWidth + 1.0));
            out.extent = float2(halfLength, halfWidth);
            out.axis = along;
            pixel = (from + to) * 0.5 + along * out.local.x + across * out.local.y;
        }
        out.kind = mark.style.y;
        out.color = mark.color;
        float2 ndc = pixel / uniforms.viewport * 2.0 - 1.0;
        out.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
        return out;
    }

    // The Canvas's own anti-aliasing, measured off SwiftUI's rasteriser (see the header): a
    // ramp one pixel wide ALONG THE EDGE'S NORMAL, where a pixel's width along a unit normal n
    // is |n.x| + |n.y|. `distance` is from the pixel's centre to the edge, positive outside.
    static float edge_ramp(float distance, float2 normal) {
        float extent = max(abs(normal.x) + abs(normal.y), 0.0001);
        return saturate(0.5 - distance / extent);
    }

    // A fill's edge, and a stroke's wider than 2.5 pixels: the ramp, smoothstepped.
    static float fill_edge(float distance, float2 normal) {
        float t = edge_ramp(distance, normal);
        return t * t * (3.0 - 2.0 * t);
    }

    fragment float4 orb_fragment(OrbVertex in [[stage_in]]) {
        float coverage;
        if (in.kind < 0.5) {
            // A disc is its signed distance over that distance's own screen-space derivative
            // (`fwidth`, the 2 x 2 pixel quad's), smoothstepped: what the Canvas's ellipse
            // comes to, pixel for pixel, down to a dot half a pixel in radius.
            float distance = length(in.local) - in.extent.x;
            float t = saturate(0.5 - distance / max(fwidth(distance), 0.0001));
            coverage = t * t * (3.0 - 2.0 * t);
        } else {
            float2 across = float2(-in.axis.y, in.axis.x);
            float top = in.local.y - in.extent.y;
            float bottom = -in.local.y - in.extent.y;
            float head = in.local.x - in.extent.x;
            float tail = -in.local.x - in.extent.x;
            if (in.extent.y > 1.25) {
                // Wider than 2.5 pixels, a stroke is filled as its outline.
                coverage = saturate(fill_edge(top, across) + fill_edge(bottom, across) - 1.0)
                         * saturate(fill_edge(head, in.axis) + fill_edge(tail, in.axis) - 1.0);
            } else {
                // A thin line keeps the plain ramp on both sides.
                coverage = saturate(edge_ramp(top, across) + edge_ramp(bottom, across) - 1.0)
                         * saturate(edge_ramp(head, in.axis) + edge_ramp(tail, in.axis) - 1.0);
            }
        }
        return in.color * coverage;
    }
    """
}
#endif
