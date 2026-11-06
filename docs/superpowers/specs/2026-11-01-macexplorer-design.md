# macExplorer — Design Spec

- **Date:** 2026-11-01
- **Status:** Draft for review
- **Research:** `docs/research/*.md` (stack, platform, perf, explorer, finder, ux, critique)

## 1. Intent

**What the user stated**
- A native macOS file manager for **people who know Windows File Explorer and now use a Mac**.
- It looks and feels at home on macOS 26: a Finder-style sidebar with Favorites and Locations, Liquid Glass chrome.
- It behaves like Explorer: an editable address bar, a folder tree, a command bar, Explorer keyboard conventions, cut/paste, right-drag menus, a Properties window, and Open With / choose default app.
- **It must be extremely fast.**
- It ships **outside the Mac App Store**: open source on GitHub, a Developer ID–signed and notarized build, installable via `brew install --cask`, in the same way as Marta and ForkLift.
- Minimum OS is **macOS 26 (Tahoe)**.

**Success criteria**
1. A Windows user can navigate, copy, move, rename, delete and inspect files using Explorer muscle memory, without reading docs.
2. Folders open "instantly", meaning within the performance budgets in §4.4, including folders with 100k entries.
3. No file operation can lose data, whether through a crash, a cancel, a quit or an error mid-move.
4. It feels native: real AppKit controls, Liquid Glass, VoiceOver, drag & drop to and from Finder and other apps.

**Non-goals**
- Replacing Finder as the system file viewer. macOS has no public API for this, so "Show in Finder" in other apps still opens Finder. The README will document this.
- Mac App Store distribution and sandboxing.
- Supporting macOS versions older than 26.
- Windows-only concepts with no macOS equivalent: libraries, Previous Versions, NTFS security tabs, drive letters.

## 2. Roadmap

Each phase gets its own implementation plan. Phase 1 is specified in full here. Phases 2–4 are specified at feature level and will be refined into their own detailed specs when they start.

| Phase | Scope |
|---|---|
| **1 — Core** | Window, unified sidebar and tree, breadcrumb/editable address bar, command bar, **Details view** and **Icons view**, Explorer key map, context menus, clipboard with cut semantics, drag & drop including right-drag, file-operation engine (queue, progress, conflicts, errors, undo, crash-safe moves), Open / Open With / default app, Properties window, volumes and eject, status bar, live updates, hidden-files toggle, filter-in-folder search, state restoration, privacy onboarding, local build and test, benchmarks |
| **2 — Views & Tabs** | Tabs, per-folder view settings, Group by, Quick Look (Space), folder sizes in the list (on demand), more columns (Tags, Last Opened, Permissions, Owner, Path), copy-path variants, thumbnails in Icons view, Columns (Miller) view |
| **3 — Preview & Search** | Preview pane (right split item), full search (this folder, subfolders or the whole Mac; by name or by contents) using Spotlight plus a fallback crawler, search filters (kind, date, size), saved searches |
| **4 — Power** | Custom icons, tags editing and sidebar Tags section, compress and extract, batch rename, dual-pane mode, "Authenticate…" for privileged operations, ACL editing, network/SMB browsing and connect, Sparkle auto-update, command palette, keymap customization |
| **Release track** (parallel, starts in Phase 1) | GitHub Actions build, test, bench, sign, notarize and staple, then GitHub Releases and a Homebrew tap cask. Submission to homebrew-cask once the app is stable. |

## 3. Technology decision

- **Swift 6.x** with strict concurrency, **AppKit-first**. SwiftUI is used only for low-volume windows: Properties, Settings, the conflict dialog and the onboarding sheet.
- **SwiftPM** is the source of truth.
  - `swift build` plus `scripts/bundle.sh` produce `macExplorer.app`.
  - With the Command Line Tools only, the app is built with no XIBs or asset catalogs, and the icon is a prebuilt `.icns`.
  - Full Xcode is used for Instruments, XCUITest and notarization once it is installed.
- **Why not SwiftUI for lists:** `Table`, `List` and `OutlineGroup` diff identity across every row and stall at 100k rows. They also lack file-promise drags, drop-on-row control, type-select and lazy tree expansion.
- **Why not Rust:** directory listing is limited by syscalls, not the language, and Swift calls `getattrlistbulk` directly. A Rust core would add FFI, two toolchains and per-row string marshalling for no throughput gain. It can be revisited for a Phase 3 content index if that is ever needed.

## 4. Architecture

### 4.1 Package layout

```
macExplorer/
  Package.swift
  Sources/
    CFSKit/            C target: getattrlistbulk wrapper + record parser helpers
    FSKit/             Swift: DirectoryReader, IOLane, EntryStore, SortKeys, Volumes
    Core/              FolderModel, Watcher, FileOps, Clipboard, LaunchServices, Properties, Settings
    UI/                AppKit views/controllers
    App/               @main, menus, SwiftUI windows, Info.plist resources
    macx-bench/        CLI benchmark executable
  Tests/
    FSKitTests/  CoreTests/  UITests/ (XCUITest, Xcode only)
  scripts/ bundle.sh  make-fixtures.sh  release/*.sh
  Resources/ AppIcon.icns
```

Dependency direction: `App → UI → Core → FSKit → CFSKit`. Nothing in `FSKit` or `Core` imports AppKit, except `Core/LaunchServices`, which uses `NSWorkspace` behind a protocol so tests can substitute a fake.

### 4.2 FSKit — enumeration and storage

- **I/O threading.** Actors (`DirectoryReader`, `FileOpQueue`, the `FolderModel` worker) hold only state and coordination and never make a blocking file-system call. Every blocking call runs on an **I/O lane**: a dedicated `Thread` with a serial work queue, never the Swift cooperative pool or a global GCD queue. Blocking calls include `getattrlistbulk`, `readdir`/`fstatat`, `open`/`close`, `fts`, `statfs`, `getattrlist`, `copyfile`, `removefile`, `rename`, resource-value lookups and `NSWorkspace` icon/LaunchServices lookups against paths. Results return through `withCheckedContinuation` or `AsyncStream`.
  - Each volume has at most **2 healthy read lanes**. FileOps jobs get separate lanes (at most 2 per volume, same watchdog rules), so a long copy never delays listing.
  - **Watchdog:** if work on a lane makes no progress for 2 s, the lane is marked **poisoned**, removed from the pool and never reused; its thread may stay blocked until the volume unmounts and is never joined. The next read on that volume (Retry, tree expansion, Watcher re-read) gets a freshly created lane.
  - At most 4 poisoned lanes per volume. Past that cap the whole volume is marked unresponsive and no further reads are issued until it is remounted or reappears.
  - Each read carries a generation ID. A late result is applied only if its generation is still current (§4.3).
  - **TCC prompts:** the first access to Desktop, Documents, Downloads, removable or network volumes can block while macOS shows its consent prompt. Until the app has a recorded outcome for that location (stored in Settings after the first success or `EPERM`), the watchdog shows "Waiting for macOS permission…" instead of `.unresponsive`, and the lane is not poisoned.
- **Materialization policy.** Background work that must never download dataless iCloud/File Provider content runs inside `withNoMaterialization { … }`, which calls `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)`, does the synchronous work on the lane thread and restores the previous policy, with no suspension point in between. This covers the Properties recursive count and xattr/`MDItem` reads, Tier 1 icon probes (§4.4), Watcher re-reads of non-visible tree nodes, Phase 2 folder-size scans and thumbnails, the Phase 3 crawler, and the plan-phase enumeration of trash, delete and `chmodRecursive` jobs (a dataless folder's contents count as unknown). The user-initiated listing of the folder being opened, and copy/move jobs (which need the data), keep the default policy. Dataless items (`SF_DATALESS`) are listed with a cloud badge and never opened by the reader.
- **`DirectoryReader`** is an actor, one per volume, dispatching reads to that volume's lanes.
  - **Primary path: `getattrlistbulk`**, with a 256 KB buffer and options `FSOPT_ATTR_CMN_EXTENDED` (no `FSOPT_PACK_INVAL_ATTRS`), requesting:
    - common: `ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID | ATTR_CMN_MODTIME | ATTR_CMN_CRTIME | ATTR_CMN_FLAGS | ATTR_CMN_ACCESSMASK | ATTR_CMN_FNDRINFO`;
    - file: `ATTR_FILE_DATALENGTH | ATTR_FILE_ALLOCSIZE`;
    - dir: `ATTR_DIR_ENTRYCOUNT`;
    - extended common (forkattr): `ATTR_CMNEXT_LINKID`.
  - **Parser rules:**
    1. Each record is walked by its own length; no fixed layout is assumed.
    2. The parser reads the `attribute_set_t` first, then the `uint32` error field if the returned set has `ATTR_CMN_ERROR`, then the remaining fields in the kernel's fixed bit order, **only those present in the returned set**. File attributes appear only for non-directories, `ATTR_DIR_ENTRYCOUNT` only for directories.
    3. An entry with a non-zero error is kept as a degraded row (name plus whatever attributes are valid, errno in a side table). It never fails the batch or the folder.
    4. Out-of-bounds offsets or lengths drop the record, not the batch.
  - **Fallback: `readdir` + `fstatat`.** It is used when `getattrlistbulk` returns `ENOTSUP`/`EINVAL`.
  - **Streaming:** a `Batch` (Sendable) is emitted every 2,000 entries or every 8 ms, whichever comes first.
- **`EntryStore`** uses a struct-of-arrays layout:

  ```swift
  struct Entry {            // ~56 bytes
    var rowID: UInt64       // ATTR_CMNEXT_LINKID, else fileID (identity, §4.3)
    var fileID: UInt64      // inode, shown in Properties
    var size: Int64         // logical
    var allocSize: Int64
    var mtime: Int64        // ns
    var ctime: Int64        // creation, ns
    var nameOffset: UInt32
    var nameLen: UInt16
    var kind: Kind          // UInt8: file, dir, symlink, package, alias, other
    var flags: UInt32       // hidden, locked, dataless, customIcon, degraded, ...
    var typeIndex: UInt16   // interned UTType table
  }
  ```

  - Names live in one UTF-8 arena. A `String` is created only for visible cells and for operations.
  - The display order is a `[UInt32]` permutation, so re-sorting never moves entries.
  - "Hidden" means the name starts with `.` or `UF_HIDDEN` is set.
- **`SortKeys`** builds a byte key per entry off the main thread, using `concurrentPerform`:
  1. **Name key:** `CFStringFold` with case-, diacritic- and width-insensitive options and a fixed locale, encoded as UTF-8. ICU `ucol_*` is not used (no public SDK headers).
  2. **Digit runs:** leading zeros stripped, encoded as a length byte followed by the digits, so no padding width is needed and runs up to 255 digits compare numerically. Equal values tie-break on the original run length.
  3. **Layout:** kind-prefix byte (folders first), folded key, `0x00`, then the unfolded NFC name bytes as tie-break, so `e` < `é` < `f`.
  4. **Kind key:** whenever the interned UTType table grows, each `typeIndex` gets a `UInt16` rank from sorting the table's `localizedDescription` values with `localizedStandardCompare`. The key is that rank followed by the name key.
  5. **Filter-in-folder search** (§5.2) folds the query and the names with the same `CFStringFold` options, without digit-run encoding or the kind prefix, and does a byte substring search, off main.

  Sorting is then a memcmp over the index. A golden test (§9) asserts the result matches `localizedStandardCompare` on a corpus that includes accented Latin, Greek, Cyrillic, CJK and long digit runs. Any known divergence is listed in the test file with its reason. Date and size sorts use integer keys, with name as the tie-breaker.
- **Types:** the `UTType` for each extension is computed once and cached in an interned table. Packages are detected from `UTType.conforms(to: .package)` together with the directory kind.
- **`Volumes`:**
  - A list of mounted volumes from `FileManager.mountedVolumeURLs` with resource values, read on a lane.
  - Updated live by observing **`NSWorkspace.shared.notificationCenter`** (not `NotificationCenter.default`) for `didMountNotification`, `willUnmountNotification`, `didUnmountNotification` and `didRenameVolumeNotification`; the volume comes from `userInfo[NSWorkspace.volumeURLUserInfoKey]`.
  - Per volume, `getattrlist(ATTR_VOL_CAPABILITIES)` is read once and cached: `idStable` (`VOL_CAP_FMT_PERSISTENTOBJECTIDS`), `renameExcl` (`VOL_CAP_INT_RENAME_EXCL`), `clone` (`VOL_CAP_INT_CLONE`), plus `volumeSupportsCaseSensitiveNamesKey`.
  - A main-actor table of mount-point paths and volume IDs is kept for in-memory lookups (drag validation, §5.6).
  - **`Volumes.release(volume)`** runs on `willUnmount` and before our own eject. It cancels in-flight reads, size scans and crawler tasks on the volume and waits up to 1 s for their fds to close; stops Watcher streams and vnode sources on it; pauses queued FileOps jobs that touch it (a running job asks the user to cancel or wait); and moves every window showing the volume to Home.

### 4.3 Core

- **`FolderModel`** (one per open folder per window) is the snapshot the UI observes. It has a `@MainActor` facade over a background worker.
  - It holds the `EntryStore`, a state machine, the selection by identity (below), and the sort descriptor.
  - It publishes `Change` sets (`insert(rows)`, `remove(rows)`, `reload(rows)`, `move(from:to:)`, `reset`) to views. A Change set touching more than ~1,000 rows, or a `reset`, is applied with `reloadData` and no animation.
- **State machine:** `loading → partial → complete | error(Reason) | unresponsive`.
  - `Reason = .notFound | .notADirectory | .permissionPOSIX (EACCES) | .permissionTCC (EPERM) | .volumeGone | .other(errno)`.
  - Re-reads never return a populated model to `.loading`. Watcher events, rescans, F5/⌘R and FileOps posts keep the rows, stay `.complete` (or `.partial` while streaming) and apply a diff as a Change set.
  - `.unresponsive` is not terminal: if the stalled read makes progress before Retry, the model returns to `.partial`. Retry from `.unresponsive` or `.error` goes to `.loading` with a new generation, and late results from the old one are discarded.
  - If the displayed folder is removed or renamed away, the window navigates to the nearest existing ancestor and shows a non-modal banner ("'X' was moved or deleted"). If its volume unmounts, it goes to Home. Triggers: `RootChanged`/`ItemRemoved` on the folder itself, or `didUnmountNotification`.
- **Ownership & concurrency.**
  1. The `@MainActor` `FolderModel` is the only owner and mutator of the `EntryStore`, a value-type struct of arrays (entries, name arena, permutation, identity→index map). `DirectoryReader` sends Sendable `Batch`es, which main appends in O(batch).
  2. Sorting and diffing take an immutable copy-on-write snapshot and run off main; they return only a new `[UInt32]` permutation or a Change set plus the entries to add or remove, which main applies. A result tagged with an older generation is dropped. No `@unchecked Sendable` is needed.
  3. While loading, the store is not snapshotted per batch; the worker sorts from its own copy of the batches' sort keys (below).
- **Loading-state presentation.**
  1. During `loading`/`partial`, main appends each `Batch` to the `EntryStore`, and the worker, which receives the same batches, sorts each one and merges it into a sorted permutation that it owns. Main receives a copy of that permutation at most one update per display frame, as a single `reset` applied with `reloadData` and no animation. Incremental `insert(rows)` is not used while loading. The first batch is painted sorted within itself (the < 50 ms budget).
  2. At `complete`, one final `reset` with the full sorted permutation (the < 250 ms budget).
  3. Selection is kept by identity. The top-visible row's identity is the scroll anchor and is restored after each reset; if the user hasn't scrolled, the view stays at the top.
  4. After `complete`, only incremental Change sets are published.
- **Row identity.**
  - On `idStable` volumes the identity is `rowID` (`ATTR_CMNEXT_LINKID`, falling back to `fileID`). On other volumes (msdosfs, exFAT, most SMB/NFS/FUSE) it is the normalized name bytes, and a rename there is remove + insert; the app's own renames (FileOps posts old→new) carry selection and inline-rename state across explicitly.
  - The diff tolerates duplicate keys and never traps on them. Order: match by identity; then, within one coalesced batch, an identity that disappeared plus a new identity with the same name is a **replacement** (atomic save) and emits `reload`, moving selection, scroll anchor and rename state to the new identity; the rest become remove or insert.
  - Same identity with changed mtime or size → `reload`. Same identity with a new name → `reload`, plus `move(from:to:)` when its sorted position changes.
- **`Watcher`.**
  - **Content stream:** one `FSEventStream` per window on the visible folder only, with `FileEvents | NoDefer | WatchRoot` and 100 ms latency, delivered on a private serial queue. Apart from the flag events under Full re-read, events whose parent directory is not exactly the visible folder are dropped before any work.
  - **No gap:** `FSEventsGetCurrentEventId()` is captured before the folder's enumeration starts and passed as `sinceWhen`; events arriving during the read are buffered and applied once it finishes. Each navigation creates a new stream this way. If a stream has to be recreated for the same folder, `sinceWhen` is the last processed event ID.
  - **Tree nodes:** each expanded Folders-tree node is watched non-recursively with a `DispatchSource` vnode source (`.write | .delete | .rename | .link`) on an `O_EVTONLY` fd, opened and closed as nodes expand and collapse, capped at 256 sources. Above the cap, or on non-local volumes (`volumeIsLocalKey` false), expanded nodes are re-read when they are re-expanded and when the window becomes key. Tree re-reads list directories only and run under the materialization policy.
  - **Incremental update:** a coalesced batch for the visible folder with at most 256 item paths and no rescan flag is applied by `lstat`/`getattrlist` of just those paths and patched into the store (present with a known identity → reload; present and new → insert, or a replacement under the rule above if another identity held that name; absent → remove whatever held that name). `ItemRenamed` paths arrive in pairs and are each checked the same way.
  - **Full re-read:** more than 256 paths, or `MustScanSubDirs` on the visible folder or an ancestor, `UserDropped`, `KernelDropped` or `EventIdsWrapped`, trigger a full re-read and diff of the visible folder. At most one full re-read runs per directory, plus one pending that absorbs later events. `RootChanged` on the folder follows the moved/deleted rule above.
  - Selection, scroll anchor and any in-progress inline rename survive.
  - `FileOps` also posts the paths it changed directly, so the app's own edits refresh without waiting for FSEvents.
- **`FileOps`** — see §6.
- **`Clipboard`** — see §5.6.
- **`LaunchServices`** wraps `NSWorkspace`, always on a lane:
  - lists the candidate apps for a file (`urlsForApplications(toOpen:)`), cached by `UTType` and refreshed in the background;
  - resolves the **default app per file** with `urlForApplication(toOpen: fileURL)`, because LaunchServices honours per-file overrides; this is cached briefly per file URL and dropped when the Watcher reports a change to that file;
  - sets defaults and opens files with a given app (§5.7).
  - Its lookups never run while a menu is being built.
- **`Properties`** loads and edits:
  - `URLResourceValues`, POSIX mode, owner and group;
  - xattrs (`listxattr`), quarantine, and "where from" (`kMDItemWhereFroms` via `MDItem`).

  Folder contents are counted by a cancellable recursive count that reports progress. All Properties reads run under the materialization policy.
- **`Settings`:** `UserDefaults` with a `schemaVersion`. It stores favorites as bookmark data, view mode, columns (id, width, order, visible), sort, density, show hidden, command bar visible, tree auto-reveal, Return-key behaviour and per-location TCC outcomes.

### 4.4 Performance budgets

Conditions: Apple Silicon, local APFS, warm cache. Network and File Provider volumes have no fixed budget, but they must never block the UI.

| Event | Budget |
|---|---|
| Navigate → first rows painted (any size) | < 50 ms |
| 100k entries fully listed + sorted | < 250 ms |
| Re-sort 100k by any column | < 30 ms |
| Scroll | 120 fps; cell configure < 0.5 ms |
| Main-thread hang | none > 100 ms (Hangs instrument / MetricKit) |
| Type icons visible | first frame |
| Custom icons (`.app`, custom-icon flag) | < 100 ms after rows are visible |
| FSEvent → UI updated (incremental path, §4.3) | < 150 ms |
| FSEvent → UI updated (full re-read of 100k) | < 400 ms |
| Memory, 100k-entry folder (entries, arena, sort keys, permutation, identity map) | < 20 MB steady state, < 40 MB peak during sort/diff, excluding images |
| Drag or copy of 100k items (pasteboard write) | < 300 ms |
| Cold launch → window with home folder | < 300 ms |

**Main-thread rule:** no synchronous file-system calls on the main thread. That includes `resourceValues`, `fileExists`, `NSWorkspace.icon(forFile:)` and `urlsForApplications`. In debug builds a main-thread assertion helper (`assertOffMain()`) is called inside the `FSKit` and `Core` I/O entry points. Paths that look synchronous are made in-memory or asynchronous: status-bar free space is fetched on a lane and cached; drag validation uses the in-memory volume table (§5.6); paste re-checks item existence in the job's plan phase; the rename duplicate check uses the `EntryStore`.

**Icons** come in three tiers:
- Tier 0 is a per-`UTType` icon (`NSWorkspace.icon(for:)`), pre-rasterized to a `CGImage` for each size and cached.
- Tier 1, for visible rows only, is the per-file icon (`icon(forFile:)`) on a lane under the materialization policy. It applies only to apps, volumes, `.icns` files and items with the custom-icon flag.
- Tier 2 is thumbnails, which come in Phase 2.

## 5. Phase 1 UI

### 5.1 Window

- `NSWindow` with a unified `NSToolbar` (Liquid Glass) and an `NSSplitViewController`.
  - Split items are the sidebar (`NSSplitViewItem(sidebarWithViewController:)`) and the content.
  - The inspector slot is reserved for the Phase 3 preview pane.
- Multiple windows are supported (⌘N), and windows are restored on relaunch.
- Closing the last window leaves the app running, as macOS apps do (`applicationShouldTerminateAfterLastWindowClosed` returns false); see §6.7 for running jobs.
- Glass is used only on chrome (toolbar, sidebar, the floating operations HUD), never on list rows.
- The toolbar uses SF Symbols, semantic colours and respects Reduce Transparency and Increase Contrast.

### 5.2 Toolbar row

- `◀ ▶ ↑` as an `NSToolbarItemGroup`. Back and Forward also show a history menu on long-press or right-click.
- **Address bar** (custom view, flexible width):
  - *Breadcrumb mode* (default). Segments run from the volume to the current folder, for example `💽 Macintosh HD › Users › roni › dev`.
    - Clicking a segment navigates to it.
    - Clicking the `›` after a segment opens a menu of that folder's subfolders, as in Explorer.
    - Segments accept drops (§5.6).
    - Overflowing leading segments collapse into a `«` menu.
  - *Edit mode* is entered by clicking empty space in the bar, ⌘L, or ⌥D/F4 from the content or sidebar.
    - It shows a text field holding the POSIX path, all selected.
    - It accepts `/abs`, `~`, `~/rel`, `file://` URLs, and paths relative to the current folder.
    - Typing autocompletes subfolders, from an off-main `readdir` of the parent with debounced results. The dropdown also lists recent locations (up to 20, persisted).
    - Enter navigates to a folder. For a file, it navigates to the parent and selects the file. Esc reverts.
    - A path that doesn't exist or can't be accessed shows inline red text ("Can't find '…'") and leaves the field in edit mode.
- **Search field** (Phase 1 scope): filters the current folder by substring of the name, case- and diacritic-insensitive (§4.2 SortKeys), live as you type, and clears on navigation. Full search is Phase 3.
- **View switcher:** Details / Icons segmented control.

### 5.3 Command bar

- A slim row (about 28 pt) below the toolbar, inside the content area. It can be toggled with View › Show Command Bar.
- Items:

  ```
  [＋ New ▾] | [✂ Cut] [⧉ Copy] [📋 Paste] [✎ Rename] [⇪ Share] [🗑 Delete] | [⇅ Sort ▾] [☰ View ▾] [⋯]      [ⓘ Properties]
  ```

  - New ▾: Folder, Text File (`Untitled.txt`), Empty File.
  - Sort ▾: Name, Date Modified, Size, Kind, Date Created, Ascending/Descending.
  - View ▾: Details, Icons (Small/Medium/Large), Density (Compact/Regular/Comfortable), Hidden items, Command bar.
  - ⋯: Copy as Path, Select All, Select None, Invert Selection, Open in Terminal, Reveal in Finder.
- Items enable or disable based on the first responder (content or sidebar, §5.4), the selection and the clipboard. Delete becomes Delete Permanently while ⇧ is held.
- Every command is also in the main menu bar, so all of them can be found through Help search. Each menu item's single primary key equivalent (§5.6) can be rebound in Settings › Shortcuts (see `2026-11-05-key-bindings-design.md`); System Settings › Keyboard › App Shortcuts still overrides it.

### 5.4 Sidebar (single `NSOutlineView`, source-list style)

- **FAVORITES**
  - Defaults: Home, Desktop, Documents, Downloads, Applications.
  - Add a folder by dragging it into the section. Reorder by dragging. "Remove from Favorites" is in the right-click menu.
  - Entries are stored as bookmarks. Stale bookmarks are shown dimmed with a "Locate…" action.
- **LOCATIONS**
  - The boot volume, iCloud Drive (when it exists), and mounted external, disk-image and network volumes.
  - Each ejectable volume shows an eject (⏏) button. Updates are live.
  - Right-click menu: Open in New Window, Eject, Properties.
- **FOLDERS**
  - A lazy tree whose roots are the volumes. Children are loaded on expand through `DirectoryReader` (directories only).
  - It auto-reveals and selects the current folder; this can be turned off in Settings.
  - ← collapses a node and → expands it.
  - Tree nodes are drop targets, and hovering over one during a drag springs it open.
- Each section header can be collapsed, and its state persists.
- **Commands with sidebar focus** act on the focused sidebar row, never on the content selection:

  | Section | Behaviour |
  |---|---|
  | Favorites | Return navigates. Del/⌘⌫ = Remove from Favorites (never trashes the target). ⌘C copies the target URL; ⌘V pastes into the target folder; ⌘I/⌥Return opens the target's Properties. ⇧Del, ⌘X, ⌘D and F2 are disabled. |
  | Locations | Return navigates. ⌘E ejects. ⌘V pastes into the volume root; ⌘I/⌥Return opens volume Properties. Del, ⇧Del, ⌘X, ⌘D and F2 are disabled. |
  | Folders | Same commands and semantics as the content view, applied to the focused folder (Del trashes it, F2 renames it inline, ⌘X/⌘C/⌘V/⌘D work), as in Explorer's navigation pane. Volume roots behave like Locations rows. |

### 5.5 Content views

Both views share a `FolderModel`, selection semantics, keyboard handling, context menus and drag & drop.

- **Details view** (`NSTableView`, view-based, fixed row height):
  - **Columns:** Name (with icon), Date Modified, Size, Kind, Date Created, Extension.
    - Choose columns from the header's right-click menu. Reorder by dragging. Resize, and double-click a divider to auto-fit.
    - Click a header to sort; clicking again reverses the order. Folders always sort first.
  - Sizes use the decimal file style (`ByteCountFormatter.CountStyle.file`). A folder's size shows `--`.
  - Dates use relative formatting ("Today 18:02") or the medium style.
  - **Density:** Compact 20 pt, Regular 24 pt, Comfortable 30 pt.
  - Alternating row colours. Cut items render at 50% opacity.
- **Icons view** (`NSCollectionView` with a custom fixed-grid `NSCollectionViewLayout` subclass):
  - Sizes: Small 32, Medium 64, Large 128 pt. Cell size is fixed per icon size, with a fixed two-line label area; labels wrap to two lines with a middle ellipsis.
  - The layout computes columns from the width, returns item attributes in O(1) and the elements in a rect in O(visible), with no per-item caching in `prepare()`.
  - Rubber-band selection; arrow keys move through the grid spatially, using row/column arithmetic from the layout.
  - Sorting comes from the Sort menu only.
- **Selection:**
  - Click; ⌘-click toggles; ⇧-click selects a range; ⇧+arrow extends the range from the anchor (spatially in Icons view).
  - ⌘+arrow never changes the selection: ⌘↑/⌘↓ are Up/Open (§5.6), and ⌘←/⌘→ are unbound in the content view. Explorer's Ctrl+arrow / Ctrl+Space (move focus without selecting) is not provided, because macOS reserves ⌃-arrows for Spaces and Mission Control; ⌘-click covers the same need.
  - ⌘A selects all. Invert Selection is in the ⋯ menu.
  - Type-select jumps to a matching name.
  - The canonical selection lives in `FolderModel`: an identity set (§4.3) plus an `IndexSet` over the display permutation. Neither view uses its built-in selection set as the source of truth; cells draw selection from the model, and ⌘A, Invert Selection and rubber-band selection update the model directly. Selection survives updates.
- **Empty states:**
  - "This folder is empty".
  - "No items match '…'".
  - `.permissionTCC`: "macOS is blocking access to 'X'" with an "Open Privacy Settings" button.
  - `.permissionPOSIX`: "You don't have permission to view 'X'" with a "Properties" button (owner and permissions); no Privacy Settings button.
  - `.notFound` / `.volumeGone`: handled by the navigate-to-ancestor rule (§4.3).
  - `.notADirectory` / `.other`: "Can't open 'X'" with the system error text and Retry.
  - "Location not responding" with Retry; "Waiting for macOS permission…" during a TCC prompt (§4.2).
- **Status bar** (bottom, about 22 pt):
  - `N items` / `M selected (size)`. Selection totals are computed incrementally, and folder sizes are not included in Phase 1.
  - `X available` for the current volume, from `volumeAvailableCapacityForImportantUsageKey` (matching Finder), falling back to `volumeAvailableCapacityKey` when nil. It is fetched on a lane, cached, and refreshed on navigation to another volume, when an operation finishes and when volumes change.
  - On the right, an operations capsule (§6.2), visible while operations run.

### 5.6 Interaction

The key table below is the default. Users can change it and bind extra mouse buttons (default Mouse 4 = Back, Mouse 5 = Forward) in Settings › Shortcuts; see `2026-11-05-key-bindings-design.md`.

**Key map.** Explorer conventions. Windows Ctrl maps to ⌘ and Windows Alt to ⌥. Each command has one **primary** key, which is its menu key equivalent; **alternates** work only when the content view or sidebar has focus.

| Action | Primary (menu) | Alternates |
|---|---|---|
| Open | ⌘↓ | Return, double-click |
| Rename | F2 | ⌘⇧R; Return when Settings › Return key = Rename |
| Move to Trash | ⌘⌫ | Del (fn⌫) |
| Delete permanently (confirm) | ⌥⌘⌫ | ⇧Del |
| Cut / Copy / Paste | ⌘X / ⌘C / ⌘V | ⌃X / ⌃C / ⌃V |
| Move Item Here (paste as move) | ⌥⌘V | — |
| Undo / Redo | ⌘Z / ⌘⇧Z | ⌃Z / ⌘Y |
| Back / Forward | ⌘[ / ⌘] | ⌫ (Backspace), ⌥← / ⌥→ |
| Up | ⌘↑ | ⌥↑ |
| Address bar | ⌘L | ⌥D, F4 |
| Filter / search field | ⌘F | F3 |
| New folder | ⌘⇧N | — |
| New window | ⌘N | — |
| Close window | ⌘W | — |
| Properties | ⌘I | ⌥Return |
| Refresh | ⌘R | F5 |
| Copy as Path | ⌘⇧C | — |
| Toggle hidden | ⌘⇧. | — |
| Select all | ⌘A | ⌃A |
| Duplicate | ⌘D | — |
| Eject (Locations row) | ⌘E | — |
| Cycle focus (sidebar → address bar → content) | Tab / ⇧Tab | — |

On Apple keyboards F2–F5 are media keys and need fn unless "Use F1, F2, etc. keys as standard function keys" is on; every F-key command therefore also has a non-F-key binding.

- **Key routing.**
  1. **Text fields win.** When a field editor is first responder (address bar edit mode, search field, inline rename, Properties name field), standard text editing gets every key, including ⌥←/→/↑, ⌘↑/↓, ⌘⌫, ⌥⌘⌫, ⌫, Del, Return, Tab, ⌥D (which types characters on many layouts) and ⌃-keys.
  2. **Edit-menu commands** (Cut, Copy, Paste, Select All, Undo, Redo) are the standard responder-chain actions `cut:`, `copy:`, `paste:`, `selectAll:`, `undo:`, `redo:`. The file versions are implemented by the content views and sidebar, so the field editor handles them first when it has focus.
  3. **Colliding primaries.** Menu items whose primary key is also a text-editing key (⌘↑, ⌘↓, ⌘⌫, ⌥⌘⌫, ⌘[, ⌘], F2, ⌘D) return false from `validateMenuItem` while a field editor is first responder, so `performKeyEquivalent` passes the key on to the field editor. A UI test asserts each of these keys reaches the field editor.
  4. **Alternates** go through one `KeyDispatcher` in the content views' and sidebar's `keyDown`, which sends the same action selectors through the responder chain. They never fire in text fields, and they are not rebindable in System Settings (the Phase 4 keymap covers them).
  5. Menu and command-bar items follow the first responder: with sidebar focus they act on the sidebar row (§5.4), never on the content selection.
- **F2 rename** edits inline. The base name is selected without the extension, and Tab commits and moves on to the next item.
  - The new name is checked against the `EntryStore`: it can't be empty, contain `/`, be longer than 255 UTF-8 bytes, or duplicate an existing name in the folder. The duplicate check always compares normalization-insensitively (NFC forms) and, on volumes where `volumeSupportsCaseSensitiveNamesKey` is false, case-insensitively.
  - Changing the extension asks "Are you sure you want to change the extension?".
  - Leading `.` shows a warning that the item will become hidden.
  - The rename uses the rename primitive (§6.3). A rename that changes only case or Unicode normalization (same file) uses plain `rename(2)`, which APFS and HFS+ apply atomically. Only if the volume rejects it, or the name read back is unchanged (some SMB, exFAT and FAT volumes), does it fall back to two renames through a temporary name, recorded in the journal so launch cleanup can restore it.
- **Context menu, items:**

  ```
  Open · Open With ▸ [Default ✓ · recommended apps · Other… · Choose Default App…]
  Open in New Window · Show Package Contents (packages)
  ─ Cut · Copy · Paste (into the right-clicked folder; shown only when one folder is right-clicked) · Copy as Path
  ─ Duplicate · Make Alias · Create Symbolic Link
  ─ Rename · Move to Trash · Delete Permanently…
  ─ New ▸ · Reveal in Finder · Open in Terminal
  ─ Share ▸ (NSSharingServicePicker) · Services ▸
  ─ Properties
  ```

  The Open With submenu is filled in `menuNeedsUpdate` from the `LaunchServices` caches; Default ✓ comes from the per-file default lookup (§4.3). On a cache miss it shows "Loading…" and updates in place. It never blocks.
- **Context menu, empty space:** `Paste · New ▸ · View ▸ · Sort by ▸ · Refresh · Open in Terminal · Properties`. Properties here refers to the current folder.
- **Clipboard:**
  - Copy and Cut write every selected URL as its own `public.file-url` pasteboard item (`writeObjects` with `NSURL`s), plus the legacy `NSFilenamesPboardType` path list and the paths as plain text, with no item cap.
  - Cut also writes a private `com.macexplorer.cut` marker, and the app remembers the pasteboard `changeCount` at the time of the cut. The marker counts only while the current `changeCount` still equals that value in this process; otherwise (another copy, or after a relaunch) the contents paste as a copy. A paste therefore never moves items the user can't see marked as cut.
  - **Paste target:** ⌘V, ⌃V, the command-bar Paste and the empty-space menu Paste always paste into the current folder, whatever is selected, as in Explorer. Only the item context menu's Paste on a single folder pastes into that folder.
  - **Paste:** with a valid cut marker the items are **moved**, and the cut state is then cleared; otherwise they are **copied**. Pasting file URLs that came from Finder copies them. **Move Item Here** (⌥⌘V) moves whatever file URLs are on the pasteboard, matching Finder's ⌥⌘V, so Finder → macExplorer moves work.
  - Item existence is re-checked in the job's plan phase, off main; items that no longer exist are reported per item (Skip).
  - Cut-paste into the folder the items are already in does nothing and clears the cut state, with no conflict dialog. Copy-paste into the same folder makes Finder-style copies (`name copy`, as Duplicate).
  - Cutting in macExplorer and pasting in Finder copies; the README documents this.
  - Cut items render dimmed until they are pasted, the clipboard changes (detected by polling `changeCount` on app activation and after each command), or Esc is pressed. Esc also removes the marker from the pasteboard (rewriting the URLs without it), so dimming and move-on-paste always agree.
- **Drag & drop:**
  - **Sources:** the session starts with at most 5 `NSDraggingItem`s, which carry the composite drag image (up to 5 icons plus a count badge). In `draggingSession(_:willBeginAt:)` every selected URL is written to `session.draggingPasteboard` as its own `public.file-url` item, plus `NSFilenamesPboardType`, with no item cap; `numberOfValidItemsForDrop` is set to the real count. A private compact-list type may be added as a fast path for internal drops but is never the only representation. File promises (`NSFilePromiseProvider`) are not needed in Phase 1, because every source is a real file.
  - **Destinations:** folders in the list and grid, tree nodes, Favorites (dropping a folder between favorites adds it, dropping onto one moves files into it), address-bar segments, and other apps.
  - **Validation is pure in-memory.** Same- vs cross-volume is a longest-prefix match of each source's standardized path against the `Volumes` mount table; internal sources resolve through their `FolderModel` entry. The self/descendant refusal is a path-prefix check on standardized paths. `draggingUpdated` makes no file-system calls.
  - **Default operation:** move on the same volume, copy across volumes. ⌥ forces copy, ⌘ forces move, ⌥⌘ makes an alias. The cursor badge reflects the current operation.
  - **Right-drag:**
    - On `rightMouseDown` in the list, grid, tree and sidebar views, the location is recorded and no menu is shown yet. If the pointer moves past the drag threshold (about 3 pt) before `rightMouseUp`, `beginDraggingSession(with:event:source:)` starts and no menu appears. Otherwise, on `rightMouseUp`, the normal context menu is shown with `NSMenu.popUpContextMenu(_:with:for:)`. ⌃-click still opens the context menu immediately.
    - The source marks the drag with a private pasteboard type, `com.macexplorer.secondary-drag`, because destinations can't see which button was used.
    - Holding ⌃ at the moment of drop also makes a menu drop, for any drag including left-button and trackpad drags and drags from other apps. ⌃ is not otherwise used as a drag modifier.
    - An in-app destination receiving a menu drop shows `Copy Here · Move Here · Create Alias Here · Create Symbolic Link Here · Cancel` at the drop point and performs the chosen operation; Cancel does nothing.
    - Dropped outside the app, a right-drag behaves as a normal drag: the destination app applies its own default operation.
  - Spring-loading opens a folder after a 0.5 s hover, using the system setting where available. Auto-scroll at the view edges.
  - Drops coming from other apps that use file promises are accepted with `NSFilePromiseReceiver`.
  - Dropping onto itself or into one of its own descendants is refused, with a "no" cursor.

### 5.7 Opening and Open With

- **Open:**
  - A folder navigates in place (⌘-double-click opens it in a new window).
  - An `.app` launches.
  - Other packages are treated as files, and "Show Package Contents" navigates inside them.
  - An alias or symlink resolves to its target first. A broken one shows "The original item can't be found" with Delete / Fix… options.
  - Anything else goes to `NSWorkspace.open`.
  - When several items are selected, files open with their default apps and folders open in new windows (after confirming if there are more than 10).
- **Open With** calls `try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())`; errors are shown as an alert naming the app.
- **Choose Default App…** opens a sheet listing the apps that can handle the file plus "Browse…", with an "Always use this app to open .ext files" checkbox.
  - Checked: `setDefaultApplication(at:toOpenContentTypeOfFileAt:completionHandler:)`, which works for undeclared (`dyn.*`) extensions too, plus `setDefaultApplication(at:toOpenFileAt:completionHandler:)` for this file so an existing per-file override doesn't keep winning. The file then opens with the app.
  - Unchecked: the file is opened once with the chosen app.
- **Open in Terminal** opens Terminal at the folder (`NSWorkspace.shared.open([folder], withApplicationAt: terminalURL, configuration:)`). The terminal app can be configured in Settings.

### 5.8 Properties window (SwiftUI in `NSWindow`, non-modal)

- One window per selection set, opened with ⌘I / ⌥Return. A second invocation on the same selection focuses the existing window.
- **General:**
  - 64 pt icon and an editable name field (applying the §5.6 rules).
  - Kind; Location (path plus a Reveal button).
  - Size: logical size in bytes and human-readable form, plus size on disk.
  - Contains (folders only): a live count of files and folders from a cancellable background count.
  - Created, Modified and Last Opened dates.
  - Attributes: ☐ Read-only (Locked, `uchg`), ☐ Hidden (`UF_HIDDEN`), ☐ Hide extension.
- **Permissions:**
  - Owner, Group and Everyone, each with a popup: Read & Write / Read only / Write only / No access. Owner and group names come from `getpwuid`/`getgrgid`.
  - Editable only when the current user owns the item. Otherwise read-only, with a note.
  - "Apply to enclosed items…" (folders) runs as a `FileOps` job with confirmation.
  - ACL entries are listed read-only.
  - The execute bit is shown as "Executable" for files.
- **Opens with:** the current per-file default app, a **Change…** button (the Choose Default App sheet) and "Change All…" for the type (`toOpenContentTypeOfFileAt`).
- **Details:** UTType identifier, full path, inode, volume, "Where from" URLs, quarantine (shown with a Remove button), and extended attributes (name and size, read-only).
- **Multiple selection:** "N items (X files, Y folders)", total size, and shared attributes as tri-state checkboxes. Name and Opens with are hidden.
- **Volume properties** (when a volume is selected): format, capacity, used and free with a usage bar, mount point, Eject.
- Edits apply immediately and are undoable (§6.6). A failure shows an inline error and reverts the control.

### 5.9 Volumes, privacy, onboarding

- **Eject** runs `Volumes.release` (§4.2), then `NSWorkspace.unmountAndEjectDevice(at:)`. If the volume is busy, the error names the blocking process where possible (`lsof +f --`, run off main with a timeout, excluding our own PID). If only our own process holds it, the release step is retried once before reporting. Eject is also offered for disk images and network volumes.
- **First launch:** an onboarding sheet
  - explains Full Disk Access (why it matters, an "Open Privacy & Security" button, and "Continue without");
  - notes "Using F2 or F5? Hold fn, or turn on 'Use F1, F2, etc. keys as standard function keys'", with a button that opens Keyboard settings (`x-apple.systempreferences:com.apple.Keyboard-Settings.extension`).
- `Info.plist` includes `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription` and `NSNetworkVolumesUsageDescription`.
- When TCC denies access (`EPERM`), the folder shows the `.permissionTCC` empty state (§5.5). It does not show an alert.

## 6. File-operation engine (Core/FileOps)

### 6.1 Model

- **`FileOpQueue`** is an app-wide actor holding `Job`s. It coordinates only; all file-system calls run on I/O lanes (§4.2).
  - Job kinds: `copy`, `move`, `trash`, `delete`, `duplicate`, `newItem`, `rename`, `alias`, `symlink`, `chmodRecursive`, `setAttributes` (Properties edits).
  - Jobs that touch disjoint volume sets run concurrently. Jobs on the same volume pair run in FIFO order.
- Each job has two phases:
  1. **Plan:** enumerate the sources recursively with `fts`, check that each still exists, count items and bytes, estimate the space needed (§6.5), and detect conflicts lazily per item.
  2. **Execute:** carry out the operation.
- A job reports `Progress` (items done/total, bytes done/total, current item, throughput samples) at up to 10 Hz.
- Jobs can be paused (checked between items and between copy chunks) and cancelled (finish the current item safely, then stop).
- Every job records what it did per item (created paths, moved-from paths, trash `resultingItemURL`s, previous attributes) in its job record, for undo (§6.6) and the journal.

### 6.2 Progress UI

- Jobs that finish in under 1 s show nothing.
- Otherwise the status bar shows the operations capsule (an icon and the overall %). Clicking it opens a popover listing the jobs. Each job shows:
  - title ("Copying 1,204 items from Downloads to Backup");
  - a progress bar and "x of y";
  - speed, a 60-sample throughput graph and the estimated time remaining;
  - Pause/Resume and Cancel;
  - "More details" with the current file name.
- A job that is waiting on a conflict or error shows a badge, and its dialog appears as a sheet on the window that started it. If that window has closed, the dialog appears in the Operations panel (§6.7).

### 6.3 Execution rules

- **Rename primitive** (used by same-volume moves, cross-volume finalize, Keep Both and inline rename):
  1. Same vs cross volume is decided by comparing `volumeIdentifierKey` (or `st_dev`) of the source and of the destination's parent directory, never by path prefix (the System/Data firmlinks make prefixes misleading).
  2. `renamex_np(src, dst, RENAME_EXCL)`. `EEXIST` → the conflict policy (§6.4). `EXDEV` → the item is re-planned as a cross-volume move.
  3. If the volume lacks `renameExcl` (§4.2), or the call returns `ENOTSUP`/`EINVAL`, fall back to an `lstat` existence check plus `rename(2)`. A small race window remains against other processes; the per-volume FIFO ordering (§6.1) closes it for our own jobs.
- **Copy, files and symlinks:** `copyfile(3)` with `COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_DATA_SPARSE | COPYFILE_NOFOLLOW_SRC`, one call per item. Recursion is driven by our own plan, not `COPYFILE_RECURSIVE`, so we control progress and conflicts per item.
  - Data, xattrs, ACLs, Finder info, tags, timestamps and sparse files are preserved (`COPYFILE_DATA_SPARSE` falls back to a full copy where sparse copying isn't possible), and symlinks are copied as links.
  - `COPYFILE_CLONE` implies `COPYFILE_EXCL`, so the destination name must be free; Replace therefore always goes through a partial name (conflicts below).
  - The progress callback reports bytes. A successful clone sends no callbacks, so its bytes are counted as done when the call returns; the UI accepts jumps.
- **Copy, directories:** two passes. Pre-order: `mkdir` the destination at mode 0700, with no BSD flags, ACL or stat applied. Post-order, after all its children are done: `copyfile(src, dst, NULL, COPYFILE_METADATA)` applies mode, timestamps, BSD flags (`uchg`), ACL and xattrs. The post-order step also runs for finished directories when the job is cancelled or fails, so no directory is left at 0700.
- **Move, same volume:** the rename primitive.
- **Move, across volumes:** for each top-level item:
  1. Copy it to `<dest>/.<name>.macx-partial-<jobID>`.
  2. Verify that the item count and byte totals match.
  3. Rename it to the final name with the rename primitive.
  4. Only then delete the source.
  - If a step fails, the partial copy is removed and **the source is never deleted**.
  - Partial items and trashed destinations are recorded in a journal (`~/Library/Application Support/macExplorer/journal.json`). On launch, leftover partials listed in the journal are removed, trashed destinations whose replacement never landed are restored, and the user is told about any incomplete jobs.
- **Conflicts during copy and move:**
  - **Replace, copy or cross-volume move:** copy to the partial name → verify → trash the existing destination and record its Trash URL in the journal and job record → rename partial to final (`RENAME_EXCL`) → for a move, delete the source. If the final rename fails, the trashed item is restored from its recorded URL.
  - **Replace, same-volume move:** trash the existing item (recording its Trash URL), then the rename primitive. Nothing is copied, so the source can't be lost.
  - **Merge** (both cases): recurse into the folder. Children not present at the destination are moved or copied one by one with the rules above; children that conflict follow the conflict dialog. For a move, each source folder is removed only once it is empty; anything skipped stays in place.
  - **Keep Both:** the item lands under the next free name (`x 2.ext`) via the same sequence.
- **Trash:** `FileManager.trashItem(at:resultingItemURL:)`. The resulting URL is stored for undo.
  - Put Back from the system Trash is **not promised**, because it depends on Finder metadata. Restoring through our own undo is supported.
  - Volumes without a trash (some network volumes) fall back to "Delete permanently?" with confirmation.
- **Delete permanently:** always confirms ("Permanently delete N items? This can't be undone."). Uses `removefile(3)` with progress for large trees.
- **Duplicate:** a copy into the same folder named `name copy` / `name copy 2` (Finder style).
- **New items:**
  - New Folder is created as "New Folder" (then "New Folder 2"…) and immediately enters inline rename.
  - New Text File and New Empty File are created and also enter rename.
- **Alias:** a bookmark-based Finder alias (`URL.bookmarkData(options: .suitableForBookmarkFile)` plus `writeBookmarkData`). **Symlink:** `symlink(2)` with a relative path when source and target share a volume.

### 6.4 Conflicts

- Shown in a dialog modelled on Explorer's:
  - "The destination already has a file named 'x'".
  - Actions: **Replace**, **Skip**, **Keep Both** (`x 2.ext`), and **Compare**, which opens a side-by-side panel (icon, size, modified date, path) with per-item checkboxes, as in Explorer.
  - "Do this for all remaining conflicts (N)".
- Folder onto folder: "Merge folders?" (Merge / Keep Both / Skip). Merging recurses, and each file conflict inside the merge follows the dialog.
- Replace moves the existing item to the Trash (only after the new copy is verified, §6.3) rather than deleting it, and stores its `resultingItemURL`, so it can be recovered and undone.

### 6.5 Errors

| Cause | Message (plain) | Actions |
|---|---|---|
| `EACCES` | You don't have permission to … | Retry · Skip · Skip All · Cancel (Phase 4: Authenticate…) |
| `EPERM` (TCC/SIP) | macOS is blocking access to … | Open Privacy Settings · Skip · Cancel |
| `uchg` locked | "x" is locked | Unlock and Continue · Skip · Cancel |
| `EROFS` | The destination is read-only | Cancel |
| `ENOSPC` | Not enough space (needs X, Y available) | Retry · Cancel |
| `EBUSY` / in use | "x" is in use by another app | Retry · Skip · Cancel |
| `ENAMETOOLONG` | The name is too long for the destination | Skip · Cancel |
| `ENOENT` (source gone) | "x" no longer exists | Skip · Cancel |
| Other | System error text + code | Retry · Skip · Cancel |

- **Free-space check:** the plan phase estimates the bytes the job needs as the sum of `totalFileAllocatedSizeKey` for items that won't clone. Copy and Duplicate count as 0 when source and destination are on the same volume with `clone` support; same-volume moves always count as 0. If the estimate exceeds `volumeAvailableCapacityForImportantUsageKey` (fallback `volumeAvailableCapacityKey`), a dialog ("needs X, Y available") appears before execution with **Continue Anyway** and **Cancel**; a real `ENOSPC` during execution still shows the table's dialog.
- An error affects only its own item and the rest of the job continues; a job never aborts silently.

### 6.6 Undo

- **Ownership.** There is one app-wide file-operation undo stack (`FileOpUndoStack`, a single `UndoManager` on the main actor), as in Explorer. Every browser window and Properties window returns it from `windowWillReturnUndoManager(_:)`. An entry is registered when its job completes, whatever window started it and whether that window is still open. While a field editor is first responder, `windowWillReturnUndoManager(_:)` instead returns a per-edit `UndoManager` for typing undo; it is discarded when editing ends, so file-operation entries never mix with keystrokes.
- One entry per completed job:

  | Done | Undo |
  |---|---|
  | Move | move back |
  | Copy / Duplicate / New | trash the created items |
  | Copy or Move that replaced items | remove the new item, then move each replaced item back from its stored `resultingItemURL` |
  | Merge | reverse each item-level action in reverse order; folders the merge created are removed once empty |
  | Rename | rename back |
  | Trash | move from `resultingItemURL` back to the original path |
  | Alias / Symlink | remove |
  | `chmodRecursive` | restore each item's recorded previous mode |
  | Properties edit (name, locked, hidden, hide extension, permissions, quarantine removal) | restore the recorded previous value (quarantine: rewrite the saved xattr) |

- Before acting, undo checks that each item is still at the recorded path with the same identity. Items that have gone or changed are skipped and listed in a summary; an occupied original path goes through the conflict dialog.
- Undo itself runs as a job, so it has progress and conflict handling.
- A partly completed job undoes only the items that were done.
- Permanent delete can't be undone; the confirmation says so.
- The history lasts for the session only.

### 6.7 Lifecycle while jobs run

- **Quit:** if any job is active or blocked, `applicationShouldTerminate(_:)` returns `.terminateLater` and shows "N operations are in progress" with **Stop and Quit** / **Cancel**. Stop and Quit cancels every job through the §6.1 cancel path (current item finished safely, cross-volume partials removed, journal updated), then replies `true`. If cancellation hasn't finished after 10 s the app quits anyway and launch cleanup uses the journal.
- **Last window closed:** the app keeps running (§5.1). Running jobs show progress on the Dock tile (`NSDockTile` badge with the overall %), and **Window › Operations** opens a standalone `NSPanel` with the same job list as the popover.
- Jobs and their undo entries belong to the app, not to a window; closing a window never cancels a job.

## 7. Settings (Phase 1)

| Section | Settings |
|---|---|
| General | Startup folder (Home / last location / custom), Open folders in (same / new window), Return key (Open (default) / Rename), Terminal app |
| View | Density, show hidden, command bar, auto-reveal in tree, date format (relative/absolute) |
| Sidebar | Show/hide each default favorite, Locations items |
| Shortcuts | Rebind each command's primary key, alternate keys and mouse buttons; see `2026-11-05-key-bindings-design.md` |
| Advanced | Confirm before trash (off) / delete (on, locked on), show full path in window title |

## 8. Accessibility & localization

- Native controls only.
  - Every icon-only button has an accessibility label.
  - Table headers are exposed to VoiceOver.
  - Address-bar segments are announced individually.
  - Every action can be reached from the keyboard and from the menu bar.
- Honour Reduce Transparency, Increase Contrast, Reduce Motion and Differentiate Without Color. Cut items are dimmed *and* their name is italicized, so the state doesn't rely on opacity alone.
- **Localization:**
  - All strings live in a String Catalog. Phase 1 ships English only.
  - Pseudo-localization is used in tests to catch clipped labels.
  - Localized display names (`localizedNameKey`) are used for system folders.
  - The layout is right-to-left safe (leading/trailing constraints).

## 9. Testing & verification

- **FSKitTests:**
  - **Parser golden test:** a fixture generator (`scripts/make-fixtures.sh`, plus a Swift helper) builds trees containing NFD/NFC names, emoji, 255-byte names, hidden and `UF_HIDDEN` files, symlinks (including broken ones), aliases, packages, locked files, xattrs, hard links, unreadable entries (per-entry `ATTR_CMN_ERROR`), and 0-byte and sparse files. Reader output is compared field by field with `lstat` and `getattrlist`.
  - Fuzzing the record parser with malformed and truncated buffers must never crash.
  - **Sort golden:** a corpus of about 5k names (accented Latin, non-Latin scripts, long digit runs, leading zeros), compared against `localizedStandardCompare`; any allowed differences are listed explicitly.
  - Fallback-path parity: the `readdir` path must give the same results as `getattrlistbulk`.
  - Lane tests: a simulated hung read poisons its lane, Retry gets a fresh lane, late results with a stale generation are discarded, and the poisoned-lane cap marks the volume unresponsive.
- **CoreTests** run in temporary directories:
  - every `FileOps` kind, including conflict-policy combinations (Replace, Merge and Keep Both, same- and cross-volume), pause and cancel mid-copy;
  - a cross-volume move using a mounted RAM disk or disk image (`hdiutil`), with a simulated kill during copy and during Replace. The test checks that the source is intact, the replaced item is restored and the journal cleanup works;
  - an `EROFS` disk image, locked files and `ENOSPC` on a small disk image;
  - directory copies preserve mtime, mode and `uchg` of locked and read-only source folders;
  - the rename-primitive fallback and case-only renames on an exFAT disk image;
  - undo for each job kind, including undo after the items were changed externally;
  - xattr, tag, ACL and sparse-file preservation;
  - Clipboard: a stale cut marker (changed `changeCount`) pastes as a copy.
- **Watcher tests:** 10k file-creation bursts, renames and deletes. The final model must equal a fresh read, selection by identity must be preserved, and no full reset may happen unless it was flagged. Also: two hard links to one file in the same folder, an atomic save (write temp, rename over) keeps the selection, a rename on an exFAT disk image, changes made during the initial enumeration are not lost, and events outside the visible folder cause no re-read.
- **Benchmarks:** the `macx-bench` CLI generates 1k, 10k and 100k fixtures and measures enumerate, sort-key generation, sort, re-sort, diff and a 100k-item pasteboard write. Each metric runs one warm-up pass plus 5 measured iterations and reports the median and p90 in JSON.
  - **CI gate (relative):** medians are compared against a baseline JSON produced by the same workflow on `main` with the same runner image (cached as an artifact keyed by image version, recomputed when the image changes). A PR fails only if a metric is more than 20% slower **and** more than 5 ms slower.
  - The §4.4 absolute budgets are checked in CI only as a non-blocking warning annotation. They are gated by `macx-bench --check-budgets` on Apple Silicon hardware, a required item in the per-release checklist.
- **UI:**
  - `OSSignposter` intervals cover navigation → firstBatch → firstPaint, sort and iconFill. Instruments (Time Profiler, Hangs, Allocations) is run before each release.
  - XCUITest smoke suite (needs Xcode): navigate by address bar, rename with F2, cut and paste, drag-move, right-drag menu, the conflict dialog, Properties, undo, and that colliding keys (⌥←, ⌘↑, ⌘⌫, ⌥D…) reach the field editor while editing.
- **Manual checklist** per release: `macx-bench --check-budgets`, VoiceOver pass, dark/light, Reduce Transparency, an external USB drive (including eject while browsing it), an SMB share, and iCloud Drive placeholders not being downloaded.

## 10. Build & release

- **Local:**
  - `swift build -c release`, then `scripts/bundle.sh` assembles `.build/macExplorer.app` (Info.plist, icns, `codesign --sign -`).
  - `swift test`.
  - `swift run -c release macx-bench` (add `--check-budgets` on Apple Silicon).
- **CI** (GitHub Actions, `macos-26` runner):
  - On each PR: build, test and bench with the relative gate (§9).
  - On a tag:
    1. Build a universal arm64 + x86_64 binary (`--arch arm64 --arch x86_64`).
    2. Codesign with Developer ID and the hardened runtime.
    3. `notarytool submit --wait`, then `stapler staple`.
    4. Zip and DMG, then upload to GitHub Releases.
    5. Update the cask in `homebrew-macexplorer` (tap repo) through a workflow.
- **Secrets:** Developer ID certificate (p12 + password), App Store Connect API key for notarytool. **Owner action:** enroll in the Apple Developer Program.
- **License:** MIT.
- **Versioning:** SemVer, with `0.x` until Phase 1 is complete.

## 11. Later phases: feature specs

### Phase 2 — Views & Tabs

- **Tabs:**
  - Native `NSWindow` tabbing: ⌘T new tab, ⌃Tab next tab, ⌘W close.
  - A folder can be dragged onto the tab bar to open it.
  - Tab-bar drop: via the New Tab toolbar button (native tab bar has no drop API).
  - Middle-click a folder (content, sidebar or tree), or ⌘-click a folder in the sidebar or tree, opens it in a new tab. ⌘-click in the content view keeps its toggle meaning.
- **Per-folder view state** (mode, columns, sort, icon size, density, Group by, folder sizes): stored in our own store, keyed by volume UUID and fileID on `idStable` volumes and by path elsewhere (path is also the fallback). Each record holds only the fields changed in that folder; the rest resolve from Finder's `.DS_Store`, the application-folder rule and the defaults (design 2026-11-05 §2, merged). "Use as Default for All Folders" changes the defaults, "Apply to all folders" also resets every folder, "Reset View for This Folder" resets one.
- **Group by:** Kind, Date Modified (Today, Yesterday, Earlier this week…), Size buckets, Name first letter. Collapsible group headers, using `NSTableView` floating group rows.
- **Quick Look:** Space toggles a `QLPreviewPanel` over the selection, and arrow keys move through the items.
- **Folder sizes:**
  - "Calculate folder sizes" toggle per folder.
  - Sizes are computed with a cancellable recursive `getattrlistbulk` scan on a lane under the materialization policy (§4.2), cached by identity (path on non-`idStable` volumes) and mtime, and invalidated through the Watcher.
- **More columns:** Tags, Date Last Opened, Permissions (rwx), Owner, Path (in search results), Comments.
- **Copy-path variants:** POSIX, `~`-relative, file URL, name only, quoted for the shell.
- **Thumbnails in Icons view:** `QLThumbnailGenerator`, requested only for visible, non-dataless items and cancelled when they scroll off. Kept in an `NSCache` keyed by (identity, mtime, size).
- **Columns (Miller) view:** `NSBrowser`-like, built on our own `NSTableView` columns for speed.

### Phase 3 — Preview & Search

- **Preview pane:**
  - The inspector split item (toggle with ⌥P, like Explorer) shows a `QLPreviewView` of the selection. Text and code use a fast text preview of the first 256 KB.
  - Underneath is a details summary (size, dates, dimensions or duration from `MDItem`).
  - Previews never load from dataless iCloud files unless the user clicks "Download".
- **Search:**
  - The search field gains scope chips: This folder / Subfolders / This Mac. A Name / Contents toggle sits alongside.
  - **This Mac** and **Contents** use `NSMetadataQuery`, Spotlight's API, with results streamed in.
  - **Subfolders, by name** uses our own parallel crawler (`getattrlistbulk` on lanes under the materialization policy, one task per subtree, skipping packages by default), so it works on volumes that Spotlight hasn't indexed.
  - Results appear in the Details view with a Path column. "Open containing folder" is available, and searching is cancellable.
  - **Filters:** kind, date modified/created ranges, size ranges, extension.
  - **Saved searches** appear in a sidebar SEARCHES section.
  - Search syntax supports `name:`, `kind:`, `ext:`, `size:>10MB` and `modified:today`, close to Explorer's Advanced Query Syntax.

### Phase 4 — Power

- **Custom icons:**
  - Drop an image onto the icon in Properties, or paste one, to set it (`NSWorkspace.setIcon(_:forFile:)`). "Remove custom icon" clears it.
  - An icon-pack folder lets you assign icons per extension, shown in the app only.
- **Tags:**
  - A tags editor in Properties and the context menu (colour dots and named tags).
  - A sidebar TAGS section that runs a Spotlight query for the tag. A Tags column.
- **Compress and extract:**
  - "Compress to .zip" uses `ditto -c -k --sequesterRsrc --keepParent`, or `AppleArchive` for `.aar`.
  - "Extract here" handles zip, tar/gz and aar.
  - Both run as `FileOps` jobs with progress.
- **Batch rename** (multi-selection F2): find/replace (with optional regex), add a prefix or suffix, numbering, and changing case. A live preview table shows the result, and the whole rename is undoable as one job.
- **Dual-pane:** toggle with View › Dual Pane (⌘⇧E); F3 stays the search alias. Each pane has its own address bar. While dual-pane is on, F5 copies and F6 moves to the other pane, Commander-style; Refresh stays on ⌘R.
- **Authenticate…:** privileged operations through a small helper registered with `SMAppService` and an authorization prompt. Scoped to file operations only, and audited.
- **ACL editing** in Properties › Permissions.
- **Network:**
  - Connect to Server (⌘K): `smb://`, `afp://`, `nfs://`, mounted with `NetFS`.
  - A browse list of Bonjour SMB hosts (`NWBrowser`, which needs the Local Network usage string).
- **Sparkle 2 auto-update:** an EdDSA-signed appcast hosted on GitHub Releases.
- **Command palette** (⌘⇧P): fuzzy-search every command.
- **Keymap customization:** a Settings › Keyboard table covering primaries and alternates, presets (Explorer default, Finder), and JSON import/export.

## 12. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Hidden synchronous I/O inside AppKit (menus, icons, pasteboard, drag validation) causes hangs | Main-thread I/O assertions, LaunchServices caches, icon tiers, in-memory drag validation, Hangs instrument in release checklist |
| Hung network/FUSE mounts block threads uninterruptibly | Blocking calls only on per-volume I/O lanes, never the cooperative pool; watchdog poisons lanes, Retry uses a fresh lane, poisoned-lane cap; never join on main (§4.2) |
| FSEvents storms (node_modules, Downloads) cause jank | Visible-folder-only content stream with parent filtering, non-recursive vnode sources for the tree, incremental patching, one full re-read in flight, burst tests |
| Unstable file IDs (exFAT, SMB), hard links, atomic saves | `ATTR_CMNEXT_LINKID` row identity, name identity on non-`idStable` volumes, replacement rule in the diff (§4.3) |
| iCloud/File Provider downloads triggered by background reads | Materialization policy on every background lane task (§4.2); manual iCloud check per release |
| Sort order differs from Finder | `CFStringFold`-based keys with NFC tie-break; golden corpus test; documented divergences |
| Data loss on cross-volume move or Replace | Partial-name copy → verify → trash existing → rename → delete source; journal + launch cleanup; kill tests |
| Keyboard shortcuts steal keys from text fields | Field editor wins; colliding menu items disabled while editing; alternates only in content/sidebar `keyDown`; UI test |
| Ad-hoc signing re-prompts TCC after each rebuild during dev | Use a stable self-signed dev certificate via `scripts/dev-cert.sh` once available; document |
| NSCollectionView at 100k items | Custom fixed-grid layout with O(1) attributes and model-owned selection from the start (§5.5); benchmarked in Phase 1 |
| Benchmark noise on shared CI runners | Relative gate against a same-image baseline; absolute budgets gated on Apple Silicon per release |
| Put Back unsupported | Not promised; undo-based restore provided |
