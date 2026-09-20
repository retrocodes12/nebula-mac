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
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct TimePill: View {
    let text: String
    var live = false
    var body: some View {
        HStack(spacing: 6) {
            if live { Circle().fill(Theme.danger).frame(width: 7, height: 7) }
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
    @State private var held = false
    @State private var hoverX: CGFloat?

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
                if let x = hoverX, !held, duration > 0 {
                    Text(Fmt.clock(Double(x / w) * duration))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(.ultraThinMaterial, in: Capsule()).environment(\.colorScheme, .dark)
                        .fixedSize().offset(x: min(max(0, x - 26), w - 52), y: -26)
                }
            }
            .frame(height: held ? 10 : 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in held = true; onDrag(Double(min(max(0, g.location.x / w), 1)) * duration) }
                .onEnded { g in held = false; onCommit(Double(min(max(0, g.location.x / w), 1)) * duration) })
            .onContinuousHover { phase in
                if case .active(let p) = phase { hoverX = p.x } else { hoverX = nil }
            }
            .animation(.easeOut(duration: 0.12), value: held)
        }
        .frame(height: 26)
    }
}
