import SwiftUI
import NebulaCore

struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var heroItems: [(MetaItem, Addon)] {
        guard let row = model.homeRows.first(where: { r in r.items.contains { Art.backdrop($0) != nil } }) else { return [] }
        return row.items.filter { Art.backdrop($0) != nil }.prefix(6).map { ($0, row.addon) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                if !heroItems.isEmpty { Hero(items: heroItems) }
                else { Color.clear.frame(height: 40) }

                let cw = model.progress.continueList()
                if !cw.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        RowHeader(title: "Continue Watching")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 16) {
                                ForEach(cw, id: \.id) { ContinueCard(rec: $0) }
                            }
                            .padding(.horizontal, Theme.pad).padding(.vertical, 6)
                        }
                    }
                    .id(model.progressVersion)
                }

                ForEach(model.homeRows) { CatalogRowView(row: $0) }

                if model.homeLoading && model.homeRows.isEmpty { SkeletonRows() }
                if model.activeAddons.isEmpty {
                    EmptyState(icon: "puzzlepiece.extension", title: "No add-ons are switched on", detail: "Nebula shows what your add-ons offer. Add one, or switch one back on, in Add-ons.")
                } else if model.homeFailed {
                    EmptyState(icon: "wifi.slash", title: "Nothing answered", detail: "None of your add-ons could be reached. Check the connection and try again.",
                               actionTitle: "Try again", action: { model.retryHome() })
                } else if !model.homeLoading && model.homeRows.isEmpty && cw.isEmpty {
                    EmptyState(icon: "square.grid.2x2", title: "Nothing to show yet", detail: "None of the add-ons switched on has a catalog. Add one that does in Add-ons.")
                }
                Color.clear.frame(height: 30)
            }
        }
        .background(Theme.bg)
    }
}

struct SkeletonRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 14) {
                    RoundedRectangle(cornerRadius: 5).fill(Theme.surface).frame(width: 160, height: 18).padding(.horizontal, Theme.pad)
                    HStack(spacing: 16) {
                        ForEach(0..<8, id: \.self) { _ in RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surface).frame(width: 152, height: 228) }
                    }
                    .padding(.horizontal, Theme.pad)
                }
            }
        }
        // minWidth as well as maxWidth: with a maximum alone, a frame whose child is wider than
        // the page (eight cards are ~1 330 points) takes the child's width, not the page's
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

/// Full-bleed art that dissolves into the page, the title's own logo over it, one line of facts.
struct Hero: View {
    @EnvironmentObject var model: AppModel
    let items: [(MetaItem, Addon)]
    @State private var index = 0
    @State private var hovering = false

    var body: some View {
        let item = items[min(index, items.count - 1)].0
        let addon = items[min(index, items.count - 1)].1
        ZStack(alignment: .bottomLeading) {
            Theme.backdrop(height: Theme.heroHeight) {
                RemoteImage(url: Art.backdrop(item)) { Theme.bg }
                    .id(item.id)
                    .transition(.opacity)
            }
            LinearGradient(stops: [.init(color: Theme.bg.opacity(0.0), location: 0.35), .init(color: Theme.bg.opacity(0.85), location: 0.8), .init(color: Theme.bg, location: 1)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [Theme.bg.opacity(0.85), .clear], startPoint: .leading, endPoint: .center)

            VStack(alignment: .leading, spacing: 14) {
                RemoteImage(url: Art.logo(item), contentMode: .fit) {
                    Text(item.name).font(.system(size: 40, weight: .bold)).foregroundStyle(.white).lineLimit(2).frame(maxHeight: .infinity, alignment: .bottomLeading)
                }
                .frame(maxWidth: 360, maxHeight: 110, alignment: .bottomLeading)
                Text(facts(item)).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.75))
                if let d = item.description {
                    Text(d).font(.system(size: 14)).foregroundStyle(.white.opacity(0.82)).lineLimit(3).fixedSize(horizontal: false, vertical: true).frame(maxWidth: Theme.cap(520), alignment: .leading)
                }
                HStack(spacing: 12) {
                    Button(action: { model.open(item, addonUrl: addon.manifestUrl) }) {
                        HStack(spacing: 8) { Image(systemName: "play.fill").font(.system(size: 12)); Text("Watch") }
                    }
                    .buttonStyle(PillButtonStyle())
                    RoundAction(icon: model.library.contains(item.type, item.id) ? "checkmark" : "plus", label: "My List", on: model.library.contains(item.type, item.id)) {
                        model.library.toggle(item, addonUrl: addon.manifestUrl)
                    }
                    Spacer()
                    HStack(spacing: Hero.dotGap) {
                        ForEach(items.indices, id: \.self) { i in
                            Capsule().fill(i == index ? Color.white : Color.white.opacity(0.3)).frame(width: i == index ? 18 : 6, height: 6)
                                .dotTarget()
                                .onTapGesture { withAnimation(.easeInOut(duration: 0.4)) { index = i } }
                        }
                    }
                }
                .id(model.libraryVersion)
            }
            .padding(.horizontal, Theme.pad).padding(.bottom, 8)
        }
        .frame(height: Theme.heroHeight)
        .onHover { hovering = $0 }
        .task(id: items.count) {
            // moves on by itself, and holds still while the pointer is over it
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                if !hovering && items.count > 1 && model.player == nil { withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % items.count } }
            }
        }
    }

    // On a phone each dot is a 44-point-tall target that meets its neighbours; six of them
    // still have to share the row with Watch and +, so they are 26 to 38 points wide.
    #if os(iOS)
    static let dotGap: CGFloat = 0
    #else
    static let dotGap: CGFloat = 6
    #endif

    private func facts(_ m: MetaItem) -> String {
        var p = [typeLabel(m.type) == "Films" ? "FILM" : typeLabel(m.type).uppercased()]
        if let g = m.genres.first { p.append(g.uppercased()) }
        if let y = m.releaseInfo { p.append(y) }
        if let r = m.imdbRating { p.append("★ " + r) }
        return p.joined(separator: "  ·  ")
    }
}

private extension View {
    @ViewBuilder func dotTarget() -> some View {
        #if os(iOS)
        self.padding(.horizontal, 10).frame(height: 44).contentShape(Rectangle())
        #else
        self
        #endif
    }
}
