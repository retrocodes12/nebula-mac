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
}

public struct URLSessionTransport: Transport {
    let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: c)
    }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        // a continuation rather than `data(for:)`: corelibs Foundation grew the async call late
        try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: request) { data, resp, err in
                if let err = err { cont.resume(throwing: err); return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                cont.resume(returning: (data ?? Data(), code))
            }
            task.resume()
        }
    }
}

public enum Net {
    /// Add-on requests carry the same identity Android's do: the sports add-on reads it and
    /// serves its direct cards instead of the "open in Nebula" launcher meant for other clients.
    public static let userAgent = "NebulaPlayer"
    public static let clientName = "macos"

    public static func addonRequest(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue(clientName, forHTTPHeaderField: "X-Nebula-Client")
        return r
    }
}
