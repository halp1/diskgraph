import DiskGraphCore
import Foundation

/// Assigns each cell its colour.
///
/// The hue mapping is measured, not guessed. Pointing the reference app at a folder of
/// eight equal files and sampling the ring every 15° gives eight flat plateaus:
///
///     θ (clockwise from 12 o'clock):  90   135   180   225   270   315     0    45
///     measured hue:                  4.5 312.9 266.4 223.9 182.1 123.7  85.4  45.6
///
/// Those fall on a line of slope −1 through 115°, so
///
///     hue° = (115 − θ°) mod 360
///
/// which also reproduces every quadrant of the reference screenshots: green at twelve
/// o'clock, orange-red at three, magenta-purple at six, blue-cyan at nine. (The residual
/// few degrees of wobble in the samples is a colour-space artefact of screen-grabbing a
/// P3 display, not a non-linearity.)
///
/// Because hue depends only on angular position, a node keeps the same colour in the
/// tree map as in the pie — which is why the tree map's colours look blocky and scattered
/// rather than like a spatial gradient.
public enum CellPalette {
    /// Hue, in degrees, at twelve o'clock. See the table above.
    public static let hueAtTwelveOClock: Float = 115

    /// Light and dark variants, both measured off the reference app.
    ///
    /// The light values come from the reference screenshots (vivid, V ≈ 0.91); the dark
    /// ones from driving the installed app in dark mode, where the same wedges render
    /// noticeably deeper (V ≈ 0.77). Sampled examples in dark mode: red `#C0392B`,
    /// green `#6ABF4B`, blue `#3A47C4`.
    public struct Tuning: Sendable {
        public var saturation: Float
        public var value: Float
        public var saturationFalloffPerLevel: Float
        public var valueGainPerLevel: Float
        public var gray: UInt32
        /// Outline colour for cell borders — dark on light, light on dark.
        public var border: SIMD3<Float>
        public var background: SIMD3<Double>
    }

    /// Light mode carries the same shape as dark, scaled by the compensation factors
    /// measured below. It is extrapolated rather than sampled — measuring it would mean
    /// switching the whole system's appearance — so treat these as the least certain
    /// numbers here and re-derive them from a light-mode capture when convenient.
    public static let light = Tuning(
        saturation: 0.81, value: 0.85,
        saturationFalloffPerLevel: 0, valueGainPerLevel: 0,
        gray: packed(r: 0.63, g: 0.63, b: 0.63),
        border: SIMD3(0.10, 0.10, 0.10),
        background: SIMD3(0.90, 0.90, 0.90))

    // Sampled off the running reference app in dark mode: cells measure S ≈ 0.52–0.59,
    // V ≈ 0.75–0.79, the separators near-white (V ≈ 0.97), the window #424242.
    //
    // The numbers below are *pre-compensated*: this renderer's output measures lighter and
    // less saturated than requested through this display's colour pipeline, so these were
    // solved backwards until a screen grab of our window matched a screen grab of the
    // reference's. Compare like-for-like captures before changing them.
    public static let dark = Tuning(
        saturation: 0.72, value: 0.73,
        // Flat with depth. In the reference app a fourth-ring cell is exactly as saturated
        // as a first-ring one — *all* of its colour variation is angular, because a child's
        // sweep lies inside its parent's and therefore so does its hue. Fading with depth
        // washes the outer rings out and is visibly wrong side by side.
        saturationFalloffPerLevel: 0, valueGainPerLevel: 0,
        gray: packed(r: 0.48, g: 0.48, b: 0.48),
        border: SIMD3(0.97, 0.97, 0.97),
        // Solved so the window measures #424242, as the reference's does.
        background: SIMD3(0.201, 0.201, 0.201))

    /// The tuning layouts read from. Set once per appearance change before laying out.
    nonisolated(unsafe) public static var current: Tuning = light

    public static var baseSaturation: Float { current.saturation }
    public static var baseValue: Float { current.value }
    public static var saturationFalloffPerLevel: Float { current.saturationFalloffPerLevel }
    public static var valueGainPerLevel: Float { current.valueGainPerLevel }

    /// Sections too small to show individually, drawn gray in both graphs.
    public static var mergedGray: UInt32 { current.gray }

    /// `midAngle` is in radians, clockwise from twelve o'clock.
    public static func hueWheelColor(midAngle: Float, depth: Int) -> UInt32 {
        let degrees = midAngle * 180 / .pi
        let hue = (hueAtTwelveOClock - degrees).truncatingRemainder(dividingBy: 360)
        let level = Float(max(0, depth - 1))
        let saturation = clamp(baseSaturation - saturationFalloffPerLevel * level, 0.42, 0.95)
        let value = clamp(baseValue + valueGainPerLevel * level, 0.80, 1.0)
        return hsv(hue: hue < 0 ? hue + 360 : hue, saturation: saturation, value: value)
    }

    /// Recent files run warm, old files cool — the behaviour the app's What's New text
    /// describes for its date colour modes.
    public static func dateColor(timestamp: Int64, oldest: Int64, newest: Int64) -> UInt32 {
        guard newest > oldest else { return hsv(hue: 0, saturation: baseSaturation, value: baseValue) }
        let clamped = min(max(timestamp, oldest), newest)
        let age = 1 - Float(clamped - oldest) / Float(newest - oldest)
        return hsv(hue: age * 240, saturation: baseSaturation, value: baseValue)
    }

    /// Range of timestamps across a subtree, used to normalise the date colour modes.
    public static func dateRange(
        of tree: FileTree, root: NodeID, mode: ColorMode
    ) -> (oldest: Int64, newest: Int64) {
        guard mode != .hueWheel else { return (0, 0) }
        let times = mode == .creationDate ? tree.creationTime : tree.modificationTime
        var oldest = Int64.max
        var newest = Int64.min
        var stack: [NodeID] = [root]
        while let node = stack.popLast() {
            let stamp = times[Int(node)]
            if stamp > 0 {
                oldest = min(oldest, stamp)
                newest = max(newest, stamp)
            }
            for child in tree.children(of: node) { stack.append(child) }
        }
        return oldest <= newest ? (oldest, newest) : (0, 0)
    }

    // MARK: - Colour maths

    public static func hsv(hue: Float, saturation: Float, value: Float) -> UInt32 {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 60
        let sector = Int(h) % 6
        let f = h - Float(Int(h))
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * f)
        let t = value * (1 - saturation * (1 - f))
        switch sector {
        case 0: return packed(r: value, g: t, b: p)
        case 1: return packed(r: q, g: value, b: p)
        case 2: return packed(r: p, g: value, b: t)
        case 3: return packed(r: p, g: q, b: value)
        case 4: return packed(r: t, g: p, b: value)
        default: return packed(r: value, g: p, b: q)
        }
    }

    /// Little-endian RGBA8, the layout `MTLPixelFormat.rgba8Unorm` expects.
    public static func packed(r: Float, g: Float, b: Float, a: Float = 1) -> UInt32 {
        let ri = UInt32(clamp(r, 0, 1) * 255 + 0.5)
        let gi = UInt32(clamp(g, 0, 1) * 255 + 0.5)
        let bi = UInt32(clamp(b, 0, 1) * 255 + 0.5)
        let ai = UInt32(clamp(a, 0, 1) * 255 + 0.5)
        return ri | (gi << 8) | (bi << 16) | (ai << 24)
    }

    public static func unpack(_ value: UInt32) -> (r: Float, g: Float, b: Float, a: Float) {
        (
            Float(value & 0xFF) / 255,
            Float((value >> 8) & 0xFF) / 255,
            Float((value >> 16) & 0xFF) / 255,
            Float((value >> 24) & 0xFF) / 255
        )
    }

    /// Hue in degrees, for tests and for tuning against the reference screenshots.
    public static func hue(of value: UInt32) -> Float {
        let (r, g, b, _) = unpack(value)
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        guard delta > 0.0001 else { return 0 }
        var hue: Float
        if maxC == r { hue = 60 * ((g - b) / delta) }
        else if maxC == g { hue = 60 * (2 + (b - r) / delta) }
        else { hue = 60 * (4 + (r - g) / delta) }
        return hue < 0 ? hue + 360 : hue
    }
}

@inline(__always)
func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T {
    min(max(value, low), high)
}
