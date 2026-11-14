import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NebulaCore

/// A person's films and series: the cloud's answer as cards, the filters worth offering, and one request a person.
final class PeopleTests: XCTestCase {
    private let body = """
    {"id":"Q500","name":"John Smith","items":[
      {"id":"tt0000201","name":"The Big One","year":1994,"type":"movie","as":["cast"]},
      {"id":"tt0000202","name":"A Show","year":2008,"type":"series","as":["cast","director"]},
      {"id":"tt0000201","name":"The Big One again","year":1994,"type":"movie","as":["cast"]},
      {"id":"nm0000001","name":"Not A Title","year":2012,"type":"movie","as":["cast"]},
      {"id":"tt0000203","name":"","year":2001,"type":"movie","as":["writer"]},
      {"id":"tt0000204","name":"Undated","year":null,"type":"movie","as":["director","writer"]},
      {"id":"tt0000205","name":"Odd Type","year":2010,"type":"game"}
    ]}
    """

    func testParseKeepsTitlesWithAnIdAndANameOnceEach() {
        let p = People.parse(JSON.object(body)!)!
        XCTAssertEqual(p.id, "Q500"); XCTAssertEqual(p.name, "John Smith")
        XCTAssertEqual(p.items.map(\.id), ["tt0000201", "tt0000202", "tt0000204", "tt0000205"])
        XCTAssertEqual(p.items[0].meta.name, "The Big One")
        XCTAssertEqual(p.items[0].meta.releaseInfo, "1994")
        XCTAssertEqual(p.items[0].meta.poster, "https://images.metahub.space/poster/medium/tt0000201/img")
        XCTAssertEqual(p.items[1].meta.type, "series")
        XCTAssertEqual(p.items[1].roles, ["cast", "director"])
        XCTAssertNil(p.items[2].meta.releaseInfo)
        XCTAssertEqual(p.items[3].meta.type, "movie", "anything that is not a series opens as a film")
        XCTAssertNil(People.parse(JSON.object(#"{"error":"unknown"}"#)!))
    }

    func testOnlyTheFiltersThatWouldChangeSomething() {
        let p = People.parse(JSON.object(body)!)!
        XCTAssertEqual(People.kinds(for: p.items).map(\.id), ["all", "movie", "series", "director", "writer"])
        let films = People.parse(JSON.object(#"{"items":[{"id":"tt0000301","name":"One","type":"movie","as":["cast"]},{"id":"tt0000302","name":"Two","type":"movie","as":["cast"]}]}"#)!)!
        XCTAssertTrue(People.kinds(for: films.items).isEmpty, "nothing to choose between: no row at all")
        XCTAssertEqual(p.items.filter { People.matches($0, "director") }.map(\.id), ["tt0000202", "tt0000204"])
        XCTAssertEqual(p.items.filter { People.matches($0, "series") }.map(\.id), ["tt0000202"])
    }

    func testLoadAsksOnceWithTheNameAndTheTitle() async {
        let t = ReplyTransport(body)
        let a = await People.load("John Smith", "tt0000001", base: "https://c.test/cloud", transport: t)
        let b = await People.load(" john smith ", "tt0000001", base: "https://c.test/cloud", transport: t)
        guard case .found(let p) = a else { return XCTFail("found") }
        XCTAssertEqual(p.items.count, 4)
        XCTAssertEqual(b, a)
        let reqs = await t.requests
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(reqs[0].url?.absoluteString, "https://c.test/cloud/v1/person?n=John%20Smith&t=tt0000001")
    }

    func testNobodyIsNotAFailure() async {
        let none = CodeTransport(404, #"{"error":"unknown"}"#)
        let a = await People.load("Zzyzx Nobody", nil, base: "https://c.test/cloud", transport: none)
        XCTAssertEqual(a, People.Answer.none)
        let down = CodeTransport(503, #"{"error":"unavailable"}"#)
        let b = await People.load("Someone Else", nil, base: "https://c.test/cloud", transport: down)
        XCTAssertEqual(b, .failed)
        let c = await People.load("Someone Else", nil, base: "https://c.test/cloud", transport: down)
        XCTAssertEqual(c, .failed)
        let n = await down.count
        XCTAssertEqual(n, 2, "a failure is never kept: the next visit asks again")
    }
}

actor CodeTransport: Transport {
    let code: Int, body: Data
    var count = 0
    init(_ code: Int, _ text: String) { self.code = code; body = Data(text.utf8) }
    func send(_ request: URLRequest) async throws -> (Data, Int) { count += 1; return (body, code) }
}
