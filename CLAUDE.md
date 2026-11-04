# MacExplorer — Claude instructions

## New features: always work in a git worktree

Multiple agents may be working on this repo at the same time. When asked to build a new feature (or any non-trivial change), you MUST NOT edit files in the primary checkout (`/Users/roniburd/dev/macExplorer`). Instead:

1. Before touching any code, create an isolated worktree with the `EnterWorktree` tool (or, if unavailable, `git worktree add .claude/worktrees/<feature-slug> -b feature/<feature-slug>` and `cd` into it).
   - Branch off the current branch unless told otherwise.
   - Use a short kebab-case slug describing the feature.
2. Do all edits, builds (`swift build`), and tests (`swift test`) inside the worktree. Each worktree has its own `.build/`, so builds don't collide with other agents.
3. Commit work on the feature branch inside the worktree.
4. When done, report the worktree path and branch name. Do not merge into the base branch, delete the worktree, or push unless the user asks.

Small fixes, questions, and doc tweaks the user explicitly wants done in place are exempt.
