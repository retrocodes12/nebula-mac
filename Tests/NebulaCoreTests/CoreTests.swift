import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NebulaCore

func tempStore() -> Store {
    Store(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nebula-test-" + UUID().uuidString))
}

func ep(_ id: String, _ s: Int, _ e: Int) -> Episode {
    Episode(id: id, season: s, episode: e, name: "E\(e)", overview: nil, thumbnail: nil, released: nil)
}

final class ManifestTests: XCTestCase {
    func testRepeatedResourceScopesAreUnioned() {
        let j = JSON.object("""
        {"name":"Pengu","types":["movie"],"resources":[
          {"name":"stream","types":["movie","series"],"idPrefixes":["tt","tmdb:"]},
          {"name":"stream","types":["tv"],"idPrefixes":["pp-live:"]}, "catalog"],
         "catalogs":[]}
        """)!
        let m = Stremio.parseManifest(j, url: "https://x.test/abc/manifest.json")
        XCTAssertEqual(m.addon.base, "https://x.test/abc")
        XCTAssertTrue(m.canStream("movie", "tt123"))
        XCTAssertTrue(m.canStream("tv", "pp-live:9"))
        XCTAssertFalse(m.canStream("movie", "kitsu:1"))
        XCTAssertFalse(m.canMeta("movie", "tt1"))
    }

    func testPlainResourceUsesTopLevelScopeAndOpenScopeStaysOpen() {
        let j = JSON.object("""
        {"name":"A","types":["movie"],"idPrefixes":["tt"],"resources":["stream",{"name":"stream"},"meta"]}
        """)!
        let m = Stremio.parseManifest(j, url: "https://x.test/manifest.json")
        XCTAssertTrue(m.canStream("movie", "tt1"))
        XCTAssertTrue(m.canMeta("movie", "tt9"))
        XCTAssertFalse(m.canMeta("series", "tt9"))
    }

    func testOpenScopeMatchesEverything() {
        let j = JSON.object(#"{"name":"A","resources":[{"name":"stream","types":["movie"],"idPrefixes":["tt"]},{"name":"stream","types":[],"idPrefixes":[]}]}"#)!
        let m = Stremio.parseManifest(j, url: "https://x.test/manifest.json")
        XCTAssertTrue(m.canStream("anything", "zz:1"))
    }

    func testCatalogExtras() {
        let j = JSON.object("""
        {"name":"A","resources":["catalog"],"catalogs":[
          {"type":"movie","id":"top","name":"Top","extra":[{"name":"genre","options":["Drama","Comedy"]},{"name":"skip"},{"name":"search"}]},
          {"type":"movie","id":"last","extra":[{"name":"lastVideosIds","isRequired":true}]},
          {"type":"series","id":"yr","extra":[{"name":"genre","isRequired":true,"options":["2024"]}]},
          {"type":"movie","id":"old","extraSupported":["search","skip"],"extraRequired":["search"]}]}
        """)!
        let c = Stremio.parseManifest(j, url: "https://x.test/manifest.json").catalogs
        XCTAssertEqual(c[0].genres, ["Drama", "Comedy"]); XCTAssertTrue(c[0].skip); XCTAssertTrue(c[0].search); XCTAssertTrue(c[0].browsable)
        XCTAssertFalse(c[1].browsable)
        XCTAssertTrue(c[2].browsable)
        XCTAssertFalse(c[3].browsable); XCTAssertTrue(c[3].search)
    }

    func testAddonUrlOf() {
        XCTAssertEqual(Stremio.addonUrlOf("stremio://a.test/x/manifest.json"), "https://a.test/x/manifest.json")
        XCTAssertEqual(Stremio.addonUrlOf(" a.test/x/ "), "https://a.test/x/manifest.json")
        XCTAssertNil(Stremio.addonUrlOf("  "))
    }

    func testStreamsParse() {
        let j = JSON.object("""
        {"streams":[
          {"name":"Src 1080p","title":"Film.2020.1080p.WEB-DL\\n💾 2.1 GB","url":"https://h.test/a.mpd#clearkey=00112233445566778899aabbccddeeff:ffeeddccbbaa99887766554433221100",
           "behaviorHints":{"bingeGroup":"g1","videoSize":5,"proxyHeaders":{"request":{"Referer":"https://r.test/"}}}},
          {"name":"torrent","infoHash":"0123456789012345678901234567890123456789"},
          {"name":"K","description":"d","url":"https://h.test/b.mpd","clearKeys":{"00112233-4455-6677-8899-aabbccddeeff":"FFEEDDCCBBAA99887766554433221100"}}]}
        """)!
        let s = Stremio.parseStreams(j)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].url, "https://h.test/a.mpd")
        XCTAssertEqual(s[0].clearKeys, ["00112233445566778899aabbccddeeff": "ffeeddccbbaa99887766554433221100"])
        XCTAssertEqual(s[0].headers["Referer"], "https://r.test/")
        XCTAssertEqual(s[0].bingeGroup, "g1")
        XCTAssertEqual(s[1].title, "d")
        XCTAssertEqual(s[1].clearKeys.count, 1)
    }
}

final class ClearKeyTests: XCTestCase {
    func testLicenceAddressAndKeys() {
        let xml = #"<ContentProtection><dashif:laurl xmlns:dashif="x">https://l.test/k?a=1&amp;b=2</dashif:laurl></ContentProtection>"#
        XCTAssertEqual(ClearKey.licenceUrl(inManifest: xml), "https://l.test/k?a=1&b=2")
        XCTAssertNil(ClearKey.licenceUrl(inManifest: "<MPD/>"))
        let lic = JSON.object(#"{"keys":[{"kty":"oct","kid":"ABEiM0RVZneImaq7zN3u_w","k":"_-7dzLuqmYh3ZlVEMyIRAA"}]}"#)!
        XCTAssertEqual(ClearKey.keys(fromLicence: lic), ["00112233445566778899aabbccddeeff": "ffeeddccbbaa99887766554433221100"])
    }

    func testDemuxerOptions() {
        XCTAssertEqual(ClearKey.demuxerOptions([:]), "")
        let o = ClearKey.demuxerOptions(["bb": "22", "aa": "11"])
        XCTAssertEqual(o, "cenc_decryption_key=11,cenc_decryption_keys=aa=11:bb=22")
        XCTAssertTrue(ClearKey.looksLikeDash("https://a.test/x/manifest.MPD?t=1"))
        XCTAssertFalse(ClearKey.looksLikeDash("https://a.test/x.m3u8"))
    }
}

final class DashManifestTests: XCTestCase {
    let mpd = """
    <?xml version="1.0"?>
    <MPD type="dynamic" minimumUpdatePeriod="PT5S">
      <Period id="1">
        <AdaptationSet mimeType="video/mp4">
          <Representation id="1" height="576" bandwidth="1400000"><SegmentTemplate media="v1_$Number$.mp4"/></Representation>
          <Representation id="5" height="720" bandwidth="4200000"><SegmentTemplate media="v5_$Number$.mp4"/></Representation>
          <Representation id="4" height="720" bandwidth="2099968"><SegmentTemplate media="v4_$Number$.mp4"/></Representation>
          <Representation id="6" height="1080" bandwidth="8200000"><SegmentTemplate media="v6_$Number$.mp4"/></Representation>
        </AdaptationSet>
        <AdaptationSet mimeType="audio/mp4" lang="en">
          <Representation id="a1" bandwidth="128000"/>
          <Representation id="a2" bandwidth="64000"/>
        </AdaptationSet>
      </Period>
    </MPD>
    """

    func ids(_ xml: String) -> [String] {
        DashManifest.matches(DashManifest.reRep, xml).compactMap { DashManifest.attr("id", in: DashManifest.openTag($0)) }
    }

    func testKeepsTheBestPictureAndEverySoundtrack() {
        XCTAssertEqual(ids(DashManifest.oneVideoQuality(mpd)), ["6", "a1", "a2"])
    }

    func testHonoursACeilingAndPicksTheRicherOfTwoAtThatHeight() {
        XCTAssertEqual(ids(DashManifest.oneVideoQuality(mpd, maxHeight: 720)), ["5", "a1", "a2"])
        XCTAssertEqual(ids(DashManifest.oneVideoQuality(mpd, maxHeight: 240)), ["1", "a1", "a2"], "all taller than asked: the smallest")
    }

    func testGivesARelativeManifestItsOwnFolderAsBase() {
        let out = DashManifest.absoluteBase(mpd, manifestUrl: "https://h.test/live/ch1/manifest.mpd?token=abc")
        XCTAssertTrue(out.contains("<MPD type=\"dynamic\" minimumUpdatePeriod=\"PT5S\"><BaseURL>https://h.test/live/ch1/</BaseURL>"))
    }

    func testLeavesAnAbsoluteBaseAloneAndResolvesARelativeOne() {
        let abs = mpd.replacingOccurrences(of: "<Period id=\"1\">", with: "<BaseURL>https://cdn.test/x/</BaseURL><Period id=\"1\">")
        XCTAssertEqual(DashManifest.absoluteBase(abs, manifestUrl: "https://h.test/a/m.mpd"), abs)
        let rel = mpd.replacingOccurrences(of: "<Period id=\"1\">", with: "<BaseURL>dash/</BaseURL><Period id=\"1\">")
        XCTAssertTrue(DashManifest.absoluteBase(rel, manifestUrl: "https://h.test/a/m.mpd").contains("<BaseURL>https://h.test/a/dash/</BaseURL>"))
    }

    /// `NEBULA_MPD_IN=<file> NEBULA_MPD_URL=<its address> NEBULA_MPD_OUT=<file>` runs the preparer
    /// over a manifest captured from a real source, so the result can be handed to FFmpeg.
    func testPrepareACapturedManifest() throws {
        let env = ProcessInfo.processInfo.environment
        guard let src = env["NEBULA_MPD_IN"], let out = env["NEBULA_MPD_OUT"] else { throw XCTSkip("no captured manifest given") }
        let xml = try String(contentsOfFile: src, encoding: .utf8)
        let done = DashManifest.prepare(xml, manifestUrl: env["NEBULA_MPD_URL"] ?? "https://h.test/m.mpd", maxHeight: Int(env["NEBULA_MPD_MAX"] ?? "") ?? 0)
        try done.write(toFile: out, atomically: true, encoding: .utf8)
        XCTAssertLessThan(done.count, xml.count + 200)
    }

    func testANestedBaseIsNotMistakenForTheTopOne() {
        let nested = mpd.replacingOccurrences(of: "<AdaptationSet mimeType=\"video/mp4\">", with: "<AdaptationSet mimeType=\"video/mp4\"><BaseURL>video/</BaseURL>")
        let out = DashManifest.absoluteBase(nested, manifestUrl: "https://h.test/a/m.mpd")
        XCTAssertTrue(out.contains("<BaseURL>https://h.test/a/</BaseURL>"))
        XCTAssertTrue(out.contains("<BaseURL>video/</BaseURL>"))
    }
}

final class IdsTests: XCTestCase {
    func testSeriesId() {
        XCTAssertEqual(Ids.seriesId(of: "tt123:1:2"), "tt123")
        XCTAssertEqual(Ids.seriesId(of: "12345:1:2"), "12345")
        XCTAssertEqual(Ids.seriesId(of: "kitsu:12345:3"), "kitsu:12345")
        XCTAssertEqual(Ids.seriesId(of: "tmdb:9:1:2"), "tmdb:9")
        XCTAssertEqual(Ids.seriesId(of: "tt123"), "tt123")
        XCTAssertEqual(Ids.episodeKicker("tt1:2:4"), "Season 2 · Episode 4")
        XCTAssertEqual(Ids.episodeKicker("kitsu:5:3"), "Episode 3")
        XCTAssertNil(Ids.episodeKicker("tt1"))
        XCTAssertEqual(Ids.episodeTag("tmdb:9:1:2"), "S1E2")
    }
}

final class ProgressTests: XCTestCase {
    func rec(_ id: String, pos: Double, dur: Double) -> ProgressRec {
        var r = ProgressRec(type: "movie", id: id); r.name = id; r.pos = pos; r.dur = dur; return r
    }

    func testNoteRules() {
        let p = ProgressStore(store: tempStore())
        p.note(rec("a", pos: 5, dur: 6000))
        XCTAssertNil(p.get("movie", "a"), "too early to be worth a record")
        p.note(rec("a", pos: 600, dur: 6000))
        XCTAssertEqual(p.resumeAt("movie", "a"), 600)
        XCTAssertEqual(p.continueList().map(\.id), ["a"])
        p.note(rec("a", pos: 3, dur: 6000))
        XCTAssertTrue(p.get("movie", "a")!.dismissed, "rewound to the top leaves a tombstone")
        p.note(rec("a", pos: 5990, dur: 6000))
        XCTAssertTrue(p.get("movie", "a")!.done)
        XCTAssertEqual(p.resumeAt("movie", "a"), 0)
        XCTAssertTrue(p.continueList().isEmpty)
    }

    func testPersistsAcrossInstancesInWireShape() {
        let s = tempStore()
        ProgressStore(store: s).note(rec("a", pos: 700.5, dur: 6000))
        let again = ProgressStore(store: s)
        XCTAssertEqual(again.get("movie", "a")?.pos, 700.5)
        let wire = s.object("progress").obj("movie:a")!
        XCTAssertEqual(wire.num("pos"), 700.5, "seconds on disk, as on the wire")
        XCTAssertNil(wire["done"])
    }

    func testMarkWatchedHandFlag() {
        let p = ProgressStore(store: tempStore())
        p.markWatched("series", "tt1:1:1")
        XCTAssertTrue(p.get("series", "tt1:1:1")!.hand)
        var r = ProgressRec(type: "series", id: "tt1:1:2"); r.pos = 300; r.dur = 3000
        p.note(r)
        p.markWatched("series", "tt1:1:2")
        XCTAssertFalse(p.get("series", "tt1:1:2")!.hand, "finishing what you were watching is not a claim about the past")
        p.markUnwatched("series", "tt1:1:2")
        XCTAssertTrue(p.get("series", "tt1:1:2")!.dismissed)
    }

    func testTrimSparesResumePoints() {
        let p = ProgressStore(store: tempStore())
        var m: [String: ProgressRec] = [:]
        for i in 0..<10 { var r = rec("live\(i)", pos: 100, dur: 6000); r.at = Int64(i + 1); m["movie:live\(i)"] = r }
        for i in 0..<420 { var r = ProgressRec(type: "series", id: "t\(i)"); r.done = true; r.hand = true; r.at = Int64(10_000 + i); m["series:t\(i)"] = r }
        p.replaceAll(m)
        let all = p.all()
        XCTAssertEqual(all.count, ProgressStore.maxRecords)
        XCTAssertEqual(all.values.filter { !$0.done }.count, 10, "the oldest records here are resume points and must survive")
    }

    func testContinueSkipsDisabledAddons() {
        let p = ProgressStore(store: tempStore())
        var r = rec("a", pos: 600, dur: 6000); r.addonUrl = "https://off.test/manifest.json"
        p.note(r)
        p.disabledAddons = { ["https://off.test/manifest.json"] }
        XCTAssertTrue(p.continueList().isEmpty)
    }
}

final class CursorTests: XCTestCase {
    let videos = [ep("s:0:1", 0, 1), ep("s:1:1", 1, 1), ep("s:1:2", 1, 2), ep("s:2:1", 2, 1), ep("s:2:2", 2, 2)]

    func done(_ id: String, at: Int64, hand: Bool = false) -> ProgressRec {
        var r = ProgressRec(type: "series", id: id); r.done = true; r.hand = hand; r.at = at; return r
    }

    func testNothingStarted() {
        XCTAssertNil(SeriesCursor.find(type: "series", videos: videos, progress: [:]))
    }

    func testPlayedThenNext() {
        let c = SeriesCursor.find(type: "series", videos: videos, progress: ["series:s:1:2": done("s:1:2", at: 5)])
        XCTAssertEqual(c?.upNext?.id, "s:2:1")
    }

    func testHandMarkNeverMovesTheCursorBackwards() {
        // sitting at S2E1 (played), then ticking S1E1 by hand later must not send Up next to S1E2
        let all = ["series:s:2:1": done("s:2:1", at: 5), "series:s:1:1": done("s:1:1", at: 99, hand: true)]
        XCTAssertEqual(SeriesCursor.find(type: "series", videos: videos, progress: all)?.upNext?.id, "s:2:2")
    }

    func testHandMarksOnlyStepForward() {
        let all = ["series:s:1:1": done("s:1:1", at: 1, hand: true), "series:s:1:2": done("s:1:2", at: 2, hand: true)]
        XCTAssertEqual(SeriesCursor.find(type: "series", videos: videos, progress: all)?.upNext?.id, "s:2:1")
    }

    func testFinishedShowIgnoresSpecialsForSomeoneWhoNeverWatchedThem() {
        let c = SeriesCursor.find(type: "series", videos: videos, progress: ["series:s:2:2": done("s:2:2", at: 5)])
        XCTAssertNil(c?.upNext)
        XCTAssertEqual(c?.seat.id, "s:2:2")
    }

    func testPartWayIsItsOwnUpNext() {
        var r = ProgressRec(type: "series", id: "s:1:2"); r.pos = 300; r.dur = 3000; r.at = 9
        XCTAssertEqual(SeriesCursor.find(type: "series", videos: videos, progress: ["series:s:1:2": r])?.upNext?.id, "s:1:2")
    }
}

final class LibraryTests: XCTestCase {
    func testToggleLeavesATombstone() {
        let s = tempStore()
        let l = LibraryStore(store: s)
        let m = MetaItem(id: "tt1", type: "movie", name: "Film", poster: "p")
        XCTAssertTrue(l.toggle(m, addonUrl: "u"))
        XCTAssertTrue(l.contains("movie", "tt1"))
        XCTAssertEqual(l.list().first?.name, "Film")
        XCTAssertFalse(l.toggle(m, addonUrl: "u"))
        XCTAssertFalse(l.contains("movie", "tt1"))
        XCTAssertTrue(s.object("library").obj("movie:tt1")!.bool("removed"))
        XCTAssertTrue(l.list().isEmpty)
    }
}

final class BadgeTests: XCTestCase {
    func testPlateAndBadges() {
        let raw = "Torrentio 4K\nFilm.2020.2160p.UHD.BluRay.REMUX.DV.HDR10+.TrueHD.Atmos.7.1.HEVC-GRP\n👤 120 💾 58.2 GB ⚙️ TorrentGalaxy"
        XCTAssertEqual(StreamBadges.plate(raw), StreamBadges.Plate(res: "4K", tag: "ULTRA HD"))
        let m = StreamBadges.match(raw)
        XCTAssertEqual(m.badges, ["dolby_vision.png", "remux.png", "HEVC_transparent_4x.png", "dolby_atmos.png", "7_1_audio.png"])
        let f = StreamBadges.facts(videoSize: 0, text: raw, fired: m.fired)
        XCTAssertEqual(f.size, "58.2 GB"); XCTAssertEqual(f.seeds, "120"); XCTAssertEqual(f.provider, "TorrentGalaxy")
    }

    func testHdr10IsNotHdr10Plus() {
        XCTAssertEqual(StreamBadges.match("x 1080p HDR10 DDP 5.1").badges, ["hdr10.png", "dolby_digital_plus.png", "5_1_audio.png"])
        XCTAssertEqual(StreamBadges.match("x DTS-HD MA").badges, ["dts_hd_master_audio.png"])
        XCTAssertEqual(StreamBadges.match("x DTS").badges, ["dts.png"])
    }

    func testCleanName() {
        XCTAssertEqual(StreamBadges.cleanName("Torrentio\n4k 🎬 | DV", addonName: "Torrentio"), "DV")
        XCTAssertEqual(StreamBadges.resRank("a 720p"), 2)
    }

    func testRowsDoNotRepeatThePlateOrTalkInFormats() {
        XCTAssertEqual(StreamBadges.cleanName("Nebula Sports HD · FANCODE", addonName: "Nebula Sports"), "FANCODE")
        XCTAssertEqual(StreamBadges.cleanName("Nebula Sports FHD · TNT SPORTS", addonName: "Nebula Sports"), "TNT SPORTS")
        XCTAssertEqual(StreamBadges.cleanDesc("1080p ClearKey DASH · Plays only in Nebula Player"), "")
        XCTAssertEqual(StreamBadges.cleanDesc("720p · English commentary"), "English commentary")
        XCTAssertEqual(StreamBadges.cleanName("HDTV Rip", addonName: nil), "HDTV Rip")
    }

    func testLanguages() {
        let f = StreamBadges.facts(videoSize: 2_147_483_648, text: "Film\nHindi · English · 5 Mbps 🇫🇷")
        XCTAssertEqual(f.langs, "Hindi + English + French")
        XCTAssertEqual(f.size, "2.0 GB")
        XCTAssertEqual(f.bitrate, "5 Mbps")
    }
}

// MARK: a stand-in cloud, enough of cloud/server.js to drive sync end to end

final class FakeCloud: Transport, @unchecked Sendable {
    let lock = NSLock()
    var kv: [String: (v: String, rev: Int)] = [:]
    var tokens = Set<String>()
    var log: [String] = []
    var lastDevice: JSONObject?

    func send(_ request: URLRequest) async throws -> (Data, Int) { handle(request) }

    func handle(_ request: URLRequest) -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path.replacingOccurrences(of: "/cloud", with: "")
        let method = request.httpMethod ?? "GET"
        log.append("\(method) \(path)")
        let body = request.httpBody.flatMap(JSON.object) ?? [:]
        func reply(_ code: Int, _ o: JSONObject) -> (Data, Int) { (JSON.data(o), code) }
        if path == "/v1/profile/signin" {
            lastDevice = body.obj("device")
            if body.str("password") != "correct horse" { return reply(403, ["error": "wrong handle or password"]) }
            let t = "tok\(tokens.count)"; tokens.insert(t)
            return reply(200, ["gid": "g1", "token": t, "profile": ["handle": body.str("handle"), "name": "Sohil", "avatar": "#E50914"] as JSONObject])
        }
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        guard auth.hasPrefix("Bearer g1."), tokens.contains(String(auth.dropFirst("Bearer g1.".count))) else { return reply(401, ["error": "unauthorized"]) }
        if path == "/v1/kv" {
            var keys: JSONObject = [:]
            for (k, r) in kv { keys[k] = ["rev": r.rev, "at": 1] as JSONObject }
            return reply(200, ["keys": keys])
        }
        if path.hasPrefix("/v1/kv/") {
            let key = String(path.dropFirst("/v1/kv/".count))
            if method == "PUT" {
                let rev = (kv[key]?.rev ?? 0) + 1
                kv[key] = (body.str("v"), rev)
                return reply(200, ["rev": rev])
            }
            guard let r = kv[key] else { return reply(404, ["error": "not found"]) }
            return reply(200, ["v": r.v, "rev": r.rev, "at": 1])
        }
        if path == "/v1/profile/signout" { tokens.removeAll(); return reply(200, [:]) }
        return reply(404, ["error": "not found"])
    }
}

final class CloudTests: XCTestCase {
    struct Device {
        let store: Store, addons: AddonStore, progress: ProgressStore, library: LibraryStore, cloud: Cloud
    }

    func device(_ server: FakeCloud) -> Device {
        let s = tempStore()
        let a = AddonStore(store: s), p = ProgressStore(store: s), l = LibraryStore(store: s)
        return Device(store: s, addons: a, progress: p, library: l,
                      cloud: Cloud(store: s, addons: a, progress: p, library: l, transport: server, base: "https://c.test/cloud"))
    }

    func testDeviceIsFiledUnderItsOwnPlatform() async {
        let server = FakeCloud(), s = tempStore()
        let a = AddonStore(store: s), p = ProgressStore(store: s), l = LibraryStore(store: s)
        let phone = Cloud(store: s, addons: a, progress: p, library: l, transport: server, base: "https://c.test/cloud",
                          deviceName: "Sohil's iPhone", platform: "ios")
        _ = await phone.signIn(handle: "@sohil", password: "correct horse")
        XCTAssertEqual(server.lastDevice?.str("plat"), "ios")
        XCTAssertEqual(server.lastDevice?.str("name"), "Sohil's iPhone")
        // a Mac that says nothing is still a Mac
        let server2 = FakeCloud()
        _ = await device(server2).cloud.signIn(handle: "@sohil", password: "correct horse")
        XCTAssertEqual(server2.lastDevice?.str("plat"), "macos")
    }

    func testWrongPasswordIsASentence() async {
        let d = device(FakeCloud())
        let err = await d.cloud.signIn(handle: "@Sohil", password: "nope")
        XCTAssertEqual(err, "Wrong handle or password.")
        let linked = await d.cloud.linked
        XCTAssertFalse(linked)
        let bad = await d.cloud.signIn(handle: "a", password: "x")
        XCTAssertEqual(bad, "Handles are 3–20 letters, numbers or underscores.")
    }

    func testTwoDevicesConverge() async {
        let server = FakeCloud()
        let a = device(server), b = device(server)

        a.addons.seedIfNeeded()
        a.addons.save(a.addons.all() + [Addon(manifestUrl: "https://mine.test/manifest.json", name: "Mine", base: "https://mine.test")])
        var r = ProgressRec(type: "movie", id: "tt1"); r.name = "Film"; r.pos = 600; r.dur = 6000
        a.progress.note(r)
        a.progress.markWatched("series", "tt2:1:1")
        a.library.toggle(MetaItem(id: "tt1", type: "movie", name: "Film"), addonUrl: "")
        let e1 = await a.cloud.signIn(handle: "sohil", password: "correct horse")
        XCTAssertNil(e1)
        XCTAssertEqual(a.cloud.storedProfile()?.handle, "sohil")
        XCTAssertEqual(Set(server.kv.keys), ["addons", "progress", "library"], "the first device seeds the profile")

        b.addons.seedIfNeeded()
        let e2 = await b.cloud.signIn(handle: "sohil", password: "correct horse")
        XCTAssertNil(e2)
        XCTAssertEqual(b.progress.resumeAt("movie", "tt1"), 600)
        XCTAssertTrue(b.progress.get("series", "tt2:1:1")!.hand, "the hand flag must survive the wire")
        XCTAssertTrue(b.library.contains("movie", "tt1"))
        XCTAssertTrue(b.addons.all().contains { $0.name == "Mine" })

        // B removes the add-on and moves on in the film; A must follow both
        b.addons.save(b.addons.all().filter { $0.name != "Mine" })
        var r2 = r; r2.pos = 1200
        try? await Task.sleep(nanoseconds: 5_000_000)
        b.progress.note(r2)
        await b.cloud.noteChanged("addons"); await b.cloud.noteChanged("progress")
        await b.cloud.flush()
        await a.cloud.pullAll(force: true)
        XCTAssertFalse(a.addons.all().contains { $0.name == "Mine" }, "a removal beats the older add")
        XCTAssertEqual(a.progress.resumeAt("movie", "tt1"), 1200)
        XCTAssertTrue(a.addons.all().contains { $0.name == "Cinemeta" }, "a seeded default is never removed by a device that lacks it")
    }

    func testRevokedTokenSignsTheDeviceOut() async {
        let server = FakeCloud()
        let a = device(server)
        _ = await a.cloud.signIn(handle: "sohil", password: "correct horse")
        server.tokens.removeAll()
        await a.cloud.pullAll(force: true)
        let linked = await a.cloud.linked
        XCTAssertFalse(linked)
        XCTAssertNil(a.cloud.storedProfile())
    }
}

final class HostileDataTests: XCTestCase {
    func testNumbersThatDoNotFitDegradeToZero() {
        let o: JSONObject = ["nan": "nan", "inf": "inf", "ninf": "-inf", "big": 1e300, "neg": -1e300,
                             "edge": 9.3e18, "ok": 42.9, "s": "17", "none": NSNull()]
        for k in ["nan", "inf", "ninf", "big", "neg", "edge", "none", "missing"] {
            XCTAssertEqual(o.int(k), 0, k)
            XCTAssertEqual(o.int64(k), 0, k)
        }
        XCTAssertEqual(o.int("ok"), 42)
        XCTAssertEqual(o.int64("s"), 17)
    }

    func testAStreamRowWithAnImpossibleSizeStillParses() {
        let j = JSON.object(#"""
        {"streams":[{"url":"https://x.test/a.mkv","behaviorHints":{"videoSize":1e300}},
                    {"url":"https://x.test/b.mkv","behaviorHints":{"videoSize":"nan"}},
                    {"url":"https://x.test/c.mkv","behaviorHints":{"videoSize":1073741824}}]}
        """#)!
        XCTAssertEqual(Stremio.parseStreams(j).map(\.videoSize), [0, 0, 1_073_741_824])
    }
}

final class ConcurrentStoreTests: XCTestCase {
    /// Playback, marks and a sync merge land on different threads at once; none may be lost.
    func testProgressWritesFromManyThreadsAreAllKept() {
        let p = ProgressStore(store: tempStore())
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            if i % 2 == 0 {
                var r = ProgressRec(type: "movie", id: "tt\(i)"); r.pos = 100; r.dur = 1000
                p.note(r)
            } else {
                p.mutate(notify: false) { m in
                    var r = ProgressRec(type: "series", id: "tt\(i):1:1"); r.pos = 50; r.dur = 500; r.at = 1
                    m[ProgressStore.key(r.type, r.id)] = r
                    return true
                }
            }
        }
        XCTAssertEqual(p.all().count, 64)
        XCTAssertEqual(ProgressStore(store: p.store).all().count, 64)        // and in the stored document
    }

    func testMyListTogglesFromManyThreadsAreAllKept() {
        let l = LibraryStore(store: tempStore())
        DispatchQueue.concurrentPerform(iterations: 48) { i in
            l.toggle(MetaItem(id: "tt\(i)", type: "movie", name: "Film \(i)"), addonUrl: "")
        }
        XCTAssertEqual(l.list().count, 48)
    }
}
