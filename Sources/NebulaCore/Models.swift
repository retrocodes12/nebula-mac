import Foundation

/// An installed add-on. `enabled` false = switched off in the list: kept and ranked, asked for nothing.
public struct Addon: Equatable, Hashable, Identifiable, Sendable {
    public var manifestUrl: String
    public var name: String
    public var base: String
    public var logo: String?
    public var enabled: Bool
    public var id: String { manifestUrl }

    public init(manifestUrl: String, name: String, base: String, logo: String? = nil, enabled: Bool = true) {
        self.manifestUrl = manifestUrl; self.name = name; self.base = base; self.logo = logo; self.enabled = enabled
    }
}

public struct CatalogRef: Equatable, Hashable, Sendable {
    public var type: String
    public var id: String
    public var name: String
    public var genres: [String]
    public var search: Bool
    /// Advertises the `skip` extra — without it, paging would just refetch page 1.
    public var skip: Bool
    /// Home can ask for it as it is. A catalog that only answers to a list of ids or to a
    /// search term has no page to show.
    public var browsable: Bool
}

/// Which types and id prefixes a resource answers for. nil = everything.
public struct ResourceScope: Equatable, Sendable {
    public var has = false
    public var types: [String]?
    public var prefixes: [String]?

    public func matches(type: String, id: String) -> Bool {
        guard has else { return false }
        if let t = types, !t.isEmpty, !t.contains(type) { return false }
        if let p = prefixes, !p.isEmpty { return p.contains { id.hasPrefix($0) } }
        return true
    }
}

public struct ManifestInfo: Sendable {
    public var addon: Addon
    public var catalogs: [CatalogRef]
    public var stream: ResourceScope
    public var meta: ResourceScope
    public var subtitles: ResourceScope
    public var description: String?
    public var version: String?

    public func canStream(_ type: String, _ id: String) -> Bool { stream.matches(type: type, id: id) }
    public func canMeta(_ type: String, _ id: String) -> Bool { meta.matches(type: type, id: id) }
    public func canSubs(_ type: String, _ id: String) -> Bool { subtitles.matches(type: type, id: id) }
}

public struct MetaItem: Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var name: String
    public var poster: String?
    public var posterShape: String
    public var imdbRating: String?
    public var releaseInfo: String?
    public var background: String?
    public var logo: String?
    public var description: String?
    public var genres: [String]
    public var runtime: String?

    public init(id: String, type: String, name: String, poster: String? = nil, posterShape: String = "poster",
                imdbRating: String? = nil, releaseInfo: String? = nil, background: String? = nil, logo: String? = nil,
                description: String? = nil, genres: [String] = [], runtime: String? = nil) {
        self.id = id; self.type = type; self.name = name; self.poster = poster; self.posterShape = posterShape
        self.imdbRating = imdbRating; self.releaseInfo = releaseInfo; self.background = background; self.logo = logo
        self.description = description; self.genres = genres; self.runtime = runtime
    }
}

public struct SubTrack: Equatable, Hashable, Sendable {
    public var url: String
    public var lang: String
    public init(url: String, lang: String) { self.url = url; self.lang = lang }
}

public struct StreamItem: Equatable, Hashable, Sendable {
    public var name: String
    public var title: String
    public var url: String
    public var subtitles: [SubTrack] = []
    public var videoSize: Int64 = 0
    /// behaviorHints.bingeGroup: the add-on's own "this is the same release across episodes".
    public var bingeGroup = ""
    public var fileName = ""
    /// behaviorHints.notWebReady is about browsers; this engine plays those, so it is only kept as a fact.
    public var notWebReady = false
    /// Decryption keys the row itself carries (kid → key, both 32 hex digits).
    public var clearKeys: [String: String] = [:]
    /// behaviorHints.proxyHeaders.request — headers the host insists on.
    public var headers: [String: String] = [:]

    public init(name: String, title: String, url: String) { self.name = name; self.title = title; self.url = url }
}

/// One episode of a series (a meta `videos` entry).
public struct Episode: Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var season: Int
    public var episode: Int?
    public var name: String
    public var overview: String?
    public var thumbnail: String?
    public var released: String?
}

public struct Trailer: Equatable, Hashable, Sendable {
    public var title: String
    public var key: String
}

/// The full meta document for one title — what the title page shows.
public struct FullMeta: Equatable, Sendable {
    public var name: String
    public var description: String?
    public var background: String?
    public var poster: String?
    public var logo: String?
    public var runtime: String?
    public var imdbRating: String?
    public var releaseInfo: String?
    public var genres: [String]
    public var cast: [String]
    public var director: [String]
    public var writer: [String]
    public var country: String?
    public var trailers: [Trailer]
    public var videos: [Episode]
}
