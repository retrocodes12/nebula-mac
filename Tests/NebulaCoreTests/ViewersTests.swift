import XCTest
import Foundation
@testable import NebulaCore

/// Who's watching: the list as the other apps write it, where each profile's history lives, and the merge.
final class ViewersTests: XCTestCase {
    private func store() -> Store {
        Store(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nebula-test-" + UUID().uuidString))
    }

    func testParseKeepsTheFirstAndAtMostTwo() {
        XCTAssertEqual(Viewers.parse([:]).map(\.id), ["a"])
        let d: JSONObject = ["at": 1, "list": [["id": "b", "name": "Kids"], ["id": "c", "name": "X"], ["id": "b", "name": "Dup"]] as [Any]]
        XCTAssertEqual(Viewers.parse(d).map(\.id), ["a", "b"])
        XCTAssertEqual(Viewers.parse(d).first { $0.id == "b" }?.name, "Kids")
    }

    func testHistoryAndAddonsMoveForTheSecondProfile() {
        XCTAssertEqual(Viewers.key("progress", viewer: "a"), "progress")
        XCTAssertEqual(Viewers.key("progress", viewer: "b"), "progress_b")
        XCTAssertEqual(Viewers.key("library", viewer: "b"), "library_b")
        XCTAssertEqual(Viewers.key("addons", viewer: "a"), "addons")
        XCTAssertEqual(Viewers.key("addons", viewer: "b"), "addons_b")
        XCTAssertEqual(Viewers.key("addons_sync", viewer: "b"), "addons_sync_b")
        XCTAssertEqual(Viewers.key("viewers", viewer: "b"), "viewers")
        XCTAssertEqual(Viewers.key("sub_style", viewer: "b"), "sub_style")
    }

    func testTheSecondProfileStartsAsACopyOfTheFirstsAddons() {
        let s = store(), v = Viewers(store: s), a = AddonStore(store: s)
        a.viewers = v
        let x = Addon(manifestUrl: "https://x.example/manifest.json", name: "X", base: "https://x.example")
        let y = Addon(manifestUrl: "https://y.example/manifest.json", name: "Y", base: "https://y.example")
        a.add(x); a.add(y); a.remove(y.manifestUrl); a.add(y); a.move(y.manifestUrl, by: -1)
        let firstSync = s.object("addons_sync")
        v.setCurrent("b")
        XCTAssertEqual(a.all().map(\.manifestUrl), [y.manifestUrl, x.manifestUrl], "a copy, in the first profile's order")
        // the stamps are the first profile's own, not the moment of the copy
        XCTAssertEqual(a.syncDoc().obj("at")?.int64(x.manifestUrl), firstSync.obj("at")?.int64(x.manifestUrl))
        XCTAssertEqual(a.syncDoc().int64("orderAt"), firstSync.int64("orderAt"))
        // from here each keeps its own
        a.remove(x.manifestUrl)
        XCTAssertEqual(a.all().map(\.manifestUrl), [y.manifestUrl])
        XCTAssertNotNil(s.object("addons_sync_b").obj("removed")?[x.manifestUrl])
        v.setCurrent("a")
        XCTAssertEqual(a.all().map(\.manifestUrl), [y.manifestUrl, x.manifestUrl])
        XCTAssertNil(s.object("addons_sync").obj("removed")?[x.manifestUrl])
        // the copy is made once: a list the second profile emptied stays empty
        v.setCurrent("b"); a.remove(y.manifestUrl)
        XCTAssertTrue(a.all().isEmpty)
    }

    func testAnEmptyFirstProfileGivesAnEmptySecond() {
        let s = store(), v = Viewers(store: s), a = AddonStore(store: s)
        a.viewers = v
        v.setCurrent("b")
        XCTAssertTrue(a.all().isEmpty)
        XCTAssertNotNil(s.string("addons_b"))
    }

    func testANewerRemovalFromAnotherDeviceBeatsTheCopy() async {
        let s = store(), v = Viewers(store: s), a = AddonStore(store: s)
        a.viewers = v
        let x = Addon(manifestUrl: "https://x.example/manifest.json", name: "X", base: "https://x.example")
        a.add(x)
        let added = s.object("addons_sync").obj("at")?.int64(x.manifestUrl) ?? 0
        v.setCurrent("b")
        let cloud = Cloud(store: s, addons: a, progress: ProgressStore(store: s), library: LibraryStore(store: s), viewers: v)
        // another device's second profile removed X after the first profile added it
        let remote: JSONObject = ["list": JSONObject(), "removed": [x.manifestUrl: added + 5_000] as JSONObject, "order": [String](), "orderAt": 0]
        let r = await cloud.merge("addons", remote)
        XCTAssertTrue(r.changed)
        XCTAssertTrue(a.all().isEmpty, "the removal wins over the copy's older stamp")
        v.setCurrent("a")
        XCTAssertEqual(a.all().map(\.manifestUrl), [x.manifestUrl], "the first profile keeps it")
    }

    func testEachProfileReadsAndWritesItsOwnHistory() {
        let s = store(), v = Viewers(store: s), p = ProgressStore(store: s)
        p.viewers = v
        p.mutate { m in m["movie:tt1"] = ProgressRec(type: "movie", id: "tt1"); return true }
        v.setCurrent("b"); p.reset()
        XCTAssertTrue(p.all().isEmpty, "the second profile starts empty")
        p.mutate { m in m["movie:tt2"] = ProgressRec(type: "movie", id: "tt2"); return true }
        XCTAssertNotNil(s.object("progress_b").obj("movie:tt2"))
        XCTAssertNil(s.object("progress").obj("movie:tt2"))
        v.setCurrent("a"); p.reset()
        XCTAssertNotNil(p.all()["movie:tt1"])
        XCTAssertNil(p.all()["movie:tt2"])
    }

    func testMergeNewestWinsAndARemovalMovesTheDeviceBack() {
        let s = store(), v = Viewers(store: s)
        v.setList([Viewer(id: "a", name: "", av: ""), Viewer(id: "b", name: "Kids", av: "")])
        v.setCurrent("b")
        let older: JSONObject = ["at": 1, "list": [["id": "a", "name": ""]] as [Any]]
        XCTAssertEqual(v.merge(older).localNewer, true)
        XCTAssertEqual(v.list().count, 2)
        let newer: JSONObject = ["at": nowMs() + 10_000, "list": [["id": "a", "name": ""]] as [Any]]
        XCTAssertEqual(v.merge(newer).changed, true)
        XCTAssertEqual(v.list().count, 1)
        XCTAssertEqual(v.current, "a")
    }

    // MARK: signed in: the cloud decides the second profile's first list

    private func linkedDevice(_ server: FakeCloud) -> (Store, Viewers, AddonStore, Cloud) {
        let s = store(), v = Viewers(store: s), a = AddonStore(store: s)
        a.viewers = v
        server.tokens.insert("tok0")
        s.setObject("cloud_link", ["gid": "g1", "token": "tok0"])
        let cloud = Cloud(store: s, addons: a, progress: ProgressStore(store: s), library: LibraryStore(store: s),
                          transport: server, base: "https://c.test/cloud", viewers: v)
        return (s, v, a, cloud)
    }
    private let x = Addon(manifestUrl: "https://x.example/manifest.json", name: "X", base: "https://x.example")
    private let z = "https://z.example/manifest.json"

    func testTheCloudsOwnSecondProfileListIsTakenAsItIs() async {
        let server = FakeCloud()
        let doc: JSONObject = ["list": [z: ["name": "Z", "base": "https://z.example", "at": 5] as JSONObject] as JSONObject,
                               "removed": [x.manifestUrl: 7] as JSONObject, "order": [z], "orderAt": 6]
        server.kv["addons_b"] = (JSON.text(doc), 3)
        let (s, v, a, cloud) = linkedDevice(server)
        a.add(x)
        s.setObject("cloud_revs", ["addons_b": 3])      // a stale memory of it must not skip the fetch
        await cloud.prepareAddons(for: "b")
        XCTAssertEqual(s.object("addons_b").arr("list").count, 0, "empty, not a copy of the first profile")
        v.setCurrent("b")
        await cloud.pullAll(force: true)
        XCTAssertEqual(a.all().map(\.manifestUrl), [z], "the cloud's list, without the first profile's X")
        XCTAssertNotNil(a.syncDoc().obj("removed")?[x.manifestUrl])
        v.setCurrent("a")
        XCTAssertEqual(a.all().map(\.manifestUrl), [x.manifestUrl])
    }

    func testWithNoCloudCopyTheSecondProfileStartsAsTheFirstsAndGoesUp() async {
        let server = FakeCloud()
        let (s, v, a, cloud) = linkedDevice(server)
        a.add(x)
        let stamp = s.object("addons_sync").obj("at")?.int64(x.manifestUrl) ?? 0
        await cloud.prepareAddons(for: "b")
        v.setCurrent("b")
        XCTAssertEqual(a.all().map(\.manifestUrl), [x.manifestUrl])
        await cloud.pullAll(force: true)
        let up = JSON.object(server.kv["addons_b"]?.v ?? "") ?? [:]
        XCTAssertEqual(up.obj("list")?.obj(x.manifestUrl)?.int64("at"), stamp, "sent up with the first profile's own stamp")
        XCTAssertNil(server.kv["addons"], "the first profile's copy untouched")
    }

    func testSignedInTheSecondProfileReadsAProvisionalCopyUntilTheLaunchPullDecides() async {
        let server = FakeCloud()
        let doc: JSONObject = ["list": [z: ["name": "Z", "base": "https://z.example", "at": 5] as JSONObject] as JSONObject,
                               "removed": JSONObject(), "order": [z], "orderAt": 6]
        server.kv["addons_b"] = (JSON.text(doc), 1)
        let (s, v, a, cloud) = linkedDevice(server)
        a.add(x)
        v.setCurrent("b")                                 // a device already on the second profile (0.5.x: shared add-ons)
        XCTAssertEqual(a.all().map(\.manifestUrl), [x.manifestUrl], "never an empty page: the first profile's, provisionally")
        XCTAssertTrue(a.provisional(for: "b"))
        await cloud.pullAll(force: true)
        XCTAssertEqual(a.all().map(\.manifestUrl), [z])
        XCTAssertFalse(a.provisional(for: "b"))
        XCTAssertNil(s.string(AddonStore.seedFlag))
        XCTAssertFalse(server.log.contains("PUT /v1/kv/addons_b"), "nothing of the copy sent over the cloud's list")
    }

    func testTheCloudNotAnsweringFallsBackToAProvisionalCopy() async {
        let server = FakeCloud()
        let (_, v, a, cloud) = linkedDevice(server)
        a.add(x)
        server.down = true                                // no way out: the key list fails
        await cloud.prepareAddons(for: "b")
        v.setCurrent("b")
        XCTAssertEqual(a.all().map(\.manifestUrl), [x.manifestUrl])
        XCTAssertTrue(a.provisional(for: "b"), "a copy the cloud never confirmed")
    }

    func testAProvisionalCopyGivesWayWholeToTheCloudsOwnList() async {
        let server = FakeCloud()
        let (s, v, a, cloud) = linkedDevice(server)
        a.add(x)
        server.down = true
        await cloud.prepareAddons(for: "b")
        v.setCurrent("b")
        // the cloud does hold the second profile's own list, with a removal of something else and an order
        let y = "https://y.example/manifest.json"
        let doc: JSONObject = ["list": [z: ["name": "Z", "base": "https://z.example", "at": 5] as JSONObject] as JSONObject,
                               "removed": [y: 4] as JSONObject, "order": [z], "orderAt": 6]
        server.kv["addons_b"] = (JSON.text(doc), 2)
        server.down = false
        await cloud.pullAll(force: true)
        XCTAssertEqual(a.all().map(\.manifestUrl), [z], "exactly the cloud's list")
        let st = a.syncDoc(for: "b")
        XCTAssertNil(st.obj("at")?[x.manifestUrl], "none of the first profile's stamps")
        XCTAssertEqual(st.obj("at")?.int64(z), 5)
        XCTAssertEqual(st.obj("removed")?.int64(y), 4)
        XCTAssertEqual(st.int64("orderAt"), 6)
        XCTAssertFalse(a.provisional(for: "b"))
        XCTAssertNil(s.string(AddonStore.seedFlag))
        XCTAssertFalse(server.log.contains("PUT /v1/kv/addons_b"), "nothing pushed back from the seed")
        let up = JSON.object(server.kv["addons_b"]?.v ?? "") ?? [:]
        XCTAssertNil(up.obj("list")?[x.manifestUrl], "the first profile's add-on never reached the second's list")
        v.setCurrent("a")
        XCTAssertEqual(a.all().map(\.manifestUrl), [x.manifestUrl], "the first profile keeps its own")
    }

    func testAProvisionalCopyWithNothingInTheCloudGoesUpAndSettles() async {
        let server = FakeCloud()
        let (_, v, a, cloud) = linkedDevice(server)
        a.add(x)
        server.down = true
        await cloud.prepareAddons(for: "b")
        v.setCurrent("b")
        server.down = false
        await cloud.pullAll(force: true)
        let up = JSON.object(server.kv["addons_b"]?.v ?? "") ?? [:]
        XCTAssertNotNil(up.obj("list")?[x.manifestUrl], "no list of its own in the cloud: the copy becomes it")
        XCTAssertFalse(a.provisional(for: "b"))
    }

    func testAChangeByHandMakesTheCopyTheProfilesOwn() {
        let s = store(), v = Viewers(store: s), a = AddonStore(store: s)
        a.viewers = v
        a.add(x)
        v.setCurrent("b")
        XCTAssertEqual(a.all().map(\.manifestUrl), [x.manifestUrl])
        XCTAssertTrue(a.provisional(for: "b"), "signed out: provisional")
        a.move(x.manifestUrl, by: 0)                      // no change: still provisional
        XCTAssertTrue(a.provisional(for: "b"))
        a.setEnabled(false, manifestUrl: x.manifestUrl)
        XCTAssertFalse(a.provisional(for: "b"))
        XCTAssertFalse(a.provisional(for: "a"), "the first profile's list is never provisional")
    }

    func testTheCloudSayingItHasNoneGivesACopyThatIsNotProvisional() async {
        let server = FakeCloud()
        let (_, v, a, cloud) = linkedDevice(server)
        a.add(x)
        await cloud.prepareAddons(for: "b")
        v.setCurrent("b")
        XCTAssertEqual(a.all().map(\.manifestUrl), [x.manifestUrl])
        XCTAssertFalse(a.provisional(for: "b"))
    }

    // MARK: the profile a sync step works for is fixed with the doc's name

    func testACacheIsNeverReadUnderTheOtherProfilesName() {
        let s = store(), v = Viewers(store: s), p = ProgressStore(store: s), l = LibraryStore(store: s)
        p.viewers = v; l.viewers = v
        p.mutate { m in m["movie:tt1"] = ProgressRec(type: "movie", id: "tt1"); return true }
        l.toggle(MetaItem(id: "tt1", type: "movie", name: "One"), addonUrl: "")
        XCTAssertEqual(p.all().count, 1); XCTAssertTrue(l.contains("movie", "tt1"))
        // moved on another thread (a removal merged by the cloud) and nobody called reset() yet
        v.setCurrent("b")
        XCTAssertTrue(p.all().isEmpty, "the second profile's, not the first's cached")
        XCTAssertFalse(l.contains("movie", "tt1"))
        p.mutate { m in m["movie:tt2"] = ProgressRec(type: "movie", id: "tt2"); return true }
        XCTAssertNil(s.object("progress").obj("movie:tt2"))
        XCTAssertNil(s.object("progress_b").obj("movie:tt1"), "the first profile's history never written under the second's name")
        XCTAssertNotNil(p.all(for: "a")["movie:tt1"])
    }

    func testAMergeGoesToTheProfileItWasFetchedFor() async {
        let s = store(), v = Viewers(store: s), a = AddonStore(store: s), p = ProgressStore(store: s)
        a.viewers = v; p.viewers = v
        let cloud = Cloud(store: s, addons: a, progress: p, library: LibraryStore(store: s), viewers: v)
        var rec = ProgressRec(type: "movie", id: "tt9"); rec.pos = 100; rec.dur = 2000; rec.at = 50
        let remote: JSONObject = ["movie:tt9": rec.wire]
        // fetched as "progress_b", and the device moved to the first profile before the merge
        _ = await cloud.merge("progress", remote, viewer: "b")
        XCTAssertNotNil(s.object("progress_b").obj("movie:tt9"))
        XCTAssertNil(s.object("progress").obj("movie:tt9"))
        XCTAssertEqual(v.current, "a")
        let doc = await cloud.docFor("progress", viewer: "b")
        XCTAssertTrue(doc?.contains("tt9") == true, "the second profile's doc, whichever profile is on")
    }

    func testViewersArePulledFirstSoARemovalElsewhereReadsTheFirstProfilesDocsAtOnce() async {
        let server = FakeCloud()
        let (s, v, _, cloud) = linkedDevice(server)
        v.setList([Viewer(id: "a", name: "", av: ""), Viewer(id: "b", name: "Kids", av: "")])
        v.setCurrent("b")
        let one: JSONObject = ["at": nowMs() + 60_000, "list": [["id": "a", "name": ""]] as [Any]]
        server.kv["viewers"] = (JSON.text(one), 3)
        var rec = ProgressRec(type: "movie", id: "tt5"); rec.pos = 100; rec.dur = 2000; rec.at = 70
        server.kv["progress"] = (JSON.text(["movie:tt5": rec.wire] as JSONObject), 4)
        await cloud.pullAll(force: true)
        XCTAssertEqual(v.current, "a")
        XCTAssertNotNil(s.object("progress").obj("movie:tt5"), "the first profile's history came down in the same pull")
        XCTAssertNil(s.object("progress_b").obj("movie:tt5"))
    }

    // MARK: another account on this device

    private func secondProfileOnThisDevice(_ s: Store, _ v: Viewers) {
        v.setList([Viewer(id: "a", name: "", av: ""), Viewer(id: "b", name: "Kids", av: "", lock: PinLock.make(pin: "1234"))])
        v.setCurrent("b")
        s.setObject("progress_b", ["movie:tt7": ["type": "movie", "id": "tt7", "pos": 300, "dur": 2000, "at": 10] as JSONObject])
        s.setObject("library_b", ["movie:tt7": ["type": "movie", "id": "tt7", "name": "Seven", "at": 10] as JSONObject])
        s.setObject("addons_b", ["list": [["manifestUrl": "https://k.example/manifest.json", "name": "K", "base": "https://k.example"] as JSONObject] as [Any]])
        s.setObject("addons_sync_b", ["at": ["https://k.example/manifest.json": 10] as JSONObject])
    }

    func testSigningInToAnotherAccountLeavesTheOldProfilesBehind() async {
        let server = FakeCloud()
        let (s, v, a, cloud) = linkedDevice(server)
        XCTAssertEqual(s.string(Cloud.syncGidKey), "g1", "a device signed in before sync_gid takes its account's at launch")
        secondProfileOnThisDevice(s, v)
        let resets = HitCount()
        await cloud.setHandlers(onApplied: nil, onSignedOut: nil, onProfile: nil, onAccountReset: { resets.n += 1 }, onSignedIn: nil)
        await cloud.forget()
        server.gid = "g2"
        let err = await cloud.signIn(handle: "other", password: "correct horse")
        XCTAssertNil(err)
        XCTAssertEqual(s.string(Cloud.syncGidKey), "g2")
        XCTAssertEqual(resets.n, 1)
        XCTAssertEqual(v.current, "a")
        XCTAssertEqual(v.list().map(\.id), ["a"])
        XCTAssertEqual(v.doc().int64("at"), 0)
        for k in Viewers.secondKeys { XCTAssertNil(s.string(k), k) }
        XCTAssertTrue(a.hasList(for: "a"))
        XCTAssertNil(server.kv["viewers"], "the old account's profiles (and PIN) never reach the new one")
        XCTAssertNil(server.kv["progress_b"]); XCTAssertNil(server.kv["library_b"]); XCTAssertNil(server.kv["addons_b"])
    }

    func testSigningInAgainToTheSameAccountKeepsTheProfiles() async {
        let server = FakeCloud()
        let (s, v, _, cloud) = linkedDevice(server)
        secondProfileOnThisDevice(s, v)
        let signedIn = HitCount()
        await cloud.setHandlers(onApplied: nil, onSignedOut: nil, onProfile: nil, onAccountReset: nil, onSignedIn: { signedIn.n += 1 })
        await cloud.forget()
        let err = await cloud.signIn(handle: "mine", password: "correct horse")
        XCTAssertNil(err)
        XCTAssertEqual(signedIn.n, 1, "the app is told once the sign-in's pull has landed")
        XCTAssertEqual(v.current, "b")
        XCTAssertEqual(v.list().count, 2)
        XCTAssertNotNil(s.string("progress_b"))
    }

    func testANewProfileNeverTakesTheOldAccountsProfiles() async {
        let server = FakeCloud()
        let (s, v, _, cloud) = linkedDevice(server)
        secondProfileOnThisDevice(s, v)
        // a fresh profile: another gid by definition
        await cloud.adopt(["gid": "g3", "token": "t3", "profile": ["handle": "new"] as JSONObject], fresh: true)
        XCTAssertEqual(v.current, "a")
        XCTAssertEqual(v.list().count, 1)
        XCTAssertNil(s.string("progress_b"))
        XCTAssertEqual(s.string(Cloud.syncGidKey), "g3")
    }
}

/// A count a @Sendable handler can bump from a test.
final class HitCount: @unchecked Sendable { var n = 0 }
