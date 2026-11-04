import Foundation
import SwiftUI
import NebulaCore

/// One saved or saving title, as the pages read it.
struct SavedRow: Codable, Identifiable, Equatable {
    var key: String
    var viewer: String
    var type: String
    var id: String
    /// "Show · S1E2 · Name" for an episode, the title for a film (DownloadPlan.nameParts reads it back).
    var name: String
    var poster: String?
    var addonUrl: String
    var source: String
    var fileName: String
    var streamName: String
    var streamTitle: String
    var url: String
    var headers: [String: String]
    /// The saved file's name inside the Downloads folder.
    var file: String
    var phase: DownloadPlan.Phase
    var bytes: Int64
    var total: Int64
    var error: String
    var at: Double
    var subs: [SavedSub] = []
}
struct SavedSub: Codable, Equatable { var file: String; var lang: String }

/// Downloads on the iPhone and the Mac (11-04, his "add the downloads option in ios and desktop versions"): a film or an
/// episode kept inside the app to watch with no connection — the Android app's rules (DownloadPlan.swift). A file is
/// fetched by URLSession; on the iPhone a background session keeps it going with the app closed, and a pause or a break
/// resumes where it stopped (resume data). Two at a time. The folder is the app's own and out of backups.
@MainActor
final class Downloads: ObservableObject {
    static let shared = Downloads()
    static let sessionId = "app.nebula.downloads"

    @Published private(set) var rows: [SavedRow] = []
    /// "Season 2 · 4 of 10" while a season's other episodes are being looked up.
    @Published var seasonBusy: String?
    let dir: URL
    private var session: URLSession!
    private let relay = DownloadRelay()
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var pausing: Set<String> = []
    private var lastTold: [String: Date] = [:]
    /// The iPhone's background session finished its events while the app was away (App.swift hands this over).
    var backgroundDone: (() -> Void)?
    private static let parallel = 2

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var d = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true; try? d.setResourceValues(rv)
        dir = d
        if let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
           let list = try? JSONDecoder().decode([SavedRow].self, from: data) { rows = list }
        relay.owner = self
        #if os(iOS)
        let cfg = URLSessionConfiguration.background(withIdentifier: Downloads.sessionId)
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        #else
        let cfg = URLSessionConfiguration.default
        #endif
        cfg.timeoutIntervalForRequest = 60
        session = URLSession(configuration: cfg, delegate: relay, delegateQueue: nil)
        // the tasks a background session kept while the app was gone come back by their description (the row's key)
        session.getAllTasks { all in
            let pairs = all.compactMap { t -> (String, URLSessionDownloadTask)? in
                guard let d = t as? URLSessionDownloadTask, let k = t.taskDescription else { return nil }
                return (k, d)
            }
            Task { @MainActor in
                for (k, t) in pairs { self.tasks[k] = t }
                for i in self.rows.indices where self.rows[i].phase == .running && self.tasks[self.rows[i].key] == nil { self.rows[i].phase = .queued }
                self.save(); self.pump()
            }
        }
    }

    // MARK: reading

    func mine(_ viewer: String) -> [SavedRow] { rows.filter { $0.viewer == viewer } }
    func find(_ viewer: String, _ type: String, _ id: String) -> SavedRow? { rows.first { $0.viewer == viewer && $0.type == type && $0.id == id } }
    func saved(_ viewer: String, _ type: String, _ id: String) -> SavedRow? { find(viewer, type, id).flatMap { $0.phase == .done ? $0 : nil } }
    func fileURL(_ r: SavedRow) -> URL { dir.appendingPathComponent(r.file) }
    func subURL(_ r: SavedRow, _ s: SavedSub) -> URL { dir.appendingPathComponent(r.key + "-subs", isDirectory: true).appendingPathComponent(s.file) }
    func line(_ r: SavedRow) -> String { DownloadPlan.line(r.phase, bytes: r.bytes, total: r.total, error: r.error) }

    // MARK: adding

    /// Start keeping [st] as [name]. nil when it is on its way (or already is), else the sentence why not.
    func add(_ st: StreamItem, viewer: String, type: String, id: String, name: String, poster: String?, addon: Addon?, subLangs: [String]) async -> String? {
        guard DownloadPlan.savable(st.url), let url = URL(string: st.url) else { return DownloadPlan.noKind }
        if !st.clearKeys.isEmpty { return DownloadPlan.noProtected }
        if let old = find(viewer, type, id) {
            if old.phase != .failed { return nil }
            remove(old.key)
        }
        // the first bytes decide what it is (an address alone cannot tell: many carry no extension)
        var req = URLRequest(url: url, timeoutInterval: 30)
        st.headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        req.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        let verdict: DownloadPlan.Source
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            var head = Data()
            for try await b in bytes { head.append(b); if head.count >= 1024 { break } }
            let h = resp as? HTTPURLResponse
            let total = DownloadPlan.total(code: h?.statusCode ?? 0, contentRange: h?.value(forHTTPHeaderField: "Content-Range"),
                                           contentLength: h?.value(forHTTPHeaderField: "Content-Length"))
            verdict = DownloadPlan.sniff(code: h?.statusCode ?? 0, contentType: h?.value(forHTTPHeaderField: "Content-Type"),
                                         head: String(decoding: head, as: UTF8.self), total: total)
        } catch { return DownloadPlan.noReach }
        let size: Int64
        switch verdict {
        case .refused(let why): return why
        case .playlist: return DownloadPlan.noPlaylist
        case .file(let n): size = n
        }
        let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage).flatMap { $0 } ?? Int64.max
        guard DownloadPlan.hasRoom(size: size, free: free) else { return DownloadPlan.noRoom }
        let key = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
        let row = SavedRow(key: String(key), viewer: viewer, type: type, id: id, name: name, poster: poster, addonUrl: addon?.manifestUrl ?? "",
                           source: addon?.name ?? "", fileName: st.fileName, streamName: st.name, streamTitle: st.title, url: st.url,
                           headers: st.headers, file: String(key) + Downloads.ext(st), phase: .queued, bytes: 0, total: size, error: "",
                           at: Date().timeIntervalSince1970)
        rows.insert(row, at: 0)
        save(); pump()
        keepSubs(st, key: String(key), langs: subLangs)
        return nil
    }

    static func ext(_ st: StreamItem) -> String {
        for s in [st.fileName, URL(string: st.url)?.path ?? ""] {
            let e = (s as NSString).pathExtension.lowercased()
            if ["mkv", "mp4", "m4v", "webm", "mov", "avi", "ts"].contains(e) { return "." + e }
        }
        return ".mkv"
    }

    /// The stream's own subtitles in the wanted languages (two at most), kept beside the download.
    private func keepSubs(_ st: StreamItem, key: String, langs: [String]) {
        var picks: [SubTrack] = []
        for l in langs where !l.isEmpty && picks.count < 2 {
            if let s = st.subtitles.first(where: { $0.lang.lowercased().hasPrefix(l.lowercased().prefix(2)) }), !picks.contains(where: { $0.url == s.url }) { picks.append(s) }
        }
        guard !picks.isEmpty else { return }
        let folder = dir.appendingPathComponent(key + "-subs", isDirectory: true)
        Task {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (i, p) in picks.enumerated() {
                guard let u = URL(string: p.url), let (data, _) = try? await URLSession.shared.data(from: u), !data.isEmpty else { continue }
                let vtt = String(decoding: data.prefix(16), as: UTF8.self).contains("WEBVTT")
                let name = "sub-\(i)." + (vtt ? "vtt" : "srt")
                try? data.write(to: folder.appendingPathComponent(name))
                if let j = rows.firstIndex(where: { $0.key == key }) { rows[j].subs.append(SavedSub(file: name, lang: p.lang)); save() }
            }
        }
    }

    // MARK: running

    private func pump() {
        var running = rows.filter { $0.phase == .running }.count
        for i in rows.indices where rows[i].phase == .queued && running < Downloads.parallel {
            start(i); running += 1
        }
        save()
    }

    private func start(_ i: Int) {
        let r = rows[i]
        let resume = dir.appendingPathComponent(r.key + ".resume")
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resume) {
            task = session.downloadTask(withResumeData: data)
            try? FileManager.default.removeItem(at: resume)
        } else {
            guard let u = URL(string: r.url) else { rows[i].phase = .failed; rows[i].error = "bad address"; return }
            var req = URLRequest(url: u)
            r.headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
            task = session.downloadTask(with: req)
        }
        task.taskDescription = r.key
        tasks[r.key] = task
        rows[i].phase = .running; rows[i].error = ""
        task.resume()
    }

    func pause(_ key: String) {
        guard let i = rows.firstIndex(where: { $0.key == key }) else { return }
        if let t = tasks[key] {
            pausing.insert(key)
            let resume = dir.appendingPathComponent(key + ".resume")
            t.cancel(byProducingResumeData: { data in if let d = data { try? d.write(to: resume) } })
        }
        rows[i].phase = .paused
        save(); pump()
    }

    func resume(_ key: String) {
        guard let i = rows.firstIndex(where: { $0.key == key }), rows[i].phase == .paused || rows[i].phase == .failed else { return }
        rows[i].phase = .queued; rows[i].error = ""
        pump()
    }

    func remove(_ key: String) {
        guard let r = rows.first(where: { $0.key == key }) else { return }
        pausing.insert(key)
        tasks[key]?.cancel(); tasks[key] = nil
        let fm = FileManager.default
        for f in [r.file, key + ".resume", key + ".part"] { try? fm.removeItem(at: dir.appendingPathComponent(f)) }
        try? fm.removeItem(at: dir.appendingPathComponent(key + "-subs", isDirectory: true))
        rows.removeAll { $0.key == key }
        save(); pump()
    }

    // MARK: what the session says (DownloadRelay hops here)

    func progress(_ key: String, written: Int64, expected: Int64) {
        // a published change each second, not each packet (rows is @Published: every write redraws the pages)
        if let t = lastTold[key], Date().timeIntervalSince(t) < 1 { return }
        lastTold[key] = Date()
        guard let i = rows.firstIndex(where: { $0.key == key }) else { return }
        rows[i].bytes = written
        if expected > 0 { rows[i].total = expected }
    }

    /// The finished file, already moved out of the system's temporary place (it is deleted on return).
    func finished(_ key: String, staged: URL?, status: Int) {
        guard let i = rows.firstIndex(where: { $0.key == key }) else { if let s = staged { try? FileManager.default.removeItem(at: s) }; return }
        tasks[key] = nil
        guard let s = staged, (200...299).contains(status) else {
            rows[i].phase = .failed; rows[i].error = status > 0 ? "HTTP \(status)" : "no file"
            save(); pump(); return
        }
        let dest = dir.appendingPathComponent(rows[i].file)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: s, to: dest) } catch { rows[i].phase = .failed; rows[i].error = "couldn’t keep the file"; save(); pump(); return }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? rows[i].bytes
        rows[i].bytes = size; rows[i].total = size; rows[i].phase = .done
        save(); pump()
    }

    func failed(_ key: String, error: Error, resumeData: Data?) {
        tasks[key] = nil
        if pausing.remove(key) != nil { save(); pump(); return }        // our own pause or remove
        guard let i = rows.firstIndex(where: { $0.key == key }) else { return }
        if let d = resumeData { try? d.write(to: dir.appendingPathComponent(key + ".resume")) }
        rows[i].phase = .failed; rows[i].error = (error as NSError).localizedDescription
        save(); pump()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? data.write(to: dir.appendingPathComponent("index.json"), options: .atomic)
    }
}

/// URLSession's delegate, off the main actor: it moves a finished file out of the system's temporary place before
/// returning (the system deletes it then) and hands everything else to Downloads on the main actor.
final class DownloadRelay: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var owner: Downloads?

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
        guard let k = t.taskDescription else { return }
        Task { @MainActor [weak owner] in owner?.progress(k, written: w, expected: e) }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let k = t.taskDescription else { return }
        let status = (t.response as? HTTPURLResponse)?.statusCode ?? 0
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("nebula-dl-" + k)
        try? FileManager.default.removeItem(at: staged)
        let moved = (try? FileManager.default.moveItem(at: location, to: staged)) != nil
        Task { @MainActor [weak owner] in owner?.finished(k, staged: moved ? staged : nil, status: status) }
    }

    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard let k = t.taskDescription, let e = error else { return }
        let data = (e as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor [weak owner] in owner?.failed(k, error: e, resumeData: data) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession s: URLSession) {
        Task { @MainActor [weak owner] in owner?.backgroundDone?(); owner?.backgroundDone = nil }
    }
}
