import SwiftUI
import AppKit
import NebulaCore

/// Where to watch it from: one section per add-on, each row led by its resolution plate.
struct StreamsView: View {
    @EnvironmentObject var model: AppModel
    @State var target: StreamsTarget
    @State private var sections: [StreamSection] = []
    @State private var loading = true
    @State private var asked = 0
    @State private var filter: String?
    @State private var fresh = false

    init(target: StreamsTarget) { _target = State(initialValue: target) }

    private var resumeAt: Double { model.progress.resumeAt(target.type, target.id) }
    private var total: Int { sections.reduce(0) { $0 + $1.streams.count } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 26) {
                    if sections.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                Chip(text: "All · \(total)", on: filter == nil) { filter = nil }
                                ForEach(sections) { s in Chip(text: "\(s.addon.name) · \(s.streams.count)", on: filter == s.id) { filter = s.id } }
                            }
                        }
                    }
                    ForEach(order(sections).filter { filter == nil || filter == $0.id }) { s in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(s.addon.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                                Text("\(s.streams.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.label3)
                            }
                            VStack(spacing: 6) {
                                ForEach(Array(s.streams.enumerated()), id: \.offset) { _, st in
                                    StreamRow(stream: st, addonName: s.addon.name) { model.play(st, target: target, from: s.addon, fresh: fresh) }
                                }
                            }
                        }
                    }
                    if loading {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Asking your add-ons…").font(.system(size: 13)).foregroundStyle(Theme.label2) }
                    } else if sections.isEmpty {
                        EmptyState(icon: "play.slash", title: "No streams for this",
                                   detail: asked == 0 ? "None of your add-ons offers streams for this kind of title. Add one that does in Add-ons."
                                                       : "\(asked) add-on\(asked == 1 ? "" : "s") answered, and none had a stream for it.")
                    }
                }
                .padding(.horizontal, Theme.pad).padding(.top, 8).padding(.bottom, 50)
            }
        }
        .background(Theme.bg)
        .overlay(alignment: .topLeading) { BackButton().padding(.leading, 22).padding(.top, 44) }
        .task {
            await hydrate()
            asked = await model.loadStreams(target) { s in sections.append(s) }
            loading = false
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: target.episode?.thumbnail ?? Art.backdrop(target.item)) { Theme.bg }
                .frame(maxWidth: .infinity).frame(height: 300).clipped().opacity(0.55)
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Theme.bg, location: 1)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                if let k = Ids.episodeKicker(target.id) { Eyebrow(k) }
                Text(target.episode?.name ?? target.item.name).font(.system(size: 30, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                if target.episode != nil { Text(target.item.name).font(.system(size: 14)).foregroundStyle(Theme.label2) }
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
        .frame(height: 300)
    }

    /// The add-on the title came from leads; the rest keep the viewer's own ranking.
    private func order(_ s: [StreamSection]) -> [StreamSection] {
        let rank = Dictionary(uniqueKeysWithValues: model.addons.enumerated().map { ($1.manifestUrl, $0) })
        return s.sorted { a, b in
            if (a.id == target.addonUrl) != (b.id == target.addonUrl) { return a.id == target.addonUrl }
            return (rank[a.id] ?? 999) < (rank[b.id] ?? 999)
        }
    }

    /// Opened from Continue watching there is only an episode id: fetch the series so the header
    /// can name the episode and the player knows what comes next.
    private func hydrate() async {
        guard target.episode == nil, target.id != target.item.id else { return }
        guard let (m, _) = await model.loadMeta(target.item, addonUrl: target.addonUrl) else { return }
        target.videos = m.videos
        target.episode = m.videos.first { $0.id == target.id }
        if target.item.background == nil { target.item.background = m.background }
        if target.item.poster == nil { target.item.poster = m.poster }
    }
}

struct StreamRow: View {
    let stream: StreamItem
    let addonName: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let raw = stream.name + "\n" + stream.title + "\n" + stream.fileName
        let plate = StreamBadges.plate(raw)
        let match = StreamBadges.match(raw)
        let facts = StreamBadges.facts(videoSize: stream.videoSize, text: stream.title, fired: [])
        let name = StreamBadges.cleanName(stream.name, addonName: addonName)
        Button(action: action) {
            HStack(spacing: 16) {
                VStack(spacing: 1) {
                    Text(plate?.res ?? "—").font(.system(size: 17, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink)
                    if let t = plate?.tag, !t.isEmpty { Text(t).font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(0.8).foregroundStyle(Theme.label3) }
                }
                .frame(width: 64, height: 48)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))

                VStack(alignment: .leading, spacing: 4) {
                    Text(name.isEmpty ? (facts.desc.isEmpty ? "Stream" : facts.desc) : name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    if !name.isEmpty && !facts.desc.isEmpty { Text(facts.desc).font(.system(size: 12)).foregroundStyle(Theme.label2).lineLimit(2) }
                    if !facts.line.isEmpty { Text(facts.line).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.label3).lineLimit(1) }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    ForEach(match.badges, id: \.self) { BadgeImage(file: $0) }
                }
                Image(systemName: "play.fill").font(.system(size: 12)).foregroundStyle(hover ? Theme.ink : Theme.label3)
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
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(stream.url, forType: .string)
            }
        }
    }
}

/// Badge art shared with the other Nebula clients, carried in the app's resources.
struct BadgeImage: View {
    let file: String
    static var cache: [String: NSImage] = [:]

    var body: some View {
        if let img = BadgeImage.load(file) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(height: 18).frame(maxWidth: 64)
        }
    }

    static func load(_ file: String) -> NSImage? {
        if let c = cache[file] { return c }
        // in the app the art sits in Contents/Resources/badges; SwiftPM's own resource bundle is
        // looked for at the .app's root, where nothing may live once the app is signed
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("badges"),
              let img = NSImage(contentsOf: dir.appendingPathComponent(file)) else { return nil }
        cache[file] = img
        return img
    }
}
