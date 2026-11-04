import Foundation

/// Stream card designs (Settings › Streams › Stream cards) — the shared player's `SC_DESIGNS`, `scCustom`, `scSpec`,
/// `relTitle`, `relTags` and the release card's reading of a row (`releaseCardHtml`), with no screen attached.
/// A design is a layout plus which parts show; Classic is no design at all (the row the app drew before).
public enum StreamCards {
    public enum Layout: String, Sendable { case stack, row }

    /// What a card shows. Parts are the web's `SC_PARTS`, in its order.
    public struct Spec: Equatable, Sendable {
        public var layout: Layout = .stack
        public var dense = false
        public var tags = true, size = true, seeds = true, res = true, marks = true
        public var langs = true, addon = true, service = true, play = true, file = true

        public init(layout: Layout = .stack, dense: Bool = false) { self.layout = layout; self.dense = dense }

        public subscript(part: String) -> Bool {
            get {
                switch part {
                case "tags": return tags
                case "size": return size
                case "seeds": return seeds
                case "res": return res
                case "marks": return marks
                case "langs": return langs
                case "addon": return addon
                case "service": return service
                case "play": return play
                case "file": return file
                default: return false
                }
            }
            set {
                switch part {
                case "tags": tags = newValue
                case "size": size = newValue
                case "seeds": seeds = newValue
                case "res": res = newValue
                case "marks": marks = newValue
                case "langs": langs = newValue
                case "addon": addon = newValue
                case "service": service = newValue
                case "play": play = newValue
                case "file": file = newValue
                default: break
                }
            }
        }

        /// As the web keeps it in `streamCustom`: the layout, `dense`, and each part as 0/1.
        public var object: JSONObject {
            var o: JSONObject = ["layout": layout.rawValue, "dense": dense]
            for p in StreamCards.parts { o[p.id] = self[p.id] ? 1 : 0 }
            return o
        }

        func with(_ off: [String]) -> Spec { var s = self; for p in off { s[p] = false }; return s }
    }

    public static let parts: [(id: String, name: String)] = [
        ("tags", "Source · codec"), ("size", "Size"), ("seeds", "Seeds"), ("res", "Quality"), ("marks", "Picture & sound"),
        ("langs", "Languages"), ("addon", "Add-on"), ("service", "Service"), ("play", "Play button"), ("file", "File name"),
    ]

    public struct Design: Sendable {
        public let id: String
        public let name: String
        public let sub: String
        /// nil = Classic or Custom (Custom's spec is the saved one).
        public let spec: Spec?
    }

    public static let designs: [Design] = [
        Design(id: "release", name: "Release", sub: "Everything, the file’s name at the foot", spec: Spec()),
        Design(id: "compact", name: "Compact", sub: "Marks and sources, no file name", spec: Spec(dense: true).with(["service", "file"])),
        Design(id: "line", name: "One line", sub: "Quality, title, size and the add-on",
               spec: Spec(layout: .row, dense: true).with(["seeds", "marks", "langs", "service", "file"])),
        Design(id: "minimal", name: "Minimal", sub: "Quality, title and size — nothing else",
               spec: Spec(layout: .row, dense: true).with(["tags", "seeds", "marks", "langs", "addon", "service", "play", "file"])),
        Design(id: "classic", name: "Classic", sub: "The quality plate in front", spec: nil),
        Design(id: "custom", name: "Custom", sub: "Yours: pick the layout and every part", spec: nil),
    ]

    /// A design by id; an unknown id is Release.
    public static func design(_ id: String) -> Design { designs.first { $0.id == id } ?? designs[0] }

    /// A known design id, else "release".
    public static func style(_ id: String?) -> String {
        guard let id = id, designs.contains(where: { $0.id == id }) else { return "release" }
        return id
    }

    static func truthy(_ v: Any?) -> Bool? {
        switch v {
        case let b as Bool: return b
        case let i as Int: return i != 0
        case let d as Double: return d != 0
        case let n as NSNumber: return n.intValue != 0
        default: return nil
        }
    }

    /// The custom design: what was saved, over the Release card (a part never saved shows).
    public static func custom(_ saved: JSONObject?) -> Spec {
        var out = Spec()
        guard let c = saved else { return out }
        out.layout = (c["layout"] as? String) == "row" ? .row : .stack
        out.dense = truthy(c["dense"]) ?? false
        for p in parts { if let v = truthy(c[p.id]) { out[p.id] = v } }
        return out
    }

    /// The design the stream list draws: a spec, or nil for Classic.
    public static func spec(style id: String?, custom saved: JSONObject?) -> Spec? {
        let id = style(id)
        if id == "classic" { return nil }
        if id == "custom" { return custom(saved) }
        return design(id).spec ?? designs[0].spec
    }

    /// The first Custom starts from the design that was showing, so it is a tweak, not a blank page.
    public static func firstCustom(from showing: String?, custom saved: JSONObject?) -> JSONObject {
        (spec(style: showing, custom: saved) ?? designs[0].spec!).object
    }

    /// The row every Settings preview draws: a film's 4K remux from a torrent add-on, as such rows really arrive.
    public static let sampleAddon = "Torrentio"
    public static var sample: StreamItem {
        let file = "The.Dark.Knight.2008.UHD.BluRay.2160p.TrueHD.Atmos.7.1.DV.HEVC.REMUX-FraMeSToR.mkv"
        var s = StreamItem(name: "Torrentio\n4k DV | HDR",
                           title: file + "\n👤 154 💾 53.75 GB ⚙️ TorrentGalaxy\nMulti Audio / 🇬🇧 / 🇳🇱", url: "about:blank")
        s.fileName = file
        return s
    }

    // MARK: reading a row

    static let rcExt = StreamBadges.rx(#"\.(mkv|mp4|m4v|avi|webm|mov|ts|wmv|flv)$"#)
    static let rcStop = StreamBadges.rx(#"^(2160p|1080p|1080i|720p|576p|480p|360p|4k|uhd|web|webrip|webdl|web-dl|bluray|blu-ray|bdrip|brrip|bdremux|hdtv|dvdrip|remux|hdr|hdr10|dv|dovi|x264|x265|h264|h265|hevc|avc|av1|10bit|8bit|amzn|nf|dsnp|hmax|atvp|imax|hybrid|multi|dual|repack|proper|extended|unrated|uncut|complete|internal|limited|webm|ddp|dd|aac|truehd|atmos|dts)$"#)
    static let reYear = StreamBadges.rx(#"^\(?(19|20)\d\d\)?$"#)
    static let reEp1 = StreamBadges.rx(#"^s\d{1,2}(e\d{1,3})?$"#), reEp2 = StreamBadges.rx(#"^s\d{1,2}e\d"#)
    static let reOpen = StreamBadges.rx(#"^[\[{]"#)
    static let reGroup = StreamBadges.rx(#"^(\[[^\]]*\]\s*)+"#)

    /// "The.Dark.Knight.2008.UHD.BluRay.2160p…mkv" → "The Dark Knight 2008": the words before the year (kept), or up
    /// to the first release word. "" when nothing usable is left.
    public static func relTitle(_ file: String) -> String {
        var n = file.replacingOccurrences(of: #"^.*[/\\]"#, with: "", options: .regularExpression)
        n = StreamBadges.strip(rcExt, n, with: "")
        n = n.replacingOccurrences(of: "[._]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        n = StreamBadges.strip(reGroup, n, with: "")                   // a leading "[Group]"
        var toks = n.components(separatedBy: " ")
        var out: [String] = []
        if let yi = toks.indices.dropFirst().first(where: { StreamBadges.hit(reYear, toks[$0]) }) {
            // a year: everything before it is the title ("Charlotte's Web 2006" keeps its Web)
            out = Array(toks[..<yi])
            out.append(toks[yi].replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: ""))
            toks = []
        }
        for (i, t) in toks.enumerated() {
            let tl = t.lowercased().replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            if i > 0 && (StreamBadges.hit(rcStop, tl) || StreamBadges.hit(reEp1, tl) || StreamBadges.hit(reEp2, tl) || StreamBadges.hit(reOpen, t)) { break }
            out.append(t)
        }
        let r = out.joined(separator: " ").replacingOccurrences(of: #"[\s\-–:]+$"#, with: "", options: .regularExpression)
        return r.count >= 2 ? String(r.prefix(80)) : ""
    }

    static let tagRules: [(String, String)] = [
        (#"\b(blu[\s._-]?ray|bluray)\b"#, "BluRay"), (#"\b(bdrip|brrip)\b"#, "BDRip"), (#"\b(web[\s._-]?dl|webdl)\b"#, "WEB-DL"),
        (#"\b(web[\s._-]?rip|webrip)\b"#, "WEBRip"), (#"\bweb\b"#, "WEB"), (#"\bhdtv\b"#, "HDTV"),
        (#"\b(dvd[\s._-]?rip|dvdrip)\b"#, "DVDRip"), (#"\b(hdcam|camrip|cam)\b"#, "CAM"),
    ]
    static let tagRes = tagRules.map { (StreamBadges.rx($0.0), $0.1) }
    static let reRemux = StreamBadges.rx("remux"), reDisc = StreamBadges.rx(#"\b(bd|blu[\s._-]?ray|bluray|uhd)"#)
    static let reBdremux = StreamBadges.rx("bdremux")
    static let reAv1 = StreamBadges.rx(#"\bav1\b"#), reHevc = StreamBadges.rx(#"\b(hevc|h[\s._-]?265|x265)\b"#)
    static let reAvc = StreamBadges.rx(#"\b(avc|h[\s._-]?264|x264)\b"#)

    /// The source and the picture codec, said in words beside the title: ["BDRemux", "HEVC"].
    public static func relTags(_ raw: String) -> [String] {
        var out: [String] = []
        if StreamBadges.hit(reRemux, raw) {
            out.append(StreamBadges.hit(reDisc, raw) || StreamBadges.hit(reBdremux, raw) ? "BDRemux" : "Remux")
        } else if let t = tagRes.first(where: { StreamBadges.hit($0.0, raw) }) {
            out.append(t.1)
        }
        if StreamBadges.hit(reAv1, raw) { out.append("AV1") }
        else if StreamBadges.hit(reHevc, raw) { out.append("HEVC") }
        else if StreamBadges.hit(reAvc, raw) { out.append("AVC") }
        return out
    }

    /// The release card's language chips: two letters, as the files and the add-ons write them.
    public static let langCodes: [String: String] = [
        "English": "EN", "French": "FR", "Italian": "IT", "Spanish": "ES", "German": "DE", "Hindi": "HI", "Tamil": "TA", "Telugu": "TE",
        "Malayalam": "ML", "Kannada": "KN", "Polish": "PL", "Portuguese": "PT", "Russian": "RU", "Japanese": "JA", "Korean": "KO",
        "Chinese": "ZH", "Arabic": "AR", "Turkish": "TR", "Dutch": "NL", "Latino": "LAT", "Multi": "MULTI", "Dual Audio": "DUAL",
    ]
    public static func langCode(_ name: String) -> String { langCodes[name] ?? String(name.prefix(2)).uppercased() }

    /// The add-on's own label for the row ("4KHDHub | Direct" → "Direct"), less what the marks, the plate and the
    /// title already say; "" when nothing is left or it runs past 40 characters.
    public static func leftoverLabel(name: String, addonName: String, title: String, fired: [NSRegularExpression], provider: String?) -> String {
        let low = title.lowercased()
        let kept = StreamBadges.cleanName(name, addonName: addonName).components(separatedBy: " · ").compactMap { raw -> String? in
            let tk = raw.trimmingCharacters(in: .whitespaces)
            if tk.isEmpty { return nil }
            if fired.contains(where: { StreamBadges.hit($0, tk) }) { return nil }
            if StreamBadges.hit(rcStop, tk.lowercased()) || low.contains(tk.lowercased()) { return nil }
            if let p = provider, tk == p { return nil }
            return tk
        }
        let label = kept.joined(separator: " · ")
        return label.count <= 40 ? label : ""
    }

    /// The file a card names: the add-on's file name, else a first text line that reads like a release ("The Dark
    /// Knight 2008 1080p BluRay x264" — its title is more than four characters shorter than the line).
    public static func cardFile(_ s: StreamItem) -> String {
        let file = ReleaseKey.fileName(s)
        if !file.isEmpty { return file }
        let first = s.title.components(separatedBy: "\n").first ?? ""
        let line = StreamBadges.strip(StreamBadges.reEmoji, first).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return "" }
        let t = relTitle(line)
        return !t.isEmpty && t.count < line.count - 4 ? line : ""
    }
}

/// Everything a release card can show for one row, read once as the add-on answers (beside `StreamRowText`).
/// Which of it is drawn is the design's business.
public struct ReleaseCard: Equatable, Sendable {
    public var title: String
    public var tags: [String]
    /// "4K", "1080p", "720p", "SD"; nil when the row does not say.
    public var res: String?
    /// Picture and sound marks (badge files): never the resolution, source, codec, bit depth or channels; four at most.
    public var marks: [String]
    public var langs: [String]
    /// The add-on's own leftover label ("Direct"), "" for none.
    public var label: String
    /// The service or site inside the add-on (Torrentio's "TorrentGalaxy"), when it is not the add-on itself.
    public var provider: String?
    public var size: String?
    public var seeds: String?
    public var bitrate: String?
    /// The file's own name (no folders), "" for none.
    public var file: String
    /// The description, used when there is no file name.
    public var desc: String
    /// "instant" / "not ready yet" for a debrid row.
    public var note: String?

    static let markSkip: Set<String> = ["resolution", "source", "video-codec", "bit-depth", "audio-channels"]

    public init(_ stream: StreamItem, addonName: String?, name: String, desc: String, facts f: StreamBadges.Facts,
                plate: StreamBadges.Plate?, fired: [NSRegularExpression]) {
        let raw = stream.name + "\n" + stream.title + "\n" + stream.fileName
        let fileFull = StreamCards.cardFile(stream)
        let fallback = !name.isEmpty ? name : (f.provider ?? StreamBadges.cleanName(stream.title.components(separatedBy: "\n").first ?? "", addonName: addonName))
        let rt = StreamCards.relTitle(fileFull)
        title = !rt.isEmpty ? rt : (fallback.isEmpty ? "Stream" : fallback)
        tags = StreamCards.relTags(raw)
        res = plate.map { p in p.res.allSatisfy(\.isNumber) ? p.res + "p" : p.res }
        marks = StreamBadges.match(raw, skipGroups: ReleaseCard.markSkip, cap: 4).badges
        langs = StreamBadges.langList(raw, max: 5).map(StreamCards.langCode)
        let an = addonName ?? ""
        label = StreamCards.leftoverLabel(name: stream.name, addonName: an, title: title, fired: fired, provider: f.provider)
        provider = f.provider.flatMap { $0 == an ? nil : $0 }
        size = f.size; seeds = f.seeds; bitrate = f.bitrate
        file = fileFull.replacingOccurrences(of: #"^.*[/\\]"#, with: "", options: .regularExpression)
        self.desc = fileFull.isEmpty ? desc : ""
        note = Autoplay.instant(stream) > 0 ? "instant" : Autoplay.debrid(stream) == .wait ? "not ready yet" : nil
    }
}
