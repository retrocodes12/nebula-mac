import SwiftUI
import NebulaCore

/// One add-on on the launch card: still being asked (`count` nil), or how many rows it gave (0 = none).
struct ApChip: Equatable {
    var name: String
    var count: Int?
}

/// What the launch card shows. `forUrl` = the start it waits on (nil while the add-ons are asked).
struct ApCard: Equatable {
    var title: String
    var sub: String?
    var art: String?
    var logo: String?
    var line: String
    var chips: [ApChip] = []
    var forUrl: String?
}

/// Autoplay the best stream on the iPhone (Android's AutoplayRun, the rules in NebulaCore/Autoplay.swift): one run per
/// title — its rows as the add-ons answer (the streams page stays alive under the player, so add-ons still answering
/// after the pick keep feeding the queue a failed start draws from), the rows that did not play, the tries spent, and
/// the launch card PhoneRoot draws over everything until the first picture.
@MainActor
final class AutoplayRun: ObservableObject {
    static let shared = AutoplayRun()

    @Published var card: ApCard?
    private(set) var key: String?
    private(set) var rows: [Autoplay.Row] = []
    private(set) var failed = Set<String>()
    private(set) var tries = 0
    /// The row the run started (a player it opens is an autoplay one).
    var playing: String?
    /// The card is up over the streams page, still choosing: a tap hides it, and the list is the viewer's.
    private(set) var asking = false
    private var base: ApCard?

    static func key(_ t: StreamsTarget) -> String { t.type + "\n" + t.id }

    /// A new run for this title: the previous one stops.
    func begin(_ t: StreamsTarget) {
        end()
        key = AutoplayRun.key(t)
        var sub: String?
        if let e = t.episode {
            let k = Ids.episodeKicker(e.id) ?? "Episode"
            sub = e.name.isEmpty || e.name.hasPrefix("Episode") ? k : "\(k) · \(e.name)"
        } else if t.type == "series" {
            sub = Ids.episodeKicker(t.id)
        }
        let c = ApCard(title: t.item.name, sub: sub, art: Art.backdrop(t.item) ?? t.item.poster, logo: Art.logo(t.item),
                       line: Autoplay.askLine(found: 0, asking: []))
        base = c; card = c; asking = true
    }

    /// The run is over: the card goes and nothing more is kept.
    func end() {
        key = nil; rows = []; failed = []; tries = 0; playing = nil
        card = nil; asking = false; base = nil
    }

    /// The run for this title, if it is the one going (a page or a player leaving ends only its own).
    func endFor(_ t: StreamsTarget) { if key != nil && key == AutoplayRun.key(t) { end() } }

    func isFor(_ t: StreamsTarget) -> Bool { key != nil && key == AutoplayRun.key(t) }

    /// The page's sections, in the page's order (the order ties keep).
    func offer(_ sections: [StreamSection]) {
        rows = sections.flatMap { s in s.streams.map { Autoplay.Row($0, s.addon) } }
    }

    func ranked(_ cfg: Autoplay.Cfg) -> [Autoplay.Row] { Autoplay.rank(rows, cfg) }

    /// The add-ons are still being asked: the card's line and chips.
    func askCard(found: Int, chips: [ApChip]) {
        guard asking, let b = base else { return }
        var c = b
        c.line = Autoplay.askLine(found: found, asking: chips.filter { $0.count == nil }.map(\.name))
        c.chips = chips
        if c != card { card = c }
    }

    /// A start under way: "Starting 4K · Comet · instant" (or why the last one gave way), until its first picture.
    func startCard(_ s: StreamItem, from: Addon, why: String?) {
        guard let b = base else { return }
        asking = false
        var c = b
        c.line = Autoplay.startLine(s, addonName: from.name, why: why)
        c.chips = card?.chips ?? []
        c.forUrl = s.url
        card = c
    }

    /// The start `url` showed its picture (or gave up): the card steps aside.
    func started(_ url: String) { if card?.forUrl == url { card = nil } }

    /// A tap on the card: it goes, and the tap goes no further (the list or the player is the viewer's).
    func dismiss() { asking = false; card = nil }

    /// Nothing more will be picked here (nothing playable came, or the viewer took over).
    func stopAsking() { asking = false; if card?.forUrl == nil { card = nil } }

    /// The next row after the one that did not start (`cur`): the ranked queue as it stands now (late add-ons
    /// included), never a row that failed, within "If it won't start". Nil = none left.
    func next(cur: String, cfg: Autoplay.Cfg) -> Autoplay.Row? {
        failed.insert(cur)
        guard tries < cfg.retry, let n = Autoplay.next(ranked(cfg), cur: cur, failed: failed) else { return nil }
        tries += 1
        playing = n.stream.url
        return n
    }

    /// The player's Streams list: this title's rows best first.
    func menu(cur: String, cfg: Autoplay.Cfg) -> [(label: String, url: String)] {
        Autoplay.menu(cur: cur, cfg: cfg, rows: rows, failed: failed)
    }

    /// The screenshot rig: a card as it looks while the add-ons answer.
    func plantForShots() {
        let item = MetaItem(id: "tt1375666", type: "movie", name: "Inception")
        begin(StreamsTarget(type: "movie", id: item.id, item: item, addonUrl: ""))
        askCard(found: 14, chips: [ApChip(name: "Comet | TB", count: 12), ApChip(name: "Torrentio", count: 2), ApChip(name: "PenguPlay", count: nil)])
    }
}

/// The streams page's pick (StreamsView, first load only): the card's words as the add-ons answer, then the best row
/// once "Wait for add-ons" says so. Fed by the page's own load; checks every 250 ms like Android's loop.
@MainActor
final class AutoplayPick {
    private let run = AutoplayRun.shared
    private let target: StreamsTarget
    private let cfg: Autoplay.Cfg
    private let opened = Date()
    private var chips: [ApChip] = []
    /// Add-ons not answered yet (manifests included), by name.
    private var left: [String]
    private var allIn = false
    private var loop: Task<Void, Never>?

    /// A pick for this page, when Autoplay is on and this is a film or an episode; nil otherwise.
    static func begin(model: AppModel, target: StreamsTarget, onPick: @escaping (Autoplay.Row) -> Void) -> AutoplayPick? {
        guard model.prefs.bestPlay, target.type == "movie" || target.type == "series" else { return nil }
        return AutoplayPick(model: model, target: target, onPick: onPick)
    }

    private init(model: AppModel, target: StreamsTarget, onPick: @escaping (Autoplay.Row) -> Void) {
        self.target = target
        cfg = model.prefs.autoplay
        left = model.activeAddons.map(\.name)
        run.begin(target)
        let here = Route.streams(target)
        loop = Task { [weak self, weak model] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self = self, let model = model, !Task.isCancelled else { return }
                // the viewer took over (a tap on the card), went elsewhere, or something else plays
                guard self.run.asking, self.run.isFor(target), model.path.last == here, model.player == nil else { return }
                self.run.askCard(found: self.run.rows.count, chips: self.chips)
                let elapsed = Int(Date().timeIntervalSince(self.opened) * 1000)
                switch Autoplay.verdict(self.cfg, elapsedMs: elapsed, best: self.run.ranked(self.cfg).first?.stream,
                                        asking: self.left, allAnswered: self.allIn) {
                case .wait: continue
                case .none: self.run.stopAsking(); return
                case .pick: try? await Task.sleep(nanoseconds: 300_000_000)      // a row arriving with it still counts
                case .settle: try? await Task.sleep(nanoseconds: 700_000_000)
                }
                guard !Task.isCancelled, self.run.asking, model.path.last == here, model.player == nil,
                      let best = self.run.ranked(self.cfg).first else { self.run.stopAsking(); return }
                self.run.playing = best.stream.url
                self.run.startCard(best.stream, from: best.addon, why: nil)
                onPick(best)
                return
            }
        }
    }

    func asked(_ a: Addon) {
        if !chips.contains(where: { $0.name == a.name }) { chips.append(ApChip(name: a.name, count: nil)) }
    }

    /// An add-on answered (or failed): none yet from it, until its section lands right after.
    func done(_ a: Addon) {
        left.removeAll { $0 == a.name }
        if let i = chips.firstIndex(where: { $0.name == a.name }), chips[i].count == nil { chips[i].count = 0 }
    }

    /// The page's sections so far, in its order.
    func sections(_ s: [StreamSection]) {
        run.offer(s)
        for sec in s {
            if let i = chips.firstIndex(where: { $0.name == sec.addon.name }) { chips[i].count = sec.streams.count }
            else { chips.append(ApChip(name: sec.addon.name, count: sec.streams.count)) }
        }
    }

    func finished() { allIn = true; left = [] }

    /// The page went with nothing started: the run goes with it.
    func pageLeft() {
        loop?.cancel()
        if run.playing == nil { run.endFor(target) }
    }
}
