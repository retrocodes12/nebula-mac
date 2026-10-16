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
    /// every read goes to the store under the profile this device is on.
    public var viewers: Viewers?
    var listKey: String { viewers?.key("addons") ?? "addons" }
    var syncKey: String { viewers?.key("addons_sync") ?? "addons_sync" }

    /// The first time the second profile is used on this device it starts as a COPY of the first's add-ons — the list
    /// and its stamps as they are, never "now", so a removal synced from another device's copy still wins the merge.
    private func ensureProfile() {
        guard listKey != "addons" else { return }
        lock.lock(); defer { lock.unlock() }
        guard store.string(listKey) == nil else { return }
        store.setObject(syncKey, store.object("addons_sync"))
        store.setObject(listKey, store.object("addons"))
    }

    /// The stamps written back (a sync merge, a push stamping an unstamped add-on).
    func saveSync(_ s: JSONObject) { locked { ensureProfile(); store.setObject(syncKey, s) } }

    /// Run `body` with the add-on documents to itself.
    public func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    public func all() -> [Addon] {
        ensureProfile()
        let doc = store.object(listKey)
        var seen = Set<String>()
        return doc.objs("list").compactMap { o in
            guard let u = o.text("manifestUrl"), seen.insert(u).inserted else { return nil }
            return Addon(manifestUrl: u, name: o.text("name") ?? "Add-on", base: o.text("base") ?? Stremio.baseOf(u),
                         logo: o.text("logo"), enabled: o["enabled"] == nil ? true : o.bool("enabled"))
        }
    }

    public func active() -> [Addon] { all().filter { $0.enabled } }

    /// Write the list without touching the sync stamps (a merge, a seed).
    public func saveRaw(_ list: [Addon]) {
        locked {
            ensureProfile()
            var seen = Set<String>()
            let arr: [JSONObject] = list.filter { seen.insert($0.manifestUrl).inserted }.map {
                ["manifestUrl": $0.manifestUrl, "name": $0.name, "base": $0.base, "logo": $0.logo ?? "", "enabled": $0.enabled]
            }
            store.setObject(listKey, ["list": arr])
        }
    }

    /// Apply an intent to the current list, never a replacement built from a UI snapshot.
    @discardableResult
    private func change(_ body: (inout [Addon], inout JSONObject) -> Bool) -> Bool {
        let changed = locked {
            var list = all(), s = syncDoc()
            guard body(&list, &s) else { return false }
            saveSync(s)
            saveRaw(list)
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

    public func syncDoc() -> JSONObject {
        ensureProfile()
        var s = store.object(syncKey)
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
        guard all().isEmpty else { return }
        saveRaw([AddonStore.cinemeta, AddonStore.openSubtitles])
        var s = syncDoc()
        var at = s.obj("at") ?? [:]
        at[AddonStore.cinemeta.manifestUrl] = 1
        at[AddonStore.openSubtitles.manifestUrl] = 1
        s["at"] = at
        saveSync(s)
    }
}
