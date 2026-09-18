import Foundation

/// The installed add-ons, in the viewer's order. Additions and removals are stamped so that
/// sync can tell a deliberate removal from a device that simply never had the add-on.
public final class AddonStore: @unchecked Sendable {
    public static let cinemeta = Addon(manifestUrl: "https://v3-cinemeta.strem.io/manifest.json", name: "Cinemeta", base: "https://v3-cinemeta.strem.io")
    public static let openSubtitles = Addon(manifestUrl: "https://opensubtitles-v3.strem.io/manifest.json", name: "OpenSubtitles v3", base: "https://opensubtitles-v3.strem.io")

    let store: Store
    public var onChange: (() -> Void)?

    public init(store: Store) { self.store = store }

    public func all() -> [Addon] {
        let doc = store.object("addons")
        return doc.objs("list").compactMap { o in
            guard let u = o.text("manifestUrl") else { return nil }
            return Addon(manifestUrl: u, name: o.text("name") ?? "Add-on", base: o.text("base") ?? Stremio.baseOf(u),
                         logo: o.text("logo"), enabled: o["enabled"] == nil ? true : o.bool("enabled"))
        }
    }

    public func active() -> [Addon] { all().filter { $0.enabled } }

    /// Write the list without touching the sync stamps (a merge, a seed).
    public func saveRaw(_ list: [Addon]) {
        let arr: [JSONObject] = list.map {
            ["manifestUrl": $0.manifestUrl, "name": $0.name, "base": $0.base, "logo": $0.logo ?? "", "enabled": $0.enabled]
        }
        store.setObject("addons", ["list": arr])
    }

    /// A deliberate change: stamp what was added and tombstone what was removed.
    public func save(_ next: [Addon], reordered: Bool = false) {
        let prev = all()
        var s = syncDoc()
        var at = s.obj("at") ?? [:], removed = s.obj("removed") ?? [:]
        let now = nowMs()
        let pv = Set(prev.map(\.manifestUrl)), nx = Set(next.map(\.manifestUrl))
        for a in next where !pv.contains(a.manifestUrl) { at[a.manifestUrl] = now; removed[a.manifestUrl] = nil }
        for a in prev where !nx.contains(a.manifestUrl) { removed[a.manifestUrl] = now; at[a.manifestUrl] = nil }
        s["at"] = at; s["removed"] = removed
        if reordered { s["orderAt"] = now }
        store.setObject("addons_sync", s)
        saveRaw(next)
        onChange?()
    }

    public func syncDoc() -> JSONObject {
        var s = store.object("addons_sync")
        if s["at"] == nil { s["at"] = JSONObject() }
        if s["removed"] == nil { s["removed"] = JSONObject() }
        return s
    }

    /// First run: the app must open full. A seeded default is stamped at the epoch so it can
    /// never beat a real removal made on another device.
    public func seedIfNeeded() {
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
        store.setObject("addons_sync", s)
    }
}
