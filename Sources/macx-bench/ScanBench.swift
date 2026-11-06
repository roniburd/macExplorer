import Core
import Foundation
import MacxFS

/// P2-20: non-gated Phase 2 targets (plan Global Constraints, "reported by macx-bench"), each on a fixed-size fixture
/// inside the bench's own macx-bench-<UUID> sandbox:
/// - `folderSize.scan` @ 10,000: a `FolderSizeScanner.scan` of 100 folders × 100 files (1 KB each) on a `.scan` lane;
/// - `extattrs.read` @ 2,000: `ExtendedAttributeReader.read(…, wanted: .all)` of 2,000 files, half of them tagged, on a
///   read lane.
@MainActor
enum ScanBench {
    static let folders = 100
    static let filesPerFolder = 100
    static let attributeFiles = 2_000

    static func run(_ options: BenchOptions, env: CoreEnvironment, sandbox: SandboxHandle,
                    wants: (String) -> Bool) async throws -> [MetricResult] {
        var out: [MetricResult] = []
        if wants("folderSize.scan") {
            let root = sandbox.folders("work/scan-10k", folders: folders, filesPerFolder: filesPerFolder, bytes: 1_024)
            let table = env.volumes.mountTableStore.current()
            let volume = env.volumes.volume(for: root)?.id ?? .unknown
            let lanes = env.lanes
            let expectedFiles = folders * filesPerFolder
            let samples = try await Stats.sample(warmups: options.warmups, iterations: options.iterations) {
                let start = ContinuousClock.now
                let size = try await lanes.perform(on: volume, .scan) { ctx in
                    FolderSizeScanner.scan(root, context: ctx, mountTable: table)
                }
                let ms = Stats.milliseconds(ContinuousClock.now - start)
                guard let size, size.files == expectedFiles, size.folders == folders, size.bytes == Int64(expectedFiles * 1_024),
                      !size.isPartial else {
                    throw BenchFailure.check("folder-size scan of \(expectedFiles) files returned \(String(describing: size))")
                }
                return ms
            }
            out.append(MetricResult(name: "folderSize.scan", size: expectedFiles, samples: samples))
        }
        if wants("extattrs.read") {
            let relative = "work/extattrs-2k"
            let directory = sandbox.flat(relative, count: attributeFiles)
            // FixtureTree.flat's names: "file-" + the 1-based index, zero-padded to 6 digits, + ".txt".
            let names = (1...attributeFiles).map { "file-" + String(repeating: "0", count: max(0, 6 - String($0).count)) + "\($0).txt" }
            for (i, name) in names.enumerated() where i % 2 == 0 {
                sandbox.finderTags(["Bench", "Tag \(i % 7)"], on: "\(relative)/\(name)")
            }
            let volume = env.volumes.volume(for: directory)?.id ?? .unknown
            let lanes = env.lanes
            let owners = env.ownerNames
            let samples = try await Stats.sample(warmups: options.warmups, iterations: options.iterations) {
                let start = ContinuousClock.now
                let attributes = try await lanes.perform(on: volume, .read) { _ in
                    ExtendedAttributeReader.read(names: names, in: directory, wanted: .all, owners: owners)
                }
                let ms = Stats.milliseconds(ContinuousClock.now - start)
                let tagged = attributes.values.filter { !$0.tags.isEmpty }.count
                guard attributes.count == attributeFiles, tagged == attributeFiles / 2 else {
                    throw BenchFailure.check("extended attributes of \(attributeFiles) files (\(attributes.count) read, \(tagged) tagged)")
                }
                return ms
            }
            out.append(MetricResult(name: "extattrs.read", size: attributeFiles, samples: samples))
        }
        return out
    }
}
