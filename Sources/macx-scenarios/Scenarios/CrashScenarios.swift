import Core
import Darwin
import Foundation

enum CrashScenarios {
    static let all: [CoreScenario] = [
        CoreScenario("crash.killDuringCrossVolumeMove", requires: .helperProcess, timeout: .seconds(120)) { ctx in
            try await killHelperAndRecover(ctx, mode: "copy")
        },
        CoreScenario("crash.killDuringReplace", requires: .helperProcess, timeout: .seconds(120)) { ctx in
            try await killHelperAndRecover(ctx, mode: "replace")
        },
    ]

    /// Starts `macx-scenarios crash-helper`, which blocks at the fault point; SIGKILLs it; runs LaunchRecovery.
    @MainActor
    static func killHelperAndRecover(_ ctx: ScenarioContext, mode: String) async throws {
        let helper = try ctx.requireHelper()
        let image = try await ctx.image("crash-\(mode)", .apfs, sizeMB: 64)
        let source = ctx.file("big.bin", bytes: 8 << 20)
        let finalURL = image.mountPoint.appending(path: "big.bin")
        if mode == "replace" { ctx.file(at: finalURL, "old") }
        let trash = ctx.dir(at: image.mountPoint.appending(path: ".macx-trash"))
        let journalURL = ctx.path("helper-journal.json")
        let ready = ctx.path("helper-ready")
        let process = try ctx.launchHelper(helper, [
            "crash-helper", "--mode", mode, "--source", source.path, "--destination", image.mountPoint.path,
            "--journal", journalURL.path, "--trash", trash.path, "--ready", ready.path,
        ])
        try await ctx.waitUntil("helper reaches the fault point", timeout: .seconds(60)) { ctx.exists(ready) || !process.isRunning }
        try ctx.expect(process.isRunning, "helper exited early with status \(process.terminationStatus)")
        kill(process.processIdentifier, SIGKILL)
        try await ctx.waitUntil("helper is gone", timeout: .seconds(10)) { !process.isRunning }

        let report = await LaunchRecovery.run(journal: Journal(fileURL: journalURL), lanes: ctx.env.lanes)
        try ctx.expectEqual(ctx.size(source), Int64(8 << 20), "source intact after the kill")
        try ctx.expect(CrossVolumeScenarios.noPartials(ctx, image.mountPoint),
                       "partial copy removed by launch recovery: \(ctx.entries(image.mountPoint))")
        try ctx.expect(!report.incompleteJobs.isEmpty, "the incomplete job is reported to the user")
        if mode == "replace" {
            try ctx.expect(!report.restoredDestinations.isEmpty, "trashed destination restored: \(report)")
            try ctx.expectEqual(ctx.size(finalURL), 3, "original destination content back in place")
        } else {
            try ctx.expect(!report.removedPartials.isEmpty, "partial listed as removed: \(report)")
            try ctx.expect(!ctx.exists(finalURL), "nothing landed under the final name")
        }
    }
}
