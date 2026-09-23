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
    /// Art as wide as the page and exactly `height` tall, filled and cropped. The art is an
    /// overlay on a clear box, so its size never reaches the layout: a filled 16:9 backdrop
    /// asks for its own width (≈ 924 points at 520 tall), and as a ZStack's child it widened the
    /// whole hero to that, laying the synopsis out wider than a phone or a narrow window.
    static func backdrop<Art: View>(height: CGFloat, @ViewBuilder _ art: () -> Art) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay { art() }
            .clipped()
    }

    /// How tall the full-bleed art is: the window's, and a phone's that leaves room for a row.
    #if os(iOS)
    static let heroHeight: CGFloat = 420
    static let detailHeight: CGFloat = 400
    #else
    static let heroHeight: CGFloat = 520
    static let detailHeight: CGFloat = 480
    #endif

    /// A window caps a reading column at a comfortable width. A phone is narrower than any of
    /// those caps already, so there it means "fill what there is".
    static func cap(_ points: CGFloat) -> CGFloat {
        #if os(iOS)
        return .infinity
        #else
        return points
        #endif
    }

    /// Where a pushed page's Back button sits: just under a phone's status bar, and clear of a
    /// window's traffic lights. Measured from the top of the page's frame, which on a phone is
    /// the status bar's foot even when the page's art runs up under it — an overlay is laid out
    /// in the frame the page was given, not in the one its art took.
    static var backTop: CGFloat {
        #if os(iOS)
        return 6
        #else
        return 44
        #endif
    }

    /// Where a pushed page with no art starts its title: below the Back button.
    #if os(iOS)
    static let pushedTitleTop: CGFloat = 58
    #else
    static let pushedTitleTop: CGFloat = 92
    #endif
}

/// How far a page's title art runs up under a phone's status bar — the phone shell measures it
/// and hands it down; everywhere else it is 0 and nothing moves.
private struct TopBleedKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    var topBleed: CGFloat {
        get { self[TopBleedKey.self] }
        set { self[TopBleedKey.self] = newValue }
    }
}

/// The app's type. Sizes are the design's points; on a phone they grow and shrink with the
/// reader's own text size (Dynamic Type), in step with body text. A Mac has no such setting and
/// keeps exactly the sizes it was drawn at.
struct ScaledFont: ViewModifier {
    #if os(iOS)
    @ScaledMetric private var size: CGFloat
    #else
    private let size: CGFloat
    #endif
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        #if os(iOS)
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
        #else
        self.size = size
        #endif
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

/// A row of chips or pills that scrolls sideways. It runs out to the page's edges instead of
/// stopping at its margin — where a row cut off mid-word ("GENRE All g") looked broken — fades
/// there, and still starts its first chip on the margin. Used inside a column padded by
/// `Theme.pad`, which it reaches back out through.
struct EdgeScroller<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) { content }
                .padding(.horizontal, Theme.pad)
        }
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: Theme.pad * 0.75)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: max(Theme.pad, 28))
            }
        }
        .padding(.horizontal, -Theme.pad)
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

extension View {
    /// The system face at `size` points, scaled with the reader's text size on a phone.
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }

    /// A page whose title art runs edge to edge up under a phone's status bar, the way the
    /// system's own apps draw theirs. Nothing on a Mac, whose window already starts at the top.
    @ViewBuilder func bleedsUnderStatusBar() -> some View {
        #if os(iOS)
        self.ignoresSafeArea(edges: .top)
        #else
        self
        #endif
    }

    /// On a phone, at least `side` points to touch (Apple's minimum is 44), whatever size the
    /// control is drawn at. A window's pointer needs no help.
    @ViewBuilder func touchArea(_ side: CGFloat = 44) -> some View {
        #if os(iOS)
        self.frame(minWidth: side, minHeight: side).contentShape(Rectangle())
        #else
        self
        #endif
    }

    /// What a phone's keyboard should do in a field: no capitals and no autocorrect in a handle,
    /// a password, an address or a code, the URL keyboard for an address, and the password
    /// manager told which field is which.
    @ViewBuilder func entry(_ kind: EntryKind) -> some View {
        #if os(iOS)
        switch kind {
        case .handle: self.textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
        case .password: self.textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.password)
        case .newPassword: self.textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.newPassword)
        case .address: self.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).textContentType(.URL)
        case .code: self.textInputAutocapitalization(.characters).autocorrectionDisabled()
        }
        #else
        self
        #endif
    }
}

enum EntryKind { case handle, password, newPassword, address, code }

/// The small monospaced line above a title: a kicker, a count, a label.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .scaledFont(size: 11, weight: .medium, design: .monospaced)
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
                .scaledFont(size: 14, weight: .semibold)
                // a pill never wraps: at a large text size "Watch" broke into "Watc / h"
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 22)
                .padding(.vertical, 8).frame(minHeight: 40)     // grows with a larger text size
                .foregroundStyle(filled ? accent.readableInk : Theme.ink)
                .background(Capsule().fill(filled ? accent : Theme.surface2))
                .overlay(Capsule().strokeBorder(filled ? Color.clear : Theme.line))
                .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
                .contentShape(Capsule())
                .touchArea()
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
                .touchArea()                                    // drawn at 40, touched at 44
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
                .scaledFont(size: 13, weight: .medium)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 6).frame(minHeight: 30)
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
                Text(title).scaledFont(size: 14, weight: .medium).foregroundStyle(Theme.ink)
                if let d = detail { Text(d).scaledFont(size: 12).foregroundStyle(Theme.label2).fixedSize(horizontal: false, vertical: true) }
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
    /// One way out of it, when there is one (Try again).
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).scaledFont(size: 30, weight: .light).foregroundStyle(Theme.label3)
            Text(title).scaledFont(size: 17, weight: .semibold).foregroundStyle(Theme.ink)
            Text(detail).scaledFont(size: 13).foregroundStyle(Theme.label2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 380)
            if let t = actionTitle, let a = action {
                Button(t, action: a).buttonStyle(PillButtonStyle(filled: false)).padding(.top, 8)
            }
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

    /// The facts line under a title ("SERIES · DRAMA · 52 min · 2022– · ★ 7.7"). A narrow page
    /// wraps it, but only between facts: inside one ("52 min", "★ 7.7") the spaces do not break,
    /// and the dot stays with the fact before it.
    static func facts(_ parts: [String]) -> String {
        parts.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: "\u{00A0}\u{00A0}·  ")
    }

    /// "1 h 12 min left", "12 min left".
    static func left(_ secs: Double) -> String {
        // the length comes off the wire; `Int(...)` of an infinite or enormous one traps
        guard secs.isFinite else { return "" }
        let m = max(1, Int((min(max(secs, 0), 10_000_000) / 60).rounded()))
        return m >= 60 ? "\(m / 60) h \(m % 60) min left" : "\(m) min left"
    }
}
