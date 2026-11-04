import Foundation
import NebulaCore

/// The screenshot rigs' streams page for the card designs (the Mac's `--shots`, the iPhone's `--cards-page list`):
/// one film's rows as two add-ons really send them, planted on the model so no add-on is asked.
@MainActor
enum CardShots {
    static let item = MetaItem(id: "tt0468569", type: "movie", name: "The Dark Knight",
                               background: "https://images.metahub.space/background/medium/tt0468569/img")
    static var target: StreamsTarget { StreamsTarget(type: "movie", id: item.id, item: item, addonUrl: "https://shots.invalid/torrentio/manifest.json") }

    static func row(_ name: String, _ title: String, file: String = "", size: Int64 = 0) -> StreamItem {
        var s = StreamItem(name: name, title: title, url: "https://shots.invalid/" + String(title.utf8.count))
        s.fileName = file; s.videoSize = size
        return s
    }

    static func sections() -> [StreamSection] {
        let torrentio = Addon(manifestUrl: "https://shots.invalid/torrentio/manifest.json", name: "Torrentio", base: "https://shots.invalid/torrentio")
        let hub = Addon(manifestUrl: "https://shots.invalid/4khdhub/manifest.json", name: "4KHDHub", base: "https://shots.invalid/4khdhub")
        let t = [
            StreamCards.sample,
            row("Torrentio\n1080p", "The Dark Knight 2008 1080p BluRay x264 DTS-HD MA 5.1\n👤 61 💾 12.4 GB ⚙️ 1337x"),
        ]
        let h = [
            row("4KHDHub | Direct", "The Dark Knight (2008) IMAX 2160p UHD BluRay REMUX DV HDR 10bit HEVC [Hindi DDP 2.0 + English TrueHD 5.1] x265 (FraMeSToR-LUMiX) 4KHDHub.com.mkv\n💾 52.71 GB\nHindi + English"),
            row("4KHDHub | Server 2", "Fast mirror · Hindi"),
            row("[TB⚡] 4KHDHub 4K", "Batman.The.Dark.Knight.2008.AD.MULTi.VFF.2160p.WEB.HDR10.EAC3.5.1.H265-Overflow.mp4", size: 24_266_000_000),
        ]
        return [
            StreamSection(addon: torrentio, streams: t, rows: t.map { StreamRowText($0, addonName: torrentio.name) }),
            StreamSection(addon: hub, streams: h, rows: h.map { StreamRowText($0, addonName: hub.name) }),
        ]
    }

    /// A Custom design for the shots: one line, compact, with the picture and sound marks and the seeds back on.
    static var customShot: JSONObject {
        var s = StreamCards.design("line").spec!
        s.marks = true; s.seeds = true
        return s.object
    }

    static func plant(_ m: AppModel) { m.plantedStreams = sections() }
}
