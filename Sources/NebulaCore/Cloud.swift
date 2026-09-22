import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct Profile: Equatable, Sendable {
    public var handle: String
    public var name: String
    public var avatar: String
    public var supporter: Bool
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
    static let syncKeys = ["addons", "progress", "library"]

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

    static func parseProfile(_ o: JSONObject?) -> Profile? {
        guard let o = o, let h = o.text("handle") else { return nil }
        return Profile(handle: h, name: o.text("name") ?? h, avatar: o.text("avatar") ?? "#636366",
                       supporter: o.bool("sup") || o.obj("supporter") != nil)
    }

    private func setProfile(_ o: JSONObject?) {
        let p = Cloud.parseProfile(o)
        if let p = p {
            store.setObject("profile", ["handle": p.handle, "name": p.name, "avatar": p.avatar, "sup": p.supporter])
        } else {
            store.set("profile", nil)
        }
        onProfile?(p)
    }

    var deviceInfo: JSONObject { ["name": String(deviceName.prefix(24)), "plat": platform] }

    // MARK: HTTP

    public func api(_ method: String, _ path: String, _ body: JSONObject? = nil, auth: Bool = true) async throws -> JSONObject {
        guard let url = URL(string: base + path) else { throw HTTPFailure(code: 0, error: "bad address") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        let signed = auth && linked
        if signed { r.setValue("Bearer \(cred.str("gid")).\(cred.str("token"))", forHTTPHeaderField: "Authorization") }
        if method != "GET" { r.httpBody = JSON.data(body ?? [:]) }
        let (data, code) = try await transport.send(r)
        let j = JSON.object(data) ?? [:]
        guard (200...299).contains(code) else {
            // a dead credential: the device was signed out from elsewhere, or the profile is gone
            if code == 401 && signed { credentialDead() }
            throw HTTPFailure(code: code, error: j.str("error"))
        }
        return j
    }

    /// Take a credential set {gid, token, profile} as this device's identity.
    func adopt(_ r: JSONObject, fresh: Bool) async {
        store.setObject("cloud_link", ["gid": r.str("gid"), "token": r.str("token")])
        store.setObject("cloud_revs", [:])
        store.setObject("cloud_dirty", [:])
        setProfile(r.obj("profile"))
        lastPullAt = 0
        if fresh {
            // a brand-new profile: what this device holds IS the profile's data
            for k in Cloud.syncKeys where hasContent(k) { await pushKey(k) }
        } else {
            // merge; newer local records push back on their own
            await pullAll(force: true)
        }
    }

    /// Forget the credential on this device only; nothing local is deleted.
    public func forget() {
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
        pushTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            if Task.isCancelled { return }
            await self?.pushKey(key)
        }
    }

    /// Push every dirty doc now and wait — the app is closing, or about to let go of its credential.
    public func flush() async {
        guard linked else { return }
        for k in store.object("cloud_dirty").keys {
            pushTasks[k]?.cancel()
            await pushKey(k)
        }
    }

    private func pushKey(_ key: String) async {
        let seen = changes[key, default: 0]
        guard linked, let v = docFor(key) else { return }
        guard let r = try? await api("PUT", "/v1/kv/\(key)", ["v": v]) else { return }
        var revs = store.object("cloud_revs"); revs[key] = r.int("rev")
        store.setObject("cloud_revs", revs)
        // the actor let other calls in during the PUT: a change made then is still unsent
        guard changes[key, default: 0] == seen else { return }
        var d = store.object("cloud_dirty"); d[key] = nil
        store.setObject("cloud_dirty", d)
    }

    private func hasContent(_ key: String) -> Bool {
        switch key {
        case "addons": return !addons.all().isEmpty
        case "progress": return !progress.all().isEmpty
        case "library": return !library.doc().isEmpty
        default: return false
        }
    }

    // MARK: pull + merge

    public func pullAll(force: Bool = false) async {
        guard linked else { return }
        let now = nowMs()
        if !force && now - lastPullAt < 45_000 { return }
        lastPullAt = now
        var applied = Set<String>()
        guard let keys = (try? await api("GET", "/v1/kv"))?.obj("keys") else { return }
        for key in Cloud.syncKeys {
            guard let meta = keys.obj(key) else {
                if hasContent(key) { await pushKey(key) }
                continue
            }
            if store.object("cloud_revs").optInt(key) == meta.int("rev") {
                if store.object("cloud_dirty")[key] != nil { await pushKey(key) }
                continue
            }
            guard let rec = try? await api("GET", "/v1/kv/\(key)"), let remote = JSON.object(rec.str("v")) else { continue }
            applying = true
            let (changed, localNewer) = merge(key, remote)
            applying = false
            var revs = store.object("cloud_revs"); revs[key] = rec.int("rev")
            store.setObject("cloud_revs", revs)
            if changed { applied.insert(key) }
            if localNewer { await pushKey(key) }
        }
        if !applied.isEmpty { onApplied?(applied) }
    }

    func merge(_ key: String, _ remote: JSONObject) -> (changed: Bool, localNewer: Bool) {
        switch key {
        case "addons": return mergeAddons(remote)
        case "progress": return mergeProgress(remote)
        case "library": return mergeLibrary(remote)
        default: return (false, false)
        }
    }

    // MARK: wire docs

    func docFor(_ key: String) -> String? {
        switch key {
        case "addons":
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
        case "progress": return JSON.text(progress.wireDoc())
        case "library": return JSON.text(library.doc())
        default: return nil
        }
    }

    private func mergeAddons(_ remote: JSONObject) -> (Bool, Bool) {
        var s = addons.syncDoc()
        var at = s.obj("at") ?? [:], removed = s.obj("removed") ?? [:]
        var arr = addons.all()
        var changed = false, localNewer = false
        let rl = remote.obj("list") ?? [:], rr = remote.obj("removed") ?? [:]
        let have = Set(arr.map(\.manifestUrl))
        for (u, v) in rl {
            guard let r = v as? JSONObject else { continue }
            let rAt = r.int64("at")
            if have.contains(u) {
                if at.int64(u) > rAt { localNewer = true } else if rAt > at.int64(u) { at[u] = rAt }
                continue
            }
            // adopt unless WE removed it more recently than they added it
            if removed[u] == nil || rAt > removed.int64(u) {
                arr.append(Addon(manifestUrl: u, name: r.text("name") ?? "Add-on", base: r.text("base") ?? Stremio.baseOf(u), logo: r.text("logo")))
                at[u] = rAt > 0 ? rAt : nowMs()
                removed[u] = nil
                changed = true
            } else { localNewer = true }
        }
        for u in rr.keys {
            if let idx = arr.firstIndex(where: { $0.manifestUrl == u }) {
                if rr.int64(u) > at.int64(u) {
                    arr.remove(at: idx); removed[u] = rr.int64(u); at[u] = nil
                    changed = true
                } else { localNewer = true }
            } else if removed.int64(u) > rr.int64(u) { localNewer = true }
        }
        for a in arr where rl[a.manifestUrl] == nil { localNewer = true }
        for u in removed.keys where rr[u] == nil { localNewer = true }
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

    private func mergeProgress(_ remote: JSONObject) -> (Bool, Bool) {
        var local = progress.all()
        var changed = false, localNewer = false
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
        if changed { progress.replaceAll(local) }
        return (changed, localNewer)
    }

    private func mergeLibrary(_ remote: JSONObject) -> (Bool, Bool) {
        var local = library.doc()
        var changed = false, localNewer = false
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
        if changed { library.replaceAll(local) }
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
        do {
            let r = try await api("POST", "/v1/profile/signin", ["handle": handle, "password": password, "device": deviceInfo], auth: false)
            await adopt(r, fresh: false)
            return nil
        } catch { return Cloud.errorText(error) }
    }

    /// Returns (recovery key, nil) or (nil, error).
    public func createProfile(handle raw: String, name: String, password: String) async -> (String?, String?) {
        let handle = Cloud.cleanHandle(raw)
        if !Cloud.handleOk(handle) { return (nil, "Handles are 3–20 letters, numbers or underscores.") }
        if password.count < 8 { return (nil, "Passwords are at least 8 characters.") }
        do {
            let r = try await api("POST", "/v1/profile", ["handle": handle, "name": name.trimmingCharacters(in: .whitespaces), "password": password, "device": deviceInfo], auth: false)
            await adopt(r, fresh: true)
            return (r.text("recovery"), nil)
        } catch { return (nil, Cloud.errorText(error)) }
    }

    /// Sign out here only; the server forgets this device's token, nothing local is deleted.
    public func signOut() async {
        await flush()
        _ = try? await api("POST", "/v1/profile/signout", [:])
        forget()
    }

    /// The profile and its devices; nil when the call failed.
    public func refreshProfile() async -> [DeviceRec]? {
        guard linked, let r = try? await api("GET", "/v1/profile/me") else { return nil }
        setProfile(r.bool("on") ? r : nil)
        return r.objs("devices").map {
            DeviceRec(id: $0.str("id"), name: $0.text("name") ?? "Device", plat: $0.str("plat"), at: $0.int64("at"), seen: $0.int64("seen"), me: $0.bool("me"))
        }
    }

    public func removeDevice(_ id: String) async -> String? {
        do { _ = try await api("DELETE", "/v1/profile/device/\(id)"); return nil } catch { return Cloud.errorText(error) }
    }

    /// Approve the code a TV is showing. Returns (device name, nil) or (nil, error).
    public func approveTv(code raw: String) async -> (String?, String?) {
        let code = raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if code.count != 6 { return (nil, "Enter the 6-character code from the TV.") }
        do {
            let r = try await api("POST", "/v1/tv/approve", ["code": code])
            return (r.obj("device")?.text("name") ?? "The TV", nil)
        } catch { return (nil, Cloud.errorText(error)) }
    }
}
