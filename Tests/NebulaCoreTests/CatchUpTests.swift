import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NebulaCore

/// 0.4.0: what the other Nebula apps had and these did not.
final class HlsUnwrapTests: XCTestCase {
    func testPlaylistPiecesAndVariantsGoThroughLoopbackWithAnExtension() {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:7
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin?t=1"
        #EXTINF:6.0,
        https://cdn.test/a~tplv-origin.image?x-signature=1XIw%2FJ%3D&t=4
        #EXTINF:6.0,
        seg2.ts
        """
        let out = HlsUnwrap.rewrite(text, base: "https://host.test/t/abc/index.m3u8", prefix: "http://127.0.0.1:9/h/tok/")
        let lines = out.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "#EXTM3U")
        XCTAssertTrue(lines[2].hasPrefix("#EXT-X-KEY:METHOD=AES-128,URI=\"http://127.0.0.1:9/h/tok/r/"))
        XCTAssertTrue(lines[2].hasSuffix(".bin\""))
        XCTAssertTrue(lines[4].hasPrefix("http://127.0.0.1:9/h/tok/s/") && lines[4].hasSuffix(".ts"))
        XCTAssertFalse(lines[4].contains("?"), "a query string would hide the extension from the reader")
        let enc = String(lines[4].dropFirst("http://127.0.0.1:9/h/tok/".count))
        XCTAssertEqual(HlsUnwrap.ask(enc), .piece("https://cdn.test/a~tplv-origin.image?x-signature=1XIw%2FJ%3D&t=4"))
        let second = String(lines[6].dropFirst("http://127.0.0.1:9/h/tok/".count))
        XCTAssertEqual(HlsUnwrap.ask(second), .piece("https://host.test/t/abc/seg2.ts"))
        let key = lines[2].components(separatedBy: "URI=\"")[1].dropLast().dropFirst("http://127.0.0.1:9/h/tok/".count)
        XCTAssertEqual(HlsUnwrap.ask(String(key)), .raw("https://host.test/t/abc/key.bin?t=1"))
    }

    func testMasterPlaylistVariantsStayPlaylists() {
        let text = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nlow/index\n#EXT-X-MEDIA:TYPE=AUDIO,URI=\"audio/a.m3u8\"\nhigh.m3u8\n"
        let out = HlsUnwrap.rewrite(text, base: "https://h.test/m.m3u8", prefix: "P/").components(separatedBy: "\n")
        XCTAssertTrue(out[2].hasPrefix("P/p/") && out[2].hasSuffix(".m3u8"))
        XCTAssertEqual(HlsUnwrap.ask(String(out[2].dropFirst(2))), .playlist("https://h.test/low/index"))
        XCTAssertTrue(out[3].contains("URI=\"P/p/"))
        XCTAssertTrue(out[4].hasPrefix("P/p/"))
    }

    func testWrappedPieceIsCutAtItsFirstPacket() {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x11, count: 62)
        for _ in 0..<5 { d += Data([0x47]) + Data(repeating: 0, count: 187) }
        XCTAssertEqual(HlsUnwrap.tsStart(d), 70)
        XCTAssertEqual(HlsUnwrap.unwrap(d).first, 0x47)
        XCTAssertEqual(HlsUnwrap.unwrap(d).count, 188 * 5)
        let plain = d.subdata(in: 70..<d.count)
        XCTAssertEqual(HlsUnwrap.tsStart(plain), 0)
        let other = Data(repeating: 0x00, count: 5000)
        XCTAssertNil(HlsUnwrap.tsStart(other))
        XCTAssertEqual(HlsUnwrap.unwrap(other), other)
    }

    func testOnlyWebPlaylistsAndWebAddressesDecode() {
        XCTAssertTrue(HlsUnwrap.isPlaylist("https://x.test/t/a/index.m3u8"))
        XCTAssertFalse(HlsUnwrap.isPlaylist("https://x.test/a.mpd"))
        XCTAssertFalse(HlsUnwrap.isPlaylist("file:///etc/a.m3u8"))
        XCTAssertNil(HlsUnwrap.decode(HlsUnwrap.encode("file:///etc/passwd")))
        XCTAssertNil(HlsUnwrap.ask("x/" + HlsUnwrap.encode("https://a.test/") + ".ts"))
    }

    func testAddonRequestsSayTheyCarryHeaders() {
        let r = Net.addonRequest(URL(string: "https://a.test/manifest.json")!)
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Nebula-Caps"), "headers")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Nebula-Client"), "macos")
    }
}

final class SkipAndUniverseTests: XCTestCase {
    func testSkipSegments() {
        let s = SkipSegments.parse(JSON.object(#"{"recap":{"start":2,"end":6},"intro":{"start":8,"end":20},"outro":{"start":60,"end":70},"bad":{"start":1}}"#)!)
        XCTAssertEqual(s.recap, .init(start: 2, end: 6))
        XCTAssertEqual(SkipSegments.at(s, 3)?.kind, "recap")
        XCTAssertNil(SkipSegments.at(s, 5.5), "less than a second left is not worth a button")
        XCTAssertEqual(SkipSegments.at(s, 8)?.kind, "intro")
        XCTAssertNil(SkipSegments.at(s, 30))
        XCTAssertTrue(SkipSegments.inOutro(s, 61))
        XCTAssertFalse(SkipSegments.inOutro(s, 59))
        XCTAssertNil(SkipSegments.parse(JSON.object(#"{"intro":{"start":5,"end":5.5}}"#)!).intro)
        XCTAssertTrue(SkipSegments.eligible(type: "series", id: "tt0903747:1:2"))
        XCTAssertFalse(SkipSegments.eligible(type: "movie", id: "tt0903747"))
        XCTAssertFalse(SkipSegments.eligible(type: "series", id: "kitsu:1:2"))
    }

    func testSkipLoadAsksTheCloudOnceWithTheIdOnly() async {
        let t = ReplyTransport(#"{"intro":{"start":8,"end":20}}"#)
        let a = await SkipSegments.load("tt0000001:1:1", base: "https://c.test/cloud", transport: t)
        let b = await SkipSegments.load("tt0000001:1:1", base: "https://c.test/cloud", transport: t)
        XCTAssertEqual(a?.intro?.end, 20)
        XCTAssertEqual(b, a)
        let reqs = await t.requests
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(reqs[0].url?.absoluteString, "https://c.test/cloud/v1/skip?id=tt0000001:1:1")
    }

    func testUniverse() {
        XCTAssertEqual(Universe.idOf("tt0903747:2:3"), "tt0903747")
        XCTAssertNil(Universe.idOf("kitsu:1"))
        XCTAssertNil(Universe.idOf("tt12x"))
        let items = Universe.parse(JSON.object("""
        {"items":[{"id":"tt1","name":"x"},{"id":"tt0123456","name":"A","type":"series","year":2008,"end":2013,"rel":"followed_by","poster":"https://p"},
                  {"id":"tt0123456","name":"A again","rel":"spin_off"},{"id":"tt7654321","name":"B","year":2019,"rel":"remake_of","poster":null}]}
        """)!)
        XCTAssertEqual(items.map(\.id), ["tt0123456", "tt7654321"])
        XCTAssertEqual(items[0].meta.releaseInfo, "2008–2013")
        XCTAssertEqual(items[0].label, "Followed by")
        XCTAssertEqual(items[1].meta.type, "movie")
        XCTAssertNil(items[1].meta.poster)
    }
}

final class SeekrTests: XCTestCase {
    let key = "sk_live_" + String(repeating: "ab", count: 32)

    func testKeyAndQuery() {
        XCTAssertTrue(Seekr.validKey(key))
        XCTAssertFalse(Seekr.validKey("sk_live_123"))
        XCTAssertEqual(Seekr.query(type: "movie", id: "tt0133093")!.map { $0.0 + "=" + $0.1 }, ["imdb_id=tt0133093"])
        XCTAssertEqual(Seekr.query(type: "series", id: "tt0903747:01:002")!.map { $0.0 + "=" + $0.1 }, ["show_imdb_id=tt0903747", "season=1", "episode=2"])
        XCTAssertEqual(Seekr.query(type: "movie", id: "tmdb:603")!.map { $0.0 + "=" + $0.1 }, ["tmdb_id=603"])
        XCTAssertNil(Seekr.query(type: "tv", id: "tt0133093"))
        XCTAssertNil(Seekr.query(type: "series", id: "kitsu:1:2"))
    }

    func testVttAndCues() {
        let vtt = """
        WEBVTT

        00:00.000 --> 00:10.000
        https://sprites.seekr.tv/a/0.jpg#xywh=0,0,320,180

        00:10.000 --> 00:20.000
        https://sprites.seekr.tv/a/0.jpg#xywh=320,0,320,180

        00:20.000 --> 00:30.000
        http://insecure.test/x.jpg#xywh=0,0,1,1

        00:00:30.5 --> 00:00:40.000
        https://sprites.seekr.tv/a/1.jpg#xywh=0,180,320,180
        """
        let c = Seekr.parseVtt(vtt)
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(c[2].start, 30.5, accuracy: 0.001)
        XCTAssertEqual(c[1].x, 320)
        XCTAssertEqual(Seekr.cueIndex(c, pos: 3, scale: 1), 0)
        XCTAssertEqual(Seekr.cueIndex(c, pos: 6, scale: 1), 1, "past the midpoint the next picture is nearer")
        XCTAssertEqual(Seekr.cueIndex(c, pos: 9, scale: 2), 0, "our length is twice the source’s: 4.5 s there")
        XCTAssertEqual(Seekr.cueIndex([], pos: 1, scale: 1), -1)
        XCTAssertTrue(Seekr.parseVtt("not a vtt").isEmpty)
    }

    func testSyncedKeyIsNewestWins() async {
        let store = tempStore()
        let cloud = Cloud(store: store, addons: AddonStore(store: store), progress: ProgressStore(store: store), library: LibraryStore(store: store))
        let prefs = Prefs(store: store)
        prefs.setSeekrKey(key)
        let mine = store.object("seekr_v1").int64("at")
        var r = await cloud.merge("seekr", ["key": "", "at": mine - 5])
        XCTAssertEqual(r.changed, false); XCTAssertEqual(r.localNewer, true)
        r = await cloud.merge("seekr", ["key": "", "at": mine + 5])
        XCTAssertEqual(r.changed, true)
        XCTAssertEqual(prefs.seekrKey, "", "disconnected on another device")
        r = await cloud.merge("seekr", ["key": "nope", "at": mine + 50])
        XCTAssertEqual(r.changed, false, "a malformed doc is never adopted")
        let doc = await cloud.docFor("seekr")
        XCTAssertEqual(JSON.object(doc!)?.int64("at"), mine + 5)
    }
}

final class SubStyleAndSupportTests: XCTestCase {
    func testStyleNormalizesStepsAndTellsTheEngine() {
        let s = SubStyle.normalize(["size": "huge", "color": "pink"])
        XCTAssertEqual(s["size"], "huge")
        XCTAssertEqual(s["color"], "white")
        XCTAssertEqual(s.count, SubStyle.order.count)
        XCTAssertEqual(SubStyle.step("bg", from: "none"), "dark")
        XCTAssertEqual(SubStyle.step("bg", from: "dark", by: -1), "none")
        let p = Dictionary(SubStyle.engineProperties(["size": "large", "bg": "none", "edge": "outline", "bold": "on"]), uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(p["sub-scale"], "1.30")
        XCTAssertEqual(p["sub-border-style"], "outline-and-shadow")
        XCTAssertNil(p["sub-back-color"])
        XCTAssertEqual(p["sub-outline-size"], "2.4")
        XCTAssertEqual(p["sub-bold"], "yes")
        let d = Dictionary(SubStyle.engineProperties(SubStyle.defaults), uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(d["sub-back-color"], "#CC000000")
    }

    func testSyncedStyleMergesAndPushesItsShape() async {
        let store = tempStore()
        let cloud = Cloud(store: store, addons: AddonStore(store: store), progress: ProgressStore(store: store), library: LibraryStore(store: store))
        let prefs = Prefs(store: store)
        XCTAssertFalse(prefs.subStyleChosen)
        var r = await cloud.merge("sub_style", ["style": ["size": "xl"], "at": 10])
        XCTAssertEqual(r.changed, true)
        XCTAssertEqual(prefs.subStyle["size"], "xl")
        XCTAssertTrue(prefs.subStyleChosen)
        prefs.setSubStyle(["size": "small"])
        r = await cloud.merge("sub_style", ["style": ["size": "huge"], "at": 11])
        XCTAssertEqual(r.changed, false); XCTAssertEqual(r.localNewer, true)
        r = await cloud.merge("sub_style", ["at": 99999999999999])
        XCTAssertEqual(r.changed, false, "no style: never adopted")
        let doc = JSON.object(await cloud.docFor("sub_style")!)!
        XCTAssertEqual(doc.obj("style")?.str("size"), "small")
        XCTAssertEqual(doc.obj("style")?.count, SubStyle.order.count)
    }

    func testSupporterProfileFromEveryShape() {
        let me = Cloud.parseProfile(JSON.object("""
        {"on":true,"handle":"ann","name":"Ann","avatar":"#123456","supporter":{"since":5,"wall":true,"tier":"monthly","mark":"bolt",
         "subscription":{"status":"trialing","manage":"https://pay.test/m"}}}
        """))!
        XCTAssertEqual(me.rank, 2)
        XCTAssertEqual(me.tierName, "Monthly Supporter")
        XCTAssertEqual(me.shownMark, "bolt")
        XCTAssertEqual(me.planText, "Free week")
        XCTAssertEqual(me.planManage, "https://pay.test/m")
        let signIn = Cloud.parseProfile(JSON.object(#"{"handle":"bo","sup":true,"tier":"supporter","mark":"crown"}"#))!
        XCTAssertEqual(signIn.rank, 1)
        XCTAssertEqual(signIn.shownMark, "star", "a mark is chosen from Supporter Plus up")
        let none = Cloud.parseProfile(JSON.object(#"{"handle":"cy","supporter":null}"#))!
        XCTAssertEqual(none.rank, 0)
        let evil = Cloud.parseProfile(JSON.object(#"{"handle":"dd","supporter":{"tier":"god","subscription":{"manage":"javascript:x"}}}"#))!
        XCTAssertEqual(evil.tier, "supporter")
        XCTAssertEqual(evil.planManage, "")
    }

    func testSupportInfoAndCodes() {
        let i = SupportInfo.parse(JSON.object(#"{"url":"https://pay.test/s","wall":["Ann",{"name":"Bo","tier":"founder"},{"name":" "}],"count":7}"#)!)
        XCTAssertEqual(i.url, "https://pay.test/s")
        XCTAssertEqual(i.wall.map(\.name), ["Ann", "Bo"])
        XCTAssertEqual(i.wall[1].tier, "founder")
        XCTAssertNil(SupportInfo.parse(JSON.object(#"{"url":"javascript:alert(1)"}"#)!).url)
        XCTAssertEqual(Cloud.supportCode("neb-ab12 cd34"), "AB12CD34")
        XCTAssertEqual(Cloud.supportCode("abc"), "")
    }
}
