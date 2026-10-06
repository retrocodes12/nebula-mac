import SwiftUI
import ImageIO
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Poster and backdrop loading: one shared memory cache in front of the URL cache on disk, and a
/// count of what is in flight so the screenshot rig knows when a page has settled.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, PlatformImage>()
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
        // counted in decoded pixels now (what a picture really costs in memory), not file bytes
        cache.totalCostLimit = 160 << 20
    }

    private func count(_ d: Int) { lock.lock(); inFlight += d; lock.unlock() }

    var busy: Bool { lock.lock(); defer { lock.unlock() }; return inFlight > 0 }

    func cached(_ url: String) -> PlatformImage? { cache.object(forKey: url as NSString) }

    /// Fetched, and decoded here — off the main thread, because this is not on any actor. A
    /// picture made straight from its file decodes the first time it is drawn, on the main thread,
    /// which is where the stutter on a row of posters coming in came from.
    func load(_ address: String) async -> PlatformImage? {
        if let c = cached(address) { return c }
        guard let url = URL(string: address) else { return nil }
        count(1)
        defer { count(-1) }
        guard let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true else { return nil }
        if let d = ImageLoader.decode(data) {
            cache.setObject(d.image, forKey: address as NSString, cost: d.bytes)
            return d.image
        }
        // a kind of file ImageIO does not read (a PDF logo): as before, decoded when drawn
        guard let img = Platform.image(data: data) else { return nil }
        cache.setObject(img, forKey: address as NSString, cost: data.count)
        return img
    }

    struct Decoded {
        let image: PlatformImage
        let bytes: Int
    }

    /// The bitmap, decoded now rather than when first drawn, and never wider or taller than 3000
    /// pixels (a backdrop that size is already sharper than any screen shows it).
    static func decode(_ data: Data) -> Decoded? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 3000,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        #if canImport(AppKit)
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        let image = UIImage(cgImage: cg)
        #endif
        return Decoded(image: image, bytes: max(1, cg.bytesPerRow * cg.height))
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: String?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: Placeholder
    /// The picture, and the address it is the picture of.
    @State private var image: PlatformImage?
    @State private var shown: String?

    init(url: String?, contentMode: ContentMode = .fill, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder()
        // a picture already in memory is there from the first frame: a row scrolled back into
        // view, or a page opened again, no longer flashes its placeholder first
        let hit = url.flatMap { ImageLoader.shared.cached($0) }
        _image = State(initialValue: hit)
        _shown = State(initialValue: hit == nil ? nil : url)
    }

    var body: some View {
        // the address moved on (the hero's next title) and the picture held is not this one:
        // what memory has for the new address, else the placeholder until it comes
        let current = shown == url ? image : url.flatMap { ImageLoader.shared.cached($0) }
        ZStack {
            if let img = current {
                Image(platform: img).resizable().aspectRatio(contentMode: contentMode).transition(.opacity)
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard let u = url, !u.isEmpty else { image = nil; shown = url; return }
            if let c = ImageLoader.shared.cached(u) { image = c; shown = u; return }
            let img = await ImageLoader.shared.load(u)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.2)) { image = img; shown = u }
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
