// The SwiftUI ThinkingOrb.
//
// Two renderers draw the same engine's frames:
//
// - **Metal** (`OrbRenderer.metal`, the default where Metal exists): a `CAMetalLayer` drawn
//   from a render thread of its own (`OrbMetalRenderer`), so an animating orb costs the main
//   thread nothing. Used only while the orb is animating.
// - **Canvas** (`OrbRenderer.canvas`): TimelineView(.animation) drives the clock and Canvas
//   does the drawing, on the main thread, every frame. The reference renderer; also what
//   draws every STILL frame (paused, Reduce Motion, a frozen instant), since a still costs
//   nothing per frame and a Canvas is what `ImageRenderer` can draw.

import SwiftUI

/// Theme mode. `.auto` follows the environment's colour scheme.
public enum OrbTheme: Sendable {
    case auto, dark, light
}

/// What draws an animating orb.
public enum OrbRenderer: String, CaseIterable, Sendable {
    /// Metal, off the main thread. Falls back to the Canvas where Metal is not available.
    case metal
    /// The SwiftUI Canvas on a TimelineView, on the main thread: the reference.
    case canvas

    /// The UserDefaults key holding the process-wide pick, which every orb reads live. Unset
    /// reads as `.metal`. `orbRenderer(_:)` overrides it for the orbs under one view.
    public static let defaultsKey = "ThinkingOrbs.renderer"
}

@available(iOS 15.0, macOS 12.0, *)
public struct ThinkingOrb: View {
    private let state: OrbState
    private let size: OrbSize
    private let theme: OrbTheme
    private let speed: Double
    private let paused: Bool
    private let displaySize: Double?
    /// An ink colour in place of the greys: each mark is drawn in it at the strength the grey
    /// would have on paper (the nearest near full, the farthest faint), so the orb reads the
    /// same on any background, clear glass among them. Nil keeps the tuned greys, which the
    /// golden vectors and the parity harness compare.
    private let tint: Color?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.orbRenderer) private var rendererOverride
    @AppStorage(OrbRenderer.defaultsKey) private var storedRenderer = OrbRenderer.metal.rawValue
    // ImageRenderer never advances a TimelineView, so snapshot.sh injects a
    // fixed instant here to capture a deterministic frame.
    @Environment(\.orbFrozenTime) private var frozenTime

    /// `displaySize` renders the orb at an arbitrary point size while keeping
    /// the tuned `size` preset's geometry — the drawing is scaled inside the
    /// Canvas, so it stays vector-crisp at any factor (a `scaleEffect` would
    /// rasterise the layer first). Mirrors the React Native port's prop.
    public init(
        state: OrbState = .working,
        size: OrbSize = .px64,
        theme: OrbTheme = .auto,
        speed: Double = 1,
        paused: Bool = false,
        displaySize: Double? = nil,
        tint: Color? = nil
    ) {
        self.state = state
        self.size = size
        self.theme = theme
        self.speed = speed
        self.paused = paused
        self.displaySize = displaySize
        self.tint = tint
    }

    private var isDark: Bool {
        switch theme {
        case .dark: return true
        case .light: return false
        case .auto: return colorScheme == .dark
        }
    }

    public var body: some View {
        let preset = resolvePreset(state, size)
        let effSpeed = preset.speed * speed
        let side = displaySize ?? size.value

        Group {
            if let frozenTime {
                // Raw engine time, NOT scaled by speed: the golden vectors and
                // the web parity harness both evaluate the engine at this t
                // directly, so applying the preset speed here would compare
                // two different instants and report a false mismatch.
                canvas(preset: preset, t: frozenTime)
            } else if reduceMotion || paused {
                // one static, deterministic frame — same instant as the web
                canvas(preset: preset, t: OrbSpec.reducedMotionT * effSpeed)
            } else {
                animated(preset: preset, effSpeed: effSpeed)
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel(state.label)
        .accessibilityAddTraits(.isImage)
    }

    /// The renderer asked for: the one set for this part of the view tree, else the stored pick.
    private var renderer: OrbRenderer {
        rendererOverride ?? OrbRenderer(rawValue: storedRenderer) ?? .metal
    }

    @ViewBuilder
    private func animated(preset: ResolvedPreset, effSpeed: Double) -> some View {
        #if canImport(UIKit) && canImport(Metal)
        if renderer == .metal, OrbMetalRenderer.shared.isAvailable {
            // The same wall clock as the Canvas below, read on the render thread: orbs drawn
            // either way stay in phase.
            ThinkingOrbMetalView(state: state, size: size, speed: speed, isDark: isDark,
                                 tint: tint, tintIgnoresInk: false)
                .allowsHitTesting(false)
        } else {
            timeline(preset: preset, effSpeed: effSpeed)
        }
        #else
        timeline(preset: preset, effSpeed: effSpeed)
        #endif
    }

    private func timeline(preset: ResolvedPreset, effSpeed: Double) -> some View {
        TimelineView(.animation(paused: paused)) { timeline in
            // One shared clock, so several orbs on screen stay in
            // phase exactly as they do on the web.
            let t = timeline.date.timeIntervalSinceReferenceDate * effSpeed
            canvas(preset: preset, t: t)
        }
    }

    @ViewBuilder
    private func canvas(preset: ResolvedPreset, t: Double) -> some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            var context = context
            let zoom = (displaySize ?? size.value) / size.value
            if zoom != 1 { context.scaleBy(x: zoom, y: zoom) }
            let frame = orbFrame(preset, size: size.value, t: t)
            // lines first, so nodes sit on top of their edges
            for l in frame.lines {
                var path = Path()
                path.move(to: CGPoint(x: l.x1, y: l.y1))
                path.addLine(to: CGPoint(x: l.x2, y: l.y2))
                context.stroke(
                    path,
                    with: .color(ink(l.white, l.a)),
                    lineWidth: l.w
                )
            }
            // dots are already z-sorted into draw order by the engine
            for d in frame.dots {
                let rect = CGRect(x: d.x - d.r, y: d.y - d.r, width: d.r * 2, height: d.r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(ink(d.white, d.a)))
            }
        }
    }

    /// Quantise to 8-bit exactly as the canvas painter does, so the platforms
    /// land on identical greys rather than merely close ones.
    private func ink(_ white: Double, _ alpha: Double) -> Color {
        let w = Swift.min(1, Swift.max(0, white))
        if let tint { return tint.opacity(alpha * (1 - w)) }
        let g = ((isDark ? 1 - w : w) * 255).rounded(.toNearestOrAwayFromZero) / 255
        return Color(.sRGB, red: g, green: g, blue: g, opacity: alpha)
    }
}

// MARK: - Renderer

private struct OrbRendererKey: EnvironmentKey {
    static let defaultValue: OrbRenderer? = nil
}

extension EnvironmentValues {
    /// The renderer for the orbs below, over the stored pick (`OrbRenderer.defaultsKey`). An
    /// orb used as a SwiftUI `mask` needs `.canvas`: a mask is rasterised by SwiftUI, which
    /// cannot draw a platform view into one.
    public var orbRenderer: OrbRenderer? {
        get { self[OrbRendererKey.self] }
        set { self[OrbRendererKey.self] = newValue }
    }
}

@available(iOS 15.0, macOS 12.0, *)
extension View {
    /// Draw every ThinkingOrb below this view with `renderer`.
    public func orbRenderer(_ renderer: OrbRenderer?) -> some View {
        environment(\.orbRenderer, renderer)
    }
}

// MARK: - Frozen time (snapshot testing)

private struct OrbFrozenTimeKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

extension EnvironmentValues {
    /// Pins the animation to a fixed instant. Used by the snapshot harness;
    /// `ImageRenderer` does not fire `onAppear` or advance `TimelineView`,
    /// so without this every capture would render the same t=0 frame.
    public var orbFrozenTime: Double? {
        get { self[OrbFrozenTimeKey.self] }
        set { self[OrbFrozenTimeKey.self] = newValue }
    }
}

@available(iOS 15.0, macOS 12.0, *)
extension View {
    /// Freeze every ThinkingOrb below this view at `t` seconds.
    public func orbFrozenTime(_ t: Double?) -> some View {
        environment(\.orbFrozenTime, t)
    }
}
