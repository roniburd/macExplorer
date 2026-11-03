import Foundation
import MacxFS

enum CopyJob {
    /// Copy (destination == source parent → duplicate naming) and Duplicate.
    static func run(_ ctx: JobContext, sources: [URL], destination: URL, duplicate: Bool) async {
        guard let plan = await ctx.plan(sources: sources, destination: destination, mode: .copy) else { return }
        var pending = plan.topLevelConflicts
        var first = true
        for item in plan.items {
            guard await ctx.checkpoint() else { break }
            let src = item.source
            let isDir = item.info.isDirectory
            let sameParent = src.deletingLastPathComponent().standardizedFileURL.path == destination.standardizedFileURL.path
            var name = src.lastPathComponent
            if duplicate || sameParent {
                name = (try? await ctx.onLane { _ in
                    NameGenerator.copyName(src.lastPathComponent, isDirectory: isDir) { PosixFS.exists(destination.appending(path: $0).path) }
                }) ?? name
            } else if (try? await ctx.onLane({ _ in PosixFS.exists(destination.appending(path: src.lastPathComponent).path) })) == true {
                let target = destination.appending(path: name)
                guard let action = await ConflictExecutor.decide(ctx, source: src, target: target, pending: pending, destinationDir: destination) else { break }
                pending.removeAll { $0 == src }
                switch action {
                case .skip:
                    ctx.skip(src, reason: nil)
                    continue
                case .keepBoth:
                    name = (try? await ctx.onLane { _ in
                        NameGenerator.keepBoth(src.lastPathComponent, isDirectory: isDir) { PosixFS.exists(destination.appending(path: $0).path) }
                    }) ?? name
                case .replace, .merge:
                    let r = await ConflictExecutor.execute(ctx, action: action, item: item, destinationDir: destination, name: name,
                                                           operation: .copy, renameExcl: plan.capabilities.renameExcl)
                    if r == .cancelled { return }
                    continue
                }
            }
            _ = await copyItem(ctx, item, to: destination.appending(path: name))
            if first { first = false; ctx.fault(.afterFirstItem) }
        }
    }

    /// Copies one top-level item to `target` and records it (also when cancelled or partly skipped:
    /// whatever landed is recorded so undo can remove it).
    @discardableResult
    static func copyItem(_ ctx: JobContext, _ item: PlanItem, to target: URL) async -> TreeOutcome {
        let outcome = await TreeCopier.copy(ctx, item, to: target)
        guard outcome != .skipped else { return outcome }
        if let id = (try? await ctx.onLane({ _ in FileIdentity.of(path: target.path) })) ?? nil {
            ctx.record(.created(target, id))
            ctx.landed(target)
        }
        return outcome
    }
}
