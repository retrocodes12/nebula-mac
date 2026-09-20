import Foundation
import NebulaCore

enum AppInfo {
    /// The bundle's version when packaged; the development value otherwise.
    static let version: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.2.0"
    static let site = "https://play.rifflehq.in"
    static let releasesApi = "https://play.rifflehq.in/cloud/v1/releases"
    /// Where the app keeps its documents; the rigs point it at a scratch folder.
    static func store() -> Store {
        if let dir = ProcessInfo.processInfo.environment["NEBULA_STORE_DIR"], !dir.isEmpty {
            return Store(directory: URL(fileURLWithPath: dir, isDirectory: true))
        }
        return .standard()
    }

    static let repo = "https://github.com/retrocodes12/nebula-mac"
}
