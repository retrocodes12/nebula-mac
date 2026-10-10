import SwiftUI
import NebulaCore

/// The mark by a supporter's name — the same four the other Nebula apps draw.
struct SupporterMark: View {
    let mark: String
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: SupporterMark.symbol(mark))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color(hex: "#E0B24A"))
            .accessibilityLabel("Supporter")
    }

    static func symbol(_ mark: String) -> String {
        switch mark {
        case "heart": return "heart.fill"
        case "bolt": return "bolt.fill"
        case "crown": return "crown.fill"
        default: return "star.fill"
        }
    }
}

/// Support Nebula — the one place money is mentioned. Nebula stays free, with no ads and no
/// account needed; what a supporter gets is a mark by their name, three more accents and (if
/// they like) their name on the wall. Hidden until the server names somewhere to send people,
/// unless this profile already supports.
struct SupportPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var code = ""
    @State private var note: String?
    @State private var busy = false

    var body: some View {
        Panel {
            if let p = model.profile, p.supporter { supporter(p); Hairline() }
            VStack(alignment: .leading, spacing: 10) {
                Text("Nebula is free, with no ads. If it is worth something to you, a one-time or monthly contribution keeps its servers running.")
                    .scaledFont(size: 13).foregroundStyle(Theme.label2).fixedSize(horizontal: false, vertical: true)
                if model.support.url != nil {
                    Button("Support Nebula") { model.openSupport() }.buttonStyle(PillButtonStyle())
                }
            }
            .padding(16)
            if model.profile != nil {
                Hairline()
                PanelRow(title: "Have a code?", detail: note ?? "A supporter code puts the mark on this profile.") {
                    HStack(spacing: 8) {
                        TextField("NEB-XXXX-XXXX", text: $code)
                            .entry(.code)
                            .textFieldStyle(.plain).scaledFont(size: 13, weight: .semibold, design: .monospaced).multilineTextAlignment(.center)
                            .padding(.vertical, 6).frame(width: 140).frame(minHeight: 34).background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface2))
                            .onSubmit(redeem)
                        Button("Redeem", action: redeem).buttonStyle(PillButtonStyle(filled: false)).disabled(busy)
                    }
                }
            }
            if !model.support.wall.isEmpty {
                Hairline()
                wall
            }
        }
        .task { await model.loadSupport() }
    }

    private func supporter(_ p: Profile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SupporterMark(mark: p.shownMark, size: 14)
                Text(p.tierName).scaledFont(size: 15, weight: .semibold).foregroundStyle(Theme.ink)
                if p.since > 0 { Text("since \(SupportPanel.day(p.since))").scaledFont(size: 12, design: .monospaced).foregroundStyle(Theme.label3) }
            }
            if !p.planText.isEmpty {
                HStack(spacing: 8) {
                    Text("Monthly plan · \(p.planText)").scaledFont(size: 13).foregroundStyle(Theme.label2)
                    if let u = URL(string: p.planManage), !p.planManage.isEmpty {
                        Button("Manage") { Platform.open(u) }.buttonStyle(.plain).scaledFont(size: 13, weight: .semibold).foregroundStyle(Theme.ink)
                    }
                }
            }
            if p.rank >= 2 {
                HStack(spacing: 6) {
                    Text("Mark").scaledFont(size: 13).foregroundStyle(Theme.label2)
                    ForEach(Profile.marks, id: \.self) { m in
                        Button(action: { set(mark: m) }) {
                            SupporterMark(mark: m, size: 13).frame(width: 30, height: 30)
                                .background(Circle().fill(p.shownMark == m ? Theme.surface2 : .clear))
                                .overlay(Circle().strokeBorder(p.shownMark == m ? Theme.ink.opacity(0.6) : .clear))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain).help(m.capitalized)
                    }
                }
            }
            Toggle(isOn: Binding(get: { p.wall }, set: { set(wall: $0) })) {
                Text("Show my name on the supporters’ wall").scaledFont(size: 13).foregroundStyle(Theme.ink)
            }
            .toggleStyle(.switch).controlSize(.small)
        }
        .padding(16)
    }

    private var wall: some View {
        let founders = model.support.wall.filter { $0.tier == "founder" }.map(\.name)
        let others = model.support.wall.filter { $0.tier != "founder" }.map(\.name)
        return VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Thank you")
            if !founders.isEmpty { Text("Founders: " + SupportPanel.join(founders)).scaledFont(size: 13).foregroundStyle(Theme.ink) }
            if !others.isEmpty { Text(SupportPanel.join(others)).scaledFont(size: 13).foregroundStyle(Theme.label2) }
            if model.support.count > model.support.wall.count {
                Text("…and \(model.support.count - model.support.wall.count) more who stayed off the wall.").scaledFont(size: 12).foregroundStyle(Theme.label3)
            }
        }
        .padding(16)
    }

    private func redeem() {
        guard !busy else { return }
        busy = true
        Task {
            let e = await model.cloud.redeem(code)
            busy = false
            if let e = e { note = e } else { note = "Thank you — the mark is on your profile."; code = ""; await model.loadSupport() }
        }
    }

    private func set(wall: Bool? = nil, mark: String? = nil) {
        Task { if let e = await model.cloud.setSupport(wall: wall, mark: mark) { model.say(e, error: true) } else { await model.loadSupport() } }
    }

    static func join(_ l: [String]) -> String {
        l.count < 2 ? (l.first ?? "") : l.dropLast().joined(separator: ", ") + " and " + l.last!
    }

    static func day(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
