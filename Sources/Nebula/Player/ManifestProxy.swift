import Foundation
import Network
import NebulaCore

/// A loopback server for DASH manifests — and, since 0.4.0, for HLS streams whose host wants its
/// own request headers on every piece (`openHls`, rules in `HlsUnwrap`). The engine's DASH reader reads the
/// manifest once per representation before it shows a frame; against a source that takes two
/// seconds to answer, that was 45 s of black. Here the manifest is fetched once, trimmed to one
/// picture quality (`DashManifest.prepare`), and every further read is answered from memory —
/// refreshed from the source no more often than `maxAge`. Media segments never pass through.
final class ManifestProxy: @unchecked Sendable {
    static let shared = ManifestProxy()

    private struct Entry {
        var source: String
        var headers: [String: String]
        var maxHeight: Int
        var body: Data?
        var fetchedAt = Date.distantPast
        /// An HLS stream served through `/h/`: its playlists are rewritten, its pieces unwrapped.
        var hls = false
    }

    private let queue = DispatchQueue(label: "nebula.manifest-proxy")
    private var listener: NWListener?
    private var port: UInt16 = 0
    /// The port last handed out, kept when its listener dies: binding it again keeps the
    /// addresses already given to the engine working.
    private var lastPort: UInt16 = 0
    private var entries: [String: Entry] = [:]
    private let maxAge: TimeInterval = 2.5
    static let trace = ProcessInfo.processInfo.environment["NEBULA_MPV_DEBUG"] == "1"
    private let transport = URLSessionTransport(timeout: 20)
    /// Pieces are seconds of video, megabytes each: their own session, so a slow one does not
    /// count against the manifests' short answers.
    private let pieces: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 120
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    /// An HLS stream through loopback: every playlist is fetched with the stream's headers and its
    /// addresses renamed to loopback ones, every piece fetched with them and handed over from its
    /// first video packet (a host that wraps pieces in a picture is played as if it did not).
    /// nil = play the source directly.
    func openHls(_ source: String, headers: [String: String]) async -> (address: String, token: String)? {
        guard HlsUnwrap.isPlaylist(source), !Task.isCancelled, await ensureListening(), !Task.isCancelled else { return nil }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let address = queue.sync { () -> String in
            entries[token] = Entry(source: source, headers: headers, maxHeight: 0, body: nil, hls: true)
            return "http://127.0.0.1:\(port)/h/\(token)/p/\(HlsUnwrap.encode(source)).m3u8"
        }
        if Task.isCancelled { release(token); return nil }
        return (address, token)
    }

    /// Fetch and prepare a manifest, and return the loopback address to play plus the ORIGINAL
    /// text (the licence address is read from it). nil = play the source directly.
    func open(_ source: String, headers: [String: String], maxHeight: Int) async -> (address: String, xml: String, base: String, token: String)? {
        guard !Task.isCancelled, await ensureListening(), !Task.isCancelled,
              let (xml, base) = await fetch(source, headers: headers), !Task.isCancelled else { return nil }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let body = Data(DashManifest.prepare(xml, manifestUrl: base, maxHeight: maxHeight).utf8)
        let address = queue.sync { () -> String in
            // a player on its way out must not remove the next player's live manifest
            entries[token] = Entry(source: source, headers: headers, maxHeight: maxHeight, body: body, fetchedAt: Date())
            return "http://127.0.0.1:\(port)/m/\(token).mpd"
        }
        if Task.isCancelled { release(token); return nil }
        return (address, xml, base, token)
    }

    func release(_ token: String?) {
        guard let token = token else { return }
        queue.sync { _ = entries.removeValue(forKey: token) }
    }

    /// The manifest's text and the address it finally came from. A source that redirects
    /// serves relative segment paths that belong to the address it landed on, not to the one
    /// asked for — resolving them against the first sent the engine to the wrong host.
    private func fetch(_ source: String, headers: [String: String]) async -> (xml: String, base: String)? {
        guard let url = URL(string: source) else { return nil }
        var r = Net.addonRequest(url)
        r.setValue(MPVController.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        guard let (data, code, finalURL) = try? await transport.sendWithURL(r), (200...299).contains(code),
              let xml = String(data: data, encoding: .utf8), xml.range(of: "<MPD", options: .caseInsensitive) != nil else { return nil }
        return (xml, finalURL.absoluteString)
    }

    private func ensureListening() async -> Bool {
        let (up, again) = queue.sync { (alive(), lastPort) }
        if up { return true }
        if again != 0, let p = NWEndpoint.Port(rawValue: again), await bind(p) { return true }
        return await bind(.any)
    }

    private func bind(_ on: NWEndpoint.Port) async -> Bool {
        await withCheckedContinuation { cont in
            do {
                let params = NWParameters.tcp
                params.requiredInterfaceType = .loopback
                params.allowLocalEndpointReuse = true
                let l = try NWListener(using: params, on: on)
                final class Once: @unchecked Sendable { var done = false }     // the continuation resumes once
                let once = Once()
                l.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        guard !once.done else { return }
                        once.done = true
                        self.port = l.port?.rawValue ?? 0
                        self.lastPort = self.port
                        self.listener = l
                        cont.resume(returning: self.port != 0)
                    case .failed, .cancelled:
                        // A listener can die long after it was ready — a phone reclaims a
                        // suspended app's sockets. Handing out its port then gave the engine a
                        // dead address for good; drop it, and the next open binds again.
                        if self.listener === l { self.listener = nil; self.port = 0 }
                        if case .failed = state { l.cancel() }
                        if !once.done { once.done = true; cont.resume(returning: false) }
                    default: break
                    }
                }
                l.newConnectionHandler = { [weak self] c in self?.serve(c) }
                l.start(queue: queue)
            } catch {
                cont.resume(returning: false)
            }
        }
    }

    /// Whether the listener in hand can still take a connection. One that is not ready any
    /// more is let go here. Runs on `queue`.
    private func alive() -> Bool {
        guard let l = listener, port != 0 else { return false }
        if case .ready = l.state { return true }
        l.cancel()
        listener = nil; port = 0
        return false
    }

    /// Coming back to the front (the phone): bind again now, on the old port when it can be
    /// had, rather than when the engine next asks a dead address for a manifest.
    func revive() {
        guard queue.sync(execute: { lastPort != 0 }) else { return }
        Task { _ = await ensureListening() }
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let head = String(data: data, encoding: .utf8),
                  let line = head.components(separatedBy: "\r\n").first else { c.cancel(); return }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else { self.reply(c, 404, Data()); return }
            if parts[1].hasPrefix("/h/") { self.serveHls(c, String(parts[1].dropFirst(3))); return }
            guard parts[1].hasPrefix("/m/") else { self.reply(c, 404, Data()); return }
            let token = String(parts[1].dropFirst(3).prefix { $0 != "." && $0 != "?" })
            guard let e = self.entries[token], !e.hls else { self.reply(c, 404, Data()); return }
            if Date().timeIntervalSince(e.fetchedAt) < self.maxAge, let body = e.body { self.reply(c, 200, body); return }
            Task {
                // a live manifest moves on: ask the source again, and fall back to the copy in hand
                var body = e.body
                if let (xml, base) = await self.fetch(e.source, headers: e.headers) {
                    let fresh = Data(DashManifest.prepare(xml, manifestUrl: base, maxHeight: e.maxHeight).utf8)
                    body = fresh
                    self.queue.async { if self.entries[token] != nil { self.entries[token]?.body = fresh; self.entries[token]?.fetchedAt = Date() } }
                }
                self.queue.async { self.reply(c, body == nil ? 502 : 200, body ?? Data()) }
            }
        }
    }

    /// `<token>/p/<enc>.m3u8` · `<token>/s/<enc>.ts` · `<token>/r/<enc>.bin`. Runs on `queue`.
    private func serveHls(_ c: NWConnection, _ path: String) {
        guard let slash = path.firstIndex(of: "/") else { reply(c, 404, Data()); return }
        let token = String(path[..<slash])
        guard let e = entries[token], e.hls, let ask = HlsUnwrap.ask(String(path[path.index(after: slash)...])) else { reply(c, 404, Data()); return }
        let prefix = "http://127.0.0.1:\(port)/h/\(token)/"
        Task {
            var code = 502, body = Data(), type = "application/octet-stream"
            switch ask {
            case .playlist(let u):
                if let (d, status, final) = await self.get(u, e.headers) {
                    code = status
                    if (200...299).contains(status), let text = String(data: d, encoding: .utf8), text.hasPrefix("#EXTM3U") || text.contains("#EXTINF") || text.contains("#EXT-X-") {
                        body = Data(HlsUnwrap.rewrite(text, base: final.absoluteString, prefix: prefix).utf8)
                        type = "application/vnd.apple.mpegurl"
                    } else if (200...299).contains(status) { code = 502 }
                }
            case .piece(let u):
                if let (d, status, _) = await self.get(u, e.headers) {
                    code = status
                    if (200...299).contains(status) { body = HlsUnwrap.unwrap(d); type = HlsUnwrap.tsStart(body) == 0 ? "video/mp2t" : type }
                }
            case .raw(let u):
                if let (d, status, _) = await self.get(u, e.headers) { code = status; if (200...299).contains(status) { body = d } }
            }
            if ManifestProxy.trace {
                FileHandle.standardError.write(Data("proxy: \(ask) -> \(code) \(body.count) B \(type)\n".utf8))
            }
            self.queue.async {
                // a player on its way out: nothing more is handed over for it
                guard self.entries[token] != nil else { self.reply(c, 404, Data()); return }
                self.reply(c, (200...299).contains(code) ? 200 : code, body, type: type)
            }
        }
    }

    /// One request with the stream's headers (and the engine's name unless the stream sets one).
    private func get(_ address: String, _ headers: [String: String]) async -> (Data, Int, URL)? {
        guard let url = URL(string: address) else { return nil }
        var r = URLRequest(url: url)
        r.setValue(MPVController.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let handle = PieceTask()
        let trace = ManifestProxy.trace
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<(Data, Int, URL)?, Never>) in
                let t = pieces.dataTask(with: r) { data, resp, err in
                    guard err == nil, let h = resp as? HTTPURLResponse else {
                        if trace { FileHandle.standardError.write(Data("proxy: get failed \(String(describing: err))\n".utf8)) }
                        cont.resume(returning: nil); return
                    }
                    cont.resume(returning: (data ?? Data(), h.statusCode, h.url ?? url))
                }
                handle.set(t)
                t.resume()
            }
        } onCancel: { handle.cancel() }
    }

    private func reply(_ c: NWConnection, _ code: Int, _ body: Data, type: String = "application/dash+xml") {
        let head = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// The piece request in flight, for a cancellation that can arrive before it exists.
private final class PieceTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func set(_ t: URLSessionTask) { lock.lock(); task = t; let c = cancelled; lock.unlock(); if c { t.cancel() } }
    func cancel() { lock.lock(); cancelled = true; let t = task; lock.unlock(); t?.cancel() }
}
