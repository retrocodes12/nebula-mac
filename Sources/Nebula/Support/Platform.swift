import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The few places the Mac and the phone say the same thing in different words. Everything else
/// in this app — the model, the engine, the views — is written once and compiled for both.
#if canImport(AppKit)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

enum Platform {
    /// Hands a link to the system: the releases page, an add-on's site.
    static func open(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    static func copy(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// What this device calls itself in the profile's device list.
    static var deviceName: String {
        #if canImport(AppKit)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.name
        #endif
    }

    /// What the app calls this device in a sentence ("this Mac", "this phone").
    static var deviceWord: String {
        #if canImport(AppKit)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "phone"
        #endif
    }

    /// The app's name on this device, as About gives it.
    static var appTitle: String {
        #if canImport(AppKit)
        return "Nebula for Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "Nebula for iPad" : "Nebula for iPhone"
        #endif
    }

    /// Why decoding on the graphics chip is worth having, in this device's terms: a Mac's fans,
    /// a phone's battery.
    static var hardwareDecodingGain: String {
        #if canImport(AppKit)
        return "Cooler and quieter."
        #else
        return "Easier on the battery, and the \(deviceWord) stays cooler."
        #endif
    }

    /// The user agent add-ons and hosts see.
    static var userAgentSystem: String {
        #if canImport(AppKit)
        return "Macintosh; macOS"
        #else
        return "iPhone; iOS"
        #endif
    }

    /// The platform the profile files this device under. Add-on requests say `macos` on both
    /// (`Net.clientName`), because that is the name the sports add-on serves its cards to.
    static var client: String {
        #if canImport(AppKit)
        return "macos"
        #else
        return "ios"
        #endif
    }

    static func image(contentsOfFile path: String) -> PlatformImage? {
        #if canImport(AppKit)
        return NSImage(contentsOfFile: path)
        #else
        return UIImage(contentsOfFile: path)
        #endif
    }

    static func image(data: Data) -> PlatformImage? { PlatformImage(data: data) }

    /// sRGB components, so a colour can be judged for brightness on either platform.
    static func rgb(_ color: Color) -> (r: Double, g: Double, b: Double) {
        #if canImport(AppKit)
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return (1, 1, 1) }
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        #else
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
        #endif
    }
}

extension Image {
    init(platform: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platform)
        #else
        self.init(uiImage: platform)
        #endif
    }
}
