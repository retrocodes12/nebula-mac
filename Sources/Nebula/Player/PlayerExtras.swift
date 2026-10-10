import SwiftUI
import ImageIO
import CoreGraphics
import NebulaCore

/// What both players do beside playing, kept in one place so the window and the phone agree:
/// skip intro / recap (and the credits' early Next), Seekr's scrub pictures, and the subtitle
/// timing nudge. The screens only draw what this says.
@MainActor
final class PlayerExtras: ObservableObject {
    struct SkipOffer: Equatable {
        var kind: String
        var end: Double
        var label: String { SkipSegments.label(kind) }
    }

    /// The Skip button to show now, if any.
    @Published private(set) var skipOffer: SkipOffer?
    /// Subtitles moved later (+) or earlier (−) by the viewer, in seconds. This play only.
    @Published private(set) var subDelay: Double = 0
    /// Bumped when a Seekr sheet has arrived, so the picture over the scrubber is drawn again.
    @Published private(set) var seekrVersion = 0
    @Published private(set) var seekrReady = false

    private var segs: SkipSegments.Segs?
    /// Segments Auto has already skipped this sitting — a viewer who goes back into one sees it.
    private var autoSkipped = Set<String>()
    private var skipTask: Task<Void, Never>?

    // MARK: skip intro

    /// Ask where this episode's recap, intro and credits fall (series episodes only, setting on).
    func startSkip(type: String, id: String, mode: String) {
        skipTask?.cancel()
        segs = nil; skipOffer = nil; autoSkipped = []
        guard mode != "off", SkipSegments.eligible(type: type, id: id) else { return }
        skipTask = Task { [weak self] in
            let got = await SkipSegments.load(id)
            guard !Task.isCancelled else { return }
            self?.segs = got
        }
    }

    /// Every clock tick. Returns a sentence to flash when Auto skipped something.
    func tick(_ pos: Double, mode: String, live: Bool, mpv: MPVController) -> String? {
        guard !live, mode != "off", let hit = SkipSegments.at(segs, pos) else {
            if skipOffer != nil { skipOffer = nil }
            return nil
        }
        if mode == "auto" && !autoSkipped.contains(hit.kind) {
            autoSkipped.insert(hit.kind)
            mpv.seek(to: hit.seg.end)
            skipOffer = nil
            return SkipSegments.note(hit.kind)
        }
        let offer = SkipOffer(kind: hit.kind, end: hit.seg.end)
        if skipOffer != offer { skipOffer = offer }
        return nil
    }

    /// The Skip button was pressed.
    func skipNow(_ mpv: MPVController) {
        guard let o = skipOffer else { return }
        autoSkipped.insert(o.kind)
        mpv.seek(to: o.end)
        skipOffer = nil
    }

    /// The closing credits are rolling: the next episode may be offered now.
    func inCredits(_ pos: Double) -> Bool { SkipSegments.inOutro(segs, pos) }

    // MARK: subtitle timing

    func nudgeSubs(_ by: Double, _ mpv: MPVController) {
        subDelay = ((subDelay + by) * 10).rounded() / 10
        mpv.setSubDelay(subDelay)
    }

    func resetSubs(_ mpv: MPVController) {
        subDelay = 0
        mpv.setSubDelay(0)
    }

    static func delayText(_ d: Double) -> String {
        if abs(d) < 0.05 { return "In step" }
        return String(format: "%.1f s %@", abs(d), d > 0 ? "later" : "earlier")
    }

    // MARK: Seekr

    private var track: Seekr.Track?
    private var seekrAsked: String?
    private var seekrTask: Task<Void, Never>?
    private let sheets = SheetCache()
    /// Pictures already cut, by cue index.
    private var tiles: [Int: CGImage] = [:]
    #if os(iOS)
    private let tileLimit = 80
    #else
    private let tileLimit = 160
    #endif

    /// One lookup per title and length (the key's own allowance is small: 20 films and 70
    /// episodes a day). A refused key is said once a run; nothing else is ever said.
    static var refusedKey: String?
    static var quietUntil = Date.distantPast

    func startSeekr(type: String, id: String, duration: Double, key: String, onRefused: @escaping @MainActor () -> Void) {
        guard !key.isEmpty, duration > 0, key != PlayerExtras.refusedKey, Date() >= PlayerExtras.quietUntil,
              let q = Seekr.query(type: type, id: id) else { return }
        let ask = q.map { $0.0 + "=" + $0.1 }.joined(separator: "&") + "|" + String(Int(duration))
        guard ask != seekrAsked else { return }
        seekrAsked = ask
        seekrTask?.cancel()
        seekrTask = Task { [weak self] in
            let r = await Seekr.lookup(key: key, query: q, durationMs: Int64(duration * 1000))
            guard !Task.isCancelled, let self = self else { return }
            switch r {
            case .found(let t):
                self.track = t
                self.tiles = [:]
                self.seekrReady = true
                await self.prefetch(t)
            case .refused:
                if PlayerExtras.refusedKey != key { PlayerExtras.refusedKey = key; onRefused() }
            case .quiet:
                PlayerExtras.quietUntil = Date().addingTimeInterval(30 * 60)
            case .none:
                break
            }
        }
    }

    func stop() {
        skipTask?.cancel(); seekrTask?.cancel()
        tiles = [:]
    }

    /// The picture for a position, or nil while its sheet is still on its way (never blank once
    /// any picture near it has been cut: the nearest one stands in).
    func preview(at secs: Double) -> CGImage? {
        guard let t = track else { return nil }
        let i = Seekr.cueIndex(t.cues, pos: secs, scale: t.scale)
        guard i >= 0 else { return nil }
        if let img = tiles[i] { return img }
        let c = t.cues[i]
        if let sheet = sheets.decoded(c.sheet), let img = PlayerExtras.cut(sheet, c) {
            if tiles.count >= tileLimit { tiles.removeAll() }
            tiles[i] = img
            return img
        }
        sheets.want(c.sheet) { [weak self] in self?.seekrVersion &+= 1 }
        // the nearest picture already cut stands in until this one's sheet is here
        for d in 1...6 {
            if let img = tiles[i - d] ?? tiles[i + d] { return img }
        }
        return nil
    }

    /// Every sheet's bytes, nearest the start first, one at a time (they are small JPEGs; it is
    /// decoding them that costs, and that waits until a picture is wanted).
    private func prefetch(_ t: Seekr.Track) async {
        var seen = Set<String>()
        for c in t.cues where seen.insert(c.sheet).inserted {
            if Task.isCancelled { return }
            await sheets.fetch(c.sheet)
        }
    }

    /// One tile into a picture of its own — a cropped view would keep the whole sheet alive.
    private static func cut(_ sheet: CGImage, _ c: SeekrCue) -> CGImage? {
        let r = CGRect(x: c.x, y: c.y, width: c.w, height: c.h)
        guard r.maxX <= CGFloat(sheet.width), r.maxY <= CGFloat(sheet.height),
              let ctx = CGContext(data: nil, width: c.w, height: c.h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(sheet, in: CGRect(x: -c.x, y: -(sheet.height - c.y - c.h), width: sheet.width, height: sheet.height))
        return ctx.makeImage()
    }
}

/// Seekr's sprite sheets: the bytes of every one (small), and at most a few decoded at a time
/// (a decoded 3200×1800 sheet is 23 MB).
@MainActor
final class SheetCache {
    private var bytes: [String: Data] = [:]
    private var loading: [String: Task<Void, Never>] = [:]
    private var decodedOrder: [String] = []
    private var decodedImages: [String: CGImage] = [:]
    private var waiting: [String: [() -> Void]] = [:]
    #if os(iOS)
    private let keep = 2
    #else
    private let keep = 4
    #endif
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c)
    }()

    func fetch(_ url: String) async {
        if bytes[url] != nil { return }
        if let l = loading[url] { await l.value; return }
        let t = Task { [weak self] in
            guard let u = URL(string: url), u.scheme == "https",
                  let (d, r) = try? await SheetCache.session.data(from: u), (r as? HTTPURLResponse)?.statusCode == 200, d.count < 8_000_000 else {
                self?.loading[url] = nil
                return
            }
            self?.bytes[url] = d
            self?.loading[url] = nil
            for done in self?.waiting.removeValue(forKey: url) ?? [] { done() }
        }
        loading[url] = t
        await t.value
    }

    /// Call `done` once this sheet can be decoded.
    func want(_ url: String, done: @escaping () -> Void) {
        // here already (and so undecodable): nothing will change by waiting — and a call now
        // would publish from inside the drawing that asked
        if bytes[url] != nil { return }
        waiting[url, default: []].append(done)
        if loading[url] == nil { Task { await fetch(url) } }
    }

    func decoded(_ url: String) -> CGImage? {
        if let img = decodedImages[url] { return img }
        guard let d = bytes[url], let src = CGImageSourceCreateWithData(d as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        decodedImages[url] = img
        decodedOrder.append(url)
        while decodedOrder.count > keep { decodedImages[decodedOrder.removeFirst()] = nil }
        return img
    }
}

/// The Seekr picture over the scrubber at `secs` (or nothing — the time tip alone).
struct SeekrTile: View {
    @ObservedObject var extras: PlayerExtras
    let secs: Double
    var width: CGFloat = 176

    var body: some View {
        let _ = extras.seekrVersion
        if let img = extras.preview(at: secs) {
            Image(decorative: img, scale: 1)
                .resizable().interpolation(.medium)
                .aspectRatio(CGFloat(img.width) / CGFloat(max(1, img.height)), contentMode: .fit)
                .frame(width: width)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 6)
        }
    }
}

/// The glass pill that skips the recap or the intro.
struct SkipPill: View {
    let text: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(text).scaledFont(size: 14, weight: .semibold)
                Image(systemName: "forward.fill").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18).frame(height: 44)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.3)))
            .environment(\.colorScheme, .dark)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
    }
}
