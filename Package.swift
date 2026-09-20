// swift-tools-version:5.9
import PackageDescription

// NebulaCore is plain Foundation and builds on Linux too — that is where its tests run during
// development. The app target (SwiftUI + libmpv) is macOS only and is left out elsewhere.
var products: [Product] = [.library(name: "NebulaCore", targets: ["NebulaCore"])]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "NebulaCore", path: "Sources/NebulaCore"),
    .testTarget(name: "NebulaCoreTests", dependencies: ["NebulaCore"], path: "Tests/NebulaCoreTests"),
]

#if os(macOS)
products.append(.executable(name: "Nebula", targets: ["Nebula"]))
dependencies.append(.package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.0.0"))
targets.append(
    .executableTarget(
        name: "Nebula",
        dependencies: ["NebulaCore", .product(name: "MPVKit", package: "MPVKit")],
        path: "Sources/Nebula"
    )
)
#endif

// iOS is here so the phone app's Xcode project can take NebulaCore from this package; the
// `Nebula` executable above stays macOS-only and the phone builds its own shell (iOS/project.yml).
let package = Package(
    name: "Nebula",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
