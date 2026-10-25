import Foundation

/// Small documents on disk, one file per key, written atomically. Everything the app remembers
/// goes through here: add-ons, watch progress, My List, preferences, the sync credential.
public final class Store: @unchecked Sendable {
    private let dir: URL
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    public init(directory: URL) {
        dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(iOS)
        for k in Store.privateKeys { excludeFromBackup(k) }
        #endif
    }

    /// Files that never leave the device, not even in its backups: the sign-in, and the watch log behind the
    /// supporters' monthly recap (WatchLog.swift says why).
    public static let privateKeys: Set<String> = ["cloud_link", "watchlog_v1"]

    /// `~/Library/Application Support/Nebula` on a Mac.
    public static func standard() -> Store {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return Store(directory: base.appendingPathComponent("Nebula", isDirectory: true))
    }

    private func file(_ key: String) -> URL { dir.appendingPathComponent(key + ".json") }

    public func string(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        guard let d = try? Data(contentsOf: file(key)), let s = String(data: d, encoding: .utf8) else { return nil }
        cache[key] = s
        return s
    }

    public func set(_ key: String, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        if let v = value {
            cache[key] = v
            try? Data(v.utf8).write(to: file(key), options: [.atomic])
            // the credential lives here too — keep the files to this user
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(key).path)
            #if os(iOS)
            if Store.privateKeys.contains(key) { excludeFromBackup(key) }
            #endif
        } else {
            cache[key] = nil
            try? FileManager.default.removeItem(at: file(key))
        }
    }

    #if os(iOS)
    /// Also migrate an existing file on open, without waiting for another write to rewrite it.
    private func excludeFromBackup(_ key: String) {
        var u = file(key)
        guard FileManager.default.fileExists(atPath: u.path) else { return }
        do {
            var rv = URLResourceValues(); rv.isExcludedFromBackup = true
            try u.setResourceValues(rv)
        } catch {
            // drop a file we cannot protect, but never keep the app from opening
            cache[key] = nil
            try? FileManager.default.removeItem(at: u)
        }
    }
    #endif

    public func object(_ key: String) -> JSONObject { string(key).flatMap(JSON.object) ?? [:] }
    public func setObject(_ key: String, _ o: JSONObject) { set(key, JSON.text(o)) }
}
