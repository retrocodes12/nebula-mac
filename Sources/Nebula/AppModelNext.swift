import SwiftUI
import NebulaCore

/// Continue watching the Nuvio way (11-05; NebulaCore `ContinueNext`): the row with Up next, the shows' episode lists
/// asked for it, and the offer at start of what the app was closed in the middle of.
extension AppModel {
    /// The row: one card per show (its resume point, or Up next once its newest episode is finished) and every film
    /// part-way through. A show with no kept answer is asked for one a moment later.
    func continueList() -> [ProgressRec] {
        let answers = nextUp
        return progress.continueList(nextOn: prefs.cwNext, unaired: prefs.cwUnaired,
                                     answer: { answers.get($0.id) }, want: { [weak self] s in self?.wantNext(s) })
    }

    private func wantNext(_ s: ContinueNext.Show) {
        if nuQueue[s.id]?.sig == s.sig { return }
        nuQueue[s.id] = s
        guard !nuRunning else { return }
        nuRunning = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            await self?.runNext()
        }
    }

    /// At most 12 shows a round, three at a time — newest finish first — then the row is drawn again.
    private func runNext() async {
        while !nuQueue.isEmpty {
            let viewer = viewerId
            let todo = Array(nuQueue.values.sorted { $0.seedAt > $1.seedAt }.prefix(12))
            nuQueue = [:]
            var got: [String: ContinueNext.Answer] = [:]
            var i = 0
            while i < todo.count {
                let part = Array(todo[i..<min(i + 3, todo.count)])
                i += 3
                await withTaskGroup(of: (ContinueNext.Show, FullMeta?).self) { group in
                    for s in part {
                        group.addTask { @MainActor [weak self] in
                            let item = MetaItem(id: s.id, type: s.type, name: "")
                            return (s, await self?.loadMeta(item, addonUrl: s.addonUrl)?.0)
                        }
                    }
                    for await (s, meta) in group {
                        let now = nowMs()
                        if let m = meta, !m.videos.isEmpty {
                            got[s.id] = ContinueNext.answer(show: s, name: m.name, poster: m.poster, back: m.background,
                                                            videos: m.videos, all: progress.all(), now: now)
                        } else {
                            var a = ContinueNext.Answer(sig: s.sig, t: now - ContinueNext.ttlMs + ContinueNext.failMs)
                            a.ep = nextUp.get(s.id).flatMap { $0.sig == s.sig ? $0.ep : nil }
                            got[s.id] = a
                        }
                    }
                }
            }
            guard viewer == viewerId else { continue }             // (the profile changed while asking)
            nextUp.put(got)
            progressVersion += 1
        }
        nuRunning = false
    }

    // MARK: resume at start

    /// Playing marks `last_play`; leaving the player the normal way clears it.
    func markLastPlay(_ t: StreamsTarget?) {
        guard let t = t, !t.id.isEmpty, t.type != "tv", t.type != "link" else { store.set("last_play", nil); return }
        store.setObject("last_play", ["v": viewerId, "type": t.type, "id": t.id, "at": nowMs()])
    }

    /// Once who's watching is answered and nothing else is on screen: the place it was left at, or — finished — the
    /// show's Up next if it is out. Settings › Offer to resume at start.
    func offerResumeWhenReady() async {
        let lp = launchLastPlay
        launchLastPlay = [:]
        guard let id = lp.text("id"), prefs.resumePrompt, nowMs() - lp.int64("at") < 14 * 86_400_000 else { return }
        let type = lp.str("type")
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if askingWho || whoOpen { continue }
            guard player == nil, path.isEmpty, lp.str("v") == viewerId else { return }
            let r = progress.get(type, id)
            if ProgressStore.resumable(r) { resumeOffer = r; return }
            guard r?.done == true, type == "series" else { return }
            let sid = Ids.seriesId(of: id)
            if let n = continueList().first(where: { $0.next && $0.airs == 0 && $0.seriesId == sid }) { resumeOffer = n; return }
            // its episode list may still be on its way
        }
    }

    /// Open a Continue watching card: the streams of its episode or film (an Up next not out yet: its title page).
    func openContinue(_ rec: ProgressRec) {
        let item = continueItem(rec)
        if rec.next && rec.airs > 0 { open(item, addonUrl: rec.addonUrl); return }
        push(.streams(StreamsTarget(type: rec.type, id: rec.id, item: item, addonUrl: rec.addonUrl)))
    }

    /// The title a card belongs to (the show, for an episode).
    func continueItem(_ rec: ProgressRec) -> MetaItem {
        MetaItem(id: rec.next ? rec.seriesId : Ids.itemId(type: rec.type, id: rec.id), type: rec.type, name: rec.name,
                 poster: rec.next ? rec.seriesPoster : rec.poster, posterShape: rec.next ? "poster" : rec.shape,
                 background: rec.next ? nil : rec.back)
    }
}

/// The offer at start, as an alert: Resume from 20:00 (or Play S2 E1) / Not now.
private struct ResumeOfferAlert: ViewModifier {
    @EnvironmentObject var model: AppModel

    func body(content: Content) -> some View {
        content.alert("Pick up where you left off?",
                      isPresented: Binding(get: { model.resumeOffer != nil }, set: { if !$0 { model.resumeOffer = nil } }),
                      presenting: model.resumeOffer) { r in
            Button(r.next ? "Play " + ResumeOfferAlert.tag(r) : "Resume from " + Fmt.clock(r.pos)) {
                model.resumeOffer = nil
                model.openContinue(r)
            }
            Button("Not now", role: .cancel) { model.resumeOffer = nil }
        } message: { r in
            Text([r.name, r.type == "series" ? ResumeOfferAlert.tag(r) : nil, r.next ? (r.epName.isEmpty ? "Up next" : r.epName) : nil]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        }
    }

    static func tag(_ r: ProgressRec) -> String {
        guard let n = Ids.episodeNumbers(of: r.id) else { return "the next episode" }
        return n.season.map { "S\($0) E\(n.episode)" } ?? "E\(n.episode)"
    }
}

extension View {
    func resumeOffer() -> some View { modifier(ResumeOfferAlert()) }
}
