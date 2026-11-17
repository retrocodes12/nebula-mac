import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NebulaCore

/// Rows that only open a web page (2026-11-17): a locked sports channel's two cards, kept as links beside the rows that play.
final class StreamLinksTests: XCTestCase {
    actor One: Transport {
        let body: String
        var asked = 0
        init(_ body: String) { self.body = body }
        func send(_ request: URLRequest) async throws -> (Data, Int) { asked += 1; return (Data(body.utf8), 200) }
    }

    // the sports add-on's answer for a locked channel, plus rows that must not become links
    let locked = #"""
    {"streams":[
      {"name":"▶ Watch an ad to unlock Live TV (12 h)","title":"Opens one ad in your browser.\nCome back and reopen this channel.","externalUrl":"https://sports.nebulapro.xyz/sports/go/c/0123456789abcdef0123456789abcdef01234567","behaviorHints":{"notWebReady":true}},
      {"name":"Donate $1.50 or more to unlock streams","title":"Donations only cover development and server expenses.","externalUrl":"https://play.rifflehq.in/support.html#from=sports-addon"},
      {"name":"Deep link","externalUrl":"stremio:///detail/tv/x"},
      {"externalUrl":"https://example.com/"},
      {"name":"Torrent","infoHash":"0123456789abcdef0123456789abcdef01234567","externalUrl":"https://example.com/t"},
      {"name":"A 1080p","url":"https://h.test/a.mkv","externalUrl":"https://example.com/page"}
    ]}
    """#

    func testTheSportsCardsAreLinksAndNothingElseIs() throws {
        let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(locked.utf8)) as? JSONObject)
        let links = Stremio.parseStreamLinks(j)
        XCTAssertEqual(links.map(\.name), ["▶ Watch an ad to unlock Live TV (12 h)", "Donate $1.50 or more to unlock streams"])
        XCTAssertTrue(links[0].title.contains("\nCome back"))
        XCTAssertTrue(links[0].url.hasPrefix("https://sports.nebulapro.xyz/sports/go/c/"))
        XCTAssertEqual(Stremio.parseStreams(j).map(\.name), ["A 1080p"], "a row that plays stays a stream, never a link")
    }

    func testOneRequestGivesBoth() async throws {
        let t = One(locked)
        let page = try await Stremio(transport: t).loadStreamPage(base: "https://x.test", type: "tv", id: "streamed:x")
        XCTAssertEqual(page.links.count, 2)
        XCTAssertEqual(page.streams.count, 1)
        let n = await t.asked
        XCTAssertEqual(n, 1)
    }
}
