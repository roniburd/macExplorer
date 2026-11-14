// swift-tools-version: 6.2
import PackageDescription

// The plugin API: a dynamic library with library evolution, in its own package so the app and every plugin link
// one copy of it (a same-package target would be linked statically into the app and break plugin casts).
let package = Package(
    name: "MacxPluginKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "MacxPluginKit", type: .dynamic, targets: ["MacxPluginKit"])],
    targets: [
        .target(name: "MacxPluginKit",
                swiftSettings: [.treatAllWarnings(as: .error), .unsafeFlags(["-enable-library-evolution"])]),
    ],
    swiftLanguageModes: [.v6]
)
