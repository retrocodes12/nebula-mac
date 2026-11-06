import Foundation
import Combine
import NebulaCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The watch party on Mac and iPhone (new in 0.10.0): the same relay and protocol as the other apps (brief
/// party-2026-11-06.md) — the relay's clock, the newest state anyone sent, everyone steering unless the host keeps it,
/// the speed, waiting for whoever buffers, a viewer's own pause or rewind, notices, chat, statuses, remove, end for
/// everyone, switch-the-party, Share my stream / Use my own add-ons. Only sync messages travel: every member streams
/// the video itself. Live streams keep play/pause together (this engine does not measure its distance to the edge).
@MainActor
final class PartyClient: ObservableObject {
    struct FeedLine: Identifiable { let id = UUID(); let name: String; let text: String }

    @Published private(set) var code: String?
    @Published private(set) var isHost = false
    @Published private(set) var v2 = false
    @Published private(set) var hostOnly = false
    @Published private(set) var members: [PartyMember] = []
    @Published private(set) var chat: [PartyChatLine] = []
    @Published private(set) var feed: [FeedLine] = []
    @Published var unread = 0
    @Published var panelOpen = false
    @Published private(set) var pill = ""
    @Published var ask: PartyStreamDesc?
    @Published private(set) var ownPaused = false
    @Published private(set) var ownBehind = false
    @Published private(set) var reactions: [FeedLine] = []

    private(set) var id = ""
    private(set) var stream: PartyStreamDesc?
    private(set) var key = ""
    private(set) var choosing = false
    var active: Bool { code != nil }
    var hostV2: Bool { members.first(where: \.host).map { $0.v >= 2 } ?? isHost }
    /// May this device's own play / pause / seek / speed move the whole party?
    var mayControl: Bool { isHost || (v2 && !hostOnly && hostV2) }

    /// The app plays what the party watches (a viewer): the host's link as a play request.
    var onPlay: ((PartyStreamDesc) -> Void)?
    /// …or the same file from this device's own add-ons (nil: none has it).
    var onFindOwn: ((PartyStreamDesc) async -> Bool)?
    /// …or that title's streams page, to pick one.
    var onChoose: ((PartyStreamDesc) -> Void)?
    var say: ((String) -> Void)?
    /// The party itself closes the player (to play another stream, or to pick a source): this viewer stays in it.
    var keepOnClose = false

    private var task: URLSessionWebSocketTask?
    private var clock = PartySync.Clock()
    private var relayV2 = false
    private var helloSent = false
    private var hello: (() -> Void)?
    private var closing = false
    private var ending = false
    private var ps: PartyState?
    private var mine: (PartyState, Date)?
    private var selfMarks: [String: Date] = [:]
    private var quietUntil = Date.distantPast
    private var nudging = false
    private var waitIgnore = Set<String>()
    private var waitAt: Int64 = 0
    private var resumedAt = Date()
    private var lastPub = Date.distantPast
    private var lastSeekAt = Date.distantPast
    private var statusSig = ""
    private var bufSince: Date?
    private var heartbeatTimer: AnyCancellable?

    // the player this device plays the party on
    private weak var mpv: MPVController?
    private var playKey = ""
    private var playDesc: PartyStreamDesc?
    private var binds = Set<AnyCancellable>()
    private var lastT: Double = 0
    private var lastTAt = Date()
    /// when this stream first played: nothing is the viewer's before that (its own start, a resume point)
    private var playedAt: Date?

    // MARK: device settings (Settings › Watch party)

    nonisolated static var name: String {
        if let n = UserDefaults.standard.string(forKey: "party_name"), !n.trimmingCharacters(in: .whitespaces).isEmpty { return String(n.prefix(40)) }
        #if os(macOS)
        return Host.current().localizedName.map { String($0.prefix(40)) } ?? "Mac"
        #else
        return "iPhone"
        #endif
    }
    nonisolated static var share: Bool { UserDefaults.standard.object(forKey: "party_share") as? Bool ?? true }
    nonisolated static var useOwn: Bool { UserDefaults.standard.object(forKey: "party_own") as? Bool ?? false }
    nonisolated static var device: String {
        if let d = UserDefaults.standard.string(forKey: "party_dev"), d.count >= 8 { return d }
        let d = "i" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
        UserDefaults.standard.set(d, forKey: "party_dev")
        return d
    }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) + clock.off }

    // MARK: start, join, leave

    func start(_ d: PartyStreamDesc) {
        reset()
        stream = d; key = d.key
        say?("Starting party…")
        connect { [weak self] in
            guard let self else { return }
            var desc = d
            if !self.relayV2 { desc.share = true }    // a v1 relay takes no stream without its address
            self.send(["t": "create", "name": Self.name, "v": 2, "dev": Self.device, "stream": desc.wire()])
        }
    }

    func join(_ raw: String) {
        let c = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        guard c.count >= 4 else { say?("Enter the party code first."); return }
        reset()
        say?("Joining party…")
        connect { [weak self] in self?.send(["t": "join", "code": c, "name": Self.name, "v": 2, "dev": Self.device]) }
    }

    func leave(_ why: String? = "Left the party.") {
        if task != nil { send(["t": "leave"]) }
        closing = true
        task?.cancel(with: .normalClosure, reason: nil)
        reset()
        if let w = why { say?(w) }
    }

    func endForEveryone() { ending = true; send(["t": "endall"]) }
    func setHostOnly(_ on: Bool) { send(["t": "hostonly", "on": on]) }
    func kick(_ id: String) { send(["t": "kick", "id": id]) }
    func react(_ e: String) {
        send(["t": "react", "emoji": e])
        floatReaction(e, "")
    }
    func sendChat(_ text: String) {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !t.isEmpty, v2 else { return }
        let cid = "i" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(Int.random(in: 0..<9999))
        chat.append(PartyChatLine(num: 0, by: id, name: "", text: t, cid: cid, pend: true))
        send(["t": "chat", "text": t, "cid": cid])
    }
    func openPanel(_ on: Bool) { panelOpen = on; if on { unread = 0; feed.removeAll() } }

    private func reset() {
        task = nil; code = nil; isHost = false; v2 = false; hostOnly = false; members = []; chat = []; feed = []; unread = 0
        panelOpen = false; pill = ""; ask = nil; ownPaused = false; ownBehind = false; id = ""; stream = nil; key = ""; choosing = false
        relayV2 = false; helloSent = false; hello = nil; closing = false; ending = false; ps = nil; mine = nil; selfMarks = [:]
        nudging = false; waitIgnore = []; waitAt = 0; statusSig = ""; bufSince = nil; clock = PartySync.Clock()
        heartbeatTimer = nil
    }

    // MARK: the socket

    private func relayURL() async -> URL {
        let fallback = URL(string: "wss://play.rifflehq.in/party/ws")!
        guard let u = URL(string: "https://play.rifflehq.in/party.json"),
              let (data, _) = try? await URLSession.shared.data(from: u),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = o["server"] as? String, let url = URL(string: s), url.scheme == "wss" else { return fallback }
        return url
    }

    private func connect(_ sayHello: @escaping () -> Void) {
        hello = sayHello
        Task { [weak self] in
            guard let self else { return }
            let url = await self.relayURL()
            let t = URLSession.shared.webSocketTask(with: url)
            self.task = t
            t.resume()
            self.receive(t)
            // the relay's clock first: its answer says it speaks v2 (and gives the first sample); a v1 relay never answers
            self.clockAsk()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self.sayHelloOnce()
        }
    }
    private func sayHelloOnce() { guard !helloSent, task != nil else { return }; helloSent = true; hello?() }
    private func clockAsk() { send(["t": "clock", "c": Int64(Date().timeIntervalSince1970 * 1000)]) }

    private func send(_ o: [String: Any]) {
        guard let t = task, let data = try? JSONSerialization.data(withJSONObject: o), let s = String(data: data, encoding: .utf8) else { return }
        t.send(.string(s)) { _ in }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .failure:
                    if !self.closing { let had = self.active; self.reset(); self.say?(had ? "Party connection lost." : "Could not reach the party server.") }
                case .success(let msg):
                    var text: String?
                    switch msg { case .string(let s): text = s; case .data(let d): text = String(data: d, encoding: .utf8); @unknown default: break }
                    if let s = text, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { self.handle(o) }
                    self.receive(t)
                }
            }
        }
    }

    private func state(_ o: [String: Any]) -> PartyState {
        let at = (relayV2 ? (o["at"] as? NSNumber)?.int64Value : nil).flatMap { $0 > 0 ? $0 : nil }
            ?? nowMs() - ((o["age"] as? NSNumber)?.int64Value ?? 0)
        var rate = (o["rate"] as? NSNumber)?.doubleValue ?? 1
        if !(0.25...4).contains(rate) { rate = 1 }
        return PartyState(playing: o["playing"] as? Bool ?? false, pos: (o["pos"] as? NSNumber)?.doubleValue ?? 0, live: o["live"] as? Bool ?? false,
                          rate: rate, waiting: o["waiting"] as? Bool ?? false, at: at, seq: (o["seq"] as? NSNumber)?.int64Value ?? 0,
                          by: o["by"] as? String ?? "", name: o["name"] as? String ?? "")
    }
    private func members(_ a: Any?) -> [PartyMember]? {
        guard let list = a as? [[String: Any]] else { return nil }
        return list.prefix(30).map { o in
            PartyMember(id: o["id"] as? String ?? "", name: (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Guest", host: o["host"] as? Bool ?? false,
                        s: o["s"] as? String ?? "loading", k: o["k"] as? String ?? "", behind: (o["behind"] as? NSNumber)?.intValue, v: (o["v"] as? NSNumber)?.intValue ?? 1)
        }
    }
    private func chatLine(_ o: [String: Any]) -> PartyChatLine {
        PartyChatLine(num: (o["id"] as? NSNumber)?.int64Value ?? 0, by: o["by"] as? String ?? "", name: o["name"] as? String ?? "Guest",
                      text: o["text"] as? String ?? "", cid: o["cid"] as? String)
    }

    private func handle(_ m: [String: Any]) {
        switch m["t"] as? String ?? "" {
        case "clock":
            clock.sample(sentAt: (m["c"] as? NSNumber)?.int64Value ?? 0, server: (m["s"] as? NSNumber)?.int64Value ?? 0, now: Int64(Date().timeIntervalSince1970 * 1000))
            if !relayV2 {
                relayV2 = true
                sayHelloOnce()
                Task { for _ in 0..<3 { try? await Task.sleep(nanoseconds: 400_000_000); clockAsk() } }
                heartbeatTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.clockAsk() }
            }
        case "created":
            code = m["code"] as? String; isHost = true; id = m["id"] as? String ?? ""; v2 = (m["v"] as? NSNumber)?.intValue == 2
            hostOnly = m["hostOnly"] as? Bool ?? false
            members = [PartyMember(id: id, name: Self.name, host: true, s: "ready", k: key)]
            resumedAt = Date(); panelOpen = true
            say?("Party \(code ?? "") started — friends join with the code.")
            publish(heartbeat: false, waiting: false)
        case "joined":
            code = m["code"] as? String; isHost = m["host"] as? Bool ?? false; id = m["id"] as? String ?? ""
            v2 = (m["v"] as? NSNumber)?.intValue == 2; hostOnly = m["hostOnly"] as? Bool ?? false
            members = members(m["members"]) ?? []
            chat = ((m["chat"] as? [[String: Any]]) ?? []).map(chatLine)
            if let s = m["state"] as? [String: Any] { ps = state(s) }
            say?("Joined party \(code ?? "").")
            if let o = m["stream"] as? [String: Any], let d = PartyStreamDesc.from(o) {
                if isHost { stream = d; key = d.key } else { playFor(d) }
            }
        case "state":
            let s = state(m), prev = ps
            if let p = prev, s.seq > 0, p.seq > 0, s.seq < p.seq { return }
            ps = s
            if v2, !s.by.isEmpty, s.by != id, let n = PartySync.notice(prev, s) { say?(n) }
            if let p = prev, p.waiting, !s.waiting { resumedAt = Date() }
            correct()
        case "stated":
            if let (st, _) = mine {
                var stamped = st
                stamped.seq = (m["seq"] as? NSNumber)?.int64Value ?? 0
                if let at = (m["at"] as? NSNumber)?.int64Value, at > 0 { stamped.at = at }
                if ps == nil || stamped.seq >= ps!.seq { ps = stamped }
                mine = nil
            }
        case "stream":
            guard !isHost, let o = m["stream"] as? [String: Any], let d = PartyStreamDesc.from(o) else { return }
            ps = PartyState(playing: true, pos: 0, at: nowMs(), seq: ps?.seq ?? 0)
            ownPaused = false; ownBehind = false
            say?("The party is now watching \(d.name ?? d.title).")
            playFor(d)
        case "peers":
            if let ms = members(m["members"]) {
                if !members.isEmpty {
                    var had = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
                    for x in ms { if had.removeValue(forKey: x.id) == nil && x.id != id { say?("\(x.name) joined the watch party") } }
                    for x in had.values where x.id != id { say?("\(x.name) left the watch party") }
                }
                for x in ms where x.s == "ready" { waitIgnore.remove(x.id) }
                members = ms
                if ms.first(where: { $0.id == id })?.host == true { isHost = true }
            }
        case "react":
            floatReaction(m["emoji"] as? String ?? "", m["name"] as? String ?? "")
        case "chat":
            let l = chatLine(m)
            if let i = chat.firstIndex(where: { $0.cid != nil && $0.cid == l.cid && $0.pend }) { chat[i] = l }
            else {
                chat.append(l)
                if !panelOpen && l.by != id { unread += 1; feed.append(FeedLine(name: l.name, text: l.text)); if feed.count > 3 { feed.removeFirst() }; dropFeed() }
            }
            if chat.count > 100 { chat.removeFirst(chat.count - 100) }
        case "room":
            hostOnly = m["hostOnly"] as? Bool ?? false
            if !isHost {
                say?(hostOnly ? "Only the host can control playback now." : "Everyone can control playback now.")
                if !hostOnly { ownPaused = false; ownBehind = false }
            }
        case "host":
            isHost = true; ownPaused = false; ownBehind = false
            say?("You are now the party host.")
        case "end":
            let mineEnd = ending
            closing = true; task?.cancel(with: .normalClosure, reason: nil)
            reset()
            say?(mineEnd ? "You ended the watch party." : (m["reason"] as? String ?? "Party ended."))
        case "error":
            if m["chat"] as? Bool == true, let c = m["cid"] as? String, let i = chat.firstIndex(where: { $0.cid == c }) { chat[i].pend = false; chat[i].fail = true }
            if code == nil, let msg = m["message"] as? String { closing = true; task?.cancel(with: .normalClosure, reason: nil); reset(); say?(msg); return }
            say?(m["message"] as? String ?? "Party error.")
        default: break
        }
    }

    private func dropFeed() {
        Task { try? await Task.sleep(nanoseconds: 6_000_000_000); if !feed.isEmpty { feed.removeFirst() } }
    }
    private func floatReaction(_ e: String, _ name: String) {
        guard !e.isEmpty else { return }
        let r = FeedLine(name: name, text: e)
        reactions.append(r)
        Task { try? await Task.sleep(nanoseconds: 2_800_000_000); reactions.removeAll { $0.id == r.id } }
    }

    // MARK: what a viewer plays

    private func playFor(_ d: PartyStreamDesc) {
        stream = d; key = d.key; choosing = false
        let own = (Self.useOwn || d.url.isEmpty) && d.type != nil && d.id != nil
        guard own else {
            if !d.url.isEmpty { onPlay?(d) } else { say?("The host keeps their stream to themselves and this title has nothing to look it up by.") }
            return
        }
        choosing = true
        sendStatus(force: "choosing")
        say?("Looking for this file in your add-ons…")
        Task {
            let found = await onFindOwn?(d) ?? false
            guard stream == d else { return }
            if found { choosing = false; return }
            if !d.url.isEmpty { choosing = false; say?("None of your add-ons has this file — playing the host's link."); onPlay?(d) }
            else { onChoose?(d); say?("Pick a source — the party is watching \(d.file ?? d.name ?? d.title).") }
        }
    }

    // MARK: the host takes the party along — or asks first

    /// The player opened this: another source of the party's title or its show's next episode moves the party by itself,
    /// another title asks ("Switch the party to X?").
    func hostPlays(_ d: PartyStreamDesc) {
        guard active, isHost else { return }
        if !v2 || key.isEmpty || d.key == key || PartySync.sameShow(d.type, d.id, stream?.type, stream?.id) { switchParty(d) }
        else { ask = d; panelOpen = true }
    }
    func switchParty(_ d: PartyStreamDesc) {
        ask = nil
        stream = d; key = d.key
        ps = PartyState(playing: true, pos: 0, at: nowMs(), seq: ps?.seq ?? 0, by: id)
        var w = d; if !relayV2 { w.share = true }
        send(["t": "stream", "stream": w.wire()])
    }
    private var away: Bool { isHost && !playKey.isEmpty && playKey != key }

    // MARK: the player

    /// The player shows this stream (called on appear and whenever its request changes).
    func bind(_ player: MPVController, desc: PartyStreamDesc) {
        mpv = player; playDesc = desc; playKey = desc.key
        quietUntil = Date().addingTimeInterval(2)
        playedAt = nil
        if choosing && playKey == key { choosing = false }
        binds.removeAll()
        player.$paused.dropFirst().removeDuplicates().sink { [weak self] p in self?.user(p ? "pause" : "play") }.store(in: &binds)
        player.$speed.dropFirst().removeDuplicates().sink { [weak self] _ in self?.user("rate") }.store(in: &binds)
        Timer.publish(every: 0.5, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.tick() }.store(in: &binds)
        lastT = player.timePos; lastTAt = Date()
        if isHost { hostPlays(desc) }
    }
    func unbind(_ player: MPVController) {
        guard mpv === player else { return }
        binds.removeAll(); mpv = nil; playKey = ""
    }

    private var onKey: Bool { key.isEmpty || playKey == key }
    private func gap(_ s: PartyState, _ p: MPVController) -> Double { s.live ? 0 : PartySync.expect(s, now: nowMs()) - p.timePos }
    private func mark(_ k: String) { selfMarks[k] = Date() }
    private func pause(_ p: MPVController) { if !p.paused { mark("pause"); p.setPaused(true) } }
    private func play(_ p: MPVController) { if p.paused { mark("play"); p.setPaused(false) } }
    private func seek(_ p: MPVController, _ t: Double) { mark("seek"); p.seek(to: t); lastT = t; lastTAt = Date() }
    private func rate(_ p: MPVController, _ r: Double) { if abs(p.speed - r) > 0.001 { mark("rate"); p.setSpeed(r) } }
    private func userRate(_ p: MPVController) -> Double { nudging ? (ps?.rate ?? 1) : p.speed }

    private func publish(heartbeat: Bool, waiting: Bool) {
        guard active, let p = mpv, !away, onKey else { return }
        let live = p.isLive
        let pos = live ? 0 : max(0, p.timePos)
        let r = live ? 1 : userRate(p)
        let playing = !waiting && !p.paused
        var o: [String: Any] = ["t": "state", "playing": playing, "pos": pos, "live": live]
        if relayV2 {
            o["rate"] = r
            if waiting { o["waiting"] = true }
            if heartbeat { o["hb"] = true; o["base"] = ps?.seq ?? 0 }
        }
        send(o)
        let st = PartyState(playing: playing, pos: pos, live: live, rate: r, waiting: waiting, at: nowMs(), seq: ps?.seq ?? 0, by: id.isEmpty ? "me" : id)
        if !heartbeat || ps == nil || ps!.by == st.by || ps!.by.isEmpty { ps = st }
        mine = relayV2 ? (st, Date()) : nil
        lastPub = Date()
    }

    /// The viewer's own hand on the player (not a change this device made for the party).
    private func user(_ kind: String) {
        guard active, let p = mpv else { return }
        if let t = selfMarks[kind], Date().timeIntervalSince(t) < 1.5 { selfMarks[kind] = nil; return }
        guard Date() >= quietUntil, onKey, let pa = playedAt, Date().timeIntervalSince(pa) > 0.8 else { return }
        if kind == "pause" && (p.ended || p.failure != nil) { return }
        let s = ps
        if mayControl {
            if kind == "rate" { nudging = false }
            if kind == "seek", let s, !s.live, abs(gap(s, p)) < PartySync.seek { return }
            ownPaused = false; ownBehind = false
            if isHost && kind == "play" { resumedAt = Date() }
            publish(heartbeat: false, waiting: false)
            return
        }
        // the host keeps the controls: what this viewer does stays on this screen
        switch kind {
        case "pause": ownPaused = true
        case "play": ownPaused = false; ownBehind = s.map { gap($0, p) > PartySync.rejoin } ?? false
        case "seek":
            guard let s else { return }
            let g = gap(s, p)
            if g > PartySync.rejoin { ownBehind = true }
            else if ownBehind && g >= -PartySync.rejoin { ownBehind = false; say?("Back in sync with the party.") }
            else if g < -PartySync.rejoin { ownBehind = false; seek(p, p.timePos + g); say?("Only the host can control playback.") }
        case "rate":
            let want = s?.rate ?? 1
            if abs(p.speed - want) > 0.001 && !PartySync.isNudge(p.speed, of: want) { rate(p, want); say?("Only the host can control playback.") }
        default: break
        }
    }

    func catchUp() { ownBehind = false; ownPaused = false; lastSeekAt = .distantPast; correct(); say?("Caught up with the party.") }
    func resumeOwn() { if let p = mpv { p.setPaused(false) } }

    private func tick() {
        guard active, let p = mpv else { return }
        let now = Date()
        if playedAt == nil && p.loaded && !p.paused && !p.buffering { playedAt = now }
        // a jump the engine made (the timeline moved further than the clock): the viewer's seek, unless it was ours
        let expected = lastT + (p.paused ? 0 : now.timeIntervalSince(lastTAt) * p.speed)
        if p.loaded && abs(p.timePos - expected) > 2 { user("seek") }
        lastT = p.timePos; lastTAt = now
        if let m = mine, now.timeIntervalSince(m.1) > 3 { mine = nil }
        if choosing && onKey && !key.isEmpty { choosing = false }
        if ask == nil && isHost && !away && onKey && now.timeIntervalSince(lastPub) * 1000 >= Double(PartySync.heartbeat) { publish(heartbeat: true, waiting: ps?.waiting == true) }
        // the host waits for someone buffering: everyone paused (after a beat), 15 s at most
        if isHost, v2, !away, onKey, let s0 = ps, !s0.live {
            let w = PartySync.waiters(members, me: id, key: key, ignore: waitIgnore)
            let ms = nowMs()
            if s0.playing && !s0.waiting && !w.isEmpty && now.timeIntervalSince(resumedAt) * 1000 > Double(PartySync.resumeGrace) {
                pause(p); publish(heartbeat: false, waiting: true); waitAt = ms
            } else if s0.waiting && (w.isEmpty || ms - waitAt > PartySync.waitMax) {
                w.forEach { waitIgnore.insert($0.id) }
                play(p); resumedAt = now; publish(heartbeat: false, waiting: false)
            }
        }
        correct()
        sendStatus()
        pill = pillText()
    }

    /// Everyone glides to the party: a jump when way off, small speed nudges for small drift. Never towards our own word.
    private func correct() {
        guard active, let p = mpv, let s = ps, onKey, p.loaded else { return }
        if isHost && !v2 { return }
        if !s.by.isEmpty && s.by == id { return }
        if ownPaused { return }
        let base = s.live ? 1 : s.rate
        let err = gap(s, p)
        if ownBehind {
            if !p.paused { rate(p, base) }
            if abs(err) <= PartySync.rejoin && !p.paused { ownBehind = false; say?("Back in sync with the party.") }
            return
        }
        if !s.playing {
            pause(p); nudging = false; rate(p, base)
            if !s.live && abs(p.timePos - s.pos) > PartySync.pausedTol { seek(p, s.pos) }
            return
        }
        if p.failure == nil { play(p) }
        if s.live { return }
        switch PartySync.move(err: err, rate: base, nudging: nudging) {
        case .seek(let by, _):
            if Date().timeIntervalSince(lastSeekAt) > 4 { lastSeekAt = Date(); seek(p, p.timePos + by) }
            nudging = false; rate(p, base)
        case .nudge(let r): nudging = true; rate(p, r)
        case .hold(let r): nudging = false; rate(p, r)
        }
    }

    private func sendStatus(force: String? = nil) {
        guard v2 else { return }
        var st = "ready", behind: Int? = nil
        if let f = force { st = f }
        else if choosing { st = "choosing" }
        else if let p = mpv {
            if !onKey { st = "away" }
            else if !p.loaded { st = "loading" }
            else if p.buffering {
                if bufSince == nil { bufSince = Date() }
                if Date().timeIntervalSince(bufSince!) > 1 { st = "buffering" }
            } else { bufSince = nil }
            if st == "ready", ownPaused || ownBehind, let s = ps { st = "behind"; behind = PartySync.behindReported(gap(s, p)) }
        } else { st = "away" }
        let k = st == "choosing" ? "" : playKey
        let sig = "\(st)|\(k)|\(behind.map(String.init) ?? "")"
        guard sig != statusSig else { return }
        statusSig = sig
        var o: [String: Any] = ["t": "status", "s": st, "k": k]
        if let b = behind { o["behind"] = b }
        send(o)
    }

    private func pillText() -> String {
        guard let s = ps, onKey, let p = mpv else { return "" }
        if s.waiting {
            let w = PartySync.waiters(members, me: id, key: key, ignore: []).prefix(3).map(\.name)
            return w.isEmpty ? "Waiting for everyone" : "Waiting for " + w.joined(separator: ", ")
        }
        if ownPaused { return "Paused for you" }
        if ownBehind { return PartySync.gapLabel(gap(s, p)) + " behind · Catch up" }
        return ""
    }
    var myStatus: String {
        guard let p = mpv else { return "" }
        if (ownPaused || ownBehind), let s = ps { return PartySync.gapLabel(gap(s, p)) + " behind" }
        return onKey ? "Watching" : "Watching something else"
    }
}
