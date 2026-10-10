import Foundation
import NebulaCore

/// What playing something MEANS, with no screen attached: where the bytes come from, which
/// caption goes in, what gets written down, and what plays after it.
///
/// Both players call these. The chrome differs between a window and a phone; these rules must
/// not, or the two surfaces would drift into disagreeing about the same film.
enum PlaybackRules {
    struct SubPick {
        var url: String
        var lang: String
        var title: String
        var select: Bool
    }

    /// The address to hand the engine and the keys to hand it with. Protected DASH goes through
    /// the loopback manifest cache (ManifestProxy says why), and the same fetch gives the text
    /// the licence address is read from.
    static func source(for stream: StreamItem, maxHeight: Int, stremio: Stremio) async -> (address: String, keys: [String: String], token: String?) {
        var keys = stream.clearKeys
        var address = stream.url
        var token: String?
        // an HLS row that names its own request headers: through loopback, which sends them on
        // every playlist and piece and unwraps pieces a host hides inside a picture (HlsUnwrap)
        if !Task.isCancelled, !ClearKey.looksLikeDash(stream.url), !stream.headers.isEmpty, HlsUnwrap.isPlaylist(stream.url),
           let h = await ManifestProxy.shared.openHls(stream.url, headers: stream.headers) {
            if Task.isCancelled { ManifestProxy.shared.release(h.token); return (address, keys, nil) }
            return (h.address, keys, h.token)
        }
        guard !Task.isCancelled, ClearKey.looksLikeDash(stream.url) else { return (address, keys, nil) }
        var headers = stream.headers
        if !headers.keys.contains(where: { $0.lowercased() == "user-agent" }) { headers["User-Agent"] = MPVController.userAgent }
        if let m = await ManifestProxy.shared.open(stream.url, headers: headers, maxHeight: maxHeight) {
            address = m.address; token = m.token
            if keys.isEmpty && !Task.isCancelled {
                keys = await ClearKey.resolve(xml: m.xml, manifestUrl: m.base, headers: headers, headerOrigin: stream.url, using: stremio)
            }
        } else if !Task.isCancelled && keys.isEmpty {
            keys = await ClearKey.resolve(manifestUrl: stream.url, headers: headers, using: stremio)
        }
        if Task.isCancelled { ManifestProxy.shared.release(token); token = nil }
        return (address, keys, token)
    }

    /// How many captions go in: the viewer's own language gets room to choose, every other
    /// language a couple, and the whole list stays short. Each one is a download the engine
    /// makes, and an add-on can offer a hundred.
    static let subsWanted = 12, subsPerOther = 2, subsTotal = 30

    /// The captions to attach, in order. The viewer's language is selected and the rest wait in
    /// the menu. The viewer's language is counted first, so the total cap never squeezes it out.
    static func subtitlePlan(stream: StreamItem, addon: [SubTrack], want: String) -> [SubPick] {
        let all = stream.subtitles + addon
        let language = Lang.key(want)
        func wanted(_ s: SubTrack) -> Bool { !language.isEmpty && Lang.key(s.lang) == language }
        var room: [String: Int] = [:]
        var keep = Set<Int>()
        let byPriority = all.indices.sorted { a, b in (wanted(all[a]) ? 0 : 1, a) < (wanted(all[b]) ? 0 : 1, b) }
        for i in byPriority where keep.count < subsTotal {
            let s = all[i], key = Lang.key(s.lang)
            let n = room[key] ?? 0
            if n >= (wanted(s) ? subsWanted : subsPerOther) { continue }
            room[key] = n + 1
            keep.insert(i)
        }
        var perLang: [String: Int] = [:]
        var picked = false
        var out: [SubPick] = []
        for i in all.indices where keep.contains(i) {
            let s = all[i], key = Lang.key(s.lang)
            let n = (perLang[key] ?? 0) + 1
            perLang[key] = n
            let pick = !picked && wanted(s)
            if pick { picked = true }
            let name = Lang.name(s.lang)
            out.append(SubPick(url: s.url, lang: s.lang,
                               title: n > 1 ? "\(name.isEmpty ? s.lang : name) \(n)" : "",
                               select: pick))
        }
        return out
    }

    /// When the captions go in. Two things have to have happened — the file is open, and the
    /// subtitle add-ons have answered — and they land in either order. Attaching at the first
    /// of the two dropped every add-on caption whenever the file opened before they answered.
    struct CaptionGate {
        private(set) var fileOpen = false
        /// nil while the add-ons are still being asked.
        private(set) var addonSubs: [SubTrack]?
        /// Everything that was going to be attached has been.
        private(set) var settled = false
        private(set) var handPicked = false

        mutating func picked() { handPicked = true }

        /// The file is open. True when the captions should go in now.
        mutating func fileLoaded() -> Bool { fileOpen = true; return take() }

        /// The add-ons answered (or the wait for them ran out). True when the captions should go in now.
        mutating func addonsAnswered(_ subs: [SubTrack]) -> Bool { addonSubs = subs; return take() }

        /// The same stream was loaded again (Try again): the engine dropped the captions it
        /// had, so they go in again once the new file is open.
        mutating func reopened() { fileOpen = false; settled = false }

        private mutating func take() -> Bool {
            guard fileOpen, addonSubs != nil, !settled else { return false }
            settled = true
            return true
        }
    }

    /// A remembered choice applies even without add-on captions; unset keeps the engine's default.
    static func selectSubtitles(want: String, chosen: Bool, to mpv: MPVController) {
        guard chosen else { return }
        let language = Lang.key(want)
        if want.isEmpty { mpv.selectTrack("sub", id: nil) }
        else if !language.isEmpty, let t = mpv.tracks.first(where: { $0.type == "sub" && Lang.key($0.lang) == language }), !t.selected {
            mpv.selectTrack("sub", id: t.id)
        }
    }

    /// Late captions can fill the menu, but a choice already made in the player wins.
    static func attachCaptions(_ gate: CaptionGate, stream: StreamItem, want: String, to mpv: MPVController) {
        let plan = subtitlePlan(stream: stream, addon: gate.addonSubs ?? [], want: want)
        let selected = mpv.tracks.contains { $0.type == "sub" && ($0.selected || !$0.external) && Lang.key($0.lang) == Lang.key(want) }
        for p in plan { mpv.addSubtitle(url: p.url, lang: p.lang, title: p.title, select: p.select && !gate.handPicked && !selected) }
    }

    /// Whether the engine's end is the film's end. A stream that dies part-way — a dropped
    /// connection reads to the engine as the end of the file — must not be ticked off as
    /// watched, and must not roll on into the next episode.
    static func reachedTheEnd(pos: Double, dur: Double) -> Bool {
        dur > 0 && pos >= dur - ProgressStore.endGap
    }

    static let cutShort = "The stream stopped before the end. Try again, or pick another stream."
    static let liveStopped = "The live stream stopped. Try again to reconnect, or pick another stream."

    /// The resume point, carrying what a Continue watching card needs to draw itself.
    static func record(target: StreamsTarget, pos: Double, dur: Double) -> ProgressRec {
        var r = ProgressRec(type: target.type, id: target.id)
        r.name = target.item.name
        r.poster = target.item.poster
        r.shape = target.item.posterShape
        r.back = target.item.background
        r.addonUrl = target.addonUrl
        r.pos = pos
        r.dur = dur
        return r
    }

    /// The tick playback leaves when a thing finishes.
    static func doneRecord(target: StreamsTarget) -> ProgressRec {
        var r = ProgressRec(type: target.type, id: target.id)
        r.done = true
        return r
    }

    /// The same release of the next episode when the add-on offers it, else its first stream.
    /// Nil means nobody answered — the caller shows the streams page instead.
    static func nextStream(origin: Addon?, type: String, id: String, bingeGroup: String, stremio: Stremio) async -> (StreamItem, Addon)? {
        guard let a = origin, let list = try? await stremio.loadStreams(base: a.base, type: type, id: id) else { return nil }
        guard let s = list.first(where: { !bingeGroup.isEmpty && $0.bingeGroup == bingeGroup }) ?? list.first else { return nil }
        return (s, a)
    }
}
