import Foundation
import MacxFS

enum CopyJob {
    /// Copy (destination == source parent → duplicate naming) and Duplicate.
    static func run(_ ctx: JobContext, sources: [URL], destination: URL, duplicate: Bool) async {
        guard let plan = await ctx.plan(sources: sources, destination: destination, mode: .copy) else { return }
        await copy(ctx, plan, to: destination, duplicate: duplicate)
    }

    /// Duplicate of items from several folders: one plan per parent, all planned first so the job's totals cover
    /// every group.
    static func duplicate(_ ctx: JobContext, _ urls: [URL]) async {
        let groups = Dictionary(grouping: urls) { $0.deletingLastPathComponent().standardizedFileURL.path }
        var plans: [(JobPlan, URL)] = []
        for parent in groups.keys.sorted() {
            let destination = URL(filePath: parent, directoryHint: .isDirectory)
            guard let plan = await ctx.plan(sources: groups[parent]!, destination: destination, mode: .copy) else { return }
            plans.append((plan, destination))
        }
        ctx.setTotals(items: plans.reduce(0) { $0 + $1.0.totalItems },
                      bytes: plans.reduce(Int64(0)) { $0 + $1.0.totalBytes })
        for (plan, destination) in plans where !ctx.control.isCancelled {
            await copy(ctx, plan, to: destination, duplicate: true)
        }
    }

    static func copy(_ ctx: JobContext, _ plan: JobPlan, to destination: URL, duplicate: Bool) async {
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
    /// whatever landed is recorded so undo can remove it). Only a root this copy created is recorded, never
    /// an item another process put at `target`.
    @discardableResult
    static func copyItem(_ ctx: JobContext, _ item: PlanItem, to target: URL) async -> TreeOutcome {
        let (outcome, root) = await TreeCopier.copyTracked(ctx, item, to: target)
        guard outcome != .skipped, let root else { return outcome }
        if let id = (try? await ctx.onLane({ _ in FileIdentity.of(path: target.path) })) ?? nil, id == root {
            ctx.record(.created(target, id))
            ctx.landed(target)
        }
        return outcome
    }
}
