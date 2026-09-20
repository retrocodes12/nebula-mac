import SwiftUI

/// Nebula's material, in Apple's idiom: flat near-black, ONE accent, hairline panels, two type
/// registers (the system face, and its monospaced cut for eyebrows and numbers), no glow.
enum Theme {
    static let bg = Color(red: 0.035, green: 0.035, blue: 0.043)
    static let surface = Color.white.opacity(0.06)
    static let surface2 = Color.white.opacity(0.10)
    static let line = Color.white.opacity(0.10)
    static let ink = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let label2 = Color.white.opacity(0.64)
    static let label3 = Color.white.opacity(0.40)
    static let ok = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)

    static let cardRadius: CGFloat = 10
    /// The page gutter. A phone has 16 points of it, a window 32.
    #if os(iOS)
    static let pad: CGFloat = 16
    #else
    static let pad: CGFloat = 32
    #endif
}

extension Theme {
    /// A window caps a reading column at a comfortable width. A phone is narrower than any of
    /// those caps already, so there it means "fill what there is".
    static func cap(_ points: CGFloat) -> CGFloat {
        #if os(iOS)
        return .infinity
        #else
        return points
        #endif
    }
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// Black on a light accent (White), white on the rest.
    var readableInk: Color {
        let c = Platform.rgb(self)
        let l = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        return l > 0.7 ? .black : .white
    }
}

/// The small monospaced line above a title: a kicker, a count, a label.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(Theme.label2)
    }
}

/// The one filled control on a page: Play, Sign in, Add.
struct PillButtonStyle: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, filled: filled)
    }

    // a nested view, because a style cannot read the environment itself
    private struct PillBody: View {
        @EnvironmentObject var model: AppModel
        @Environment(\.isEnabled) var enabled
        let configuration: ButtonStyle.Configuration
        let filled: Bool

        var body: some View {
            let accent = model.accent
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 22)
                .frame(height: 40)
                .foregroundStyle(filled ? accent.readableInk : Theme.ink)
                .background(Capsule().fill(filled ? accent : Theme.surface2))
                .overlay(Capsule().strokeBorder(filled ? Color.clear : Theme.line))
                .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
                .contentShape(Capsule())
        }
    }
}

/// A round icon button beside the pill: My List, Mark as watched.
struct RoundAction: View {
    let icon: String
    let label: String
    var on = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
                .foregroundStyle(on ? Color.black : Theme.ink)
                .background(Circle().fill(on ? Theme.ink : Theme.surface2))
                .overlay(Circle().strokeBorder(Theme.line))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A selectable capsule: a genre, a filter, a season.
struct Chip: View {
    let text: String
    var on = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .foregroundStyle(on ? Color.black : Theme.ink)
                .background(Capsule().fill(on ? Theme.ink : Theme.surface))
                .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.line))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A hairline panel — the grouped card Settings and the add-on list are built from.
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }
}

struct PanelRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
                if let d = detail { Text(d).font(.system(size: 12)).foregroundStyle(Theme.label2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 16) }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(Theme.label3)
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(detail).font(.system(size: 13)).foregroundStyle(Theme.label2).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 80)
    }
}

enum Fmt {
    /// 1:02:03 or 2:03.
    static func clock(_ secs: Double) -> String {
        guard secs.isFinite, secs >= 0 else { return "0:00" }
        let t = Int(secs.rounded(.down))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "1 h 12 min left", "12 min left".
    static func left(_ secs: Double) -> String {
        let m = max(1, Int((secs / 60).rounded()))
        return m >= 60 ? "\(m / 60) h \(m % 60) min left" : "\(m) min left"
    }
}
