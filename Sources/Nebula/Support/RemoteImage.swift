import SwiftUI
import AppKit

/// Poster and backdrop loading: one shared memory cache in front of the URL cache on disk, and a
/// count of what is in flight so the screenshot rig knows when a page has settled.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, NSImage>()
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight = 0

    init() {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.timeoutIntervalForRequest = 20
        c.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: c)
        cache.totalCostLimit = 160 << 20
    }

    private func count(_ d: Int) { lock.lock(); inFlight += d; lock.unlock() }

    var busy: Bool { lock.lock(); defer { lock.unlock() }; return inFlight > 0 }

    func cached(_ url: String) -> NSImage? { cache.object(forKey: url as NSString) }

    func load(_ address: String) async -> NSImage? {
        if let c = cached(address) { return c }
        guard let url = URL(string: address) else { return nil }
        count(1)
        defer { count(-1) }
        guard let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
              let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: address as NSString, cost: data.count)
        return img
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: String?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: Placeholder
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let img = image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: contentMode).transition(.opacity)
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard let u = url, !u.isEmpty else { image = nil; return }
            if let c = ImageLoader.shared.cached(u) { image = c; return }
            image = nil
            let img = await ImageLoader.shared.load(u)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.2)) { image = img }
        }
    }
}

/// Two-letter fallback for a missing or broken poster.
struct InitialsTile: View {
    let name: String
    var body: some View {
        let letters = String(name.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased()
        ZStack {
            Theme.surface
            Text(letters.isEmpty ? "••" : letters)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.label3)
        }
    }
}
