import SwiftUI
import NebulaCore

/// My List › Downloads (Downloads.swift): one shelf per film or show, a show's episodes in order; a row plays its copy once
/// it is kept, and carries Pause / Resume / Retry and Remove.
struct DownloadsList: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var downloads = Downloads.shared
    let switchBack: () -> Void

    var body: some View {
        let mine = downloads.mine(model.viewerId)
        let shelves = DownloadPlan.shelves(mine, name: { $0.name }, type: { $0.type }, id: { $0.id }, at: { $0.at })
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Downloads").scaledFont(size: 30, weight: .bold).foregroundStyle(Theme.ink)
                    Text("\(mine.count)").scaledFont(size: 13, design: .monospaced).foregroundStyle(Theme.label3)
                    Spacer()
                    Chip(text: "My List", on: false, action: switchBack)
                }
                .padding(.top, 56)
                if mine.isEmpty {
                    EmptyState(icon: "arrow.down.circle", title: "Nothing downloaded yet",
                               detail: "A film’s page has Download; an episode has it in its menu, and a season above its episodes.")
                }
                ForEach(Array(shelves.enumerated()), id: \.offset) { _, shelf in
                    VStack(alignment: .leading, spacing: 8) {
                        if shelf.rows.count > 1 || shelf.rows.first?.type == "series" {
                            Text(shelf.title).scaledFont(size: 17, weight: .semibold).foregroundStyle(Theme.ink)
                        }
                        ForEach(shelf.rows) { r in row(r) }
                    }
                }
            }
            .padding(.horizontal, Theme.pad).padding(.bottom, 50)
        }
        .background(Theme.bg)
    }

    private func row(_ r: SavedRow) -> some View {
        let rest = DownloadPlan.nameParts(r.name).rest ?? r.name
        return HStack(spacing: 12) {
            Button {
                guard r.phase == .done else { return }
                let item = MetaItem(id: r.type == "series" ? Ids.seriesId(of: r.id) : r.id, type: r.type, name: DownloadPlan.nameParts(r.name).show)
                model.playSaved(r, target: StreamsTarget(type: r.type, id: r.id, item: item, addonUrl: r.addonUrl))
            } label: {
                HStack(spacing: 12) {
                    RemoteImage(url: r.poster) { Theme.surface }.frame(width: 48, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rest).scaledFont(size: 14.5, weight: .semibold).foregroundStyle(Theme.ink).lineLimit(2)
                        Text(downloads.line(r)).scaledFont(size: 12, design: .monospaced).foregroundStyle(Theme.label2).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            switch r.phase {
            case .running, .queued: Chip(text: "Pause", on: false) { downloads.pause(r.key) }
            case .paused: Chip(text: "Resume", on: false) { downloads.resume(r.key) }
            case .failed: Chip(text: "Retry", on: false) { downloads.resume(r.key) }
            case .done: EmptyView()
            }
            Chip(text: "Remove", on: false) { downloads.remove(r.key) }
        }
        .padding(.vertical, 4)
    }
}
