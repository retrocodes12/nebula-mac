import XCTest
@testable import NebulaCore

/// Stream card designs: the shared player's relTitle / relTags / language chips / leftover label / designs, the same cases.
final class StreamCardsTests: XCTestCase {
    func testTitleIsTheWordsBeforeTheYear() {
        XCTAssertEqual(StreamCards.relTitle("The.Dark.Knight.2008.UHD.BluRay.2160p.TrueHD.5.1.DV.HEVC.HYBRID.REMUX-FraMeSToR.mkv"), "The Dark Knight 2008")
        XCTAssertEqual(StreamCards.relTitle("The Dark Knight (2008) IMAX 2160p UHD BluRay REMUX DV HDR 10bit HEVC [Hindi DDP 2.0 + English TrueHD 5.1] x265 (FraMeSToR-LUMiX) 4KHDHub.com.mkv"),
                       "The Dark Knight 2008")
        XCTAssertEqual(StreamCards.relTitle("Batman.The.Dark.Knight.2008.AD.MULTi.VFF.2160p.WEB.HDR10.EAC3.5.1.H265-Overflow.mp4"), "Batman The Dark Knight 2008")
        XCTAssertEqual(StreamCards.relTitle("Charlotte's Web 2006 1080p"), "Charlotte's Web 2006")
    }

    func testNoYearStopsAtTheFirstReleaseWordAndALeadingGroupGoes() {
        XCTAssertEqual(StreamCards.relTitle("[YTS] Some.Film.1080p.WEB.x264.mkv"), "Some Film")
        XCTAssertEqual(StreamCards.relTitle("Show.Name.S01E03.1080p.WEB-DL.mkv"), "Show Name")
        XCTAssertEqual(StreamCards.relTitle("/a/b/Folder Film 720p.mp4"), "Folder Film")
        XCTAssertEqual(StreamCards.relTitle(""), "")
    }

    func testTagsSayTheSourceAndTheCodec() {
        XCTAssertEqual(StreamCards.relTags("The.Dark.Knight.2008.UHD.BluRay.2160p.TrueHD.5.1.DV.HEVC.HYBRID.REMUX-FraMeSToR.mkv"), ["BDRemux", "HEVC"])
        XCTAssertEqual(StreamCards.relTags("The Dark Knight (2008) IMAX 2160p UHD BluRay REMUX DV HDR 10bit HEVC [Hindi DDP 2.0 + English TrueHD 5.1] x265"), ["BDRemux", "HEVC"])
        XCTAssertEqual(StreamCards.relTags("Batman.The.Dark.Knight.2008.AD.MULTi.VFF.2160p.WEB.HDR10.EAC3.5.1.H265-Overflow.mp4"), ["WEB", "HEVC"])
        XCTAssertEqual(StreamCards.relTags("The Dark Knight 2008 1080p BluRay x264 DTS-HD MA 5.1"), ["BluRay", "AVC"])
        XCTAssertEqual(StreamCards.relTags("Film.2020.1080p.WEB-DL.AV1"), ["WEB-DL", "AV1"])
        XCTAssertEqual(StreamCards.relTags("Film REMUX"), ["Remux"])
        XCTAssertEqual(StreamCards.relTags("Server 2"), [])
    }

    func testLanguagesAreWordsThenFlagsAsTwoLetters() {
        let raw = "Torrentio\n4k DV | HDR\n👤 154 💾 53.75 GB ⚙️ TorrentGalaxy\nMulti Audio / 🇬🇧 / 🇳🇱"
        XCTAssertEqual(StreamBadges.langList(raw, max: 5).map(StreamCards.langCode), ["MULTI", "EN", "NL"])
        XCTAssertEqual(StreamBadges.langList("🇨🇳 🇹🇼 🇸🇦 🇹🇷 🇲🇽", max: 5), ["Chinese", "Arabic", "Turkish", "Latino"])
        XCTAssertEqual(StreamCards.langCode("Dual Audio"), "DUAL")
        XCTAssertEqual(StreamCards.langCode("Klingon"), "KL")
    }

    func testTheAddOnsOwnLabelIsWhatTheMarksAndTitleDoNotSay() {
        let torrentio = "Torrentio\n4k DV | HDR"
        let fired = StreamBadges.match(torrentio + "\nThe.Dark.Knight.2008.mkv").fired
        XCTAssertEqual(StreamCards.leftoverLabel(name: torrentio, addonName: "Torrentio", title: "The Dark Knight 2008", fired: fired, provider: "TorrentGalaxy"), "")
        XCTAssertEqual(StreamCards.leftoverLabel(name: "4KHDHub | Direct", addonName: "4KHDHub", title: "The Dark Knight 2008", fired: [], provider: nil), "Direct")
        XCTAssertEqual(StreamCards.leftoverLabel(name: "Src | " + String(repeating: "x", count: 45), addonName: "Src", title: "T", fired: [], provider: nil), "")
    }

    func testACardReadsTheRowOnce() {
        var s = StreamItem(name: "Torrentio\n4k DV | HDR",
                           title: "The.Dark.Knight.2008.UHD.BluRay.2160p.TrueHD.Atmos.7.1.DV.HEVC.REMUX-FraMeSToR.mkv\n👤 154 💾 53.75 GB ⚙️ TorrentGalaxy\nMulti Audio / 🇬🇧 / 🇳🇱",
                           url: "https://x/1")
        s.fileName = "The.Dark.Knight.2008.UHD.BluRay.2160p.TrueHD.Atmos.7.1.DV.HEVC.REMUX-FraMeSToR.mkv"
        let c = StreamRowText(s, addonName: "Torrentio").card
        XCTAssertEqual(c.title, "The Dark Knight 2008")
        XCTAssertEqual(c.tags, ["BDRemux", "HEVC"])
        XCTAssertEqual(c.res, "4K")
        XCTAssertEqual(c.marks, ["dolby_vision.png", "dolby_atmos.png"])
        XCTAssertEqual(c.langs, ["MULTI", "EN", "NL"])
        XCTAssertEqual(c.label, "")
        XCTAssertEqual(c.provider, "TorrentGalaxy")
        XCTAssertEqual(c.size, "53.75 GB")
        XCTAssertEqual(c.seeds, "154")
        XCTAssertEqual(c.file, s.fileName)
        XCTAssertEqual(c.desc, "")

        // no file name: a first line that reads like a release stands in for one; a plain label does not
        let line = StreamRowText(StreamItem(name: "Torrentio\n1080p", title: "The Dark Knight 2008 1080p BluRay x264 DTS-HD MA 5.1\n👤 61", url: "https://x/2"),
                                 addonName: "Torrentio").card
        XCTAssertEqual(line.title, "The Dark Knight 2008")
        XCTAssertEqual(line.res, "1080p")
        XCTAssertEqual(line.file, "The Dark Knight 2008 1080p BluRay x264 DTS-HD MA 5.1")
        let plain = StreamRowText(StreamItem(name: "4KHDHub | Server 2", title: "Fast mirror", url: "https://x/3"), addonName: "4KHDHub").card
        XCTAssertEqual(plain.title, "Server 2")
        XCTAssertEqual(plain.file, "")
        XCTAssertEqual(plain.desc, "Fast mirror")
        XCTAssertNil(plain.res)

        // a debrid mark is said in words, never left in a pill
        let deb = StreamRowText(StreamItem(name: "[TB⚡] 4KHDHub 4K", title: "Batman.The.Dark.Knight.2008.AD.MULTi.VFF.2160p.WEB.HDR10.EAC3.5.1.H265-Overflow.mp4",
                                           url: "https://x/4"), addonName: "4KHDHub").card
        XCTAssertEqual(deb.title, "Batman The Dark Knight 2008")
        XCTAssertEqual(deb.tags, ["WEB", "HEVC"])
        XCTAssertEqual(deb.label, "")
        XCTAssertEqual(deb.note, "instant")
        XCTAssertEqual(StreamBadges.cleanName("[RD+] Torrentio 1080p", addonName: "Torrentio"), "")
    }

    func testTheDesignsAreTheWebsOwn() {
        XCTAssertEqual(StreamCards.designs.map(\.id), ["release", "compact", "line", "minimal", "classic", "custom"])
        let release = StreamCards.design("release").spec!
        XCTAssertTrue(StreamCards.parts.allSatisfy { release[$0.id] })
        XCTAssertEqual(release.layout, .stack); XCTAssertFalse(release.dense)
        let compact = StreamCards.design("compact").spec!
        XCTAssertTrue(compact.dense); XCTAssertFalse(compact.service); XCTAssertFalse(compact.file); XCTAssertTrue(compact.marks)
        let line = StreamCards.design("line").spec!
        XCTAssertEqual(line.layout, .row)
        XCTAssertEqual(StreamCards.parts.filter { line[$0.id] }.map(\.id), ["tags", "size", "res", "addon", "play"])
        let minimal = StreamCards.design("minimal").spec!
        XCTAssertEqual(StreamCards.parts.filter { minimal[$0.id] }.map(\.id), ["size", "res"])
        XCTAssertNil(StreamCards.spec(style: "classic", custom: nil))
        XCTAssertEqual(StreamCards.spec(style: nil, custom: nil), release)
        XCTAssertEqual(StreamCards.spec(style: "nonsense", custom: nil), release)
    }

    func testCustomIsTheSavedOverReleaseAndStartsFromWhatWasShowing() {
        let saved: JSONObject = ["layout": "row", "dense": 1, "seeds": 0, "file": false, "extra": 1]
        let c = StreamCards.custom(saved)
        XCTAssertEqual(c.layout, .row); XCTAssertTrue(c.dense); XCTAssertFalse(c.seeds); XCTAssertFalse(c.file); XCTAssertTrue(c.marks)
        XCTAssertEqual(StreamCards.custom(["layout": "sideways"]).layout, .stack)
        XCTAssertEqual(StreamCards.spec(style: "custom", custom: nil), StreamCards.design("release").spec)
        let first = StreamCards.firstCustom(from: "line", custom: nil)
        XCTAssertEqual(StreamCards.custom(first), StreamCards.design("line").spec)
        XCTAssertEqual(first["layout"] as? String, "row")
        XCTAssertEqual(StreamCards.custom(StreamCards.firstCustom(from: "classic", custom: nil)), StreamCards.design("release").spec)
        // round trip through the prefs file
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sc-\(UUID().uuidString)")
        let p = Prefs(store: Store(directory: dir))
        XCTAssertEqual(p.streamStyle, "release")
        XCTAssertNil(p.streamCustom)
        p.streamCustom = first; p.streamStyle = "custom"
        let p2 = Prefs(store: Store(directory: dir))
        XCTAssertEqual(p2.streamStyle, "custom")
        XCTAssertEqual(p2.streamCard, StreamCards.design("line").spec)
        p2.streamStyle = "bogus"
        XCTAssertEqual(p2.streamStyle, "release")
    }
}
