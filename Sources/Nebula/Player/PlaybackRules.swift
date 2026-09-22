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
    static func source(for stream: StreamItem, maxHeight: Int, stremio: Stremio) async -> (address: String, keys: [String: String]) {
        var keys = stream.clearKeys
        var address = stream.url
        guard ClearKey.looksLikeDash(stream.url) else { return (address, keys) }
        if let m = await ManifestProxy.shared.open(stream.url, headers: stream.headers, maxHeight: maxHeight) {
            address = m.address
            if keys.isEmpty { keys = await ClearKey.resolve(xml: m.xml, using: stremio) }
        } else if keys.isEmpty {
            keys = await ClearKey.resolve(manifestUrl: stream.url, using: stremio)
        }
        return (address, keys)
    }

    /// How many captions go in: the viewer's own language gets room to choose, every other
    /// language a couple, and the whole list stays short. Each one is a download the engine
    /// makes, and an add-on can offer a hundred.
    static let subsWanted = 12, subsPerOther = 2, subsTotal = 30

    /// The captions to attach, in order. The viewer's language is selected and the rest wait in
    /// the menu. The viewer's language is counted first, so the total cap never squeezes it out.
    static func subtitlePlan(stream: StreamItem, addon: [SubTrack], want: String) -> [SubPick] {
        let all = stream.subtitles + addon
        func wanted(_ s: SubTrack) -> Bool { !want.isEmpty && s.lang == want }
        var room: [String: Int] = [:]
        var keep = Set<Int>()
        let byPriority = all.indices.sorted { a, b in (wanted(all[a]) ? 0 : 1, a) < (wanted(all[b]) ? 0 : 1, b) }
        for i in byPriority where keep.count < subsTotal {
            let s = all[i], n = room[s.lang] ?? 0
            if n >= (wanted(s) ? subsWanted : subsPerOther) { continue }
            room[s.lang] = n + 1
            keep.insert(i)
        }
        var perLang: [String: Int] = [:]
        var picked = false
        var out: [SubPick] = []
        for i in all.indices where keep.contains(i) {
            let s = all[i]
            let n = (perLang[s.lang] ?? 0) + 1
            perLang[s.lang] = n
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

        /// The file is open. True when the captions should go in now.
        mutating func fileLoaded() -> Bool { fileOpen = true; return take() }

        /// The add-ons answered (or the wait for them ran out). True when the captions should go in now.
        mutating func addonsAnswered(_ subs: [SubTrack]) -> Bool { addonSubs = subs; return take() }

        private mutating func take() -> Bool {
            guard fileOpen, addonSubs != nil, !settled else { return false }
            settled = true
            return true
        }
    }

    /// Put the plan into the engine. With nothing external to add, the file's own tracks are
    /// left exactly as the engine chose them.
    static func attachCaptions(_ gate: CaptionGate, stream: StreamItem, want: String, to mpv: MPVController) {
        let plan = subtitlePlan(stream: stream, addon: gate.addonSubs ?? [], want: want)
        if plan.isEmpty { return }
        for p in plan { mpv.addSubtitle(url: p.url, lang: p.lang, title: p.title, select: p.select) }
        if want.isEmpty { mpv.selectTrack("sub", id: nil) }
    }

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
