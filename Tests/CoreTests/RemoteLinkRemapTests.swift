import Foundation
import MacxFixtures
import XCTest
@testable import Core

/// Experimental remote-symlink remapping on SSH/FUSE mounts. The "mount" is a sandbox folder; `mountOf` is injected.
final class RemoteLinkRemapTests: XCTestCase {
    private let mount = "/Users/me/mnt/box"

    private func candidate(_ destination: String, root: String?, learned: [String] = [], existing: Set<String>)
        -> (path: String, learnedPrefix: String?)? {
        Remapper.candidate(for: destination, mount: RemoteMount(mountPoint: mount, remoteRoot: root), learned: learned,
                           exists: { existing.contains($0) })
    }

    // MARK: candidate (pure)

    func testRemoteRootPrefixMapsDirectly() {
        let hit = candidate("/local/home/me/tools/x", root: "/local/home/me", existing: [mount + "/tools/x"])
        XCTAssertEqual(hit?.path, mount + "/tools/x")
        XCTAssertNil(hit?.learnedPrefix, "the remote root is already known")
    }

    func testAliasOfTheRemoteRootIsLearnedWhenItsLastComponentMatches() {
        let hit = candidate("/home/me/.toolbox/bin/cr", root: "/local/home/me", existing: [mount + "/.toolbox/bin/cr"])
        XCTAssertEqual(hit?.path, mount + "/.toolbox/bin/cr")
        XCTAssertEqual(hit?.learnedPrefix, "/home/me")
    }

    func testLearnedPrefixIsReused() {
        let hit = candidate("/home/me/a/b", root: "/local/home/me", learned: ["/home/me"], existing: [mount + "/a/b"])
        XCTAssertEqual(hit?.path, mount + "/a/b")
        XCTAssertNil(hit?.learnedPrefix)
    }

    func testUnrelatedSystemPathIsNotMappedWhenTheRootIsKnown() {
        // ~/mnt/box/bin/x exists, but /usr/local isn't the remote home: no guess.
        XCTAssertNil(candidate("/usr/local/bin/x", root: "/local/home/me", existing: [mount + "/bin/x"]))
    }

    func testSingleComponentPrefixIsNeverLearned() {
        XCTAssertNil(candidate("/etc/hosts", root: nil, existing: [mount + "/hosts"]))
        XCTAssertNil(candidate("/workplace/me", root: "/local/home/me", existing: [mount + "/me"]))
    }

    func testUnknownRootLearnsShortestTwoComponentPrefix() {
        let hit = candidate("/home/me/src/pkg", root: nil, existing: [mount + "/src/pkg", mount + "/pkg"])
        XCTAssertEqual(hit?.path, mount + "/src/pkg", "the longest remainder wins")
        XCTAssertEqual(hit?.learnedPrefix, "/home/me")
    }

    func testTargetOutsideTheMountStaysBroken() {
        XCTAssertNil(candidate("/workplace/me/pkg", root: "/local/home/me", existing: []))
    }

    func testTargetAlreadyUnderTheMountPointIsLeftAlone() {
        XCTAssertNil(candidate(mount + "/gone", root: "/local/home/me", existing: [mount + "/gone"]))
    }

    func testWholeRemoteDiskMountedMapsDirectlyOnly() {
        XCTAssertEqual(candidate("/opt/x", root: "/", existing: [mount + "/opt/x"])?.path, mount + "/opt/x")
        XCTAssertNil(candidate("/home/me/x", root: "/", existing: [mount + "/x"]))
    }

    func testDotDotCannotEscapeTheMount() {
        let hit = candidate("/local/home/me/../../../etc/passwd", root: "/local/home/me", existing: ["/etc/passwd"])
        XCTAssertNil(hit)
    }

    // MARK: mount sources and sshfs arguments

    func testRemotePathFromMountSource() {
        XCTAssertEqual(RemoteMount.remotePath(fromSource: "me@box.example.com:/local/home/me/"), "/local/home/me")
        XCTAssertEqual(RemoteMount.remotePath(fromSource: "box:/"), "/")
        XCTAssertNil(RemoteMount.remotePath(fromSource: "box:"), "relative to an unknown remote home")
        XCTAssertNil(RemoteMount.remotePath(fromSource: "box:src"))
        XCTAssertNil(RemoteMount.remotePath(fromSource: "/dev/disk3s1"))
    }

    func testSSHFSArgumentsGiveTheRemoteRootOfTheirMountPoint() {
        let args = ["/usr/local/bin/sshfs", "box.example.com:/local/home/me", "/Users/me/mnt/box",
                    "-o", "volname=box,reconnect"]
        XCTAssertEqual(SSHFSProcesses.remoteRoot(arguments: args, mountPoint: "/Users/me/mnt/box/"), "/local/home/me")
        XCTAssertNil(SSHFSProcesses.remoteRoot(arguments: args, mountPoint: "/Users/me/mnt/other"))
    }

    // MARK: through LinkResolver, on files

    func testBrokenRemoteLinkResolvesInsideTheMount() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let root = sandbox.root.path(percentEncoded: false)
        try sandbox.createFile(".toolbox/bin/real-tool")
        try sandbox.createDirectory("projects/app")
        let fileLink = try sandbox.createSymlink("tool", target: "/macx-remote-home/macx-remote-user/.toolbox/bin/real-tool")
        let folderLink = try sandbox.createSymlink("app", target: "/macx-remote-home/macx-remote-user/projects/app")
        let outside = try sandbox.createSymlink("ws", target: "/workplace-macx-missing/macx-remote-user")
        let remapper = Remapper(mountOf: { _ in RemoteMount(mountPoint: root, remoteRoot: "/local/macx-remote-home/macx-remote-user") },
                                exists: Remapper.lstatExists)
        let remap: @Sendable (String, String) -> String? = { remapper.remap(link: $0, destination: $1) }
        let resolve = { @Sendable (url: URL, remap: @escaping @Sendable (String, String) -> String?) async -> LinkTarget in
            await Task.detached { LinkResolver.resolve(url, remap: remap) }.value   // lane-only: never on main
        }
        let expected = { (relative: String) in RemoteMount.normalized(sandbox.root.appending(path: relative).path(percentEncoded: false)) }

        guard case .document(let file) = await resolve(fileLink, remap) else { return XCTFail("file link") }
        XCTAssertEqual(RemoteMount.normalized(file.path(percentEncoded: false)), expected(".toolbox/bin/real-tool"))
        guard case .folder(let folder) = await resolve(folderLink, remap) else { return XCTFail("folder link") }
        XCTAssertEqual(RemoteMount.normalized(folder.path(percentEncoded: false)), expected("projects/app"))
        let outsideTarget = await resolve(outside, remap)
        XCTAssertEqual(outsideTarget, .broken)
        let off = await resolve(fileLink, { _, _ in nil })
        XCTAssertEqual(off, .broken, "off: unchanged behavior")
    }

    func testLocalVolumesAreNeverRemapped() throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.createFile("x")
        let link = try sandbox.createSymlink("l", target: "/macx-remote-home/macx-remote-user/x")
        // The real detector: the sandbox is on the boot volume, not a FUSE mount.
        let remapper = Remapper(mountOf: RemoteMount.detect, exists: Remapper.lstatExists)
        XCTAssertNil(remapper.remap(link: link.path(percentEncoded: false), destination: "/macx-remote-home/macx-remote-user/x"))
    }

    func testDisabledByDefault() {
        XCTAssertNil(RemoteLinkRemap.remap(link: "/tmp/l", destination: "/macx-remote-home/macx-remote-user/x"))
    }

    @MainActor func testSettingPersistsAndDrivesTheSwitch() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage, home: URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory))
        XCTAssertFalse(s.experimentalRemoteLinkRemap)
        XCTAssertFalse(RemoteLinkRemap.isEnabled)
        s.experimentalRemoteLinkRemap = true
        defer { RemoteLinkRemap.setEnabled(false) }
        XCTAssertTrue(RemoteLinkRemap.isEnabled)
        XCTAssertTrue(Settings(storage: storage, home: s.home).experimentalRemoteLinkRemap)
        s.experimentalRemoteLinkRemap = false
        XCTAssertFalse(RemoteLinkRemap.isEnabled)
    }
}
