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

    /// The captions to attach, in order. The viewer's language is selected and the rest wait in
    /// the menu; a language that offers dozens of the same track is capped at twelve.
    static func subtitlePlan(stream: StreamItem, addon: [SubTrack], want: String) -> [SubPick] {
        var perLang: [String: Int] = [:]
        var picked = false
        var out: [SubPick] = []
        for s in stream.subtitles + addon {
            let n = (perLang[s.lang] ?? 0) + 1
            perLang[s.lang] = n
            if n > 12 { continue }
            let pick = !picked && !want.isEmpty && s.lang == want
            if pick { picked = true }
            let name = Lang.name(s.lang)
            out.append(SubPick(url: s.url, lang: s.lang,
                               title: n > 1 ? "\(name.isEmpty ? s.lang : name) \(n)" : "",
                               select: pick))
        }
        return out
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
