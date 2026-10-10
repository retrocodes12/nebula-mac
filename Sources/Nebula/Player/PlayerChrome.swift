import SwiftUI

/// The Apple-TV glass the player chrome is built from: the round buttons, the time pills and the
/// scrubber. Shared, because the Mac window and the phone wear the same material (§9) — only the
/// way they are laid out differs.

struct GlassCircle: View {
    let icon: String
    let label: String
    var size: CGFloat = 44
    var on = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(on ? Color.black : Color.white)
                .frame(width: size, height: size)
                .background { if on { Circle().fill(.white) } else { Circle().fill(.ultraThinMaterial) } }
                .overlay(Circle().strokeBorder(.white.opacity(0.16)))
                .environment(\.colorScheme, .dark)
                .contentShape(Circle())
                .touchArea()
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct TimePill: View {
    let text: String
    var live = false
    /// The live dot wears the app's one accent, not an alarm red of its own.
    var accent: Color = .white
    var body: some View {
        HStack(spacing: 6) {
            if live { Circle().fill(accent).frame(width: 7, height: 7) }
            Text(text).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
        }
        .padding(.horizontal, 11).frame(height: 26)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

struct Scrubber: View {
    let position: Double
    let duration: Double
    let buffered: Double
    let accent: Color
    let onDrag: (Double) -> Void
    let onCommit: (Double) -> Void
    /// A picture of the moment under the pointer or the finger (Seekr's), drawn over the time.
    var preview: ((Double) -> AnyView)? = nil
    @State private var held = false
    @State private var hoverX: CGFloat?
    @State private var dragX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = duration > 0 ? min(1, max(0, position / duration)) : 0
            let buf = duration > 0 ? min(1, max(0, buffered / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(0.28)).frame(width: w * buf)
                Capsule().fill(accent).frame(width: max(8, w * frac))
                if held || hoverX != nil {
                    Circle().fill(.white).frame(width: 16, height: 16).offset(x: w * frac - 8).shadow(color: .black.opacity(0.4), radius: 3)
                }
            }
            .frame(height: held ? 10 : 8)
            .frame(maxHeight: .infinity)
            // the tip: the time under the pointer, or under the finger while it drags (a phone has
            // no pointer, and a picture of where it is going is what a finger most needs), with
            // Seekr's picture over it. Its foot sits just above the bar, centred on the spot.
            .overlay(alignment: .bottomLeading) {
                if let x = held ? dragX : hoverX, duration > 0, w > 0 {
                    let t = Double(min(max(0, x / w), 1)) * duration
                    let half = Scrubber.tipWidth / 2
                    VStack(spacing: 6) {
                        if let p = preview { p(t) }
                        Text(Fmt.clock(t))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(.ultraThinMaterial, in: Capsule()).environment(\.colorScheme, .dark)
                    }
                    .frame(width: Scrubber.tipWidth, alignment: .bottom)
                    .offset(x: min(max(0, x - half), max(0, w - Scrubber.tipWidth)), y: -(Scrubber.band / 2 + 8))
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in held = true; dragX = g.location.x; onDrag(Double(min(max(0, g.location.x / w), 1)) * duration) }
                .onEnded { g in held = false; dragX = nil; onCommit(Double(min(max(0, g.location.x / w), 1)) * duration) })
            .onContinuousHover { phase in
                if case .active(let p) = phase { hoverX = p.x } else { hoverX = nil }
            }
            .animation(.easeOut(duration: 0.12), value: held)
        }
        .frame(height: Scrubber.band)
    }

    /// The time tip's column (a Seekr picture is drawn 176 points wide in it).
    static let tipWidth: CGFloat = 184

    /// The band a finger or the pointer grabs; the bar drawn in it stays 8 points. A phone needs
    /// Apple's 44 to hit it at all; a pointer does with 26.
    #if os(iOS)
    static let band: CGFloat = 44
    #else
    static let band: CGFloat = 26
    #endif
}
