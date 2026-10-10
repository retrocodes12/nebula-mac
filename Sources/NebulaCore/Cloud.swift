import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct Profile: Equatable, Sendable {
    public var handle: String
    public var name: String
    public var avatar: String
    public var supporter: Bool
    /// supporter · plus · monthly · founder (the server's names); "" when not a supporter.
    public var tier: String = ""
    /// The mark by the name — star, heart, bolt or crown (chosen from Supporter Plus up).
    public var mark: String = "star"
    public var since: Int64 = 0
    /// The name is on the supporters' wall.
    public var wall = false
    /// The monthly plan's state (trialing, active, past_due, paused) and its private manage link.
    public var planStatus: String = ""
    public var planManage: String = ""

    public init(handle: String, name: String, avatar: String, supporter: Bool) {
        self.handle = handle; self.name = name; self.avatar = avatar; self.supporter = supporter
    }

    public static let tiers: [(id: String, name: String)] = [("supporter", "Supporter"), ("plus", "Supporter Plus"), ("monthly", "Monthly Supporter"), ("founder", "Founder")]
    public static let marks = ["star", "heart", "bolt", "crown"]

    /// 0 not a supporter · 1 supporter · 2 plus or monthly · 3 founder.
    public var rank: Int {
        guard supporter else { return 0 }
        switch tier { case "plus", "monthly": return 2; case "founder": return 3; default: return 1 }
    }
    public var tierName: String { Profile.tiers.first { $0.id == tier }?.name ?? "Supporter" }
    /// The mark by THIS name: the chosen one from Supporter Plus up, a star below.
    public var shownMark: String { rank >= 2 && Profile.marks.contains(mark) ? mark : "star" }
    public var planText: String {
        switch planStatus {
        case "trialing": return "Free week"
        case "active": return "Active"
        case "past_due": return "Payment failed — update your card"
        case "paused": return "Paused"
        default: return ""
        }
    }
}

/// `GET /v1/support`: where to send someone who wants to chip in (nil until one is set), and
/// the wall of names — founders first, as the server sends them.
public struct SupportInfo: Equatable, Sendable {
    public var url: String?
    public var wall: [(name: String, tier: String)]
    public var count: Int

    public static let empty = SupportInfo(url: nil, wall: [], count: 0)

    public static func == (a: SupportInfo, b: SupportInfo) -> Bool {
        a.url == b.url && a.count == b.count && a.wall.map { $0.name + "|" + $0.tier } == b.wall.map { $0.name + "|" + $0.tier }
    }

    static func parse(_ o: JSONObject) -> SupportInfo {
        let raw = (o["url"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let url = raw.hasPrefix("https://") || raw.hasPrefix("http://") ? raw : nil
        var wall: [(String, String)] = []
        for v in o.arr("wall") {
            if let n = v as? String, !n.trimmingCharacters(in: .whitespaces).isEmpty { wall.append((n.trimmingCharacters(in: .whitespaces), "supporter")) }
            else if let r = v as? JSONObject, let n = r.text("name")?.trimmingCharacters(in: .whitespaces), !n.isEmpty {
                let t = r.str("tier")
                wall.append((n, Profile.tiers.contains { $0.id == t } ? t : "supporter"))
            }
        }
        return SupportInfo(url: url, wall: wall, count: o.int("count"))
    }

    var doc: JSONObject {
        ["url": url ?? "", "wall": wall.map { ["name": $0.name, "tier": $0.tier] as JSONObject }, "count": count]
    }
}

public struct DeviceRec: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var plat: String
    public var at: Int64
    public var seen: Int64
    public var me: Bool
}

/// Nebula Cloud client — the profile and the sync it carries.
///
/// A profile is an @handle and a password, nothing else. Every device that signs in gets a token
/// of its own, and add-ons, watch progress and My List flow between them, newest change winning
/// per record. THE WIRE FORMAT IS THE SHARED PLAYER'S, verbatim — that is the whole point.
/// Ratings and the subtitle style also live on the profile; this client neither reads nor writes
/// them, so they pass through untouched.
public actor Cloud {
    public static let defaultBase = "https://play.rifflehq.in/cloud"
    static let syncKeys = ["addons", "progress", "library", "sub_style", "seekr"]

    let base: String
    let store: Store
    let transport: Transport
    let addons: AddonStore
    let progress: ProgressStore
    let library: LibraryStore
    let deviceName: String
    /// What the profile's device list files this device under ("macos", "ios"). Add-on requests
    /// keep saying macos (Net.clientName) — that is what the sports add-on recognises.
    let platform: String

    private var pushTasks: [String: Task<Void, Never>] = [:]
    private var writes: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var requests: [UUID: Task<(Data, Int), Error>] = [:]
    private var generation: UInt64 = 0
    /// How many times each key has changed. A push only clears the dirty mark when nothing
    /// changed while it was on the wire — otherwise that change was never sent and a flush at
    /// quit would find nothing to send.
    private var changes: [String: Int] = [:]
    private var lastPullAt: Int64 = 0
    private var applying = false

    /// After a pull changed local state, with the keys that changed.
    public var onApplied: (@Sendable (Set<String>) -> Void)?
    /// A signed request came back 401 — the token was revoked elsewhere.
    public var onSignedOut: (@Sendable () -> Void)?
    public var onProfile: (@Sendable (Profile?) -> Void)?

    public init(store: Store, addons: AddonStore, progress: ProgressStore, library: LibraryStore,
                transport: Transport = URLSessionTransport(), base: String = Cloud.defaultBase, deviceName: String = "Mac",
                platform: String = "macos") {
        self.store = store; self.addons = addons; self.progress = progress; self.library = library
        self.transport = transport; self.base = base; self.deviceName = deviceName; self.platform = platform
    }

    public func setHandlers(onApplied: (@Sendable (Set<String>) -> Void)?, onSignedOut: (@Sendable () -> Void)?, onProfile: (@Sendable (Profile?) -> Void)?) {
        self.onApplied = onApplied; self.onSignedOut = onSignedOut; self.onProfile = onProfile
    }

    // MARK: credential

    private var cred: JSONObject { store.object("cloud_link") }
    public var linked: Bool { !cred.str("gid").isEmpty && !cred.str("token").isEmpty }

    public nonisolated func storedProfile() -> Profile? { Cloud.parseProfile(store.object("profile")) }

    /// A profile from `/me` (its `supporter` object), from a sign-in's `profile` (`sup`, `tier`,
    /// `mark`), or from what this device stored (the same flat fields plus the plan's).
    static func parseProfile(_ o: JSONObject?) -> Profile? {
        guard let o = o, let h = o.text("handle") else { return nil }
        let s = o.obj("supporter")
        var p = Profile(handle: h, name: o.text("name") ?? h, avatar: o.text("avatar") ?? "#636366",
                        supporter: o.bool("sup") || s != nil)
        if p.supporter {
            let t = s?.text("tier") ?? o.text("tier") ?? "supporter"
            p.tier = Profile.tiers.contains { $0.id == t } ? t : "supporter"
            let m = s?.text("mark") ?? o.text("mark") ?? "star"
            p.mark = Profile.marks.contains(m) ? m : "star"
            p.since = s?.int64("since") ?? o.int64("since")
            p.wall = s?.bool("wall") ?? o.bool("wall")
            let plan = s?.obj("subscription")
            p.planStatus = plan?.text("status") ?? (s == nil ? o.str("planStatus") : "")
            let manage = plan?.text("manage") ?? (s == nil ? o.str("planManage") : "")
            p.planManage = manage.hasPrefix("https://") ? manage : ""
        }
        return p
    }

    private func setProfile(_ o: JSONObject?) {
        let p = Cloud.parseProfile(o)
        if let p = p {
            store.setObject("profile", ["handle": p.handle, "name": p.name, "avatar": p.avatar, "sup": p.supporter, "tier": p.tier,
                                        "mark": p.mark, "since": p.since, "wall": p.wall, "planStatus": p.planStatus, "planManage": p.planManage])
        } else {
            store.set("profile", nil)
        }
        onProfile?(p)
    }

    var deviceInfo: JSONObject { ["name": String(deviceName.prefix(24)), "plat": platform] }

    // MARK: HTTP

    public func api(_ method: String, _ path: String, _ body: JSONObject? = nil, auth: Bool = true) async throws -> JSONObject {
        try Task.checkCancellation()
        let session = generation
        guard let url = URL(string: base + path) else { throw HTTPFailure(code: 0, error: "bad address") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        let signed = auth && linked
        if signed { r.setValue("Bearer \(cred.str("gid")).\(cred.str("token"))", forHTTPHeaderField: "Authorization") }
        if method != "GET" { r.httpBody = JSON.data(body ?? [:]) }
        let id = UUID(), request = r, transport = self.transport
        let task = Task { try await transport.send(request) }
        requests[id] = task
        defer { requests[id] = nil }
        let (data, code) = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        guard current(session) else { throw CancellationError() }
        let j = JSON.object(data) ?? [:]
        guard (200...299).contains(code) else {
            // a dead credential: the device was signed out from elsewhere, or the profile is gone
            if code == 401 && signed { credentialDead() }
            throw HTTPFailure(code: code, error: j.str("error"))
        }
        return j
    }

    private func current(_ session: UInt64) -> Bool { session == generation && !Task.isCancelled }

    private func switchSession() {
        generation &+= 1
        for task in pushTasks.values { task.cancel() }
        for write in writes.values { write.task.cancel() }
        for task in requests.values { task.cancel() }
        pushTasks.removeAll(); writes.removeAll(); requests.removeAll(); changes.removeAll()
        lastPullAt = 0
    }

    /// Take a credential set {gid, token, profile} as this device's identity.
    func adopt(_ r: JSONObject, fresh: Bool) async {
        switchSession()
        let session = generation
        store.setObject("cloud_link", ["gid": r.str("gid"), "token": r.str("token")])
        store.setObject("cloud_revs", [:])
        store.setObject("cloud_dirty", [:])
        setProfile(r.obj("profile"))
        lastPullAt = 0
        if fresh {
            // a brand-new profile: what this device holds IS the profile's data
            for k in Cloud.syncKeys where hasContent(k) {
                guard current(session) else { return }
                await pushKey(k, session: session)
            }
        } else {
            // merge; newer local records push back on their own
            await pullAll(force: true)
        }
    }

    /// Forget the credential on this device only; nothing local is deleted.
    public func forget() {
        switchSession()
        store.set("cloud_link", nil)
        store.setObject("cloud_revs", [:])
        store.setObject("cloud_dirty", [:])
        setProfile(nil)
    }

    private func credentialDead() {
        guard linked else { return }
        forget()
        onSignedOut?()
    }

    // MARK: push

    /// Mark a key changed and schedule a debounced push. Safe to call constantly.
    public func noteChanged(_ key: String) {
        guard linked, !applying else { return }
        changes[key, default: 0] += 1
        var d = store.object("cloud_dirty"); d[key] = 1
        store.setObject("cloud_dirty", d)
        pushTasks[key]?.cancel()
        let wait: UInt64 = key == "progress" ? 20_000_000_000 : 2_000_000_000   // progress churns every few seconds
        let session = generation
        pushTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            guard let self = self, await self.current(session) else { return }
            await self.pushKey(key, session: session)
        }
    }

    /// Push every dirty doc now and wait — the app is closing, or about to let go of its credential.
    public func flush() async {
        guard linked else { return }
        let session = generation
        for k in store.object("cloud_dirty").keys {
            guard current(session) else { return }
            pushTasks[k]?.cancel()
            await pushKey(k, session: session)
        }
    }

    private func pushKey(_ key: String, session: UInt64) async {
        guard current(session), linked else { return }
        let previous = writes[key]?.task, id = UUID()
        let task = Task<Void, Never> { [weak self] in
            if let previous = previous { await previous.value }
            await self?.pushDocument(key, session: session)
        }
        writes[key] = (id, task)
        await task.value
        guard current(session) else { return }
        if writes[key]?.id == id { writes[key] = nil }
    }

    private func pushDocument(_ key: String, session: UInt64) async {
        guard current(session), linked,
              let keys = (try? await api("GET", "/v1/kv"))?.obj("keys"), current(session) else { return }
        if let meta = keys.obj(key), store.object("cloud_revs").optInt(key) != meta.int("rev") {
            guard let rec = try? await api("GET", "/v1/kv/\(key)"), current(session),
                  let remote = JSON.object(rec.str("v")) else { return }
            applying = true
            let (changed, _) = merge(key, remote)
            applying = false
            var revs = store.object("cloud_revs"); revs[key] = rec.int("rev")
            store.setObject("cloud_revs", revs)
            if changed { onApplied?([key]) }
        }
        let seen = changes[key, default: 0]
        guard current(session), let v = docFor(key) else { return }
        // Fetch/merge narrows the race; only a server-side conditional PUT can make it atomic.
        guard let r = try? await api("PUT", "/v1/kv/\(key)", ["v": v]), current(session) else { return }
        var revs = store.object("cloud_revs"); revs[key] = r.int("rev")
        store.setObject("cloud_revs", revs)
        // the actor let other calls in during the PUT: a change made then is still unsent
        guard changes[key, default: 0] == seen else { return }
        var d = store.object("cloud_dirty"); d[key] = nil
        store.setObject("cloud_dirty", d)
    }

    private func hasContent(_ key: String) -> Bool {
        switch key {
        case "addons": return !addons.all().isEmpty || !(addons.syncDoc().obj("removed") ?? [:]).isEmpty
        case "progress": return !progress.all().isEmpty
        case "library": return !library.doc().isEmpty
        case "sub_style": return store.object("sub_style").int64("at") > 0
        case "seekr": return store.object("seekr_v1").int64("at") > 0
        default: return false
        }
    }

    // MARK: pull + merge

    public func pullAll(force: Bool = false) async {
        guard linked else { return }
        let session = generation
        let now = nowMs()
        if !force && now - lastPullAt < 45_000 { return }
        lastPullAt = now
        var applied = Set<String>()
        guard let keys = (try? await api("GET", "/v1/kv"))?.obj("keys"), current(session) else { return }
        for key in Cloud.syncKeys {
            guard current(session) else { return }
            guard let meta = keys.obj(key) else {
                if hasContent(key) { await pushKey(key, session: session) }
                continue
            }
            if store.object("cloud_revs").optInt(key) == meta.int("rev") {
                if store.object("cloud_dirty")[key] != nil { await pushKey(key, session: session) }
                continue
            }
            guard let rec = try? await api("GET", "/v1/kv/\(key)"), current(session),
                  let remote = JSON.object(rec.str("v")) else { continue }
            applying = true
            let (changed, localNewer) = merge(key, remote)
            applying = false
            var revs = store.object("cloud_revs"); revs[key] = rec.int("rev")
            store.setObject("cloud_revs", revs)
            if changed { applied.insert(key) }
            if localNewer { await pushKey(key, session: session) }
        }
        if current(session), !applied.isEmpty { onApplied?(applied) }
    }

    func merge(_ key: String, _ remote: JSONObject) -> (changed: Bool, localNewer: Bool) {
        switch key {
        case "addons": return mergeAddons(remote)
        case "progress": return mergeProgress(remote)
        case "library": return mergeLibrary(remote)
        case "sub_style": return mergeSubStyle(remote)
        case "seekr": return mergeSeekr(remote)
        default: return (false, false)
        }
    }

    // MARK: wire docs

    func docFor(_ key: String) -> String? {
        switch key {
        case "addons":
            return addons.locked { () -> String in
                var s = addons.syncDoc()
                var at = s.obj("at") ?? [:]
                var stamped = false
                var list: JSONObject = [:]
                let all = addons.all()
                for a in all {
                    // an add-on with no stamp can never be adopted by a newest-wins merge — stamp it now
                    if at.int64(a.manifestUrl) == 0 { at[a.manifestUrl] = nowMs(); stamped = true }
                    list[a.manifestUrl] = ["name": a.name, "base": a.base, "logo": a.logo ?? "", "at": at.int64(a.manifestUrl)] as JSONObject
                }
                if stamped { s["at"] = at; store.setObject("addons_sync", s) }
                // the list is keyed by address and carries no order of its own — rank travels beside it
                return JSON.text(["list": list, "removed": s.obj("removed") ?? [:], "order": all.map(\.manifestUrl), "orderAt": s.int64("orderAt")] as JSONObject)
            }
        case "progress": return JSON.text(progress.wireDoc())
        case "library": return JSON.text(library.doc())
        case "sub_style":
            let l = store.object("sub_style")
            return JSON.text(["style": SubStyle.normalize(l.obj("style")), "at": l.int64("at")] as JSONObject)
        case "seekr":
            let l = store.object("seekr_v1")
            return JSON.text(["key": l.str("key"), "at": l.int64("at")] as JSONObject)
        default: return nil
        }
    }

    private func mergeAddons(_ remote: JSONObject) -> (Bool, Bool) {
        addons.locked { mergeAddonsLocked(remote) }
    }

    private func mergeAddonsLocked(_ remote: JSONObject) -> (Bool, Bool) {
        var s = addons.syncDoc()
        var at = s.obj("at") ?? [:], removed = s.obj("removed") ?? [:]
        var arr = addons.all()
        var changed = false, localNewer = false
        let rl = remote.obj("list") ?? [:], rr = remote.obj("removed") ?? [:]
        let have = Set(arr.map(\.manifestUrl))
        // Keep removals even for an add-on this device has never installed.
        for u in rr.keys {
            if removed[u] == nil || rr.int64(u) > removed.int64(u) { removed[u] = rr.int64(u) }
        }
        for (u, v) in rl {
            guard let r = v as? JSONObject else { continue }
            let rAt = r.int64("at")
            if have.contains(u) {
                if rAt > at.int64(u) { at[u] = rAt }
                continue
            }
            // adopt unless WE removed it more recently than they added it
            if removed[u] == nil || rAt > removed.int64(u) {
                arr.append(Addon(manifestUrl: u, name: r.text("name") ?? "Add-on", base: r.text("base") ?? Stremio.baseOf(u), logo: r.text("logo")))
                at[u] = rAt > 0 ? rAt : nowMs()
                removed[u] = nil
                changed = true
            }
        }
        for u in removed.keys {
            if let idx = arr.firstIndex(where: { $0.manifestUrl == u }) {
                if removed.int64(u) > at.int64(u) {
                    arr.remove(at: idx); at[u] = nil
                    changed = true
                } else { removed[u] = nil }
            }
        }
        // compare after clearing superseded removals, so the settled document needs no push
        for a in arr {
            let u = a.manifestUrl
            if rl.obj(u) == nil || at.int64(u) > (rl.obj(u)?.int64("at") ?? 0) { localNewer = true }
        }
        for u in removed.keys {
            if rr[u] == nil || removed.int64(u) > rr.int64(u) || rl[u] != nil { localNewer = true }
        }
        for u in rr.keys where removed[u] == nil { localNewer = true }
        // Ranking, newest wins. Add-ons the sender did not know about keep their place at the end.
        let ro = remote.strs("order") ?? [], roAt = remote.int64("orderAt")
        if roAt > s.int64("orderAt") && !ro.isEmpty {
            var rank: [String: Int] = [:]
            for (i, u) in ro.enumerated() { rank[u] = i }
            let next = arr.filter { rank[$0.manifestUrl] != nil }.sorted { rank[$0.manifestUrl]! < rank[$1.manifestUrl]! }
                + arr.filter { rank[$0.manifestUrl] == nil }
            s["orderAt"] = roAt
            if next != arr { arr = next; changed = true }
        } else if s.int64("orderAt") > roAt { localNewer = true }
        s["at"] = at; s["removed"] = removed
        store.setObject("addons_sync", s)
        if changed { addons.saveRaw(arr) }
        return (changed, localNewer)
    }

    /// Merged inside the store's own write step, so a resume point the player writes while
    /// the merge runs is not overwritten by the merge's older copy.
    private func mergeProgress(_ remote: JSONObject) -> (Bool, Bool) {
        var changed = false, localNewer = false
        progress.mutate(notify: false) { local in
            for (k, v) in remote {
                guard let r = v as? JSONObject, let rec = ProgressRec(wire: r) else { continue }
                if let l = local[k], l.at >= rec.at { continue }
                local[k] = rec
                changed = true
            }
            for (k, l) in local {
                let rAt = (remote[k] as? JSONObject)?.int64("at")
                if rAt == nil || l.at > rAt! { localNewer = true }
            }
            return changed
        }
        return (changed, localNewer)
    }

    /// Newest wins, whole document. A malformed one is written over by ours, if we have one.
    private func mergeSubStyle(_ remote: JSONObject) -> (Bool, Bool) {
        let lAt = store.object("sub_style").int64("at"), rAt = remote.int64("at")
        guard let style = remote.obj("style") else { return (false, lAt > 0) }
        if rAt > lAt {
            store.setObject("sub_style", ["style": SubStyle.normalize(style), "at": rAt])
            return (true, false)
        }
        return (false, lAt > rAt)
    }

    private func mergeSeekr(_ remote: JSONObject) -> (Bool, Bool) {
        let lAt = store.object("seekr_v1").int64("at")
        guard let r = Seekr.read(remote) else { return (false, lAt > 0) }
        if r.at > lAt {
            store.setObject("seekr_v1", ["key": r.key, "at": r.at])
            return (true, false)
        }
        return (false, lAt > r.at)
    }

    private func mergeLibrary(_ remote: JSONObject) -> (Bool, Bool) {
        var changed = false, localNewer = false
        library.mutate(notify: false) { local in
            for (k, v) in remote {
                guard let r = v as? JSONObject else { continue }
                if let l = local.obj(k), l.int64("at") >= r.int64("at") { continue }
                local[k] = r
                changed = true
            }
            for (k, v) in local {
                guard let l = v as? JSONObject else { continue }
                let rAt = (remote[k] as? JSONObject)?.int64("at")
                if rAt == nil || l.int64("at") > rAt! { localNewer = true }
            }
            return changed
        }
        return (changed, localNewer)
    }

    // MARK: profile actions — each returns nil on success or a sentence the screen can show

    public static func cleanHandle(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("@") { h.removeFirst() }
        return h
    }

    public static func handleOk(_ h: String) -> Bool {
        (3...20).contains(h.count) && h.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }
    }

    public static func errorText(_ e: Error) -> String {
        guard let f = e as? HTTPFailure else { return "Could not reach the server." }
        if f.code == 429 { return "Too many tries — give it a minute." }
        switch f.error {
        case "handle taken": return "That handle is taken."
        case "bad handle": return "Handles are 3–20 letters, numbers or underscores."
        case "bad password": return "Passwords are at least 8 characters."
        case "wrong handle or password": return "Wrong handle or password."
        case "wrong handle or key": return "That handle and recovery key don’t match."
        case "wrong password": return "Wrong password."
        case "code not found or expired": return "That code was not found — it may have expired."
        case "unauthorized": return "This device was signed out. Sign in again."
        default: return "Something went wrong (\(f.code))."
        }
    }

    public func signIn(handle raw: String, password: String) async -> String? {
        let handle = Cloud.cleanHandle(raw)
        if !Cloud.handleOk(handle) { return handle.isEmpty ? "Enter your @handle." : "Handles are 3–20 letters, numbers or underscores." }
        if password.isEmpty { return "Enter your password." }
        let session = generation
        do {
            let r = try await api("POST", "/v1/profile/signin", ["handle": handle, "password": password, "device": deviceInfo], auth: false)
            guard current(session) else { throw CancellationError() }
            await adopt(r, fresh: false)
            guard current(session &+ 1), linked else { throw CancellationError() }
            return nil
        } catch { return Cloud.errorText(error) }
    }

    /// Returns (recovery key, nil) or (nil, error).
    public func createProfile(handle raw: String, name: String, password: String) async -> (String?, String?) {
        let handle = Cloud.cleanHandle(raw)
        if !Cloud.handleOk(handle) { return (nil, "Handles are 3–20 letters, numbers or underscores.") }
        if password.count < 8 { return (nil, "Passwords are at least 8 characters.") }
        let session = generation
        do {
            let r = try await api("POST", "/v1/profile", ["handle": handle, "name": name.trimmingCharacters(in: .whitespaces), "password": password, "device": deviceInfo], auth: false)
            guard current(session) else { throw CancellationError() }
            await adopt(r, fresh: true)
            guard current(session &+ 1), linked else { throw CancellationError() }
            return (r.text("recovery"), nil)
        } catch { return (nil, Cloud.errorText(error)) }
    }

    /// Sign out here only; the server forgets this device's token, nothing local is deleted.
    public func signOut() async {
        let session = generation
        await flush()
        guard current(session) else { return }
        _ = try? await api("POST", "/v1/profile/signout", [:])
        guard current(session) else { return }
        forget()
    }

    /// The profile and its devices; nil when the call failed.
    public func refreshProfile() async -> [DeviceRec]? {
        let session = generation
        guard linked, let r = try? await api("GET", "/v1/profile/me"), current(session) else { return nil }
        setProfile(r.bool("on") ? r : nil)
        return r.objs("devices").map {
            DeviceRec(id: $0.str("id"), name: $0.text("name") ?? "Device", plat: $0.str("plat"), at: $0.int64("at"), seen: $0.int64("seen"), me: $0.bool("me"))
        }
    }

    public func removeDevice(_ id: String) async -> String? {
        let session = generation
        do {
            _ = try await api("DELETE", "/v1/profile/device/\(id)")
            guard current(session) else { throw CancellationError() }
            return nil
        } catch { return Cloud.errorText(error) }
    }

    /// Approve the code a TV is showing. Returns (device name, nil) or (nil, error).
    public func approveTv(code raw: String) async -> (String?, String?) {
        let code = raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if code.count != 6 { return (nil, "Enter the 6-character code from the TV.") }
        let session = generation
        do {
            let r = try await api("POST", "/v1/tv/approve", ["code": code])
            guard current(session) else { throw CancellationError() }
            return (r.obj("device")?.text("name") ?? "The TV", nil)
        } catch { return (nil, Cloud.errorText(error)) }
    }

    // MARK: Support Nebula

    /// The last known answer of `GET /v1/support`, so the section does not flicker in.
    public nonisolated func storedSupport() -> SupportInfo { SupportInfo.parse(store.object("support_v1")) }

    /// One `GET /v1/support` (no sign-in needed); nil when it could not be asked.
    public func loadSupport() async -> SupportInfo? {
        guard let r = try? await api("GET", "/v1/support", auth: false) else { return nil }
        let info = SupportInfo.parse(r)
        store.setObject("support_v1", info.doc)
        return info
    }

    /// The support page's address, with a 15-minute link token when signed in — what is bought
    /// then lands on this profile without a code. The plain address if the token call fails.
    public func supportLink(_ url: String) async -> String {
        guard linked, let t = (try? await api("POST", "/v1/support/link", [:]))?.text("token") else { return url }
        return url + (url.contains("?") ? "&" : "?") + "for=" + t
    }

    /// "neb-ab12 cd34" → "AB12CD34"; anything that is not 8 such characters → "".
    public static func supportCode(_ raw: String) -> String {
        var s = raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if s.count == 11 && s.hasPrefix("NEB") { s = String(s.dropFirst(3)) }
        return s.count == 8 ? s : ""
    }

    /// Redeem a supporter code on this profile. nil on success, else a sentence.
    public func redeem(_ raw: String) async -> String? {
        guard linked else { return "Sign in first — the supporter mark lives on your profile." }
        let code = Cloud.supportCode(raw)
        if code.isEmpty { return "A code looks like NEB-XXXX-XXXX." }
        do {
            _ = try await api("POST", "/v1/support/redeem", ["code": code])
            _ = await refreshProfile()
            return nil
        } catch {
            if let f = error as? HTTPFailure, f.code == 404 || f.error.contains("code") { return "That code was not found, or it was already used." }
            return Cloud.errorText(error)
        }
    }

    /// Show or hide the name on the wall, or choose the mark (Supporter Plus and up).
    public func setSupport(wall: Bool? = nil, mark: String? = nil) async -> String? {
        var body: JSONObject = [:]
        if let w = wall { body["wall"] = w }
        if let m = mark, Profile.marks.contains(m) { body["mark"] = m }
        do {
            _ = try await api("PUT", "/v1/support", body)
            _ = await refreshProfile()
            return nil
        } catch { return Cloud.errorText(error) }
    }
}
