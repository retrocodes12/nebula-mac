import SwiftUI
import NebulaCore

/// Where to watch it from: one section per add-on, each row led by its resolution plate.
struct StreamsView: View {
    @EnvironmentObject var model: AppModel
    @State var target: StreamsTarget
    @State private var sections: [StreamSection] = []
    @State private var loading = true
    @State private var answered = 0
    @State private var unreachable = 0
    @State private var filter: String?
    @State private var fresh = false
    /// How far the art runs up under a phone's status bar (0 on a Mac).
    @Environment(\.topBleed) private var bleed
    /// The series lookup for a page opened from Continue watching, which runs beside the streams.
    @State private var hydration: Task<Void, Never>?
    /// The row whose tap is waiting for that lookup, and the wait itself.
    @State private var waiting: String?
    @State private var waitTask: Task<Void, Never>?
    /// The page as it was pushed — what the model's stack holds for it (`target` fills in).
    private let opened: StreamsTarget

    init(target: StreamsTarget) { _target = State(initialValue: target); opened = target }

    private var resumeAt: Double { model.progress.resumeAt(target.type, target.id) }
    private var total: Int { sections.reduce(0) { $0 + $1.streams.count } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 26) {
                    // some add-ons answered and some did not: the list is not the whole story
                    if !loading && !sections.isEmpty && unreachable > 0 { partialNote }
                    if sections.count > 1 {
                        EdgeScroller {
                            Chip(text: "All · \(total)", on: filter == nil) { filter = nil }
                            ForEach(sections) { s in Chip(text: "\(s.addon.name) · \(s.streams.count)", on: filter == s.id) { filter = s.id } }
                        }
                    }
                    ForEach(order(sections).filter { filter == nil || filter == $0.id }) { s in
                        // rows line their names up behind a plate when any row in the section has one
                        let plates = s.streams.contains { StreamBadges.plate($0.name + "\n" + $0.title + "\n" + $0.fileName) != nil }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(s.addon.name).scaledFont(size: 16, weight: .semibold).foregroundStyle(Theme.ink)
                                Text("\(s.streams.count)").scaledFont(size: 12, design: .monospaced).foregroundStyle(Theme.label3)
                            }
                            VStack(spacing: 6) {
                                ForEach(Array(s.streams.enumerated()), id: \.offset) { i, st in
                                    let key = s.id + "#\(i)"
                                    StreamRow(stream: st, addonName: s.addon.name, plateSlot: plates, busy: waiting == key) { play(st, from: s.addon, key: key) }
                                }
                            }
                        }
                    }
                    if loading {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Asking your add-ons…").scaledFont(size: 13).foregroundStyle(Theme.label2) }
                    } else if sections.isEmpty {
                        if unreachable > 0 {
                            EmptyState(icon: "wifi.slash", title: "No streams for this", detail: unreachableLine,
                                       actionTitle: "Try again", action: retry)
                        } else {
                            EmptyState(icon: "play.slash", title: "No streams for this",
                                       detail: answered == 0 ? "None of your add-ons offers streams for this kind of title. Add one that does in Add-ons."
                                                             : "\(answered) add-on\(answered == 1 ? "" : "s") answered, and none had a stream for it.")
                        }
                    }
                }
                .padding(.horizontal, Theme.pad).padding(.top, 8).padding(.bottom, 50)
            }
        }
        .background(Theme.bg)
        .bleedsUnderStatusBar()
        .overlay(alignment: .topLeading) { BackButton().padding(.leading, 22).padding(.top, Theme.backTop(bleed)) }
        .onDisappear {
            // Back while a tap waited for the series: that tap is void
            waitTask?.cancel(); waitTask = nil; waiting = nil
        }
        .task {
            // the series is looked up beside the streams, not before them
            let h = Task { await hydrate() }
            hydration = h
            await withTaskCancellationHandler {
                await load()
                await h.value
            } onCancel: { h.cancel() }
        }
    }

    /// A tap plays — but opened from Continue watching, not before the series lookup is in
    /// (or three seconds have gone): without the episode list the player has no Next episode
    /// and no autoplay, and a quick tap used to start it with neither.
    private func play(_ st: StreamItem, from addon: Addon, key: String) {
        guard waiting == nil else { return }
        guard let h = hydration, needsSeries else {
            model.play(st, target: target, from: addon, fresh: fresh)
            return
        }
        waiting = key
        let here = Route.streams(opened)
        waitTask = Task {
            _ = await Patience.value(of: h, within: 3)
            if waiting == key { waiting = nil }
            // the viewer went Back, or on to another page, while it waited: not theirs to play now
            guard !Task.isCancelled, model.path.last == here, model.player == nil else { return }
            model.play(st, target: target, from: addon, fresh: fresh)
        }
    }

    /// Asks every add-on again. What came back before stays on screen while it does, and a
    /// section that answers again replaces its old self.
    private func load() async {
        loading = true
        let r = await model.loadStreams(target) { s in
            if let i = sections.firstIndex(where: { $0.id == s.id }) { sections[i] = s } else { sections.append(s) }
        }
        answered = r.answered; unreachable = r.unreachable
        loading = false
    }

    private func retry() {
        model.forgetMisses()
        Task { await load() }
    }

    /// One quiet line over the list: how many add-ons did not answer, and the way to ask again.
    private var partialNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash").scaledFont(size: 12).foregroundStyle(Theme.label3)
            Text("\(unreachable) add-on\(unreachable == 1 ? "" : "s") did not answer").scaledFont(size: 13).foregroundStyle(Theme.label2)
            Text("·").scaledFont(size: 13).foregroundStyle(Theme.label3)
            Button("Try again", action: retry)
                .buttonStyle(.plain).scaledFont(size: 13, weight: .semibold).foregroundStyle(Theme.ink)
                .touchArea()
        }
    }

    private var unreachableLine: String {
        let who = "\(unreachable) add-on\(unreachable == 1 ? "" : "s") could not be reached"
        return answered > 0 ? "\(who), and the \(answered) that answered had no stream for it. Check the connection, or try again."
                            : "\(who). Check the connection, or try again."
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Theme.backdrop(height: 300 + bleed) {
                RemoteImage(url: target.episode?.thumbnail ?? Art.backdrop(target.item)) { Theme.bg }
            }
            .opacity(0.55)
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Theme.bg, location: 1)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                if let k = Ids.episodeKicker(target.id) { Eyebrow(k) }
                Text(target.episode?.name ?? target.item.name).scaledFont(size: 30, weight: .bold).foregroundStyle(.white).lineLimit(2)
                if target.episode != nil { Text(target.item.name).scaledFont(size: 14).foregroundStyle(Theme.label2) }
                if resumeAt > 0 {
                    HStack(spacing: 8) {
                        Chip(text: "Resume from \(Fmt.clock(resumeAt))", on: !fresh) { fresh = false }
                        Chip(text: "Start over", on: fresh) { fresh = true }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, Theme.pad).padding(.bottom, 18)
        }
        .frame(height: 300 + bleed)
    }

    /// The add-on the title came from leads; the rest keep the viewer's own ranking.
    private func order(_ s: [StreamSection]) -> [StreamSection] {
        let rank = Dictionary(uniqueKeysWithValues: model.addons.enumerated().map { ($1.manifestUrl, $0) })
        return s.sorted { a, b in
            if (a.id == target.addonUrl) != (b.id == target.addonUrl) { return a.id == target.addonUrl }
            return (rank[a.id] ?? 999) < (rank[b.id] ?? 999)
        }
    }

    /// An episode id with no series around it yet.
    private var needsSeries: Bool { target.episode == nil && target.id != target.item.id }

    /// Opened from Continue watching there is only an episode id: fetch the series so the header
    /// can name the episode and the player knows what comes next.
    private func hydrate() async {
        guard needsSeries else { return }
        guard let (m, _) = await model.loadMeta(target.item, addonUrl: target.addonUrl), !Task.isCancelled else { return }
        target.videos = m.videos
        target.episode = m.videos.first { $0.id == target.id }
        if target.item.background == nil { target.item.background = m.background }
        if target.item.poster == nil { target.item.poster = m.poster }
    }
}

struct StreamRow: View {
    let stream: StreamItem
    let addonName: String
    /// Keep the plate's column when this row has none, so the names down a section line up.
    var plateSlot = true
    /// Tapped, and waiting for something before it can play.
    var busy = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let raw = stream.name + "\n" + stream.title + "\n" + stream.fileName
        let plate = StreamBadges.plate(raw)
        let match = StreamBadges.match(raw)
        // the rules that drew a badge also take their words out of the description, so a row
        // does not say "HDR · Atmos" beside the HDR and Atmos badges
        let facts = StreamBadges.facts(videoSize: stream.videoSize, text: stream.title, fired: match.fired)
        let name = StreamBadges.cleanName(stream.name, addonName: addonName)
        let desc = StreamBadges.cleanDesc(facts.desc)
        Button(action: action) {
            HStack(spacing: 16) {
                // the plate says what the resolution is; with none known there is no plate — a
                // box holding a dash said nothing and looked like a broken badge
                if let p = plate {
                    VStack(spacing: 1) {
                        Text(p.res).font(.system(size: 17, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink)
                        if !p.tag.isEmpty { Text(p.tag).font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(0.8).foregroundStyle(Theme.label3) }
                    }
                    .frame(width: 64, height: 48)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                } else if plateSlot {
                    Color.clear.frame(width: 64, height: 48)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(name.isEmpty ? (desc.isEmpty ? "Stream" : desc) : name).scaledFont(size: 14, weight: .semibold).foregroundStyle(Theme.ink).lineLimit(1)
                    if !name.isEmpty && !desc.isEmpty { Text(desc).scaledFont(size: 12).foregroundStyle(Theme.label2).lineLimit(2) }
                    if !facts.line.isEmpty { Text(facts.line).scaledFont(size: 11, design: .monospaced).foregroundStyle(Theme.label3).lineLimit(1) }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    ForEach(match.badges, id: \.self) { BadgeImage(file: $0) }
                }
                if busy { ProgressView().controlSize(.small).frame(width: 14) }
                else { Image(systemName: "play.fill").scaledFont(size: 12).foregroundStyle(hover ? Theme.ink : Theme.label3) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(hover ? Theme.surface2 : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hover ? Color.white.opacity(0.5) : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Play") { action() }
            Button("Copy the stream’s address") {
                Platform.copy(stream.url)
            }
        }
    }
}

/// Badge art shared with the other Nebula clients, carried in the app's resources.
struct BadgeImage: View {
    let file: String
    static var cache: [String: PlatformImage] = [:]

    var body: some View {
        if let img = BadgeImage.load(file) {
            Image(platform: img).resizable().aspectRatio(contentMode: .fit).frame(height: 18).frame(maxWidth: 64)
        }
    }

    static func load(_ file: String) -> PlatformImage? {
        if let c = cache[file] { return c }
        // in the app the art sits in Contents/Resources/badges; SwiftPM's own resource bundle is
        // looked for at the .app's root, where nothing may live once the app is signed
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("badges"),
              let img = Platform.image(contentsOfFile: dir.appendingPathComponent(file).path) else { return nil }
        cache[file] = img
        return img
    }
}
