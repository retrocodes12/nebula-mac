import Foundation

/// The installed add-ons, in the viewer's order. Additions and removals are stamped so that
/// sync can tell a deliberate removal from a device that simply never had the add-on.
public final class AddonStore: @unchecked Sendable {
    public static let cinemeta = Addon(manifestUrl: "https://v3-cinemeta.strem.io/manifest.json", name: "Cinemeta", base: "https://v3-cinemeta.strem.io")
    public static let openSubtitles = Addon(manifestUrl: "https://opensubtitles-v3.strem.io/manifest.json", name: "OpenSubtitles v3", base: "https://opensubtitles-v3.strem.io")

    let store: Store
    public var onChange: (() -> Void)?
    /// The list and its sync stamps are two documents changed together, by the Add-ons page on
    /// the main thread and by a sync merge on the cloud's; one lock keeps each change whole.
    /// Recursive, because a locked step calls `all()` and `syncDoc()`.
    private let lock = NSRecursiveLock()

    public init(store: Store) { self.store = store }

    /// Who's watching: each profile keeps its own add-ons. The first profile's are the old documents ("addons",
    /// "addons_sync"); the second's sit beside them ("addons_b", "addons_sync_b"). Switching profile needs no reset —
    /// every read goes to the store under the profile this device is on, or under the one a sync step names (`for:`):
    /// a merge or a push captures the profile with the doc's name and never reads "current" again half-way.
    public var viewers: Viewers?
    /// The profile this device is on.
    var here: String { viewers?.current ?? "a" }
    private func listKey(for viewer: String) -> String { Viewers.key("addons", viewer: viewer) }
    private func syncKey(for viewer: String) -> String { Viewers.key("addons_sync", viewer: viewer) }

    /// The second profile's list is a PROVISIONAL copy of the first's: made without the cloud saying it has no
    /// "addons_b" of its own (signed out, the cloud did not answer, or read before anyone asked). Local only, never
    /// synced. While it stands, a pull that finds the cloud's "addons_b" takes it as it is in place of the copy, and
    /// one that finds none sends the copy up (Cloud.mergeAddons / pushDocument); a change by hand ends it.
    public static let seedFlag = "addons_b_seed"
    public func provisional(for viewer: String) -> Bool { viewer == "b" && store.string(AddonStore.seedFlag) != nil }
    func settle(for viewer: String) { if viewer == "b" { store.set(AddonStore.seedFlag, nil) } }

    /// The first time the second profile is used on this device it needs a list of its own. Asked before the device
    /// moves onto it, the cloud decides (`Cloud.prepareAddons`): its own "addons_b" when it has one, else a copy of the
    /// first profile's. Read before that (signed out, or a device that was already on it), it starts as the copy at
    /// once — provisional, so that the cloud's own list, when it comes, wins whole.
    private func ensureProfile(_ viewer: String) {
        guard viewer == "b" else { return }
        lock.lock(); defer { lock.unlock() }
        guard store.string(listKey(for: viewer)) == nil else { return }
        copyFirst(provisional: true)
    }

    /// The first profile's list and its stamps as they are — never "now", so a removal synced from another device's
    /// copy still wins the merge. The first profile with nothing gives an empty second.
    private func copyFirst(provisional: Bool) {
        store.set(AddonStore.seedFlag, provisional ? "1" : nil)
        store.setObject(syncKey(for: "b"), store.object("addons_sync"))
        store.setObject(listKey(for: "b"), store.object("addons"))
    }

    /// Whether this device holds that profile's own list (the first profile's always counts).
    public func hasList(for viewer: String) -> Bool { viewer != "b" || store.string(listKey(for: viewer)) != nil }

    /// The second profile's first list on this device: a copy of the first's (`provisional` when the cloud was not
    /// asked or did not answer), or empty with no stamps (the cloud's copy is adopted by the pull). Nothing when it
    /// already has one. True when it wrote. No `onChange`: the pull that follows sends a copy up itself, and must not
    /// send an empty list over the cloud's.
    @discardableResult
    public func startList(for viewer: String, copyingFirst: Bool, provisional: Bool = false) -> Bool {
        locked {
            guard !hasList(for: viewer) else { return false }
            if copyingFirst { copyFirst(provisional: provisional) } else {
                store.set(AddonStore.seedFlag, nil)
                store.setObject(syncKey(for: viewer), [:])
                store.setObject(listKey(for: viewer), ["list": [Any]()])
            }
            return true
        }
    }

    /// The stamps written back (a sync merge, a push stamping an unstamped add-on).
    func saveSync(_ s: JSONObject, for viewer: String) { locked { ensureProfile(viewer); store.setObject(syncKey(for: viewer), s) } }

    /// Run `body` with the add-on documents to itself.
    public func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    public func all() -> [Addon] { all(for: here) }

    public func all(for viewer: String) -> [Addon] {
        ensureProfile(viewer)
        let doc = store.object(listKey(for: viewer))
        var seen = Set<String>()
        return doc.objs("list").compactMap { o in
            guard let u = o.text("manifestUrl"), seen.insert(u).inserted else { return nil }
            return Addon(manifestUrl: u, name: o.text("name") ?? "Add-on", base: o.text("base") ?? Stremio.baseOf(u),
                         logo: o.text("logo"), enabled: o["enabled"] == nil ? true : o.bool("enabled"))
        }
    }

    public func active() -> [Addon] { all().filter { $0.enabled } }

    /// Write the list without touching the sync stamps (a merge, a seed).
    public func saveRaw(_ list: [Addon]) { saveRaw(list, for: here) }

    public func saveRaw(_ list: [Addon], for viewer: String) {
        locked {
            ensureProfile(viewer)
            var seen = Set<String>()
            let arr: [JSONObject] = list.filter { seen.insert($0.manifestUrl).inserted }.map {
                ["manifestUrl": $0.manifestUrl, "name": $0.name, "base": $0.base, "logo": $0.logo ?? "", "enabled": $0.enabled]
            }
            store.setObject(listKey(for: viewer), ["list": arr])
        }
    }

    /// Apply an intent to the current list, never a replacement built from a UI snapshot. Every caller is a change
    /// by hand, so a provisional copy (`seedFlag`) becomes the profile's own list.
    @discardableResult
    private func change(_ body: (inout [Addon], inout JSONObject) -> Bool) -> Bool {
        let changed = locked { () -> Bool in
            let v = here
            var list = all(for: v), s = syncDoc(for: v)
            guard body(&list, &s) else { return false }
            saveSync(s, for: v)
            saveRaw(list, for: v)
            settle(for: v)
            return true
        }
        if changed { onChange?() }
        return changed
    }

    /// The final install step is atomic even when sync installed this URL during its fetch.
    @discardableResult
    public func add(_ addon: Addon) -> Bool {
        change { list, s in
            guard !list.contains(where: { $0.manifestUrl == addon.manifestUrl }) else { return false }
            var at = s.obj("at") ?? [:], removed = s.obj("removed") ?? [:]
            at[addon.manifestUrl] = nowMs(); removed[addon.manifestUrl] = nil
            s["at"] = at; s["removed"] = removed
            list.append(addon)
            return true
        }
    }

    public func setEnabled(_ enabled: Bool, manifestUrl: String) {
        change { list, _ in
            guard let i = list.firstIndex(where: { $0.manifestUrl == manifestUrl }), list[i].enabled != enabled else { return false }
            list[i].enabled = enabled
            return true
        }
    }

    public func move(_ manifestUrl: String, by offset: Int) {
        change { list, s in
            guard let i = list.firstIndex(where: { $0.manifestUrl == manifestUrl }) else { return false }
            let step = max(-i, min(list.count - 1 - i, offset))
            guard step != 0 else { return false }
            let moved = list.remove(at: i)
            list.insert(moved, at: i + step)
            s["orderAt"] = nowMs()
            return true
        }
    }

    public func remove(_ manifestUrl: String) {
        change { list, s in
            guard let i = list.firstIndex(where: { $0.manifestUrl == manifestUrl }) else { return false }
            list.remove(at: i)
            var at = s.obj("at") ?? [:], removed = s.obj("removed") ?? [:]
            removed[manifestUrl] = nowMs(); at[manifestUrl] = nil
            s["at"] = at; s["removed"] = removed
            return true
        }
    }

    public func syncDoc() -> JSONObject { syncDoc(for: here) }

    public func syncDoc(for viewer: String) -> JSONObject {
        ensureProfile(viewer)
        var s = store.object(syncKey(for: viewer))
        if s["at"] == nil { s["at"] = JSONObject() }
        if s["removed"] == nil { s["removed"] = JSONObject() }
        return s
    }

    /// First run: the app must open full. A seeded default is stamped at the epoch so it can
    /// never beat a real removal made on another device.
    public func seedIfNeeded() { locked { seedLocked() } }

    private func seedLocked() {
        var flags = store.object("seeded")
        guard !flags.bool("v1") else { return }
        flags["v1"] = true
        store.setObject("seeded", flags)
        let v = here
        guard all(for: v).isEmpty else { return }
        saveRaw([AddonStore.cinemeta, AddonStore.openSubtitles], for: v)
        var s = syncDoc(for: v)
        var at = s.obj("at") ?? [:]
        at[AddonStore.cinemeta.manifestUrl] = 1
        at[AddonStore.openSubtitles.manifestUrl] = 1
        s["at"] = at
        saveSync(s, for: v)
    }
}
