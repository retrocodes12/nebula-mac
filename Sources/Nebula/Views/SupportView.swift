import SwiftUI
import NebulaCore

/// The mark by a supporter's name — the same four the other Nebula apps draw.
struct SupporterMark: View {
    let mark: String
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: SupporterMark.symbol(mark))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Theme.gold)
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

extension Theme {
    /// The supporters' gold: the mark, and a Founder's ring.
    static let gold = Color(hex: "#E0B24A")
}

extension View {
    /// A Founder's avatar wears a gold ring, 2 points outside the circle (the web's `.pav.founder`, Android's
    /// `Avatar(ring:)`).
    func founderRing(_ on: Bool) -> some View {
        overlay(Circle().strokeBorder(Theme.gold, lineWidth: 2).padding(-2).opacity(on ? 1 : 0))
    }
}

/// Support Nebula — the one place money is mentioned. Nebula stays free, with no ads and no
/// account needed; what a supporter gets is a mark by their name, three more accents and (if
/// they like) their name on the wall. Hidden until the server names somewhere to send people,
/// unless this profile already supports.
struct SupportPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.nebulaAccent) private var accent
    @State private var code = ""
    @State private var note: String?
    @State private var busy = false
    @State private var vote: SupportVote?
    @State private var voteBusy = false
    @State private var voteLine: String?
    /// The month the recap shows (nil = this one).
    @State private var recapMonth: String?

    private var rank: Int { model.profile?.rank ?? 0 }

    var body: some View {
        Panel {
            if let p = model.profile, p.supporter { supporter(p); Hairline() }
            if let v = vote, v.round != nil || rank >= 2 || v.last?.winner != nil { voteBlock(v); Hairline() }
            if rank >= 2 { recap; Hairline() }
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
        // `mine` and `can` are the profile's: asked again when it signs in, out or changes
        .task(id: model.profile?.handle ?? "") { vote = await model.cloud.loadVote() ?? vote }
        .onReceive(NotificationCenter.default.publisher(for: SupportPanel.shotsVote)) { n in
            if let v = n.object as? SupportVote { vote = v }
        }
    }

    // MARK: the screenshot rig (a scratch store only)

    /// The rig hands the panel a vote in progress, so the ballot can be looked at with no round open on the cloud.
    static let shotsVote = Notification.Name("nebula.shots.supportVote")

    /// A Founder on this device, a month of watching and a vote with one's own ballot in — what the perks look like.
    /// Nothing reaches the cloud: the profile is set on the model only, and the store is the rig's scratch one.
    static func plantForShots(_ m: AppModel) {
        let now = m.watchLog.nowKey(), today = max(1, Calendar.current.component(.day, from: Date()))
        var d: JSONObject = [:]
        for (title, day, secs) in [("The Bear", today, 7_400), ("Arabic Live", 1, 5_100), ("Sintel", today, 2_900), ("Tears of Steel", 1, 1_300)] {
            WatchLog.add(&d, month: now, day: day, title: title, secs: secs)
        }
        WatchLog.add(&d, month: WatchLog.prevMonth(now), day: 12, title: "Big Buck Bunny", secs: 4_000)
        m.store.setObject(WatchLog.key, d)
        var p = Profile(handle: "nebula_shots", name: "Sam", avatar: "#0A84FF", supporter: true)
        p.tier = "founder"; p.mark = "crown"; p.since = nowMs() - 40 * 86_400_000; p.wall = true
        m.profile = p
        m.setAccent("#B08CFF")
        let round = SupportVote.Round(id: "r1", title: "What should Nebula build next?", closes: nowMs() + 12 * 86_400_000, options: [
            .init(id: "o1", title: "Watch parties on Mac and iPhone", note: "Watch together, in sync, with the TV and the web.", votes: 5),
            .init(id: "o2", title: "Downloads for the road", note: "", votes: 8),
            .init(id: "o3", title: "Picture in picture", note: "Keep a game playing in a corner.", votes: 1),
        ], voters: 14)
        // after the panel's own question to the cloud for the planted profile has come back
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            NotificationCenter.default.post(name: shotsVote, object: SupportVote(round: round, mine: "o2", can: true, last: nil))
        }
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
            if p.rank == 1 {
                Text("Supporter Plus or the monthly plan add any accent colour, your own mark, a vote on what gets built next and a private recap of your month.")
                    .scaledFont(size: 12.5).foregroundStyle(Theme.label2).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: Binding(get: { p.wall }, set: { set(wall: $0) })) {
                Text("Show my name on the supporters’ wall").scaledFont(size: 13).foregroundStyle(Theme.ink)
            }
            .toggleStyle(.switch).controlSize(.small)
        }
        .padding(16)
    }

    // MARK: the vote on what gets built next

    private func voteBlock(_ v: SupportVote) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Vote on what’s next")
            if let r = v.round {
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.title).scaledFont(size: 16, weight: .semibold).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    Text(SupportPanel.closesLine(r, voted: v.voted)).scaledFont(size: 12, design: .monospaced).foregroundStyle(Theme.label3)
                }
                let shares = v.voted ? SupportVote.shares(r.options.map { $0.votes ?? 0 }) : []
                VStack(spacing: 6) {
                    ForEach(Array(r.options.enumerated()), id: \.element.id) { i, o in
                        voteRow(o, mine: v.mine == o.id, share: i < shares.count ? shares[i] : nil, enabled: v.can && !voteBusy)
                    }
                }
                Text(SupportPanel.voteFoot(v, r)).scaledFont(size: 12.5).foregroundStyle(Theme.label2).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No vote open right now — the next one shows up here.").scaledFont(size: 13).foregroundStyle(Theme.label2)
                if let w = v.last?.winner {
                    Text("Last time, supporters chose \(w).").scaledFont(size: 13).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let l = voteLine { Text(l).scaledFont(size: 12.5).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(16)
    }

    /// One option: the ballot mark, the title and its note; after one's own ballot, its share as a figure and a bar.
    private func voteRow(_ o: SupportVote.Option, mine: Bool, share: Int?, enabled: Bool) -> some View {
        Button(action: { cast(o.id) }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().strokeBorder(Theme.label3, lineWidth: 1.5).opacity(mine ? 0 : 1)
                        if mine {
                            Circle().fill(accent)
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(accent.readableInk)
                        }
                    }
                    .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(o.title).scaledFont(size: 14, weight: .semibold).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                        if !o.note.isEmpty { Text(o.note).scaledFont(size: 12).foregroundStyle(Theme.label2).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer(minLength: 8)
                    if let sh = share { Text("\(sh)%").scaledFont(size: 12.5, weight: .medium, design: .monospaced).foregroundStyle(mine ? Theme.ink : Theme.label2) }
                }
                if let sh = share {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.line)
                            Capsule().fill(mine ? accent : Theme.label3).frame(width: g.size.width * CGFloat(sh) / 100)
                        }
                    }
                    .frame(height: 3).padding(.leading, 32)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(mine ? Theme.surface2 : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(o.title + (mine ? ", your vote" : "") + (share.map { ", \($0) percent" } ?? ""))
    }

    private func cast(_ id: String) {
        guard !voteBusy, vote?.mine != id else { return }
        voteBusy = true; voteLine = nil
        Task {
            let (next, err) = await model.cloud.castVote(id)
            voteBusy = false
            if let n = next { vote = n; model.say("Your vote is in — you can change it until the vote closes.") }
            if let e = err { voteLine = e; vote = await model.cloud.loadVote() ?? vote }
        }
    }

    static func closesLine(_ r: SupportVote.Round, voted: Bool) -> String {
        var line = r.closes > 0 ? "Closes " + day(r.closes, template: "d MMM") : ""
        if voted, let n = r.voters { line += (line.isEmpty ? "" : " · ") + "\(n) vote\(n == 1 ? "" : "s") so far" }
        return line
    }

    static func voteFoot(_ v: SupportVote, _ r: SupportVote.Round) -> String {
        if !v.can { return "The vote is for Supporter Plus, Founders and Monthly supporters." }
        if let t = r.options.first(where: { $0.id == v.mine })?.title { return "You voted for \(t). Pick another to change it while the vote is open." }
        return "Pick one. You can change it until the vote closes; the counts show once you have voted."
    }

    // MARK: your month on Nebula

    /// This device's month — worked out here from what it played, and never sent anywhere (WatchLog).
    private var recap: some View {
        let _ = model.watchLogVersion
        let months = model.watchLog.monthsShown()
        let now = months.first ?? model.watchLog.nowKey()
        let pick = recapMonth.flatMap { months.contains($0) ? $0 : nil } ?? now
        let r = model.watchLog.recap(pick)
        return VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Your month")
            Text("Your \(WatchLog.monthName(pick)) on Nebula").scaledFont(size: 16, weight: .semibold).foregroundStyle(Theme.ink)
            if months.count > 1 {
                HStack(spacing: 6) { ForEach(months, id: \.self) { m in Chip(text: WatchLog.monthShort(m), on: m == pick) { recapMonth = m } } }
            }
            if r.empty {
                Text(pick == now ? "Nothing watched yet this month — it fills in as you watch." : "Nothing watched in \(WatchLog.monthName(pick)).")
                    .scaledFont(size: 13).foregroundStyle(Theme.label2)
            } else {
                let h = WatchLog.hoursStat(r.total)
                HStack(alignment: .top, spacing: 16) {
                    stat(h.value, h.label)
                    stat("\(r.days)", r.days == 1 ? "day you watched" : "days you watched")
                    if r.busiestDay > 0 { stat(WatchLog.dayLabel(pick, r.busiestDay), "busiest day · " + WatchLog.length(r.busiestSecs)) }
                }
                if !r.top.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(r.top.enumerated()), id: \.offset) { i, t in
                            HStack(spacing: 10) {
                                Text("\(i + 1)").scaledFont(size: 12, design: .monospaced).foregroundStyle(Theme.label3).frame(width: 16, alignment: .leading)
                                Text(t.name).scaledFont(size: 13.5, weight: .medium).foregroundStyle(Theme.ink).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(WatchLog.length(t.secs)).scaledFont(size: 12, design: .monospaced).foregroundStyle(Theme.label2)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            Text("Worked out on this \(Platform.deviceWord) from what it played — never sent anywhere.")
                .scaledFont(size: 12).foregroundStyle(Theme.label3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .id("recap")
    }

    /// One figure: the number large, what it counts under it.
    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).scaledFont(size: 24, weight: .bold).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).scaledFont(size: 11.5).foregroundStyle(Theme.label2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    static func day(_ ms: Int64, template: String = "d MMM yyyy") -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
