import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPFailure: Error, CustomStringConvertible {
    public let code: Int
    public let error: String
    public var description: String { "HTTP \(code) \(error)" }
}

/// One way out to the network, so tests can stand in for it.
public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
    func sendWithURL(_ request: URLRequest) async throws -> (Data, Int, URL)
}

public extension Transport {
    func sendWithURL(_ request: URLRequest) async throws -> (Data, Int, URL) {
        let (data, code) = try await send(request)
        return (data, code, request.url!)
    }
}

public struct URLSessionTransport: Transport {
    let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        // the idle timeout alone let a host that trickles a byte now and then hold a request
        // for days (the default here is seven): every page shares one manifest request per
        // add-on, so that one held Home, Search and Streams with it. Everything sent through
        // this is a short answer — add-on JSON, a manifest, a licence, the sync service;
        // streams go to the engine and the manifest cache keeps its own session.
        c.timeoutIntervalForResource = 45
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: c)
    }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, code, _) = try await sendWithURL(request)
        return (data, code)
    }

    public func sendWithURL(_ request: URLRequest) async throws -> (Data, Int, URL) {
        // a continuation rather than `data(for:)`: corelibs Foundation grew the async call late.
        // Cancelling the caller cancels the request — without that a capped wait (subtitles,
        // a dead add-on) still sat out the full timeout before it could return.
        let handle = TaskHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let task = session.dataTask(with: request) { data, resp, err in
                    if let err = err { cont.resume(throwing: err); return }
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    cont.resume(returning: (data ?? Data(), code, resp?.url ?? request.url!))
                }
                handle.set(task)
                task.resume()
            }
        } onCancel: {
            handle.cancel()
        }
    }
}

/// The request in flight, for a cancellation that can arrive before it exists.
final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ t: URLSessionTask) {
        lock.lock(); task = t; let c = cancelled; lock.unlock()
        if c { t.cancel() }
    }

    func cancel() {
        lock.lock(); cancelled = true; let t = task; lock.unlock()
        t?.cancel()
    }
}

public enum Net {
    /// Add-on requests carry the same identity Android's do: the sports add-on reads it and
    /// serves its direct cards instead of the "open in Nebula" launcher meant for other clients.
    public static let userAgent = "NebulaPlayer"
    public static let clientName = "macos"
    /// What this player can do that an add-on may ask about before offering a row.
    public static let caps = "headers"

    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let scheme = a.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = a.host?.lowercased(), !host.isEmpty else { return false }
        return scheme == b.scheme?.lowercased() && host == b.host?.lowercased()
            && (a.port ?? (scheme == "https" ? 443 : 80)) == (b.port ?? (scheme == "https" ? 443 : 80))
    }

    public static func addonRequest(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue(clientName, forHTTPHeaderField: "X-Nebula-Client")
        // this player sends a stream's own request headers on every request of its play (the
        // engine's header fields, and the loopback playlist path for HLS) — so an add-on may
        // offer rows that only play with them, as Android 1.90.0 told it too
        r.setValue(caps, forHTTPHeaderField: "X-Nebula-Caps")
        return r
    }
}
