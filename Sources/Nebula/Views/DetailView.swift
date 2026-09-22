import SwiftUI
import NebulaCore

/// The title page: art edge to edge dissolving into the page, the facts, one Play pill and its
/// round companions, then — for a series — seasons and episodes inline.
struct DetailView: View {
    @EnvironmentObject var model: AppModel
    let item: MetaItem
    let addonUrl: String
    @State private var meta: FullMeta?
    @State private var metaAddon: Addon?
    @State private var loading = true
    @State private var season: Int?
    @State private var expanded = false

    private var isSeries: Bool { !(meta?.videos.isEmpty ?? true) }
    private var full: MetaItem {
        var m = item
        if let f = meta {
            if !f.name.isEmpty { m.name = f.name }
            m.poster = m.poster ?? f.poster
            m.background = f.background ?? m.background
            m.logo = f.logo ?? m.logo
            m.runtime = f.runtime ?? m.runtime
        }
        return m
    }
    private var cursor: SeriesCursor? {
        guard let v = meta?.videos, !v.isEmpty else { return nil }
        return SeriesCursor.find(type: item.type, videos: v, progress: model.progress.all())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 28) {
                    if let d = meta?.description ?? item.description {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(d).font(.system(size: 14.5)).foregroundStyle(Theme.ink.opacity(0.86)).lineSpacing(3)
                                .lineLimit(expanded ? nil : 4).fixedSize(horizontal: false, vertical: true).frame(maxWidth: Theme.cap(720), alignment: .leading)
                            if d.count > 320 {
                                Button(expanded ? "Less" : "More") { expanded.toggle() }.buttonStyle(.plain)
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.label2)
                            }
                        }
                    }
                    if let m = meta { credits(m) }
                    if isSeries, let m = meta { episodes(m) }
                    if loading && meta == nil { ProgressView().controlSize(.small).padding(.vertical, 20) }
                }
                .padding(.horizontal, Theme.pad).padding(.top, 22).padding(.bottom, 50)
            }
        }
        .background(Theme.bg)
        .overlay(alignment: .topLeading) { BackButton().padding(.leading, 22).padding(.top, 44) }
        .task {
            if let (m, a) = await model.loadMeta(item, addonUrl: addonUrl) {
                meta = m; metaAddon = a
                season = SeriesCursor.find(type: item.type, videos: m.videos, progress: model.progress.all())?.seat.season
                    ?? m.videos.map(\.season).filter { $0 > 0 }.min() ?? m.videos.first?.season
            }
            loading = false
        }
    }

    // MARK: header

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Theme.backdrop(height: Theme.detailHeight) {
                RemoteImage(url: Art.backdrop(full)) { Theme.bg }
            }
            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: Theme.bg.opacity(0.88), location: 0.82), .init(color: Theme.bg, location: 1)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [Theme.bg.opacity(0.8), .clear], startPoint: .leading, endPoint: .center)
            VStack(alignment: .leading, spacing: 14) {
                RemoteImage(url: Art.logo(full), contentMode: .fit) {
                    Text(full.name).font(.system(size: 38, weight: .bold)).foregroundStyle(.white).lineLimit(2).frame(maxHeight: .infinity, alignment: .bottomLeading)
                }
                .frame(maxWidth: 380, maxHeight: 120, alignment: .bottomLeading)
                Text(facts).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.75))
                actions
            }
            .padding(.horizontal, Theme.pad)
        }
        .frame(height: Theme.detailHeight)
    }

    private var facts: String {
        var p: [String] = [isSeries ? "SERIES" : typeLabel(item.type) == "Films" ? "FILM" : typeLabel(item.type).uppercased()]
        p.append(contentsOf: (meta?.genres ?? item.genres).prefix(3).map { $0.uppercased() })
        if let r = meta?.runtime ?? item.runtime { p.append(r) }
        if let y = meta?.releaseInfo ?? item.releaseInfo { p.append(y) }
        if let r = meta?.imdbRating ?? item.imdbRating { p.append("★ " + r) }
        return p.joined(separator: "  ·  ")
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button(action: playMain) {
                HStack(spacing: 8) { Image(systemName: "play.fill").font(.system(size: 12)); Text(playLabel) }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(loading && meta == nil && item.type == "series")
            let saved = model.library.contains(item.type, item.id)
            RoundAction(icon: saved ? "checkmark" : "plus", label: saved ? "Remove from My List" : "Add to My List", on: saved) {
                let nowIn = model.library.toggle(full, addonUrl: addonUrl)
                model.say(nowIn ? "Added to My List." : "Removed from My List.")
            }
            if !isSeries && !loading {
                let watched = model.progress.get(item.type, item.id)?.done == true
                RoundAction(icon: watched ? "eye.fill" : "eye", label: watched ? "Mark as not watched" : "Mark as watched", on: watched) {
                    if watched { model.progress.markUnwatched(item.type, item.id) } else { model.progress.markWatched(item.type, item.id) }
                }
            }
        }
        .id(model.libraryVersion &+ model.progressVersion)
    }

    private var playLabel: String {
        if isSeries {
            guard let up = cursor?.upNext else { return cursor == nil ? "Play" : "Watch again" }
            let tag = Ids.episodeTag(up.id) ?? ""
            return model.progress.resumeAt(item.type, up.id) > 0 ? "Resume \(tag)" : "Play \(tag)"
        }
        let at = model.progress.resumeAt(item.type, item.id)
        if at > 0, let r = model.progress.get(item.type, item.id) { return "Resume · \(Fmt.left(r.dur - r.pos))" }
        return "Play"
    }

    private func playMain() {
        if isSeries, let m = meta {
            let flat = m.videos.filter { $0.season != 0 }.sorted { ($0.season, $0.episode ?? 0) < ($1.season, $1.episode ?? 0) }
            guard let ep = cursor?.upNext ?? flat.first ?? m.videos.first else { return }
            openEpisode(ep, m)
        } else {
            model.push(.streams(StreamsTarget(type: item.type, id: item.id, item: full, addonUrl: addonUrl)))
        }
    }

    private func openEpisode(_ ep: Episode, _ m: FullMeta) {
        model.push(.streams(StreamsTarget(type: item.type, id: ep.id, item: full, addonUrl: metaAddon?.manifestUrl ?? addonUrl, episode: ep, videos: m.videos)))
    }

    // MARK: credits

    @ViewBuilder
    private func credits(_ m: FullMeta) -> some View {
        let rows: [(String, String)] = [("Cast", m.cast.joined(separator: ", ")), ("Director", m.director.joined(separator: ", ")),
                                        ("Writer", m.writer.joined(separator: ", ")), ("Country", m.country ?? "")].filter { !$0.1.isEmpty }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows, id: \.0) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(r.0.uppercased()).font(.system(size: 10.5, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(Theme.label3).frame(width: 80, alignment: .leading)
                        Text(r.1).font(.system(size: 13.5)).foregroundStyle(Theme.ink.opacity(0.85))
                    }
                }
            }
        }
    }

    // MARK: episodes

    @ViewBuilder
    private func episodes(_ m: FullMeta) -> some View {
        let seasons = Array(Set(m.videos.map(\.season))).sorted { a, b in a == 0 ? false : b == 0 ? true : a < b }
        let cur = season ?? seasons.first ?? 1
        let list = m.videos.filter { $0.season == cur }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
        let upNextId = cursor?.upNext?.id
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Episodes").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("\(list.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.label3)
            }
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(seasons, id: \.self) { s in Chip(text: s == 0 ? "Specials" : "Season \(s)", on: s == cur) { season = s } }
                    }
                }
            }
            LazyVStack(spacing: 2) {
                ForEach(list) { ep in
                    EpisodeRow(ep: ep, type: item.type, upNext: ep.id == upNextId) { openEpisode(ep, m) }
                }
            }
            .id(model.progressVersion)
        }
    }
}

struct EpisodeRow: View {
    @EnvironmentObject var model: AppModel
    let ep: Episode
    let type: String
    let upNext: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let rec = model.progress.get(type, ep.id)
        let done = rec?.done == true
        let part = rec.flatMap { r in !r.done && !r.dismissed && r.dur > 0 && r.pos >= ProgressStore.minPos ? r.fraction : nil }
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: ep.thumbnail) { ZStack { Theme.surface; Image(systemName: "play.rectangle").foregroundStyle(Theme.label3) } }
                        .frame(width: 176, height: 99).clipped()
                    if let p = part {
                        GeometryReader { g in
                            ZStack(alignment: .leading) { Rectangle().fill(.white.opacity(0.3)); Rectangle().fill(model.accent).frame(width: g.size.width * p) }
                        }
                        .frame(height: 3)
                    }
                }
                .frame(width: 176, height: 99)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(upNext ? model.accent : Theme.line, lineWidth: upNext ? 2 : 1))
                .opacity(done ? 0.55 : 1)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(ep.episode.map { "E\($0)" } ?? "•").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(upNext ? model.accent : Theme.label3)
                        if upNext { Text("UP NEXT").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(model.accent) }
                        if done { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(model.accent) }
                        Spacer()
                        if let d = airDate { Text(d).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.label3) }
                    }
                    Text(ep.name).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    if let o = ep.overview { Text(o).font(.system(size: 12.5)).foregroundStyle(Theme.label2).lineLimit(2).lineSpacing(2) }
                }
                .padding(.top, 4)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(hover ? Theme.surface : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Play") { action() }
            if done || part != nil { Button("Mark as not watched") { model.progress.markUnwatched(type, ep.id) } }
            if !done { Button("Mark as watched") { model.progress.markWatched(type, ep.id) } }
        }
    }

    private var airDate: String? {
        guard let r = ep.released, r.count >= 10 else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        guard let d = f.date(from: String(r.prefix(10))) else { return nil }
        let out = DateFormatter(); out.dateFormat = "d MMM yyyy"
        return out.string(from: d)
    }
}
