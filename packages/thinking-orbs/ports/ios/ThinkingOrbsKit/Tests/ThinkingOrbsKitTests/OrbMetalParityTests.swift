// Asserts the Metal renderer draws what the SwiftUI Canvas draws.
//
// The Canvas (through ImageRenderer, as OrbSnapshotTests captures it) is the reference: every
// state, at a spread of sizes, instants and screen scales, drawn by both and compared byte for
// byte. The Metal renderer's coverage rules were measured off the Canvas one shape at a time
// (see OrbMetalRenderer.swift), and with them the two agree to within 8-bit rounding: the
// worst channel of the worst pixel over all of this is 2 of 255.
//
// A failure names the state, size, instant and scale, and with ORB_PARITY_DIR set writes the
// two renders and their difference as PNGs for looking at.

#if canImport(Metal) && canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import ThinkingOrbsKit

@available(macOS 13.0, *)
final class OrbMetalParityTests: XCTestCase {
    /// The largest difference allowed in any channel of any pixel, of 255.
    static let tolerance = 3

    /// The preset and the side it is shown at, in points: both presets at their own size and
    /// zoomed, as `displaySize` zooms them.
    static let sizes: [(OrbSize, Double)] = [(.px20, 13), (.px20, 20), (.px20, 42), (.px64, 64), (.px64, 128), (.px64, 180)]
    static let times = [0.6, 2.5, 7.3, 31.7, 1234.5]
    static let scales: [CGFloat] = [2, 3]

    private static let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    @MainActor
    func testMetalDrawsWhatTheCanvasDraws() throws {
        guard OrbMetalRenderer.shared.isAvailable else { throw XCTSkip("no Metal device") }
        let outDir = ProcessInfo.processInfo.environment["ORB_PARITY_DIR"].map { URL(fileURLWithPath: $0) }
        if let outDir { try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) }

        var worst = 0
        var frames = 0
        for scale in Self.scales {
            for time in Self.times {
                for state in OrbState.allCases {
                    for (size, side) in Self.sizes {
                        let pixels = Int((side * scale).rounded())
                        let name = "\(state.rawValue)-\(size.rawValue)@\(Int(side))pt-\(Int(scale))x-t\(time)"
                        let metal = try XCTUnwrap(
                            OrbMetalRenderer.shared.renderBitmap(state: state, size: size, time: time, pixels: pixels,
                                                                 ink: .greys(isDark: false)),
                            "Metal render failed: \(name)")
                        let canvas = try XCTUnwrap(
                            Self.canvas(state: state, size: size, side: side, scale: scale, time: time),
                            "Canvas render failed: \(name)")
                        // A blank frame would agree with a blank frame.
                        XCTAssertGreaterThan(stride(from: 3, to: metal.count, by: 4).filter { metal[$0] > 0 }.count, 10,
                                             "the Metal frame is empty: \(name)")
                        var difference = 0
                        for index in 0..<metal.count {
                            difference = max(difference, abs(Int(metal[index]) - Int(canvas[index])))
                        }
                        worst = max(worst, difference)
                        frames += 1
                        if difference > Self.tolerance {
                            XCTFail("\(name): a channel is \(difference) of 255 apart")
                            if let outDir {
                                try Self.png(metal, pixels: pixels)?.write(to: outDir.appendingPathComponent("\(name)-metal.png"))
                                try Self.png(canvas, pixels: pixels)?.write(to: outDir.appendingPathComponent("\(name)-canvas.png"))
                            }
                        }
                    }
                }
            }
        }
        print("Metal against the Canvas over \(frames) frames: the worst channel is \(worst) of 255 apart")
    }

    /// The greys of the dark appearance, and one colour in place of the greys. The dark greys
    /// agree as the light ones do. A colour is looser: 7 at the worst, on fewer than one pixel
    /// in ten thousand.
    @MainActor
    func testMetalDrawsTheOtherInksTheCanvasDraws() throws {
        guard OrbMetalRenderer.shared.isAvailable else { throw XCTSkip("no Metal device") }
        let inks: [(String, OrbTheme, Color?, OrbInk, Int)] = [
            ("dark", .dark, nil, .greys(isDark: true), Self.tolerance),
            ("tint", .light, Color(.sRGB, red: 0.42, green: 0.36, blue: 0.91, opacity: 1),
             .tint(SIMD4(0.42, 0.36, 0.91, 1)), 8),
            ("faint tint", .light, Color(.sRGB, red: 0.95, green: 0.55, blue: 0.2, opacity: 0.6),
             .tint(SIMD4(0.95, 0.55, 0.2, 0.6)), 8),
        ]
        for (inkName, theme, tint, ink, limit) in inks {
            var worst = 0
            var over2 = 0
            var total = 0
            for state in OrbState.allCases {
                for (size, side) in Self.sizes {
                    let scale: CGFloat = 3
                    let time = 2.5
                    let pixels = Int((side * scale).rounded())
                    let name = "\(inkName) \(state.rawValue)-\(size.rawValue)@\(Int(side))pt"
                    let metal = try XCTUnwrap(
                        OrbMetalRenderer.shared.renderBitmap(state: state, size: size, time: time, pixels: pixels, ink: ink),
                        "Metal render failed: \(name)")
                    let canvas = try XCTUnwrap(
                        Self.canvas(state: state, size: size, side: side, scale: scale, time: time, theme: theme, tint: tint),
                        "Canvas render failed: \(name)")
                    var difference = 0
                    for pixel in 0..<(pixels * pixels) {
                        var here = 0
                        for channel in 0..<4 {
                            here = max(here, abs(Int(metal[pixel * 4 + channel]) - Int(canvas[pixel * 4 + channel])))
                        }
                        difference = max(difference, here)
                        if here > 2 { over2 += 1 }
                    }
                    total += pixels * pixels
                    worst = max(worst, difference)
                    XCTAssertLessThanOrEqual(difference, limit, "\(name): a channel is \(difference) of 255 apart")
                }
            }
            print(String(format: "Metal against the Canvas in the %@ ink: the worst channel is %d of 255 apart, %.4f%% of pixels more than 2",
                         inkName, worst, 100 * Double(over2) / Double(max(total, 1))))
        }
    }

    /// The tinted inks draw through the same pipeline; this pins their arithmetic.
    func testInkColours() {
        let grey = OrbInk.greys(isDark: false).color(white: 0.5, alpha: 0.5)
        XCTAssertEqual(grey.w, 0.5, accuracy: 1e-6)
        XCTAssertEqual(grey.x, Float(128.0 / 255) * 0.5, accuracy: 1e-6)
        let dark = OrbInk.greys(isDark: true).color(white: 0.2, alpha: 1)
        XCTAssertEqual(dark.x, Float(204.0 / 255), accuracy: 1e-6)
        // A tint is the colour at the strength the grey would have on paper…
        let tint = OrbInk.tint(SIMD4(1, 0.5, 0, 1)).color(white: 0.25, alpha: 0.8)
        XCTAssertEqual(tint.w, 0.6, accuracy: 1e-6)
        XCTAssertEqual(tint.y, 0.3, accuracy: 1e-6)
        // …and a mask is the colour at the mark's own alpha, whatever its grey.
        let mask = OrbInk.mask(SIMD4(1, 1, 1, 1)).color(white: 0.9, alpha: 0.8)
        XCTAssertEqual(mask.w, 0.8, accuracy: 1e-6)
    }

    // MARK: Renders

    /// The Canvas's frame as premultiplied BGRA bytes, top row first: the Metal read-back's layout.
    @MainActor
    private static func canvas(state: OrbState, size: OrbSize, side: Double, scale: CGFloat, time: Double,
                               theme: OrbTheme = .light, tint: Color? = nil) -> [UInt8]? {
        let pixels = Int((side * scale).rounded())
        let content = ThinkingOrb(state: state, size: size, theme: theme, displaySize: side, tint: tint)
            .orbFrozenTime(time)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.isOpaque = false
        renderer.proposedSize = ProposedViewSize(width: side, height: side)
        guard let image = renderer.cgImage, image.width == pixels, image.height == pixels else { return nil }
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: pixels, height: pixels, bitsPerComponent: 8,
                                          bytesPerRow: pixels * 4, space: sRGB, bitmapInfo: bitmapInfo) else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            return true
        }
        return drawn ? bytes : nil
    }

    private static func png(_ bytes: [UInt8], pixels: Int) -> Data? {
        var copy = bytes
        let image: CGImage? = copy.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: pixels, height: pixels, bitsPerComponent: 8,
                      bytesPerRow: pixels * 4, space: sRGB, bitmapInfo: bitmapInfo)?.makeImage()
        }
        guard let image else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
#endif
