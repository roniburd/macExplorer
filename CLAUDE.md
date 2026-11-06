# MacExplorer — Claude instructions

## New features: always work in a git worktree

Multiple agents may be working on this repo at the same time. When asked to build a new feature (or any non-trivial change), you MUST NOT edit files in the primary checkout (`/Users/roniburd/dev/macExplorer`). Instead:

1. Before touching any code, create an isolated worktree with the `EnterWorktree` tool (or, if unavailable, `git worktree add .claude/worktrees/<feature-slug> -b feature/<feature-slug>` and `cd` into it).
   - Branch off the current branch unless told otherwise.
   - Use a short kebab-case slug describing the feature.
2. Do all edits, builds (`swift build`), and tests (`swift test --parallel`) inside the worktree. Each worktree has its own `.build/`, so builds don't collide with other agents.
3. Commit work on the feature branch inside the worktree.
4. When done, report the worktree path and branch name. Do not merge into the base branch, delete the worktree, or push unless the user asks.

Small fixes, questions, and doc tweaks the user explicitly wants done in place are exempt.

## Run things in parallel whenever possible

- Full test runs: always `swift test --parallel` (as `scripts/verify-phase1.sh`, CI and the README do). It takes about 2 minutes; serial `swift test` takes 6–7. Use plain `swift test --filter <Class or Class/test>` only for a targeted run of a few tests.
- Don't run the full suite repeatedly while iterating: run the affected test classes with `--filter`, and do one `swift test --parallel` at the end.
- Independent work (separate tasks, reviews, research, checks) runs concurrently: several tool calls or subagents in one message, or `parallel()`/`pipeline()` in workflows, never one after another.
- Exception: UI scenarios (`scripts/ui-scenarios.sh`, the UI gate of `verify-phase1.sh`) need keyboard focus, so only one can run on the Mac at a time, across all worktrees. Wait until no other `macExplorer-scenarios.app` is running.
