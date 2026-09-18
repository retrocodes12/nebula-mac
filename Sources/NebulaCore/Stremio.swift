import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The add-on protocol client: manifests, catalogs, meta, streams, subtitles.
public struct Stremio: Sendable {
    public let transport: Transport

    public init(transport: Transport = URLSessionTransport()) { self.transport = transport }

    public struct BadAddress: Error {}

    public func getData(_ address: String) async throws -> Data {
        guard let url = URL(string: address) else { throw BadAddress() }
        let (data, code) = try await transport.send(Net.addonRequest(url))
        guard (200...299).contains(code) else { throw HTTPFailure(code: code, error: "") }
        return data
    }

    public func getJSON(_ address: String) async throws -> JSONObject {
        JSON.object(try await getData(address)) ?? [:]
    }

    // MARK: addresses

    static let pathAllowed: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()

    public static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? s
    }

    public static func baseOf(_ manifestUrl: String) -> String {
        guard let r = manifestUrl.range(of: "/manifest.json") else { return manifestUrl }
        return String(manifestUrl[..<r.lowerBound])
    }

    /// What someone pastes into "Add an add-on": an install link reads as https, and a bare
    /// base address gains its manifest.
    public static func addonUrlOf(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if t.lowercased().hasPrefix("stremio://") { t = "https://" + t.dropFirst("stremio://".count) }
        if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://") { t = "https://" + t }
        if t.range(of: "/manifest.json") == nil {
            while t.hasSuffix("/") { t.removeLast() }
            t += "/manifest.json"
        }
        return URL(string: t) == nil ? nil : t
    }

    // MARK: manifest

    public func loadManifest(_ url: String) async throws -> ManifestInfo {
        Stremio.parseManifest(try await getJSON(url), url: url)
    }

    public static func parseManifest(_ j: JSONObject, url: String) -> ManifestInfo {
        let logo = j.text("logo") ?? j.text("icon")
        let addon = Addon(manifestUrl: url, name: j.text("name") ?? "Add-on", base: baseOf(url), logo: logo)
        var cats: [CatalogRef] = []
        for c in j.objs("catalogs") {
            var genres: [String] = []
            var search = false, skip = false
            // an extra the add-on insists on is only fine when it lists the values to pick from
            var required = Set<String>(), withOptions = Set<String>()
            for e in c.objs("extra") {
                let name = e.str("name")
                let opts = e.strs("options") ?? []
                if !opts.isEmpty { withOptions.insert(name) }
                if e.bool("isRequired") { required.insert(name) }
                switch name {
                case "genre": genres.append(contentsOf: opts)
                case "search": search = true
                case "skip": skip = true
                default: break
                }
            }
            for r in c.strs("extraRequired") ?? [] { required.insert(r) }
            for s in c.strs("extraSupported") ?? [] {
                if s == "search" { search = true }
                if s == "skip" { skip = true }
            }
            let type = c.str("type"), id = c.str("id")
            let browsable = !type.isEmpty && !id.isEmpty && required.allSatisfy { withOptions.contains($0) }
            cats.append(CatalogRef(type: type, id: id, name: c.text("name") ?? id, genres: genres,
                                   search: search, skip: skip, browsable: browsable))
        }
        // A resource is either the plain string "stream" (scoped by the top-level types and
        // idPrefixes) or an object with its own. A manifest may name the SAME resource more than
        // once with different scopes, so the scopes are UNIONED — keeping the last one hid an
        // add-on's films behind its live channels on the other clients. A scope with no types or
        // no prefixes matches everything, and stays that way once seen.
        let topTypes = j.strs("types"), topPrefixes = j.strs("idPrefixes")
        var scopes: [String: ScopeBuilder] = ["stream": ScopeBuilder(), "meta": ScopeBuilder(), "subtitles": ScopeBuilder()]
        for r in j.arr("resources") {
            if let name = r as? String {
                scopes[name]?.add(topTypes, topPrefixes)
            } else if let o = r as? JSONObject {
                scopes[o.str("name")]?.add(o.strs("types") ?? topTypes, o.strs("idPrefixes") ?? topPrefixes)
            }
        }
        return ManifestInfo(addon: addon, catalogs: cats,
                            stream: scopes["stream"]!.out(), meta: scopes["meta"]!.out(), subtitles: scopes["subtitles"]!.out(),
                            description: j.text("description"), version: j.text("version"))
    }

    struct ScopeBuilder {
        var has = false
        var types: [String]? = []
        var prefixes: [String]? = []

        mutating func add(_ t: [String]?, _ p: [String]?) {
            has = true
            if let t = t, !t.isEmpty { if types != nil { for x in t where !types!.contains(x) { types!.append(x) } } } else { types = nil }
            if let p = p, !p.isEmpty { if prefixes != nil { for x in p where !prefixes!.contains(x) { prefixes!.append(x) } } } else { prefixes = nil }
        }

        func out() -> ResourceScope {
            guard has else { return ResourceScope() }
            return ResourceScope(has: true, types: (types?.isEmpty ?? true) ? nil : types,
                                 prefixes: (prefixes?.isEmpty ?? true) ? nil : prefixes)
        }
    }

    // MARK: catalog

    public func loadCatalog(base: String, catalog c: CatalogRef, genre: String? = nil, query: String? = nil, skip: Int = 0) async throws -> [MetaItem] {
        var u = "\(base)/catalog/\(Stremio.enc(c.type))/\(Stremio.enc(c.id))"
        // every extra goes in one path segment, joined with &
        var extras: [String] = []
        if let q = query, !q.isEmpty { extras.append("search=" + Stremio.enc(q)) }
        else if let g = genre, !g.isEmpty { extras.append("genre=" + Stremio.enc(g)) }
        if skip > 0 { extras.append("skip=\(skip)") }
        if !extras.isEmpty { u += "/" + extras.joined(separator: "&") }
        u += ".json"
        return Stremio.parseMetas(try await getJSON(u), fallbackType: c.type)
    }

    public static func parseMetas(_ j: JSONObject, fallbackType: String) -> [MetaItem] {
        j.objs("metas").compactMap { m in
            let id = m.str("id")
            if id.isEmpty { return nil }
            let genres = (m.strs("genres") ?? m.strs("genre") ?? [])
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return MetaItem(id: id, type: m.text("type") ?? fallbackType, name: m.text("name") ?? id,
                            poster: m.text("poster"), posterShape: m.text("posterShape") ?? "poster",
                            imdbRating: m.text("imdbRating"), releaseInfo: m.text("releaseInfo") ?? m.text("year"),
                            background: m.text("background"), logo: m.text("logo"), description: m.text("description"),
                            genres: Array(genres.prefix(6)), runtime: m.text("runtime"))
        }
    }

    // MARK: meta

    public func loadFullMeta(base: String, type: String, id: String) async throws -> FullMeta? {
        let j = try await getJSON("\(base)/meta/\(Stremio.enc(type))/\(Stremio.enc(id)).json")
        guard let meta = j.obj("meta") else { return nil }
        return Stremio.parseFullMeta(meta)
    }

    public static func parseFullMeta(_ meta: JSONObject) -> FullMeta {
        let clean: ([String]?) -> [String] = { ($0 ?? []).filter { !$0.isEmpty } }
        var director = clean(meta.strs("director"))
        if director.isEmpty, let d = meta.text("director") { director = [d] }
        // two shapes in the wild: `trailerStreams` [{title, ytId}] and `trailers` [{source, type}]
        var trailers: [Trailer] = meta.objs("trailerStreams").compactMap { o in
            o.text("ytId").map { Trailer(title: o.text("title") ?? "Trailer", key: $0) }
        }
        if trailers.isEmpty {
            trailers = meta.objs("trailers").compactMap { o in
                o.text("source").map { Trailer(title: o.text("type") ?? "Trailer", key: $0) }
            }
        }
        return FullMeta(
            name: meta.str("name"),
            description: meta.text("description") ?? meta.text("overview"),
            background: meta.text("background"), poster: meta.text("poster"), logo: meta.text("logo"),
            runtime: meta.text("runtime"), imdbRating: meta.text("imdbRating"),
            releaseInfo: meta.text("releaseInfo") ?? meta.text("released").map { String($0.prefix(4)) },
            genres: clean(meta.strs("genres") ?? meta.strs("genre")),
            cast: Array(clean(meta.strs("cast")).prefix(8)),
            director: Array(director.prefix(2)), writer: Array(clean(meta.strs("writer")).prefix(2)),
            country: meta.text("country"), trailers: Array(trailers.prefix(6)),
            videos: parseVideos(meta.objs("videos")))
    }

    static func parseVideos(_ vids: [JSONObject]) -> [Episode] {
        vids.compactMap { v in
            let id = v.str("id")
            if id.isEmpty { return nil }
            let ep = v.optInt("episode") ?? v.optInt("number")
            let fallback = ("Episode " + (ep.map(String.init) ?? "")).trimmingCharacters(in: .whitespaces)
            return Episode(id: id, season: v.optInt("season") ?? 1, episode: ep,
                           name: v.text("name") ?? v.text("title") ?? fallback,
                           overview: v.text("overview") ?? v.text("description"),
                           thumbnail: v.text("thumbnail"), released: v.text("released"))
        }
    }

    // MARK: streams and subtitles

    public func loadStreams(base: String, type: String, id: String) async throws -> [StreamItem] {
        Stremio.parseStreams(try await getJSON("\(base)/stream/\(Stremio.enc(type))/\(Stremio.enc(id)).json"))
    }

    public static func parseStreams(_ j: JSONObject) -> [StreamItem] {
        j.objs("streams").compactMap { s in
            let url = s.str("url")
            // a row with no address (a torrent, an external page) has nothing this player can open
            if url.isEmpty { return nil }
            let bh = s.obj("behaviorHints") ?? [:]
            var item = StreamItem(name: s.str("name"), title: s.text("title") ?? s.str("description"), url: ClearKey.cleanUrl(url))
            item.subtitles = s.objs("subtitles").compactMap { o in
                o.text("url").map { SubTrack(url: $0, lang: o.text("lang") ?? "und") }
            }
            item.videoSize = bh.int64("videoSize")
            item.bingeGroup = bh.str("bingeGroup")
            item.fileName = bh.str("filename")
            item.notWebReady = bh.bool("notWebReady")
            item.clearKeys = ClearKey.extract(stream: s)
            if let req = bh.obj("proxyHeaders")?.obj("request") {
                for (k, v) in req { if let v = v as? String { item.headers[k] = v } }
            }
            return item
        }
    }

    public func loadSubtitles(base: String, type: String, id: String) async throws -> [SubTrack] {
        let j = try await getJSON("\(base)/subtitles/\(Stremio.enc(type))/\(Stremio.enc(id)).json")
        return j.objs("subtitles").compactMap { o in
            o.text("url").map { SubTrack(url: $0, lang: o.text("lang") ?? o.text("language") ?? "und") }
        }
    }
}
