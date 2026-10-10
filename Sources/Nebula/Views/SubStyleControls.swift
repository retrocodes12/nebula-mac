import SwiftUI
import NebulaCore

/// The subtitle look, one row per choice with ‹ › to step through its values — in the player's
/// Subtitles panel and in Settings. The look is the profile's (`sub_style`), so a choice here
/// shows on the TV and the phone as well.
struct SubStyleControls: View {
    @EnvironmentObject var model: AppModel
    /// Drawn on the player's dark glass (white text) or on a Settings panel.
    var onGlass = false

    var body: some View {
        let _ = model.subStyleVersion
        let style = model.prefs.subStyle
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SubStyle.order, id: \.self) { k in
                HStack(spacing: 8) {
                    Text(SubStyle.labels[k] ?? k).scaledFont(size: 13).foregroundStyle(onGlass ? .white.opacity(0.7) : Theme.label2)
                    Spacer(minLength: 8)
                    stepButton("chevron.left", "Previous \(SubStyle.labels[k] ?? k)") { step(k, style, -1) }
                    Text(SubStyle.label(style[k] ?? "")).scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(onGlass ? .white : Theme.ink).frame(minWidth: 92)
                    stepButton("chevron.right", "Next \(SubStyle.labels[k] ?? k)") { step(k, style, 1) }
                }
                .padding(.horizontal, 12).frame(minHeight: 32)
            }
            HStack {
                Spacer()
                Button("Reset to the defaults") { model.setSubStyle(nil) }
                    .buttonStyle(.plain).scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(onGlass ? .white.opacity(0.7) : Theme.label2)
                    .touchArea()
            }
            .padding(.horizontal, 12).padding(.top, 4)
        }
    }

    private func step(_ k: String, _ style: [String: String], _ d: Int) {
        var s = style
        s[k] = SubStyle.step(k, from: style[k] ?? "", by: d)
        model.setSubStyle(s)
    }

    private func stepButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
                .foregroundStyle(onGlass ? .white : Theme.ink)
                .frame(width: 26, height: 26)
                .background(Circle().fill(onGlass ? Color.white.opacity(0.12) : Theme.surface2))
                .contentShape(Circle())
                .touchArea()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Subtitles later or earlier, for this play: − / the offset / + / back in step.
struct SubTimingControls: View {
    @ObservedObject var extras: PlayerExtras
    let mpv: MPVController
    var onGlass = false

    var body: some View {
        HStack(spacing: 8) {
            Text("Timing").scaledFont(size: 13).foregroundStyle(onGlass ? .white.opacity(0.7) : Theme.label2)
            Spacer(minLength: 8)
            nudge("minus", "Subtitles earlier") { extras.nudgeSubs(-0.5, mpv) }
            Button(PlayerExtras.delayText(extras.subDelay)) { extras.resetSubs(mpv) }
                .buttonStyle(.plain)
                .scaledFont(size: 12.5, weight: .semibold, design: .monospaced)
                .foregroundStyle(onGlass ? .white : Theme.ink)
                .frame(minWidth: 104)
                .accessibilityHint("Puts the subtitles back in step")
            nudge("plus", "Subtitles later") { extras.nudgeSubs(0.5, mpv) }
        }
        .padding(.horizontal, 12).frame(minHeight: 34)
    }

    private func nudge(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
                .foregroundStyle(onGlass ? .white : Theme.ink)
                .frame(width: 26, height: 26)
                .background(Circle().fill(onGlass ? Color.white.opacity(0.12) : Theme.surface2))
                .contentShape(Circle())
                .touchArea()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
