import SwiftUI
import NebulaCore

enum Art {
    /// A backdrop for titles whose catalogue row did not bring one (imdb ids only).
    static func backdrop(_ item: MetaItem) -> String? {
        if let b = item.background, !b.isEmpty { return b }
        return item.id.hasPrefix("tt") ? "https://images.metahub.space/background/medium/\(item.id)/img" : nil
    }

    static func logo(_ item: MetaItem) -> String? {
        if let l = item.logo, !l.isEmpty { return l }
        return item.id.hasPrefix("tt") ? "https://images.metahub.space/logo/medium/\(item.id)/img" : nil
    }

    static func size(shape: String, height: CGFloat) -> CGSize {
        switch shape {
        case "landscape": return CGSize(width: height * 16 / 9, height: height)
        case "square": return CGSize(width: height, height: height)
        default: return CGSize(width: height * 2 / 3, height: height)
        }
    }
}

/// A title in a row or a grid. Hover lifts it and draws the white ring a remote would.
struct PosterCard: View {
    @EnvironmentObject var model: AppModel
    let item: MetaItem
    let addonUrl: String
    var height: CGFloat = 228
    /// Rows of wide art are shorter, so a row of channels does not tower over a row of films.
    var fitWidth: CGFloat? = nil
    @State private var hover = false

    var body: some View {
        let size = fitWidth.map { w -> CGSize in
            let s = Art.size(shape: item.posterShape, height: 100)
            return CGSize(width: w, height: w * s.height / s.width)
        } ?? Art.size(shape: item.posterShape, height: item.posterShape == "landscape" ? height * 0.62 : item.posterShape == "square" ? height * 0.72 : height)
        Button(action: { model.open(item, addonUrl: addonUrl) }) {
            VStack(alignment: .leading, spacing: 8) {
                RemoteImage(url: item.poster) { InitialsTile(name: item.name) }
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(hover ? Color.white : Theme.line, lineWidth: hover ? 2 : 1))
                    .overlay(alignment: .topTrailing) {
                        if model.progress.get(item.type, item.id)?.done == true {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(.white, Theme.ok).padding(7)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(item.releaseInfo ?? " ").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.label3).lineLimit(1)
                }
                .frame(width: size.width, alignment: .leading)
            }
            .scaleEffect(hover ? 1.035 : 1, anchor: .center)
            .animation(.easeOut(duration: 0.16), value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu { TitleMenu(item: item, addonUrl: addonUrl) }
    }
}

/// What a right-click on any title offers.
struct TitleMenu: View {
    @EnvironmentObject var model: AppModel
    let item: MetaItem
    let addonUrl: String

    var body: some View {
        Button("Details") { model.open(item, addonUrl: addonUrl) }
        Button(model.library.contains(item.type, item.id) ? "Remove from My List" : "Add to My List") {
            let nowIn = model.library.toggle(item, addonUrl: addonUrl)
            model.say(nowIn ? "Added to My List." : "Removed from My List.")
        }
        if item.type == "movie" {
            if model.progress.get("movie", item.id)?.done == true {
                Button("Mark as not watched") { model.progress.markUnwatched("movie", item.id) }
            } else {
                Button("Mark as watched") { model.progress.markWatched("movie", item.id) }
            }
        }
    }
}

struct RowHeader: View {
    let title: String
    var subline: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.ink)
            if let s = subline { Text(s).font(.system(size: 12)).foregroundStyle(Theme.label3) }
            Spacer()
            if let a = action {
                Button(action: a) {
                    HStack(spacing: 4) { Text("See all"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)) }
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.label2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.pad)
    }
}

struct CatalogRowView: View {
    @EnvironmentObject var model: AppModel
    let row: CatalogRow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RowHeader(title: row.catalog.name, subline: "from \(row.addon.name) · \(typeLabel(row.catalog.type))") {
                model.push(.catalog(CatalogTarget(addon: row.addon, catalog: row.catalog)))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(row.items) { PosterCard(item: $0, addonUrl: row.addon.manifestUrl) }
                }
                .padding(.horizontal, Theme.pad).padding(.vertical, 6)
            }
        }
    }
}

func typeLabel(_ type: String) -> String {
    switch type {
    case "movie": return "Films"
    case "series": return "Series"
    case "tv": return "Live TV"
    case "channel": return "Channels"
    case "anime": return "Anime"
    case "sports": return "Sports"
    default: return type.prefix(1).uppercased() + type.dropFirst()
    }
}

/// The wide Continue watching card: the backdrop, how far in, how long is left.
struct ContinueCard: View {
    @EnvironmentObject var model: AppModel
    let rec: ProgressRec
    @State private var hover = false

    var seriesItem: MetaItem {
        MetaItem(id: Ids.seriesId(of: rec.id), type: rec.type, name: rec.name, poster: rec.poster, posterShape: rec.shape, background: rec.back)
    }

    var body: some View {
        Button(action: resume) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: rec.back ?? Art.backdrop(seriesItem) ?? rec.poster) { InitialsTile(name: rec.name) }
                        .frame(width: 300, height: 169)
                        .clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Image(systemName: "play.fill").font(.system(size: 11))
                            Text(Fmt.left(rec.dur - rec.pos)).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.3))
                                Capsule().fill(model.accent).frame(width: g.size.width * rec.fraction)
                            }
                        }
                        .frame(height: 4)
                    }
                    .padding(12)
                }
                .frame(width: 300, height: 169)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(hover ? Color.white : Theme.line, lineWidth: hover ? 2 : 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.name.isEmpty ? "Untitled" : rec.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(Ids.episodeKicker(rec.id) ?? typeLabel(rec.type)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.label3).lineLimit(1)
                }
            }
            .scaleEffect(hover ? 1.025 : 1)
            .animation(.easeOut(duration: 0.16), value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Details") { model.open(seriesItem, addonUrl: rec.addonUrl) }
            Button("Mark as watched") { model.progress.markWatched(rec.type, rec.id) }
            Button("Remove from Continue Watching") { model.progress.clear(rec.type, rec.id) }
        }
    }

    private func resume() {
        model.push(.streams(StreamsTarget(type: rec.type, id: rec.id, item: seriesItem, addonUrl: rec.addonUrl)))
    }
}

/// A page pushed over a tab carries its own way back.
struct BackButton: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button(action: { if !model.path.isEmpty { model.path.removeLast() } }) {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.14)))
                .environment(\.colorScheme, .dark)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back")
    }
}

struct PosterGrid: View {
    let items: [MetaItem]
    let addonUrl: (MetaItem) -> String
    var onReachEnd: (() -> Void)? = nil

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18, alignment: .top)], alignment: .leading, spacing: 24) {
            ForEach(items) { item in
                GeometryReader { g in
                    PosterCard(item: item, addonUrl: addonUrl(item), fitWidth: g.size.width)
                }
                .aspectRatio(cellRatio(item), contentMode: .fit)
                .onAppear { if item.id == items.last?.id { onReachEnd?() } }
            }
        }
    }

    // the card is its art plus 42 points of label, so the cell reserves both
    private func cellRatio(_ item: MetaItem) -> CGFloat {
        let s = Art.size(shape: item.posterShape, height: 100)
        let w: CGFloat = 170
        return w / (w * s.height / s.width + 42)
    }
}
