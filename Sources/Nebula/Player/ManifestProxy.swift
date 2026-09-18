import Foundation
import Network
import NebulaCore

/// A loopback server for DASH manifests, and nothing else. The engine's DASH reader reads the
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
    }

    private let queue = DispatchQueue(label: "nebula.manifest-proxy")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var entries: [String: Entry] = [:]
    private let maxAge: TimeInterval = 2.5
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// Fetch and prepare a manifest, and return the loopback address to play plus the ORIGINAL
    /// text (the licence address is read from it). nil = play the source directly.
    func open(_ source: String, headers: [String: String], maxHeight: Int) async -> (address: String, xml: String)? {
        guard await ensureListening(), let (_, xml) = await fetch(source, headers: headers) else { return nil }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let body = Data(DashManifest.prepare(xml, manifestUrl: source, maxHeight: maxHeight).utf8)
        queue.sync {
            // one film at a time: what came before is never asked for again
            entries = [token: Entry(source: source, headers: headers, maxHeight: maxHeight, body: body, fetchedAt: Date())]
        }
        return ("http://127.0.0.1:\(port)/m/\(token).mpd", xml)
    }

    private func fetch(_ source: String, headers: [String: String]) async -> (Data, String)? {
        guard let url = URL(string: source) else { return nil }
        var r = Net.addonRequest(url)
        r.setValue(MPVController.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        guard let (data, resp) = try? await session.data(for: r), (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false,
              let xml = String(data: data, encoding: .utf8), xml.range(of: "<MPD", options: .caseInsensitive) != nil else { return nil }
        return (data, xml)
    }

    private func ensureListening() async -> Bool {
        if queue.sync(execute: { listener != nil && port != 0 }) { return true }
        return await withCheckedContinuation { cont in
            do {
                let params = NWParameters.tcp
                params.requiredInterfaceType = .loopback
                params.allowLocalEndpointReuse = true
                let l = try NWListener(using: params, on: .any)
                final class Once: @unchecked Sendable { var done = false }     // the continuation resumes once
                let once = Once()
                l.stateUpdateHandler = { [weak self] state in
                    guard let self = self, !once.done else { return }
                    switch state {
                    case .ready:
                        once.done = true
                        self.port = l.port?.rawValue ?? 0
                        self.listener = l
                        cont.resume(returning: self.port != 0)
                    case .failed, .cancelled:
                        once.done = true
                        cont.resume(returning: false)
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

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let head = String(data: data, encoding: .utf8),
                  let line = head.components(separatedBy: "\r\n").first else { c.cancel(); return }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD", parts[1].hasPrefix("/m/") else { self.reply(c, 404, Data()); return }
            let token = String(parts[1].dropFirst(3).prefix { $0 != "." && $0 != "?" })
            guard let e = self.entries[token] else { self.reply(c, 404, Data()); return }
            if Date().timeIntervalSince(e.fetchedAt) < self.maxAge, let body = e.body { self.reply(c, 200, body); return }
            Task {
                // a live manifest moves on: ask the source again, and fall back to the copy in hand
                var body = e.body
                if let (_, xml) = await self.fetch(e.source, headers: e.headers) {
                    let fresh = Data(DashManifest.prepare(xml, manifestUrl: e.source, maxHeight: e.maxHeight).utf8)
                    body = fresh
                    self.queue.async { if self.entries[token] != nil { self.entries[token]?.body = fresh; self.entries[token]?.fetchedAt = Date() } }
                }
                self.queue.async { self.reply(c, body == nil ? 502 : 200, body ?? Data()) }
            }
        }
    }

    private func reply(_ c: NWConnection, _ code: Int, _ body: Data) {
        let head = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: application/dash+xml\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}
