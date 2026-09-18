import Foundation

public struct LibItem: Equatable, Hashable, Identifiable, Sendable {
    public var type: String
    public var id: String
    public var name: String
    public var poster: String?
    public var shape: String
    public var addonUrl: String
    public var at: Int64

    public var meta: MetaItem { MetaItem(id: id, type: type, name: name, poster: poster, posterShape: shape) }
}

/// My List — one record per saved title, keyed "<type>:<id>", the SAME document the other
/// clients keep. A removal stays as a `{removed, at}` tombstone so it beats a stale copy in sync.
public final class LibraryStore: @unchecked Sendable {
    static let maxLive = 500
    let store: Store
    public var onChange: (() -> Void)?

    public init(store: Store) { self.store = store }

    public func doc() -> JSONObject { store.object("library") }
    public func replaceAll(_ o: JSONObject) { store.setObject("library", o) }

    public func contains(_ type: String, _ id: String) -> Bool {
        guard let r = doc().obj("\(type):\(id)") else { return false }
        return !r.bool("removed")
    }

    /// Add or remove; returns true when the title is now saved.
    @discardableResult
    public func toggle(_ item: MetaItem, addonUrl: String) -> Bool {
        var o = doc()
        let k = "\(item.type):\(item.id)"
        let nowIn: Bool
        if let cur = o.obj(k), !cur.bool("removed") {
            o[k] = ["removed": true, "at": nowMs()] as JSONObject
            nowIn = false
        } else {
            o[k] = ["type": item.type, "id": item.id, "name": item.name, "poster": item.poster ?? "",
                    "shape": item.posterShape, "addonUrl": addonUrl, "at": nowMs()] as JSONObject
            nowIn = true
        }
        persist(o)
        return nowIn
    }

    private func persist(_ input: JSONObject) {
        var o = input
        // tombstones purge only under space pressure, and old ones first — a device offline for
        // months may still hold the record a tombstone exists to beat
        if o.count > 200 {
            let cut = nowMs() - 180 * 24 * 3_600_000
            for (k, v) in o { if let r = v as? JSONObject, r.bool("removed"), r.int64("at") < cut { o[k] = nil } }
        }
        let live = o.compactMap { (k, v) -> (String, Int64)? in
            guard let r = v as? JSONObject, !r.bool("removed") else { return nil }
            return (k, r.int64("at"))
        }
        if live.count > LibraryStore.maxLive {
            for (k, _) in live.sorted(by: { $0.1 > $1.1 }).dropFirst(LibraryStore.maxLive) { o[k] = nil }
        }
        replaceAll(o)
        onChange?()
    }

    /// Saved titles, newest first.
    public func list() -> [LibItem] {
        doc().values.compactMap { v -> LibItem? in
            guard let r = v as? JSONObject, !r.bool("removed"), let id = r.text("id") else { return nil }
            return LibItem(type: r.str("type"), id: id, name: r.str("name"), poster: r.text("poster"),
                           shape: r.text("shape") ?? "poster", addonUrl: r.str("addonUrl"), at: r.int64("at"))
        }.sorted { $0.at > $1.at }
    }
}
