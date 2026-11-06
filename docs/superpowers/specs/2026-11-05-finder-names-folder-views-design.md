# Finder-compatible display names and per-folder views — design

Date: 2026-11-05 · Branch: `worktree-finder-names-folder-views`

## Intent

MacExplorer should show items the way Finder does, using Finder's own metadata, and extend it where useful:

- Hide extensions Finder hides (the per-file "hide extension" Finder flag), and always hide `.app` on application
  bundles. A MacExplorer-only "Show all filename extensions" setting (off by default) shows every extension.
- Show Finder's localized display names (apps and system folders in the user's language).
- Remember view settings per folder (view mode, icon size, sort, columns, density). Folders never configured in
  MacExplorer start from what Finder recorded in that folder's `.DS_Store`; app folders default to Large Icons.

Success: `/Applications` lists "Safari", "Safari Technology Preview" (in that order) as large icons; changing the view
in one folder doesn't change others; nothing MacExplorer does ever writes a `.DS_Store`.

Decisions made with the owner: read `.DS_Store`, store our own overrides, never write `.DS_Store`; our own
show-all-extensions toggle (Finder's `AppleShowAllExtensions` is ignored); localized names included; all five view
settings are per-folder.

## 1. Display names

### Rule (FSKit, pure)

`DisplayName.make(name:kind:flags:localizedStem:showAllExtensions:) -> String`

- `ext` = `fileExtensionRange` of the name (so `.zshrc`, `name.` have none).
- `hide` = `!showAllExtensions && ext != nil && (flags.contains(.extensionHidden) || (kind == .package && ext ==
  "app" case-insensitively))`.
- `stem` = `localizedStem ?? name-without-extension` (when `ext == nil`, the whole name).
- result = `hide ? stem : stem + "." + ext` (when no localized stem and not hidden, this is exactly `name`).
- Never returns an empty string: if the stem would be empty, the real name is returned.

`.extensionHidden` is already read in bulk (`ATTR_CMN_FNDRINFO`, `RecordConverter.kIsExtensionHidden`), so the rule
costs no I/O.

### Localized names

`EntryStore` gets a `localizedStems: [UInt32: String]` side table (like `errors`): remapped by `remove`, cleared for an
index by `upsert`, copied with the store. `EntryStore.displayName(_:showAllExtensions:)` applies the rule.

Candidates (bounded, cheap to find without I/O): packages with extension `app`; directories named `*.localized`;
every directory whose parent is `/`, `/System`, `/Users`, the user's home or `~/Library`. For each candidate, a
resolver in Core (`LocalizedNameResolver`, off main, cancellable) reads `URLResourceValues.localizedName`, strips the
real extension (and `.localized`) and keeps the result only if it differs from the real stem. It runs after the initial
listing completes (and for upserted candidates after a watcher patch), so the first frame never waits for it. Results
are applied in one worker call that replaces those rows' name/search keys and re-sorts (one `.changes` event).
The resolver never runs on non-local volumes.

### Where each name is used

| Display name | Real name |
|---|---|
| Name column, icon labels, sort by name, filter/search keys, type-to-select, sizing columns to fit, status-bar/selection text | rename (inline field edits the full real name), copy/paste, drag, the address bar, `Extension` column, Properties, file operations, identity, `row(named:)` |

### Sort keys

`FolderWorker.Keys` are built from display names: `SortKeys.nameKeys`/`searchKeys` take a `showAllExtensions` flag
and read `store.displayName`. `ViewQuery` gains `showAllExtensions: Bool`; the worker records the flag its keys were
built with and rebuilds name/search keys when a query arrives with a different one. Extension keys keep using the real
name. A Settings observer in `BrowserSession` pushes the toggle into every session's query (as `showHidden` does).

## 2. Per-folder view memory

> **Merged with Phase 2 (2026-11-06).** The store below became Phase 2's (P2-07/P2-08): records are keyed by volume
> UUID + fileID on `idStable` volumes (path elsewhere and while the identity probe is pending), so a renamed or moved
> folder keeps its view; they hold the fields below plus Group by and "Calculate Folder Sizes", and `viewMode`
> includes Columns (Finder's `clmv` now maps to it; `label`, `dateLastOpened` and `comments` map to the Phase 2
> columns). The resolved type is `FolderViewState`; sessions change it with `updateViewState`. Persistence moved to
> the settings storage (`folderViews.v3`, compact text); an existing `folder-views.json` is imported once and left
> in place. Finder's `.DS_Store` is read on a lane under no-materialization. Phase 2's "Apply to All Folders…" is
> kept next to "Use as Default for All Folders" (it also forgets every folder's own record).

### Data (Core)

```swift
public struct FolderViewSettings: Codable, Equatable, Sendable {   // every field optional = "not set here"
    var viewMode: ViewMode?; var iconSize: IconSize?; var density: Density?
    var sort: SortDescriptor?; var columns: [ColumnSetting]?
}
public struct ResolvedFolderView: Equatable, Sendable {            // every field set
    var viewMode: ViewMode; var iconSize: IconSize; var density: Density
    var sort: SortDescriptor; var columns: [ColumnSetting]
}
```

`FolderViewStore` (@MainActor): `[standardized path: Entry(settings, lastUsed)]`, persisted as JSON at
`~/Library/Application Support/MacExplorer/FolderViews.json` (directory injectable for tests; written debounced ~1 s
and on app terminate; a corrupt file is renamed `.corrupt` and ignored). Evicts least-recently-used beyond 5,000
folders. Paths, not file IDs: a moved folder loses its view (Finder behaves the same for `.DS_Store` stored in the
parent).

### Resolution (field by field, first that has the field wins)

1. MacExplorer's entry for the folder.
2. Finder's `.DS_Store` view for the folder (§3), local volumes only, read off main.
3. Built-in rule: `/Applications`, `/System/Applications`, `~/Applications` (and their `Utilities`) → Icons, Large.
4. Global defaults: the existing `Settings.viewMode/iconSize/density/sort/columns`.

`FolderViewResolver.resolve(path, stored:, finder:, globals:) -> ResolvedFolderView` is pure and unit tested.

### Runtime

`BrowserSession` owns an `@Observable FolderViewState` (`resolved: ResolvedFolderView`). On `open(url)` it resolves
synchronously from 1, 3, 4; if the folder has no MacExplorer entry it starts a `.DS_Store` read (cached in memory per
path, 1 MB cap, ~250 ms deadline) and re-resolves when it arrives (only fields the user hasn't changed since open).
`session.viewMode` becomes a computed view of `resolved.viewMode`. The FolderModel is created with the resolved sort.

Details/Icons controllers read `iconSize`, `density`, `columns` from the session's view state instead of `Settings`;
menu/command-bar check marks (`ContextMenuBuilder`, `CommandStateBuilder`) do too.

Every view change (view mode switcher, Icon Size, Density, sort header/menu, column show/hide/move/resize) goes through
`session.updateView { … }`, which updates the state and writes **only that field** to the folder's
`FolderViewStore` entry. It no longer writes the global `Settings` fields.

New commands (View menu and context-menu View submenu):

- **Use as Default for All Folders** — copies the current resolved view into the global `Settings` fields.
- **Reset View for This Folder** — removes the folder's MacExplorer entry and re-resolves (falls back to Finder → rule
  → defaults).

The Settings window's density picker keeps editing the global default.

## 3. `.DS_Store` reader (Core, read-only)

`DSStore.parse(_ data: Data) -> [String: [String: DSValue]]?` (filename → structure code → value) implementing the
documented reverse-engineered "Bud1" buddy-allocator B-tree:

- header: `00000001 'Bud1'`, root offset, size, offset copy (must match); offsets are +4.
- root block: block-address table (`addr & ~0x1f` offset, `1 << (addr & 0x1f)` size), table of contents (`DSDB`),
  free lists (ignored).
- `DSDB`: root node, levels, record count, node count, page size; nodes are leaf (`P == 0`) or internal.
- records: UTF-16BE filename, 4-char code, type `long`/`shor`/`bool`/`blob`/`type`/`ustr`/`comp`/`dutc`.

Every read is bounds-checked; recursion depth ≤ 32 and visited-block set (no cycles); record count ≤ 100k; file ≤ 1 MB.
Any violation → `nil` (treated as "no Finder data"). Never writes, never creates files.

`FinderFolderView.read(folder:) -> FolderViewSettings?` looks at `folder/.DS_Store` record `"."`, then the parent's
`.DS_Store` record `<folder name>`, and maps:

- `vstl` (`type`): `icnv` → icons, `Nlsv` → details; `clmv`, `Flwv`, `glyv` → not set.
- `icvp` (binary plist blob) `iconSize`: ≤ 48 → small, ≤ 96 → medium, else large.
- `lsvp`/`lsvP` (binary plist blob): `sortColumn` (`name`, `dateModified`, `dateCreated`, `size`, `kind`) and that
  column's `ascending` → sort; `columns` (dictionary keyed by column name, or legacy array with `identifier`) →
  visibility and width for our five Finder-known columns (`name` always visible; `fileExtension` keeps the global
  setting); `iconSize` 16/20/32 → density compact/regular/comfortable is **not** mapped (different meaning).
  `icvp`'s `arrangeBy` is not mapped (icon view sorting is ours).

## 4. Testing

- `DisplayNameTests`: hide flag, `.app` packages (and `.APP`), `.app` folder that is not a package, dotfiles,
  trailing dot, show-all toggle, localized stem with/without hidden extension, empty-stem fallback.
- `EntryStore` side-table remap on `remove`/`upsert`; `SortKeys` with display names (`Safari` before
  `Safari Technology Preview`); worker rebuilds keys when `showAllExtensions` flips; localized-names apply re-sorts.
- `DSStoreTests`: a test-only `DSStoreWriter` builds files (single leaf, multi-level internal nodes, all value types);
  parse round-trips; truncated/corrupt/cyclic/oversized inputs return nil without crashing (byte-flip fuzz loop).
  One manual check (not committed) parses real `.DS_Store` files on this Mac read-only.
- `FolderViewResolverTests`, `FolderViewStoreTests` (persistence, eviction, corrupt file) in a temp directory.
- UI/scenario: a sandbox folder `Apps/` holding a synthetic `Tool.app` bundle shows "Tool"; changing icon size in one
  folder leaves another unchanged; reset restores.
- All file-system tests use directories the tests create (`$TMPDIR/macx-*`). Bench budgets (`macx-bench`) re-checked.

## Implementation order

1. Display names: `DisplayName`, store side table, keys, `ViewQuery.showAllExtensions`, setting + UI usage.
2. Localized names: resolver + worker apply.
3. `.DS_Store` parser + Finder view mapping.
4. Per-folder store, resolver, session view state, UI wiring, commands.

Each step builds, passes `swift test`, and is committed separately.
