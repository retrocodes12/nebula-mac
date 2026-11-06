import Foundation
import NebulaCore

/// The watch party's hands in the app: what a viewer plays for it (the host's link, or the same file from this device's
/// own add-ons), the streams page when none has it, and the toasts.
extension AppModel {
    func makeParty() -> PartyClient {
        let p = PartyClient()
        p.say = { [weak self] t in self?.say(t) }
        p.onPlay = { [weak self] d in self?.playForParty(d, stream: nil, addon: nil) }
        p.onFindOwn = { [weak self] d in await self?.findOwnForParty(d) ?? false }
        p.onChoose = { [weak self] d in self?.chooseForParty(d) }
        return p
    }

    /// The party's title as a streams page target (a series episode keeps the show as its item).
    func partyTarget(_ d: PartyStreamDesc) -> StreamsTarget {
        let type = d.type ?? "movie", id = d.id ?? d.url
        let itemId = type == "series" ? PartySync.seriesIdOf(id) : id
        return StreamsTarget(type: type, id: id, item: MetaItem(id: itemId, type: type, name: d.name ?? d.title, poster: d.poster),
                             addonUrl: d.addonUrl ?? "", episode: nil)
    }

    /// Plays for the party: no resume point — the party owns the position.
    func playForParty(_ d: PartyStreamDesc, stream: StreamItem?, addon: Addon?) {
        var st = stream ?? StreamItem(name: d.title, title: "", url: d.url)
        if stream == nil { st.subtitles = d.subs; st.clearKeys = d.keys }
        player = PlayRequest(stream: st, target: partyTarget(d), streamAddon: addon)
    }

    func findOwnForParty(_ d: PartyStreamDesc) async -> Bool {
        let t = partyTarget(d)
        var rows: [(StreamItem, Addon)] = []
        _ = await loadStreams(t) { sec in rows += sec.streams.map { ($0, sec.addon) } }
        guard let hit = PartySync.matchOwn(rows.map(\.0), file: d.file),
              let from = rows.first(where: { $0.0 == hit })?.1 else { return false }
        playForParty(d, stream: hit, addon: from)
        say("Playing your own copy from \(from.name).")
        return true
    }

    func chooseForParty(_ d: PartyStreamDesc) {
        if player != nil { party.keepOnClose = true; player = nil }
        push(.streams(partyTarget(d)))
    }
}
