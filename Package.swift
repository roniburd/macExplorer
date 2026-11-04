// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "macExplorer",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "macExplorer", targets: ["macExplorer"]),
        .executable(name: "macx-bench", targets: ["macx-bench"]),
        .executable(name: "macx-scenarios", targets: ["macx-scenarios"]),
    ],
    targets: [
        .target(
            name: "CFSKit",
            cSettings: [.unsafeFlags(["-Wall", "-Wextra", "-Werror"])]
        ),
        .target(name: "MacxFS", dependencies: ["CFSKit"], path: "Sources/FSKit", swiftSettings: strict),
        .target(name: "Core", dependencies: ["MacxFS"], swiftSettings: strict),
        .target(
            name: "UI",
            dependencies: ["Core", "MacxFS"],
            resources: [.process("Resources")],
            swiftSettings: strict
        ),
        .executableTarget(name: "macExplorer", dependencies: ["UI", "Core"], path: "Sources/App", swiftSettings: strict),
        .target(name: "MacxFixtures", dependencies: ["MacxFS"], swiftSettings: strict),
        .executableTarget(name: "macx-bench", dependencies: ["MacxFS", "Core", "MacxFixtures"], swiftSettings: strict),
        .executableTarget(name: "macx-scenarios", dependencies: ["Core", "MacxFS", "MacxFixtures"], swiftSettings: strict),
        .testTarget(name: "MacxFixturesTests", dependencies: ["MacxFixtures"], swiftSettings: strict),
        .testTarget(name: "FSKitTests", dependencies: ["MacxFS", "CFSKit", "MacxFixtures"], resources: [.copy("Corpus")], swiftSettings: strict),
        .testTarget(name: "CoreTests", dependencies: ["Core", "MacxFS", "MacxFixtures"], swiftSettings: strict),
        .testTarget(name: "UITests", dependencies: ["UI", "Core", "MacxFS", "MacxFixtures"], swiftSettings: strict),
        .testTarget(name: "BenchTests", dependencies: ["macx-bench", "Core", "MacxFS", "MacxFixtures"], swiftSettings: strict),
        .testTarget(name: "ScenarioRunnerTests", dependencies: ["macx-scenarios", "Core", "MacxFS", "MacxFixtures"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
