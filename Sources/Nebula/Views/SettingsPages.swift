import SwiftUI
import NebulaCore

/// One page of Settings (2026-11-17): its group, its icon, one line on what it holds, and the words a search may use.
struct SetPage: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let group: String
    let words: String
}

/// Settings in groups: a Mac's left column and a phone's list of cards, both with a search over the pages.
extension SettingsView {
    static let groups = ["You", "Look", "Watch", "Services", "System"]

    /// The screenshot rig names sections; this is the page that holds each.
    static func pageFor(_ id: String) -> String {
        switch id {
        case "recap": return "support"
        case StreamCardSettings.customId: return "streams"
        default: return id
        }
    }

    var pages: [SetPage] {
        var l: [SetPage] = [
            SetPage(id: "profile", title: "Account", detail: "Your profile, who's watching and your devices", icon: "person.crop.circle",
                    group: "You", words: "profile sign in sign out password handle sync devices who's watching profiles pin tv code"),
            SetPage(id: "party", title: "Watch party", detail: "Watch in sync with friends using a code", icon: "person.2",
                    group: "You", words: "party code together sync host join friends"),
            SetPage(id: "appearance", title: "Appearance", detail: "The one colour Nebula uses", icon: "paintpalette",
                    group: "Look", words: "accent colour color theme"),
            SetPage(id: "streams", title: "Stream cards", detail: "How each stream on a streams page is drawn", icon: "rectangle.stack",
                    group: "Look", words: "streams cards design release compact line minimal classic custom"),
            SetPage(id: "playback", title: "Playback", detail: "Resuming, the next episode, skipping, quality and sound", icon: "play.circle",
                    group: "Watch", words: "resume next episode skip intro recap advisory continue watching quality night mode hardware decoding seek seekr"),
            SetPage(id: "subtitles", title: "Subtitles", detail: "The size, colour and background of the lines", icon: "captions.bubble",
                    group: "Watch", words: "subtitle captions style size colour background"),
        ]
        #if os(iOS)
        l.append(SetPage(id: "autoplay", title: "Autoplay the best stream", detail: "Play starts the best stream by itself", icon: "bolt.circle",
                         group: "Watch", words: "auto pick best stream debrid instant 4k aim"))
        #endif
        if model.supportVisible {
            l.append(SetPage(id: "support", title: "Support Nebula", detail: "Free, no ads. Chip in if you like", icon: "heart",
                             group: "Services", words: "support donate supporter code redeem plus founder monthly wall recap vote"))
        }
        l.append(SetPage(id: "about", title: "About", detail: "The version and updates", icon: "info.circle",
                         group: "System", words: "about version update releases keyboard shortcuts"))
        return l
    }

    /// Every word somewhere in a page's name, group, line or words.
    var hits: [SetPage] {
        let q = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        guard !q.isEmpty else { return [] }
        return pages.filter { p in
            let hay = "\(p.title) \(p.group) \(p.detail) \(p.words)".lowercased()
            return q.allSatisfy { hay.contains($0) }
        }
    }

    var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.label3)
            TextField("Search settings", text: $query).textFieldStyle(.plain).scaledFont(size: 15).foregroundStyle(Theme.ink)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.label3) }
                    .buttonStyle(.plain).accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }

    /// A phone's groups, or what the search found: cards of rows that open a page.
    var rootList: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !query.isEmpty {
                if hits.isEmpty {
                    Text("Nothing in Settings matches that.").scaledFont(size: 14).foregroundStyle(Theme.label2)
                } else {
                    pageCard(hits)
                }
            } else {
                ForEach(SettingsView.groups, id: \.self) { g in
                    let ps = pages.filter { $0.group == g }
                    if !ps.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow(g)
                            pageCard(ps)
                        }
                    }
                }
            }
        }
    }

    private func pageCard(_ ps: [SetPage]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(ps.enumerated()), id: \.element.id) { i, p in
                if i > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 64) }
                Button { page = p.id } label: { SetPageRow(page: p, accent: model.accent) }.buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line))
    }

    /// A Mac's left column: the title, the search, then the groups with the open page lit.
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings").scaledFont(size: 24, weight: .bold).foregroundStyle(Theme.ink).padding(.bottom, 10)
            searchField.padding(.bottom, 6)
            let list = query.isEmpty ? pages : hits
            if list.isEmpty {
                Text("Nothing matches.").scaledFont(size: 13).foregroundStyle(Theme.label2).padding(.top, 8)
            }
            ForEach(SettingsView.groups, id: \.self) { g in
                let ps = list.filter { $0.group == g }
                if !ps.isEmpty {
                    Eyebrow(g).padding(.top, 14).padding(.bottom, 4).padding(.leading, 6)
                    ForEach(ps) { p in
                        Button { page = p.id } label: {
                            SetPageRow(page: p, accent: model.accent, selected: (page ?? "profile") == p.id, compact: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// A page's row: an accent-tinted icon tile and its name; in a phone's list, one line on what it holds and a chevron.
struct SetPageRow: View {
    let page: SetPage
    let accent: Color
    var selected = false
    var compact = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: page.icon)
                .font(.system(size: compact ? 14 : 17, weight: .semibold)).foregroundStyle(accent)
                .frame(width: compact ? 30 : 38, height: compact ? 30 : 38)
                .background(RoundedRectangle(cornerRadius: compact ? 8 : 11).fill(accent.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title).scaledFont(size: compact ? 14 : 16, weight: selected ? .semibold : .medium).foregroundStyle(Theme.ink)
                if !compact {
                    Text(page.detail).scaledFont(size: 13).foregroundStyle(Theme.label2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if !compact { Image(systemName: "chevron.right").scaledFont(size: 13, weight: .semibold).foregroundStyle(Theme.label3) }
        }
        .padding(.horizontal, compact ? 8 : 14).padding(.vertical, compact ? 6 : 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.white.opacity(0.08) : (hover && compact ? Color.white.opacity(0.04) : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
