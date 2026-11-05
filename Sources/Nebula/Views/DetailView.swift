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
    /// What it follows, what follows it, its spin-offs and remakes (Nebula Cloud, a week's cache).
    @State private var universe: [Universe.Item] = []
    /// The age rating where this device is ("UA", "PG-13"; Advisory.swift), asked once a title.
    @State private var age = ""
    /// How far the art runs up under a phone's status bar (0 on a Mac).
    @Environment(\.topBleed) private var bleed
    /// The credits' label column, which widens with a larger text size on a phone.
    #if os(iOS)
    @ScaledMetric(relativeTo: .caption) private var labelColumn: CGFloat = 80
    #else
    private let labelColumn: CGFloat = 80
    #endif

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
                            Text(d).scaledFont(size: 14.5).foregroundStyle(Theme.ink.opacity(0.86)).lineSpacing(3)
                                .lineLimit(expanded ? nil : 4).fixedSize(horizontal: false, vertical: true).readingCap(720, alignment: .leading)
                            if d.count > 320 {
                                Button(expanded ? "Less" : "More") { expanded.toggle() }.buttonStyle(.plain)
                                    .scaledFont(size: 13, weight: .semibold).foregroundStyle(Theme.label2)
                            }
                        }
                    }
                    if let m = meta { credits(m) }
                    if isSeries, let m = meta { episodes(m) }
                    if loading && meta == nil { ProgressView().controlSize(.small).padding(.vertical, 20) }
                }
                .padding(.horizontal, Theme.pad).padding(.top, 22).padding(.bottom, universe.isEmpty ? 50 : 26)
                // its own row, running past the reading column like the rows on Home
                if !universe.isEmpty { universeRow.padding(.bottom, 50) }
            }
        }
        .background(Theme.bg)
        .bleedsUnderStatusBar()
        .overlay(alignment: .topLeading) { BackButton().padding(.leading, 22).padding(.top, Theme.backTop) }
        .task {
            if let (m, a) = await model.loadMeta(item, addonUrl: addonUrl) {
                meta = m; metaAddon = a
                season = SeriesCursor.find(type: item.type, videos: m.videos, progress: model.progress.all())?.seat.season
                    ?? m.videos.map(\.season).filter { $0 > 0 }.min() ?? m.videos.first?.season
            }
            loading = false
            if let tt = Advisory.idOf(item.id) {
                age = Advisory.cached(tt)?.cert ?? ""
                if age.isEmpty, let a = await Advisory.load(tt), !Task.isCancelled { age = a.cert }
            }
            if let id = Universe.idOf(item.id) {
                universe = Universe.cached(id) ?? []
                if universe.isEmpty, let got = await Universe.load(id), !Task.isCancelled { universe = got }
            }
        }
    }

    // MARK: header

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Theme.backdrop(height: Theme.detailHeight + bleed) {
                RemoteImage(url: Art.backdrop(full), settle: true) { Theme.bg }
            }
            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: Theme.bg.opacity(0.88), location: 0.82), .init(color: Theme.bg, location: 1)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [Theme.bg.opacity(0.8), .clear], startPoint: .leading, endPoint: .center)
            VStack(alignment: .leading, spacing: 14) {
                RemoteImage(url: Art.logo(full), contentMode: .fit) {
                    Text(full.name).font(.system(size: 38, weight: .bold)).foregroundStyle(.white).lineLimit(2).frame(maxHeight: .infinity, alignment: .bottomLeading)
                }
                .frame(maxWidth: 380, maxHeight: 120, alignment: .bottomLeading)
                FactsLine(parts: facts).scaledFont(size: 12, weight: .medium, design: .monospaced).foregroundStyle(.white.opacity(0.75))
                actions
            }
            .padding(.horizontal, Theme.pad)
        }
        .frame(height: Theme.detailHeight + bleed)
    }

    private var facts: [String] {
        var p: [String] = [isSeries ? "SERIES" : typeLabel(item.type) == "Films" ? "FILM" : typeLabel(item.type).uppercased()]
        p.append(contentsOf: (meta?.genres ?? item.genres).prefix(3).map { $0.uppercased() })
        if let r = meta?.runtime ?? item.runtime { p.append(r) }
        if let y = meta?.releaseInfo ?? item.releaseInfo { p.append(y) }
        if !age.isEmpty { p.append(age) }
        if let r = meta?.imdbRating ?? item.imdbRating { p.append("★ " + r) }
        return p
    }

    private var actions: some View {
        // one row while it fits; at a large text size ("Resume · 1 h 12 min left" beside two round buttons) the round
        // buttons go under the pill instead of running past the margin and pulling the page off centre
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { playPill; roundActions }
            VStack(alignment: .leading, spacing: 12) { playPill; HStack(spacing: 12) { roundActions } }
        }
        .id(model.libraryVersion &+ model.progressVersion)
    }

    private var playPill: some View {
        Button(action: playMain) {
            HStack(spacing: 8) { Image(systemName: "play.fill").scaledFont(size: 12); Text(playLabel) }
        }
        .buttonStyle(PillButtonStyle())
        .layoutPriority(1)
        .disabled(loading && meta == nil && item.type == "series")
    }

    @ObservedObject private var downloads = Downloads.shared

    @ViewBuilder private var roundActions: some View {
            if !isSeries && !loading && item.type == "movie" {
                // Download (Downloads.swift): pick a source; once kept, Play plays the copy
                let r = downloads.find(model.viewerId, item.type, item.id)
                RoundAction(icon: r == nil ? "arrow.down.circle" : r!.phase == .done ? "checkmark.circle.fill" : r!.phase == .failed ? "exclamationmark.circle" : "arrow.down.circle.dotted",
                            label: r == nil ? "Download" : r!.phase == .done ? "Downloaded" : r!.phase == .failed ? "Download failed · Retry" : "Downloading · " + downloads.line(r!),
                            on: r?.phase == .done) {
                    if let r { if r.phase == .failed { downloads.resume(r.key) } else if r.phase != .done { model.libraryShowsDownloads = true; model.select(.library) } }
                    else { model.push(.streams(StreamsTarget(type: item.type, id: item.id, item: full, addonUrl: addonUrl, save: true))) }
                }
            }
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

    /// "Download Season N · X episodes": two or more aired episodes of the season on screen not kept yet.
    @ViewBuilder private func seasonDownload(_ list: [Episode], _ m: FullMeta) -> some View {
        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let todo = list.filter { e in
            let d = String((e.released ?? "").prefix(10))
            return (d.count < 10 || d <= today) && downloads.find(model.viewerId, item.type, e.id) == nil
        }
        if let busy = downloads.seasonBusy {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Finding the same source · " + busy).scaledFont(size: 13).foregroundStyle(Theme.label2) }
        } else if todo.count >= 2, let s = todo.first?.season {
            Chip(text: (s == 0 ? "Download the specials" : "Download Season \(s)") + " · \(todo.count) episodes", on: false) { downloadEpisodes(todo, m) }
        }
    }

    /// Pick a source for the first; the rest (a season) follow with the same one.
    private func downloadEpisodes(_ eps: [Episode], _ m: FullMeta) {
        guard let first = eps.first else { return }
        model.push(.streams(StreamsTarget(type: item.type, id: first.id, item: full, addonUrl: metaAddon?.manifestUrl ?? addonUrl, episode: first,
                                          videos: m.videos, save: true, seasonRest: Array(eps.dropFirst()))))
    }

    private func openEpisode(_ ep: Episode, _ m: FullMeta) {
        model.push(.streams(StreamsTarget(type: item.type, id: ep.id, item: full, addonUrl: metaAddon?.manifestUrl ?? addonUrl, episode: ep, videos: m.videos)))
    }

    // MARK: universe

    private var universeRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            RowHeader(title: "Universe")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(universe) { u in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(u.label.uppercased()).scaledFont(size: 10, weight: .medium, design: .monospaced).tracking(1).foregroundStyle(Theme.label3)
                            PosterCard(item: u.meta, addonUrl: metaAddon?.manifestUrl ?? addonUrl, height: 200)
                        }
                    }
                }
                .padding(.horizontal, Theme.pad).padding(.vertical, 6)
            }
        }
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
                        Text(r.0.uppercased()).scaledFont(size: 10.5, weight: .medium, design: .monospaced).tracking(1).foregroundStyle(Theme.label3).frame(width: labelColumn, alignment: .leading)
                        Text(r.1).scaledFont(size: 13.5).foregroundStyle(Theme.ink.opacity(0.85))
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
                Text("Episodes").scaledFont(size: 19, weight: .semibold).foregroundStyle(Theme.ink)
                Text("\(list.count)").scaledFont(size: 12, design: .monospaced).foregroundStyle(Theme.label3)
            }
            if seasons.count > 1 {
                EdgeScroller {
                    ForEach(seasons, id: \.self) { s in Chip(text: s == 0 ? "Specials" : "Season \(s)", on: s == cur) { season = s } }
                }
            }
            seasonDownload(list, m)
            // the rows read their ticks from the store as they draw; a fresh identity for every
            // progress change rebuilt the whole list for one tick
            LazyVStack(spacing: 2) {
                ForEach(list) { ep in
                    EpisodeRow(ep: ep, type: item.type, upNext: ep.id == upNextId, download: { downloadEpisodes([ep], m) }) { openEpisode(ep, m) }
                }
            }
        }
    }
}

struct EpisodeRow: View {
    @EnvironmentObject var model: AppModel
    let ep: Episode
    let type: String
    let upNext: Bool
    /// Download this episode (the menu offers it; nil = no Downloads here).
    var download: (() -> Void)? = nil
    let action: () -> Void
    @State private var hover = false
    @ObservedObject private var downloads = Downloads.shared

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
                        Text(ep.episode.map { "E\($0)" } ?? "•").scaledFont(size: 11, weight: .semibold, design: .monospaced).foregroundStyle(upNext ? model.accent : Theme.label3)
                        if upNext { Text("UP NEXT").scaledFont(size: 10, weight: .semibold, design: .monospaced).tracking(1).foregroundStyle(model.accent) }
                        if done { Image(systemName: "checkmark.circle.fill").scaledFont(size: 12).foregroundStyle(model.accent) }
                        if let d = downloads.find(model.viewerId, type, ep.id) {
                            Text(d.phase == .done ? "DOWNLOADED" : d.phase == .failed ? "DOWNLOAD FAILED" : d.total > 0 ? "\(Int(Double(d.bytes) * 100 / Double(d.total)))%" : "WAITING")
                                .scaledFont(size: 10, weight: .semibold, design: .monospaced).tracking(1).foregroundStyle(Theme.label2)
                        }
                        Spacer()
                        if let d = airDate { Text(d).scaledFont(size: 11, design: .monospaced).foregroundStyle(Theme.label3) }
                    }
                    Text(ep.name).scaledFont(size: 14.5, weight: .semibold).foregroundStyle(Theme.ink).lineLimit(1)
                    if let o = ep.overview { Text(o).scaledFont(size: 12.5).foregroundStyle(Theme.label2).lineLimit(2).lineSpacing(2) }
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
            if let d = downloads.find(model.viewerId, type, ep.id) {
                Button(d.phase == .done ? "Remove the download" : "Cancel the download", role: .destructive) { downloads.remove(d.key) }
            } else if let download { Button("Download") { download() } }
        }
    }

    /// The day an episode aired, as the add-on dates it ("2024-03-07T00:00:00.000Z"): a calendar
    /// day, read and shown in UTC. Shown in the viewer's own zone, that midnight fell on the day
    /// before anywhere west of UTC — every episode dated a day early in the Americas.
    private var airDate: String? {
        guard let r = ep.released, r.count >= 10, let d = EpisodeRow.reader.date(from: String(r.prefix(10))) else { return nil }
        return EpisodeRow.shown.string(from: d)
    }

    /// Made once (a formatter is costly, and each row made two every time it was drawn). The
    /// reader is fixed to POSIX, so a phone set to another calendar still reads the year right.
    private static let reader: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// In the viewer's own words and order ("7 Mar 2024", "Mar 7, 2024"), on the UTC day.
    private static let shown: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f
    }()
}
