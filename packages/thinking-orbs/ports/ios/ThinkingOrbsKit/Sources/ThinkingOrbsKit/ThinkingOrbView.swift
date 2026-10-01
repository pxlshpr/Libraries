// The orb as a UIKit view on a Metal layer, and the SwiftUI wrapper `ThinkingOrb` uses for it.
//
// The view does nothing per frame: it tells its `OrbRenderLoop` what to draw and whether to be
// drawing at all, and the loop's own thread does the rest. It draws while it is in a window of
// a scene in the foreground, and rests otherwise (its last frame stays on the layer).

#if canImport(UIKit) && canImport(Metal)
import SwiftUI
import UIKit

/// A thinking orb drawn off the main thread. Size it like any view: the orb's square fills the
/// view's width, as the SwiftUI `ThinkingOrb` fills its `displaySize`.
public final class ThinkingOrbView: UIView {

    public override class var layerClass: AnyClass { CAMetalLayer.self }

    /// Which animation.
    public var state: OrbState { didSet { if state != oldValue { apply() } } }
    /// Which tuned preset's geometry (the 64 pt lattice or the 20 pt one).
    public var size: OrbSize { didSet { if size != oldValue { apply() } } }
    /// A multiplier on the preset's own speed.
    public var speed: Double = 1 { didSet { if speed != oldValue { apply() } } }
    /// What the marks are drawn in.
    public var ink: OrbInk { didSet { if ink != oldValue { apply() } } }
    /// Holds the one still frame Reduce Motion shows.
    public var isPaused = false { didSet { if isPaused != oldValue { apply() } } }
    /// Pins the engine to an instant (snapshots, the parity check). Raw engine time, as
    /// `orbFrozenTime` is.
    public var frozenTime: Double? { didSet { if frozenTime != oldValue { apply() } } }

    private var loop: OrbRenderLoop!
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var observers: [NSObjectProtocol] = []
    private var isRetryingSize = false

    public init(state: OrbState = .working, size: OrbSize = .px64, ink: OrbInk = .greys(isDark: false)) {
        self.state = state
        self.size = size
        self.ink = ink
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false

        let layer = metalLayer
        layer.device = OrbMetalRenderer.shared.device
        layer.pixelFormat = OrbMetalRenderer.pixelFormat
        layer.framebufferOnly = true
        layer.isOpaque = false
        // The frame is shown as soon as it is drawn, not held for the main thread's next commit:
        // that is what takes the orb off the main thread.
        layer.presentsWithTransaction = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.drawableSize = .zero
        loop = OrbRenderLoop(layer: layer, drawing: drawing)

        let center = NotificationCenter.default
        for name in [UIScene.didEnterBackgroundNotification, UIScene.willEnterForegroundNotification,
                     UIScene.didActivateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let scene = note.object as? UIScene, scene === self.window?.windowScene else { return }
                self.apply()
            })
        }
        observers.append(center.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.apply()
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        loop.invalidate()
    }

    // MARK: What to draw

    /// The engine time the orb stands at while it is not animating, or nil while it is.
    private var stillTime: Double? {
        if let frozenTime { return frozenTime }
        guard isPaused || UIAccessibility.isReduceMotionEnabled else { return nil }
        // The same instant the Canvas (and the web) show a reduced-motion user.
        return OrbSpec.reducedMotionT * resolvePreset(state, size).speed * speed
    }

    private var drawing: OrbDrawing {
        let preset = resolvePreset(state, size)
        return OrbDrawing(preset: preset, presetSide: size.value, speed: preset.speed * speed,
                          ink: ink, stillTime: stillTime)
    }

    /// Whether anything can show a frame: in a window, on a scene that is not in the
    /// background (a backgrounded app may not submit GPU work), with a drawable to draw into.
    private var canDraw: Bool {
        guard let window, !isHidden, bounds.width > 0, bounds.height > 0 else { return false }
        if let scene = window.windowScene, scene.activationState == .background { return false }
        return metalLayer.drawableSize.width >= 1
    }

    private func apply() {
        guard loop != nil else { return }
        let drawing = self.drawing
        loop.update(drawing)
        guard canDraw else {
            loop.rest()
            return
        }
        if drawing.stillTime != nil {
            loop.drawStill()
        } else {
            loop.run()
        }
    }

    // MARK: UIView

    public override var isHidden: Bool {
        didSet { if isHidden != oldValue { apply() } }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // Before `apply()`: the loop makes its display link for the scene it is on.
        loop.setScene(window?.windowScene)
        sizeDrawable()
        apply()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        sizeDrawable()
        apply()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.displayScale != traitCollection.displayScale {
            sizeDrawable()
            apply()
        }
    }

    /// The drawable is the view's bounds in pixels.
    private func sizeDrawable() {
        let scale = traitCollection.displayScale
        guard scale > 0 else { return }
        if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard !loop.setDrawableSize(size), !isRetryingSize else { return }
        // A draw was in flight. Try again shortly rather than make the main thread wait for it.
        isRetryingSize = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.isRetryingSize = false
            self.sizeDrawable()
            self.apply()
        }
    }
}

// MARK: - SwiftUI

/// `ThinkingOrbView` for `ThinkingOrb`'s body. The frame comes from the caller.
struct ThinkingOrbMetalView: UIViewRepresentable {
    let state: OrbState
    let size: OrbSize
    let speed: Double
    let isDark: Bool
    let tint: Color?
    /// With a tint: each mark at its own alpha, whatever its grey (see `OrbInk.mask`).
    let tintIgnoresInk: Bool

    func makeUIView(context: Context) -> ThinkingOrbView {
        let view = ThinkingOrbView(state: state, size: size, ink: ink(in: context))
        view.speed = speed
        return view
    }

    func updateUIView(_ view: ThinkingOrbView, context: Context) {
        view.state = state
        view.size = size
        view.speed = speed
        view.ink = ink(in: context)
    }

    private func ink(in context: Context) -> OrbInk {
        guard let tint else { return .greys(isDark: isDark) }
        let color: SIMD4<Float>
        if #available(iOS 17.0, *) {
            let resolved = tint.resolve(in: context.environment)
            color = SIMD4(resolved.red, resolved.green, resolved.blue, resolved.opacity)
        } else {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(tint).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            color = SIMD4(Float(red), Float(green), Float(blue), Float(alpha))
        }
        return tintIgnoresInk ? .mask(color) : .tint(color)
    }
}
#endif
