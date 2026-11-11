import SwiftUI

struct XY: Codable, Equatable { var x: Double; var y: Double }

/// HSV (v = 1) <-> Hue xy, via sRGB -> linear -> XYZ (Wide gamut D65 matrix from the Hue docs).
enum HueColor {
    private static func lin(_ c: Double) -> Double { c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92 }
    private static func gam(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    static func xy(h: Double, s: Double) -> XY {
        func f(_ n: Double) -> Double { let k = (n + h * 6).truncatingRemainder(dividingBy: 6); return lin(1 - s * max(0, min(k, 4 - k, 1))) }
        let (r, g, b) = (f(5), f(3), f(1))
        let X = r * 0.664511 + g * 0.154324 + b * 0.162028
        let Y = r * 0.283881 + g * 0.668433 + b * 0.047685
        let Z = r * 0.000088 + g * 0.072310 + b * 0.986039
        let sum = X + Y + Z
        guard sum.isFinite, sum > 0 else { return XY(x: 0.3127, y: 0.3290) }   // D65 white
        return XY(x: X / sum, y: Y / sum)
    }

    /// Display colour of an xy point: gamma sRGB normalised so the brightest channel is 1.
    static func rgb(_ p: XY) -> RGB {
        guard p.x.isFinite, p.y.isFinite, p.y > 0 else { return RGB(r: 1, g: 1, b: 1) }
        let X = p.x / p.y, Y = 1.0, Z = (1 - p.x - p.y) / p.y
        var r = X * 1.656492 - Y * 0.354851 - Z * 0.255038
        var g = -X * 0.707196 + Y * 1.655397 + Z * 0.036152
        var b = X * 0.051713 - Y * 0.121364 + Z * 1.011530
        (r, g, b) = (max(r, 0), max(g, 0), max(b, 0))
        let m = max(r, g, b)
        guard m > 0 else { return RGB(r: 1, g: 1, b: 1) }
        return RGB(r: gam(r / m), g: gam(g / m), b: gam(b / m))
    }

    /// White temperature, t: 0 = cool bluish white, 1 = warm amber.
    static func white(_ t: Double) -> RGB { RGB(r: 0.7 + 0.3 * t, g: 0.85 - 0.2 * t, b: 1 - 0.7 * t) }

    static func hs(_ p: XY) -> (h: Double, s: Double) {
        let c = rgb(p), (r, g, b) = (c.r, c.g, c.b)
        let hi = max(r, g, b), lo = min(r, g, b), d = hi - lo
        guard d > 0 else { return (0, 0) }
        var h = r == hi ? (g - b) / d : g == hi ? 2 + (b - r) / d : 4 + (r - g) / d
        h = (h / 6).truncatingRemainder(dividingBy: 1)
        return (h < 0 ? h + 1 : h, d / hi)
    }
}

struct RGB: Equatable {
    static let warm = RGB(hex: 0xF3C77A)
    var r: Double, g: Double, b: Double
    var color: Color { Color(red: r, green: g, blue: b) }
    init(r: Double, g: Double, b: Double) { (self.r, self.g, self.b) = (r, g, b) }
    init(hex: UInt32) { self.init(r: Double(hex >> 16 & 255) / 255, g: Double(hex >> 8 & 255) / 255, b: Double(hex & 255) / 255) }
    static func average(_ l: [RGB]) -> RGB? {
        guard !l.isEmpty else { return nil }
        let n = Double(l.count)
        return RGB(r: l.map(\.r).reduce(0, +) / n, g: l.map(\.g).reduce(0, +) / n, b: l.map(\.b).reduce(0, +) / n)
    }
}

extension Light {
    /// What the light looks like right now (the bridge reports xy even in colour-temperature mode).
    var rgb: RGB {
        if let c = color { return HueColor.rgb(c.xy) }
        return HueColor.white(color_temperature?.t ?? 0.5)
    }
}
