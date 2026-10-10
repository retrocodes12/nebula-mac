import Foundation

/// The subtitle look — stored as the shared player's `sub_style` document: option KEYS, not values
/// ({size: "large", color: "yellow", …}), so one synced style follows the viewer across the TV, the
/// browser, Android and here. The doc on the wire is {style: {…}, at: epoch ms}; newest wins.
/// Until a style has ever been chosen (`at` 0) the engine keeps its own look.
public enum SubStyle {
    public static let order = ["size", "color", "bg", "edge", "font", "pos", "bold"]

    public static let labels: [String: String] = [
        "size": "Size", "color": "Colour", "bg": "Background", "edge": "Edge", "font": "Font", "pos": "Position", "bold": "Bold",
    ]

    public static let valueLabels: [String: String] = [
        "off": "Off", "on": "On",
        "small": "Small", "normal": "Normal", "large": "Large", "xl": "Extra large", "huge": "Huge",
        "white": "White", "yellow": "Yellow", "cyan": "Cyan", "green": "Green",
        "dark": "Dark", "light": "Translucent", "none": "None",
        "shadow": "Shadow", "outline": "Outline",
        "sans": "Sans-serif", "serif": "Serif", "mono": "Monospace",
        "bottom": "Bottom", "raised": "Raised", "high": "High", "centre": "Centre",
    ]

    public static func options(_ k: String) -> [String] {
        switch k {
        case "size": return ["small", "normal", "large", "xl", "huge"]
        case "color": return ["white", "yellow", "cyan", "green"]
        case "bg": return ["dark", "light", "none"]
        case "edge": return ["shadow", "outline", "none"]
        case "font": return ["sans", "serif", "mono"]
        case "bold": return ["off", "on"]
        default: return ["bottom", "raised", "high", "centre"]
        }
    }

    public static let defaults: [String: String] = [
        "size": "normal", "color": "white", "bg": "dark", "edge": "shadow", "font": "sans", "pos": "bottom", "bold": "off",
    ]

    /// Every key present; an unknown value falls back to the default.
    public static func normalize(_ o: JSONObject?) -> [String: String] {
        var out: [String: String] = [:]
        for k in order {
            let v = o?[k] as? String ?? ""
            out[k] = options(k).contains(v) ? v : defaults[k]!
        }
        return out
    }

    public static func label(_ v: String) -> String { valueLabels[v] ?? v }

    /// The value after (or before) `current` for a key, wrapping round.
    public static func step(_ k: String, from current: String, by d: Int = 1) -> String {
        let o = options(k)
        let i = o.firstIndex(of: current) ?? 0
        return o[((i + d) % o.count + o.count) % o.count]
    }

    static let sizes: [String: Double] = ["small": 0.75, "normal": 1, "large": 1.3, "xl": 1.65, "huge": 2]
    static let colors: [String: String] = ["white": "#FFFFFF", "yellow": "#FFE600", "cyan": "#62F0FF", "green": "#7DFF8A"]
    // the engine writes colours #AARRGGBB
    static let backs: [String: String] = ["dark": "#CC000000", "light": "#73000000"]
    static let fonts: [String: String] = ["sans": "Helvetica Neue", "serif": "Times New Roman", "mono": "Menlo"]
    /// The engine's `sub-pos`: 100 = the bottom edge, 0 = the top.
    static let positions: [String: String] = ["bottom": "100", "raised": "92", "high": "82", "centre": "55"]

    /// What the engine is told, in order. Text an add-on or the file sends without a style of its
    /// own takes these; a styled ASS track keeps its own typesetting.
    public static func engineProperties(_ s: [String: String]) -> [(String, String)] {
        let st = normalize(s)
        let box = st["bg"] != "none"
        var p: [(String, String)] = [
            ("sub-scale", String(format: "%.2f", sizes[st["size"]!] ?? 1)),
            ("sub-color", colors[st["color"]!] ?? "#FFFFFF"),
            ("sub-font", fonts[st["font"]!] ?? "Helvetica Neue"),
            ("sub-bold", st["bold"] == "on" ? "yes" : "no"),
            ("sub-pos", positions[st["pos"]!] ?? "100"),
            ("sub-border-style", box ? "background-box" : "outline-and-shadow"),
        ]
        if box { p.append(("sub-back-color", backs[st["bg"]!]!)) }
        switch st["edge"] {
        case "outline": p += [("sub-outline-size", "2.4"), ("sub-shadow-offset", "0")]
        case "none": p += [("sub-outline-size", "0"), ("sub-shadow-offset", "0")]
        default: p += [("sub-outline-size", "0"), ("sub-shadow-offset", "2"), ("sub-shadow-color", "#B0000000")]
        }
        return p
    }
}
