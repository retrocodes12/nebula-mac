import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import NebulaCore

func tempStore() -> Store {
    Store(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nebula-test-" + UUID().uuidString))
}

func ep(_ id: String, _ s: Int, _ e: Int) -> Episode {
    Episode(id: id, season: s, episode: e, name: "E\(e)", overview: nil, thumbnail: nil, released: nil)
}

actor ReplyTransport: Transport {
    let body: Data
    var requests: [URLRequest] = []

    init(_ text: String) { body = Data(text.utf8) }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        return (body, 200)
    }
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
        XCTAssertFalse(m.canStream("movie", "pp-live:9"))
        XCTAssertFalse(m.canStream("tv", "tt123"))
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
        XCTAssertFalse(c[2].browsable)
        XCTAssertEqual(c[2].requiredExtras, ["genre"])
        XCTAssertFalse(c[3].browsable); XCTAssertTrue(c[3].search)
    }

    func testRequiredExtrasAreNeverAutomaticBrowseOrUnsupportedSearch() async throws {
        let j = JSON.object("""
        {"catalogs":[
          {"type":"movie","id":"genre","extra":[{"name":"genre","isRequired":true,"options":["Drama"]},{"name":"search"}]},
          {"type":"movie","id":"sort","extra":[{"name":"sort","isRequired":true,"options":["new"]},{"name":"search"}]},
          {"type":"movie","id":"search","extra":[{"name":"search","isRequired":true}]},
          {"type":"movie","id":"both","extraSupported":["search"],"extraRequired":["search","genre"]}]}
        """)!
        let cats = Stremio.parseManifest(j, url: "https://x.test/manifest.json").catalogs
        XCTAssertTrue(cats.allSatisfy { !$0.browsable })
        XCTAssertEqual(cats.map(\.search), [false, false, true, false])
        let transport = ReplyTransport(#"{"metas":[]}"#), client = Stremio(transport: transport)
        for catalog in cats {
            do {
                _ = try await client.loadCatalog(base: "https://x.test", catalog: catalog)
                XCTFail("missing required extra was sent")
            } catch { XCTAssertTrue(error is Stremio.MissingRequiredExtras) }
        }
        _ = try await client.loadCatalog(base: "https://x.test", catalog: cats[2], query: "film")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].url!.absoluteString.contains("/search=film.json"))
    }

    func testInvalidJSONAndNonObjectsThrow() async {
        for body in ["<html>Login</html>", "not json", "[]", "null", "42"] {
            do {
                _ = try await Stremio(transport: ReplyTransport(body)).getJSON("https://x.test/manifest.json")
                XCTFail("accepted \(body)")
            } catch { XCTAssertTrue(error is Stremio.BadJSON) }
        }
    }

    func testMalformedManifestsThrowBeforeInstallation() async {
        for body in ["{}", #"{"name":"Not a manifest"}"#, #"{"resources":["stream"]}"#,
                     #"{"id":" ","name":"","resources":[]}"#, #"{"id":42,"resources":[]}"#,
                     #"{"id":"a","resources":"stream"}"#, #"{"name":"A","resources":[{}]}"#,
                     #"{"id":"a","resources":[42]}"#, #"{"id":"a","resources":[{"name":42}]}"#,
                     #"{"name":"A","catalogs":[]}"#, #"{"name":"A","catalogs":{}}"#] {
            do {
                _ = try await Stremio(transport: ReplyTransport(body)).loadManifest("https://x.test/manifest.json")
                XCTFail("accepted malformed manifest: \(body)")
            } catch { XCTAssertTrue(error is Stremio.BadManifest) }
        }
    }

    func testMinimalManifestsDoNotNeedVersionOrTopLevelTypes() async throws {
        for body in [#"{"id":"a","resources":["stream"]}"#,
                     #"{"name":"A","resources":[{"name":"stream"}]}"#,
                     #"{"id":"a","name":"","version":7,"types":null,"resources":["stream"],"catalogs":{}}"#] {
            let manifest = try await Stremio(transport: ReplyTransport(body)).loadManifest("https://x.test/manifest.json")
            XCTAssertTrue(manifest.canStream("movie", "tt1"))
            XCTAssertTrue(manifest.canStream("tv", "live:1"))
        }
        for body in [#"{"name":"A","resources":[]}"#,
                     #"{"name":"A","catalogs":[{"id":"top","type":"movie"}]}"#,
                     #"{"id":"a","resources":null,"catalogs":[{}]}"#,
                     #"{"id":"a","resources":[{}],"catalogs":[{}]}"#] {
            _ = try await Stremio(transport: ReplyTransport(body)).loadManifest("https://x.test/manifest.json")
        }
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

    /// 2026-09-24: an add-on names web addresses only — a file: path or another scheme is dropped where it comes in.
    func testOnlyWebAddressesArePlayed() {
        let j = JSON.object("""
        {"streams":[
          {"name":"ok","url":"HTTPS://h.test/a.mkv","subtitles":[{"url":"https://s.test/a.srt","lang":"eng"},{"url":"file:///etc/passwd","lang":"eng"}]},
          {"name":"local","url":"file:///Users/me/secret.mkv"},
          {"name":"script","url":"javascript:alert(1)"},
          {"name":"data","url":"data:video/mp4;base64,AAAA"}]}
        """)!
        let s = Stremio.parseStreams(j)
        XCTAssertEqual(s.map(\.name), ["ok"])
        XCTAssertEqual(s[0].subtitles.map(\.url), ["https://s.test/a.srt"])
        XCTAssertTrue(Stremio.isWeb(" http://x.test/y "))
        XCTAssertFalse(Stremio.isWeb("smb://nas/film.mkv"))
    }

    /// 2026-10-07: an add-on that lists one id twice (or none at all) gave cards and episodes
    /// that shared an identity; each id is kept once, the first one listed.
    func testDuplicateAndEmptyIdsAreDropped() {
        let metas = JSON.object(#"{"metas":[{"id":"tt1","name":"First"},{"id":"","name":"Nameless"},{"name":"No id"},{"id":"tt1","name":"Again"},{"id":"tt2","name":"Second"}]}"#)!
        let items = Stremio.parseMetas(metas, fallbackType: "movie")
        XCTAssertEqual(items.map(\.id), ["tt1", "tt2"])
        XCTAssertEqual(items.first?.name, "First", "the first one listed is kept")
        let meta = Stremio.parseFullMeta(JSON.object(#"{"name":"Show","videos":[{"id":"tt9:1:1","season":1,"episode":1},{"id":""},{"id":"tt9:1:1","season":1,"episode":1,"name":"Twice"},{"id":"tt9:1:2","season":1,"episode":2}]}"#)!)
        XCTAssertEqual(meta.videos.map(\.id), ["tt9:1:1", "tt9:1:2"])
        XCTAssertEqual(meta.videos.first?.name, "Episode 1")
    }
}

final class ClearKeyTests: XCTestCase {
    func testLicenceAddressAndKeys() {
        let xml = #"<ContentProtection schemeIdUri="urn:uuid:e2719d58-a985-b3c9-781a-b030af78d30e"><dashif:laurl xmlns:dashif="https://dashif.org/">https://l.test/k?a=1&amp;b=2</dashif:laurl></ContentProtection>"#
        XCTAssertEqual(ClearKey.licenceUrl(inManifest: xml), "https://l.test/k?a=1&b=2")
        XCTAssertNil(ClearKey.licenceUrl(inManifest: "<MPD/>"))
        let lic = JSON.object(#"{"keys":[{"kty":"oct","kid":"ABEiM0RVZneImaq7zN3u_w","k":"_-7dzLuqmYh3ZlVEMyIRAA"}]}"#)!
        XCTAssertEqual(ClearKey.keys(fromLicence: lic), ["00112233445566778899aabbccddeeff": "ffeeddccbbaa99887766554433221100"])
    }

    func manifest(_ licence: String) -> String {
        """
        <MPD xmlns:dashif="https://dashif.org/" xmlns:ck="http://dashif.org/guidelines/clearKey">
          <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"><dashif:Laurl>https://widevine.test/licence</dashif:Laurl></ContentProtection>
          <ContentProtection schemeIdUri="urn:uuid:e2719d58-a985-b3c9-781a-b030af78d30e"><ck:Laurl>\(licence)</ck:Laurl></ContentProtection>
        </MPD>
        """
    }

    func testLicenceIsScopedToClearKeyProtection() {
        XCTAssertEqual(ClearKey.licenceUrl(inManifest: manifest("keys.json?a=1&amp;b=&#50;")), "keys.json?a=1&b=2")
        let wrong = manifest("keys.json").replacingOccurrences(of: "urn:uuid:e2719d58-a985-b3c9-781a-b030af78d30e", with: "urn:uuid:widevine")
        XCTAssertNil(ClearKey.licenceUrl(inManifest: wrong))
        XCTAssertNil(ClearKey.licenceUrl(inManifest: "<MPD><Laurl>https://wrong.test/</Laurl></MPD>"))
    }

    func testLicenceWithUndeclaredClearKeyPrefix() {
        let xml = """
        <MPD>
          <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"><clearkey:Laurl>wrong.json</clearkey:Laurl></ContentProtection>
          <ContentProtection schemeIdUri="urn:uuid:e2719d58-a985-b3c9-781a-b030af78d30e"><clearkey:Laurl>keys.json?a=1&amp;b=&#50;</clearkey:Laurl></ContentProtection>
        </MPD>
        """
        XCTAssertEqual(ClearKey.licenceUrl(inManifest: xml), "keys.json?a=1&b=2")
        XCTAssertEqual(ClearKey.licenceFallback(inManifest: xml), "keys.json?a=1&b=2")
    }

    func testCommonProtectionSchemeCanNameAClearKeyLicence() {
        for scheme in ["urn:uuid:1077efec-c0b2-4d02-ace3-3c1e52e2fb4b", "URN:UUID:1077EFEC-C0B2-4D02-ACE3-3C1E52E2FB4B", "URN:MPEG:DASH:CLEARKEY:2013"] {
            let xml = manifest("keys.json").replacingOccurrences(of: "urn:uuid:e2719d58-a985-b3c9-781a-b030af78d30e", with: scheme)
            XCTAssertEqual(ClearKey.licenceUrl(inManifest: xml), "keys.json")
            XCTAssertEqual(ClearKey.licenceFallback(inManifest: xml), "keys.json")
        }
    }

    func testLicenceFoundBeforeAnXMLFailureIsKept() {
        let xml = manifest("keys.json?a=1&amp;<![CDATA[b=2]]>") + "<broken"
        XCTAssertEqual(ClearKey.licenceUrl(inManifest: xml), "keys.json?a=1&b=2")
    }

    func testLicenceFallbackStaysInsideClearKeyProtection() {
        let wrong = """
        <MPD>
          <!-- <ContentProtection schemeIdUri="urn:mpeg:dash:clearkey:2013"><Laurl>comment.json</Laurl></ContentProtection> -->
          <ContentProtection schemeIdUri="urn:mpeg:dash:clearkey:2013"/>
          <ContentProtection schemeIdUri="urn:uuid:widevine"><clearkey:Laurl>wrong.json</clearkey:Laurl></ContentProtection>
          <ContentProtection><clearkey:Laurl>no-scheme.json</clearkey:Laurl></ContentProtection>
          <clearkey:Laurl>outside.json</clearkey:Laurl>
        </MPD>
        """
        XCTAssertNil(ClearKey.licenceFallback(inManifest: wrong))
        let clear = #"<mpd:ContentProtection schemeIdUri = 'URN:UUID:E2719D58-A985-B3C9-781A-B030AF78D30E'><ck:Laurl><![CDATA[keys.json?a=1&b=2]]></ck:Laurl></mpd:ContentProtection>"#
        XCTAssertEqual(ClearKey.licenceFallback(inManifest: wrong + clear), "keys.json?a=1&b=2")
    }

    func testRelativeLicenceUsesFinalManifestAndScopedHeaders() async {
        let reply = #"{"keys":[{"kid":"ABEiM0RVZneImaq7zN3u_w","k":"_-7dzLuqmYh3ZlVEMyIRAA"}]}"#
        let transport = ReplyTransport(reply), client = Stremio(transport: transport)
        let headers = ["Authorization": "Bearer fixture", "Referer": "https://media.test/watch"]
        let keys = await ClearKey.resolve(xml: manifest("keys.json?a=1&amp;b=2"), manifestUrl: "https://media.test/final/manifest.mpd", headers: headers, using: client)
        XCTAssertEqual(keys.count, 1)
        _ = await ClearKey.resolve(xml: manifest("https://licence.test/keys"), manifestUrl: "https://media.test/final/manifest.mpd", headers: headers, using: client)
        _ = await ClearKey.resolve(xml: manifest("keys.json"), manifestUrl: "https://redirect.test/final/manifest.mpd", headers: headers, headerOrigin: "https://media.test/original.mpd", using: client)
        _ = await ClearKey.resolve(xml: manifest("http://media.test/keys"), manifestUrl: "https://media.test/m.mpd", headers: headers, using: client)
        _ = await ClearKey.resolve(xml: manifest("https://media.test:8443/keys"), manifestUrl: "https://media.test/m.mpd", headers: headers, using: client)
        _ = await ClearKey.resolve(xml: manifest("file:///tmp/keys"), manifestUrl: "https://media.test/m.mpd", headers: headers, using: client)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://media.test/final/keys.json?a=1&b=2")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), headers["Authorization"])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Referer"), headers["Referer"])
        for request in requests.dropFirst() {
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
        }
    }

    func testFetchedManifestUsesItsRedirectedURLForTheLicence() async {
        struct RedirectedManifest: Transport {
            let xml: String
            let licence: ReplyTransport
            func send(_ request: URLRequest) async throws -> (Data, Int) { try await licence.send(request) }
            func sendWithURL(_ request: URLRequest) async throws -> (Data, Int, URL) {
                (Data(xml.utf8), 200, URL(string: "https://media.test/final/path/manifest.mpd")!)
            }
        }
        let licence = ReplyTransport(#"{"keys":[]}"#)
        let transport = RedirectedManifest(xml: manifest("keys.json"), licence: licence)
        _ = await ClearKey.resolve(manifestUrl: "https://media.test/original.mpd", headers: ["Authorization": "Bearer fixture"], using: Stremio(transport: transport))
        let requests = await licence.requests
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://media.test/final/path/keys.json")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
    }

    func testRedirectsUseURLSessionDefaults() {
        let transport = URLSessionTransport()
        defer { transport.session.invalidateAndCancel() }
        XCTAssertNil(transport.session.delegate, "media headers must use URLSession's redirect handling")
    }

    func testLicenceOriginIncludesSchemeAndPort() {
        let origin = URL(string: "https://media.test/m.mpd")!
        XCTAssertTrue(Net.sameOrigin(origin, URL(string: "https://MEDIA.test:443/keys")!))
        XCTAssertFalse(Net.sameOrigin(origin, URL(string: "https://elsewhere.test/keys")!))
        XCTAssertFalse(Net.sameOrigin(origin, URL(string: "http://media.test/keys")!))
        XCTAssertFalse(Net.sameOrigin(origin, URL(string: "https://media.test:8443/keys")!))
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

    func testLegalAttributeQuotesAndWhitespaceRespectTheCeiling() {
        let xml = """
        <MPD><Period><AdaptationSet mimeType = 'video/mp4'>
          <Representation id='large' height = '2160' bandwidth = '9000'/>
          <Representation id = "small" height\t=\n"720" bandwidth='3000'/>
        </AdaptationSet></Period></MPD>
        """
        XCTAssertEqual(ids(DashManifest.oneVideoQuality(xml, maxHeight: 720)), ["small"])
        let unknown = "<AdaptationSet mimeType='video/mp4'><Representation id='a'/><Representation id='b'/></AdaptationSet>"
        XCTAssertEqual(DashManifest.oneVideoQuality(unknown, maxHeight: 720), unknown)
        XCTAssertEqual(DashManifest.oneVideoQuality(unknown), unknown)
    }

    func testBaseURLsDecodeEntitiesAndEscapeGeneratedXML() {
        let simple = "<MPD><Period/></MPD>"
        let injected = DashManifest.absoluteBase(simple, manifestUrl: "https://h.test/a&b/m.mpd")
        XCTAssertTrue(injected.contains("<BaseURL>https://h.test/a&amp;b/</BaseURL>"))
        XCTAssertTrue(XMLParser(data: Data(injected.utf8)).parse())
        let xml = "<MPD><BaseURL>dash&#x2f;?a=1&amp;b=&#50;</BaseURL><Period/></MPD>"
        let resolved = DashManifest.absoluteBase(xml, manifestUrl: "https://h.test/a/m.mpd")
        XCTAssertTrue(resolved.contains("<BaseURL>https://h.test/a/dash/?a=1&amp;b=2</BaseURL>"))
        XCTAssertFalse(resolved.contains("&amp;amp;"))
        XCTAssertTrue(XMLParser(data: Data(resolved.utf8)).parse())
        XCTAssertEqual(DashManifest.xmlDecoded("&amp;lt; &quot; &apos; &gt;"), "&lt; \" ' >")
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
    func testItemIDPreservesStandaloneMovieIDs() {
        XCTAssertEqual(Ids.itemId(type: "movie", id: "catalog:movie:42"), "catalog:movie:42")
        XCTAssertEqual(Ids.itemId(type: "tv", id: "catalog:channel:42"), "catalog:channel:42")
        XCTAssertEqual(Ids.itemId(type: "series", id: "tt123:1:2"), "tt123")
        XCTAssertEqual(Ids.itemId(type: "series", id: "kitsu:12345:3"), "kitsu:12345")
    }

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

    func testRepeatedWatchedMarksAreIdempotentAndDoNotMoveTheCursor() {
        let p = ProgressStore(store: tempStore())
        var played = ProgressRec(type: "series", id: "s:2:1"); played.pos = 300; played.dur = 3000
        p.note(played)
        p.markWatched("series", "s:1:1")
        let first = p.get("series", "s:1:1")
        var changes = 0; p.onChange = { changes += 1 }
        p.markWatched("series", "s:1:1")
        XCTAssertEqual(p.get("series", "s:1:1"), first)
        XCTAssertEqual(changes, 0)
        let videos = [ep("s:1:1", 1, 1), ep("s:1:2", 1, 2), ep("s:2:1", 2, 1)]
        XCTAssertEqual(SeriesCursor.find(type: "series", videos: videos, progress: p.all())?.upNext?.id, "s:2:1")
        p.markWatched("series", "s:2:1")
        let real = p.get("series", "s:2:1")
        p.markWatched("series", "s:2:1")
        XCTAssertEqual(p.get("series", "s:2:1"), real)
        XCTAssertFalse(real!.hand)
    }

    func testTrimHandlesExtremeDismissalTimestamps() {
        let p = ProgressStore(store: tempStore())
        var records: [String: ProgressRec] = [:]
        for i in 0..<ProgressStore.maxRecords {
            var r = rec("live\(i)", pos: 100, dur: 6000); r.at = Int64(i + 1)
            records[ProgressStore.key(r.type, r.id)] = r
        }
        let old = ProgressRec(wire: ["type": "movie", "id": "old", "dismissed": true, "at": "-9223372036854775808"])!
        records["movie:old"] = old
        var future = ProgressRec(type: "movie", id: "future"); future.dismissed = true; future.at = .max
        records["movie:future"] = future
        p.replaceAll(records)
        XCTAssertEqual(p.all().count, ProgressStore.maxRecords)
        XCTAssertNil(p.get("movie", "old"))
        XCTAssertEqual(p.all().values.filter { !$0.dismissed }.count, ProgressStore.maxRecords)
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

final class AddonStoreTests: XCTestCase {
    func testIdentityMutationsPreserveAddonsAbsentFromAnOldSnapshot() {
        let store = tempStore(), addons = AddonStore(store: store)
        let a = AddonStore.cinemeta, b = AddonStore.openSubtitles
        addons.add(a); addons.add(b)
        let stale = addons.all()
        let synced = Addon(manifestUrl: "https://synced.test/manifest.json", name: "Synced", base: "https://synced.test")
        addons.saveRaw(addons.all() + [synced])
        addons.setEnabled(false, manifestUrl: stale[0].manifestUrl)
        addons.move(stale[1].manifestUrl, by: -1)
        XCTAssertEqual(addons.all().map(\.manifestUrl), [b.manifestUrl, a.manifestUrl, synced.manifestUrl])
        XCTAssertFalse(addons.all()[1].enabled)
        XCTAssertNil(addons.syncDoc().obj("removed")?[synced.manifestUrl])
        addons.remove(a.manifestUrl)
        XCTAssertEqual(addons.all().map(\.manifestUrl), [b.manifestUrl, synced.manifestUrl])
        XCTAssertNotNil(addons.syncDoc().obj("removed")?[a.manifestUrl])
        XCTAssertNil(addons.syncDoc().obj("removed")?[synced.manifestUrl])
    }

    func testDuplicateInstallsAndLegacyListsAreUniqueByManifestURL() {
        let store = tempStore(), addons = AddonStore(store: store)
        let a = AddonStore.cinemeta
        XCTAssertTrue(addons.add(a))
        addons.setEnabled(false, manifestUrl: a.manifestUrl)
        XCTAssertFalse(addons.add(a))
        XCTAssertFalse(addons.all()[0].enabled, "a late install must not reset a concurrent toggle")
        DispatchQueue.concurrentPerform(iterations: 32) { _ in addons.add(a) }
        XCTAssertEqual(addons.all().count, 1)
        addons.saveRaw([a, a, AddonStore.openSubtitles])
        XCTAssertEqual(store.object("addons").objs("list").count, 2)
        let row: JSONObject = ["manifestUrl": a.manifestUrl, "name": a.name]
        store.setObject("addons", ["list": [row, row]])
        XCTAssertEqual(addons.all().count, 1)
    }

    func testUnknownIdentityMutationsCannotRemoveOrReorderCurrentAddons() {
        let addons = AddonStore(store: tempStore())
        addons.add(AddonStore.cinemeta); addons.add(AddonStore.openSubtitles)
        let before = addons.all()
        addons.setEnabled(false, manifestUrl: "missing")
        addons.move("missing", by: .max)
        addons.remove("missing")
        XCTAssertEqual(addons.all(), before)
        addons.move(AddonStore.cinemeta.manifestUrl, by: .max)
        XCTAssertEqual(addons.all().last?.manifestUrl, AddonStore.cinemeta.manifestUrl)
        addons.move(AddonStore.cinemeta.manifestUrl, by: .min)
        XCTAssertEqual(addons.all(), before)
    }
}

final class PrefsTests: XCTestCase {
    func testSubtitlePreferenceDistinguishesUnsetFromOff() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nebula-prefs-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir), prefs = Prefs(store: store)
        XCTAssertEqual(prefs.subLang, "")
        XCTAssertFalse(prefs.hasSubLang)
        prefs.volume = 75
        XCTAssertFalse(prefs.hasSubLang, "unrelated settings do not choose subtitles")
        prefs.subLang = ""
        XCTAssertEqual(prefs.subLang, "")
        XCTAssertTrue(prefs.hasSubLang)
        let reopened = Prefs(store: Store(directory: dir))
        XCTAssertEqual(reopened.subLang, "")
        XCTAssertTrue(reopened.hasSubLang, "Off survives reopening the store")
        reopened.subLang = "eng"
        let language = Prefs(store: Store(directory: dir))
        XCTAssertEqual(language.subLang, "eng")
        XCTAssertTrue(language.hasSubLang)
    }
}

#if os(iOS)
final class BackupMigrationTests: XCTestCase {
    func testExistingCredentialIsExcludedOnStoreOpen() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nebula-backup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var file = dir.appendingPathComponent("cloud_link.json")
        try Data(#"{"gid":"fixture","token":"fixture"}"#.utf8).write(to: file)
        var values = URLResourceValues(); values.isExcludedFromBackup = false
        try file.setResourceValues(values)
        for _ in 0..<2 {
            let store = Store(directory: dir)
            file = dir.appendingPathComponent("cloud_link.json")
            XCTAssertEqual(store.object("cloud_link").str("token"), "fixture")
            XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        }
        let store = Store(directory: dir)
        store.setObject("cloud_link", ["gid": "fixture", "token": "replacement"])
        file = dir.appendingPathComponent("cloud_link.json")
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(Store(directory: dir).object("cloud_link").str("token"), "replacement")
        store.set("cloud_link", nil)
        let signedOut = Store(directory: dir)
        signedOut.setObject("prefs", ["subLang": "eng"])
        XCTAssertNil(signedOut.string("cloud_link"))
        XCTAssertEqual(signedOut.object("prefs").str("subLang"), "eng")
    }
}
#endif

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

    /// 2026-10-07: a row's words are read once, as the add-on answers — the same words the row
    /// used to read for itself every time it was drawn.
    func testARowIsReadOnce() {
        let s = StreamItem(name: "Torrentio\n4k 🎬 | DV", title: "Film.2160p.HDR10.DDP.5.1\n👤 12 💾 4 GB", url: "https://x.test/a.mkv")
        let t = StreamRowText(s, addonName: "Torrentio")
        XCTAssertEqual(t.plate, StreamBadges.Plate(res: "4K", tag: "ULTRA HD"))
        XCTAssertEqual(t.name, "DV")
        XCTAssertEqual(t.badges.first, "dolby_vision.png")
        XCTAssertEqual(t.facts, "4 GB  ·  12 seeds")
        XCTAssertEqual(t, StreamRowText(s, addonName: "Torrentio"), "the same row reads the same")
        // an add-on's name becomes a pattern once, and each name keeps its own
        XCTAssertEqual(StreamBadges.cleanName("Alpha · x", addonName: "Alpha"), "x")
        XCTAssertEqual(StreamBadges.cleanName("Alpha · x", addonName: "Beta"), "Alpha · x")
        XCTAssertEqual(StreamBadges.cleanName("Alpha · y", addonName: "Alpha"), "y")
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

/// Cancellation deliberately does not release the reply: stale-success guards must work even
/// when a transport has already delivered a response and cannot stop its continuation.
actor PausedCloud: Transport {
    let server: FakeCloud
    var target: (method: String, path: String)?
    var held: (request: URLRequest, continuation: CheckedContinuation<(Data, Int), Never>)?
    var waiter: CheckedContinuation<Void, Never>?
    var activePuts = 0, maxPuts = 0

    init(_ server: FakeCloud) { self.server = server }

    func pauseNext(_ method: String, _ path: String) { target = (method, path) }

    func waitUntilPaused() async {
        if held != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func resume(_ body: JSONObject? = nil, code: Int = 200) {
        guard let pending = held else { return }
        held = nil
        pending.continuation.resume(returning: body.map { (JSON.data($0), code) } ?? server.handle(pending.request))
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let isPut = request.httpMethod == "PUT"
        if isPut { activePuts += 1; maxPuts = max(maxPuts, activePuts) }
        defer { if isPut { activePuts -= 1 } }
        if let next = target, next.method == request.httpMethod, request.url?.path.hasSuffix(next.path) == true {
            target = nil
            return await withCheckedContinuation { continuation in
                held = (request, continuation)
                waiter?.resume(); waiter = nil
            }
        }
        return server.handle(request)
    }
}

final class CloudTests: XCTestCase {
    struct Device {
        let store: Store, addons: AddonStore, progress: ProgressStore, library: LibraryStore, cloud: Cloud
    }

    func device(_ server: Transport) -> Device {
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
        a.addons.add(Addon(manifestUrl: "https://mine.test/manifest.json", name: "Mine", base: "https://mine.test"))
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
        b.addons.remove("https://mine.test/manifest.json")
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

    func testPushMergesNewRemoteRevisionBeforeReplacingDocument() async {
        let server = FakeCloud(), a = device(server), b = device(server)
        _ = await a.cloud.signIn(handle: "alpha", password: "correct horse")
        _ = await b.cloud.signIn(handle: "alpha", password: "correct horse")
        a.progress.markWatched("movie", "a")
        await a.cloud.noteChanged("progress"); await a.cloud.flush()
        b.progress.markWatched("movie", "b")
        await b.cloud.noteChanged("progress"); await b.cloud.flush()
        let doc = JSON.object(server.kv["progress"]!.v)!
        XCTAssertNotNil(doc["movie:a"])
        XCTAssertNotNil(doc["movie:b"])
        XCTAssertTrue(b.progress.get("movie", "a")!.done)
        XCTAssertTrue(server.log.contains("GET /v1/kv/progress"))
    }

    func testAbsentAddonTombstonesAreRetainedAndAdvanced() async {
        let d = device(FakeCloud()), url = "https://removed.test/manifest.json"
        _ = await d.cloud.merge("addons", ["removed": [url: 10]])
        XCTAssertEqual(d.addons.syncDoc().obj("removed")?.int64(url), 10)
        _ = await d.cloud.merge("addons", ["removed": [url: 30]])
        _ = await d.cloud.merge("addons", ["removed": [url: 20]])
        _ = await d.cloud.merge("addons", ["list": [url: ["at": 25, "name": "Old"]]])
        XCTAssertTrue(d.addons.all().isEmpty)
        let text = await d.cloud.docFor("addons")!
        XCTAssertEqual(JSON.object(text)?.obj("removed")?.int64(url), 30)
        let remote: JSONObject = ["list": [url: ["at": 40, "name": "New"]]]
        let adopted = await d.cloud.merge("addons", remote)
        XCTAssertTrue(adopted.changed)
        XCTAssertFalse(adopted.localNewer)
        XCTAssertEqual(d.addons.all().first?.name, "New")
        XCTAssertNil(d.addons.syncDoc().obj("removed")?[url])
        let nextText = await d.cloud.docFor("addons")!
        let next = JSON.object(nextText)!
        XCTAssertNotNil(next.obj("list")?[url])
        XCTAssertNil(next.obj("removed")?[url])
        let settled = await d.cloud.merge("addons", next)
        XCTAssertFalse(settled.changed)
        XCTAssertFalse(settled.localNewer)
    }

    func testAddonWinningOverRemoteTombstonePushesOnlyItsNormalizedDocument() async {
        for installed in [false, true] {
            let server = FakeCloud(), d = device(server), addon = AddonStore.cinemeta
            let url = addon.manifestUrl
            if installed {
                d.addons.saveRaw([addon])
                d.store.setObject("addons_sync", ["at": [url: 40], "removed": [url: 30]])
            } else {
                d.store.setObject("addons_sync", ["removed": [url: 30]])
            }
            let remote: JSONObject = ["list": [url: ["at": 40, "name": addon.name]], "removed": [url: 20]]
            server.kv["addons"] = (JSON.text(remote), 1)
            _ = await d.cloud.signIn(handle: "alpha", password: "correct horse")
            XCTAssertEqual(d.addons.all().map(\.manifestUrl), [url])
            XCTAssertNil(d.addons.syncDoc().obj("removed")?[url])
            let pushed = JSON.object(server.kv["addons"]!.v)!
            XCTAssertEqual(pushed.obj("list")?.obj(url)?.int64("at"), 40)
            XCTAssertNil(pushed.obj("removed")?[url])
            XCTAssertEqual(server.log.filter { $0 == "PUT /v1/kv/addons" }.count, 1)
            let settled = await d.cloud.merge("addons", pushed)
            XCTAssertFalse(settled.changed)
            XCTAssertFalse(settled.localNewer)
            // re-read the document, not just the revision shortcut
            d.store.setObject("cloud_revs", [:])
            await d.cloud.pullAll(force: true)
            d.store.setObject("cloud_revs", [:])
            await d.cloud.pullAll(force: true)
            XCTAssertEqual(server.log.filter { $0 == "PUT /v1/kv/addons" }.count, 1)
        }
    }

    func testAbsentAddonTombstoneSteadyStateDoesNotNeedAPush() async {
        let d = device(FakeCloud()), url = "https://removed.test/manifest.json"
        let remote: JSONObject = ["removed": [url: 30]]
        _ = await d.cloud.merge("addons", remote)
        let settled = await d.cloud.merge("addons", remote)
        XCTAssertFalse(settled.changed)
        XCTAssertFalse(settled.localNewer)
        let older = await d.cloud.merge("addons", ["removed": [url: 20]])
        XCTAssertTrue(older.localNewer)
        XCTAssertEqual(d.addons.syncDoc().obj("removed")?.int64(url), 30)
    }

    func testOldProfileResponsesCannotRestoreOrRevokeReplacementSession() async {
        for code in [200, 401] {
            let server = FakeCloud(), transport = PausedCloud(server), d = device(transport)
            _ = await d.cloud.signIn(handle: "alpha", password: "correct horse")
            await transport.pauseNext("GET", "/v1/profile/me")
            let old = Task { await d.cloud.refreshProfile() }
            await transport.waitUntilPaused()
            await d.cloud.forget()
            _ = await d.cloud.signIn(handle: "bravo", password: "correct horse")
            await transport.resume(["on": true, "handle": "alpha", "error": "unauthorized"], code: code)
            let devices = await old.value
            let linked = await d.cloud.linked
            XCTAssertNil(devices)
            XCTAssertTrue(linked)
            XCTAssertEqual(d.cloud.storedProfile()?.handle, "bravo")
        }
    }

    func testOldProfileCannotRestoreAForgottenSession() async {
        let server = FakeCloud(), transport = PausedCloud(server), d = device(transport)
        _ = await d.cloud.signIn(handle: "alpha", password: "correct horse")
        await transport.pauseNext("GET", "/v1/profile/me")
        let old = Task { await d.cloud.refreshProfile() }
        await transport.waitUntilPaused()
        await d.cloud.forget()
        await transport.resume(["on": true, "handle": "alpha"])
        _ = await old.value
        XCTAssertNil(d.cloud.storedProfile())
        XCTAssertTrue(d.store.object("cloud_link").isEmpty)
    }

    func testOldDocumentCannotMergeAfterSessionSwitch() async {
        let server = FakeCloud(), transport = PausedCloud(server), d = device(transport)
        _ = await d.cloud.signIn(handle: "alpha", password: "correct horse")
        let value = JSON.text(["movie:old": ["type": "movie", "id": "old", "done": true, "at": 100]])
        server.kv["progress"] = (value, 1)
        await transport.pauseNext("GET", "/v1/kv/progress")
        let old = Task { await d.cloud.pullAll(force: true) }
        await transport.waitUntilPaused()
        await d.cloud.forget()
        server.kv.removeAll()
        _ = await d.cloud.signIn(handle: "bravo", password: "correct horse")
        await transport.resume(["v": value, "rev": 1])
        await old.value
        XCTAssertTrue(d.progress.all().isEmpty)
        XCTAssertNil(d.store.object("cloud_revs")["progress"])
        XCTAssertEqual(d.cloud.storedProfile()?.handle, "bravo")
    }

    func testSignOutContinuationCannotForgetReplacementSession() async {
        let server = FakeCloud(), transport = PausedCloud(server), d = device(transport)
        _ = await d.cloud.signIn(handle: "alpha", password: "correct horse")
        d.progress.markWatched("movie", "a")
        await d.cloud.noteChanged("progress")
        await transport.pauseNext("GET", "/v1/kv")
        let old = Task { await d.cloud.signOut() }
        await transport.waitUntilPaused()
        await d.cloud.forget()
        _ = await d.cloud.signIn(handle: "bravo", password: "correct horse")
        await transport.resume()
        await old.value
        XCTAssertEqual(d.cloud.storedProfile()?.handle, "bravo")
        XCTAssertFalse(server.log.contains("POST /v1/profile/signout"))
    }

    func testOverlappingFlushesSerializeWritesAndKeepLocalEdits() async {
        let server = FakeCloud(), transport = PausedCloud(server), d = device(transport)
        _ = await d.cloud.signIn(handle: "alpha", password: "correct horse")
        d.progress.markWatched("movie", "a")
        await d.cloud.noteChanged("progress")
        await transport.pauseNext("PUT", "/v1/kv/progress")
        let first = Task { await d.cloud.flush() }
        await transport.waitUntilPaused()
        d.progress.markWatched("movie", "b")
        await d.cloud.noteChanged("progress")
        let second = Task { await d.cloud.flush() }
        for _ in 0..<20 { await Task.yield() }
        await transport.resume()
        await first.value; await second.value
        let maxPuts = await transport.maxPuts
        XCTAssertEqual(maxPuts, 1)
        let doc = JSON.object(server.kv["progress"]!.v)!
        XCTAssertNotNil(doc["movie:a"]); XCTAssertNotNil(doc["movie:b"])
        XCTAssertNil(d.store.object("cloud_dirty")["progress"])
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

    /// A resume point from another client or the sync server with a position no film has.
    /// It used to reach `Int(...)` in the Continue watching card and the engine's start and trap.
    func testImpossiblePositionsFromTheWireReadAsZero() {
        let hostile: [(Any, Any)] = [("inf", "inf"), (1e300, 1e300), ("nan", 3000.0), (-50.0, 3000.0), (600.0, "-inf"), (600.0, 2e7)]
        for (pos, dur) in hostile {
            let r = ProgressRec(wire: ["type": "movie", "id": "a", "pos": pos, "dur": dur, "at": 5])!
            for v in [r.pos, r.dur] { XCTAssertTrue(v.isFinite && v >= 0 && v < 10_000_000, "\(pos) / \(dur) gave \(v)") }
            XCTAssertTrue(r.fraction.isFinite)
        }
        XCTAssertEqual(ProgressRec(wire: ["type": "movie", "id": "a", "pos": 600.5, "dur": "3000"])!.pos, 600.5, "a real position is left alone")

        // the same through a store written by someone else: nothing to resume, nothing to show
        let s = tempStore()
        s.setObject("progress", ["movie:a": ["type": "movie", "id": "a", "name": "A", "pos": "inf", "dur": 1e300, "at": 5.0] as JSONObject,
                                 "movie:b": ["type": "movie", "id": "b", "name": "B", "pos": 900.0, "dur": "inf", "at": 6.0] as JSONObject])
        let p = ProgressStore(store: s)
        XCTAssertEqual(p.resumeAt("movie", "a"), 0)
        XCTAssertEqual(p.resumeAt("movie", "b"), 0)
        XCTAssertTrue(p.continueList().isEmpty)

        // and the player's own note cannot put one there either
        var bad = ProgressRec(type: "movie", id: "c"); bad.pos = .infinity; bad.dur = .nan
        p.note(bad)
        XCTAssertTrue(p.all().values.allSatisfy { $0.pos.isFinite && $0.dur.isFinite })
    }

    /// An engine sample with no real position leaves the resume point alone. Read as 0 it was a
    /// rewind to the top, which wrote a dismissed record — and that syncs to every device.
    func testANonFiniteSampleIsSkippedNotReadAsARewind() {
        let p = ProgressStore(store: tempStore())
        var r = ProgressRec(type: "movie", id: "a"); r.name = "A"; r.pos = 600; r.dur = 3000
        p.note(r)
        var changes = 0
        p.onChange = { changes += 1 }
        for (pos, dur) in [(Double.nan, 3000.0), (.infinity, 3000.0), (600.0, .nan), (600.0, -.infinity), (2e7, 3000.0)] {
            var s = r; s.pos = pos; s.dur = dur
            p.note(s)
        }
        let kept = p.get("movie", "a")!
        XCTAssertFalse(kept.dismissed, "no tombstone")
        XCTAssertEqual(kept.pos, 600)
        XCTAssertEqual(p.resumeAt("movie", "a"), 600)
        XCTAssertEqual(changes, 0, "nothing written, nothing sent to the profile")
        // a real rewind to the top still forgets the place
        var top = r; top.pos = 2
        p.note(top)
        XCTAssertTrue(p.get("movie", "a")!.dismissed)
    }
}

final class PatienceTests: XCTestCase {
    func testAQuickAnswerComesBack() async {
        let t = Task { () -> Int in 7 }
        let v = await Patience.value(of: t, within: 5)
        XCTAssertEqual(v, 7)
    }

    /// The caller stops waiting at the deadline, and the work runs on and still finishes.
    func testASlowAnswerIsNotWaitedForButStillLands() async {
        final class Box: @unchecked Sendable { var landed = false }
        let box = Box()
        let t = Task { () -> Int in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            box.landed = true
            return 9
        }
        let start = Date()
        let v = await Patience.value(of: t, within: 0.2)
        XCTAssertNil(v)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "the wait ended at its deadline")
        XCTAssertFalse(box.landed)
        let late = await t.value
        XCTAssertEqual(late, 9)
        XCTAssertTrue(box.landed, "the work was not cancelled by the caller giving up")
    }

    func testCancellingTheCallerEndsTheWait() async {
        let slow = Task { () -> Int in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return 1
        }
        let start = Date()
        let caller = Task { await Patience.value(of: slow, within: .infinity) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        caller.cancel()
        let v = await caller.value
        XCTAssertNil(v)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        slow.cancel()
    }
}

final class MissWindowTests: XCTestCase {
    /// An add-on that did not answer is passed by for two minutes, doubling with each miss in a
    /// row, and never for more than sixteen.
    func testTheWindowDoublesAndStopsAtSixteenMinutes() {
        XCTAssertEqual(Patience.missWindow(1), 120)
        XCTAssertEqual(Patience.missWindow(2), 240)
        XCTAssertEqual(Patience.missWindow(3), 480)
        XCTAssertEqual(Patience.missWindow(4), 960)
        XCTAssertEqual(Patience.missWindow(5), 960)
        XCTAssertEqual(Patience.missWindow(1_000), 960, "a long run of misses neither overflows nor grows past the cap")
        XCTAssertEqual(Patience.missWindow(0), 120, "a count that never happened still reads as one miss")
        XCTAssertEqual(Patience.missWindow(-3), 120)
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
