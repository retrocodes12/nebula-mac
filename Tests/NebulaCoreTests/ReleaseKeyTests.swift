import XCTest
@testable import NebulaCore

/// The same release by file name: the episode comes out, the release tail stays.
final class ReleaseKeyTests: XCTestCase {
    func testTheEpisodeComesOutAndTheReleaseTailStays() {
        let k = ReleaseKey.of("Show.Name.S01E03.Pilot.1080p.WEB-DL.x265-GRP.mkv")
        XCTAssertEqual(k, "e:show.name|1080p.web.dl.x265.grp")
        XCTAssertEqual(k, ReleaseKey.of("Show.Name.S01E04.The.Other.One.1080p.WEB-DL.x265-GRP.mkv"))
        XCTAssertEqual(ReleaseKey.of("Show.Name.S01E10.1080p.WEB.x264-GRP"), ReleaseKey.of("Show.Name.S02E01.1080p.WEB.x264-GRP"))
        XCTAssertEqual(ReleaseKey.of("Show Name 1x03 [1080p] GRP.mkv"), ReleaseKey.of("Show Name 1x04 [1080p] GRP.mkv"))
        XCTAssertEqual(ReleaseKey.of("[Subs] Anime EP.03 (1080p).mkv"), ReleaseKey.of("[Subs] Anime EP.04 (1080p).mkv"))
    }

    func testAnotherGroupOrQualityIsAnotherRelease() {
        XCTAssertNotEqual(ReleaseKey.of("Show.S01E03.1080p.WEB.x264-A"), ReleaseKey.of("Show.S01E04.1080p.WEB.x264-B"))
        XCTAssertNotEqual(ReleaseKey.of("Show.S01E03.1080p.WEB.x264-A"), ReleaseKey.of("Show.S01E04.720p.WEB.x264-A"))
    }

    func testAFilmKeepsItsWholeNameAndNoFileIsNoKey() {
        XCTAssertEqual(ReleaseKey.of("Movie.Name.2019.1920x1080.BluRay.x264-GRP.mkv"), "m:movie.name.2019.1920x1080.bluray.x264.grp")
        XCTAssertEqual(ReleaseKey.of(""), "")
    }

    func testTheFileIsReadFromTheHintElseATitleLineThatLooksLikeOne() {
        var s = StreamItem(name: "A", title: "Show.S01E03.1080p.WEB.x264-GRP\n💾 1 GB", url: "https://x/1")
        XCTAssertEqual(ReleaseKey.fileName(s), "Show.S01E03.1080p.WEB.x264-GRP")
        s.fileName = "Other.S01E03.720p.mkv"
        XCTAssertEqual(ReleaseKey.fileName(s), "Other.S01E03.720p.mkv")
        XCTAssertEqual(ReleaseKey.fileName(StreamItem(name: "A", title: "1080p WEB\nEnglish", url: "https://x/2")), "")
    }
}
