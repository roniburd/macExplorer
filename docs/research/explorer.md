# Windows File Explorer Feature Inventory → macExplorer Port

## Toolchain finding
- `xcode-select -p` → `/Library/Developer/CommandLineTools`. **Full Xcode is NOT installed** (nothing in `/Applications` matches "xcode").
- Swift 6.4 (swiftlang-6.4.0.34.1), target arm64-apple-macosx26.0, macOS 26.7.2 (25G332).
- What this means: SwiftPM and `swiftc` builds of AppKit/SwiftUI work. There is no Interface Builder, no `xcodebuild`, no Instruments GUI, and no asset-catalog or notarization UI. The app bundle would need to be put together by a script (Info.plist plus codesign). Installing Xcode is recommended for Instruments profiling and signing.

Legend: **P0** = core MVP, **P1** = next, **P2** = later. **[NM]** = doesn't map to macOS, or needs a reinterpretation.

## 1. Navigation
- **P0** Address bar breadcrumbs: click a segment to go there, chevron ▸ shows sibling dropdown (`NSPathControl` is too limited, so build a custom one). Click empty space or press Ctrl+L / Alt+D / F4 to switch to editable text mode. Accept `~`, `/Volumes/...`, `file://` and env-style paths. Esc reverts.
- **P0** Back / Forward (Alt+←/→ maps to ⌘[ / ⌘]), Up (Alt+↑ maps to ⌘↑), Refresh (F5 maps to ⌘R).
- **P0** Path autocomplete while typing (prefix-match from a directory read, Tab to complete).
- **P1** Recent-locations dropdown (▾ next to Forward) and history list on right-clicking Back/Forward.
- **P1** Typing a command in the address bar (`cmd`, `powershell`) launches it. Port this as "Open in Terminal here".
- **P2** Shell namespaces (`shell:startup`, `::{CLSID}`) **[NM]**. Map them to aliases such as `airdrop:`, `icloud:`, `trash:`.

## 2. Navigation pane
- **P0** Home / Quick access = Finder Favorites (pinned folders, drag to pin), Recent files, Locations (Volumes via `FileManager.mountedVolumeURLs`, network, iCloud).
- **P0** Folder tree: lazy expand (`NSOutlineView`), expand-on-hover during drag, drop onto a node.
- **P1** "Expand to open folder" (auto-reveal the current path in the tree), "Show all folders", libraries **[NM: use Smart Folders]**.
- **P2** "This PC" view with drive capacity bars (`URLResourceKey.volumeAvailableCapacityForImportantUsageKey`). OneDrive status icons map to iCloud/File Provider badges (`NSFileProviderItem`).

## 3. Views
- **P0** Details view: column chooser (right-click header → Name, Date modified, Type, Size, Date created, Kind, Tags, Dimensions…, plus "More…"). Columns can be resized and reordered, with per-folder saved state. Uses a view-based `NSTableView` for 100k-row virtualization.
- **P0** Sort by any column, ascending/descending. Folders-first toggle (Windows default; Finder has an option for it).
- **P1** Group by (Type, Date with "Today/Last week" buckets, Size buckets, Name A–H…), collapsible groups. Icon sizes: Extra large / Large / Medium / Small / List / Tiles / Content (`NSCollectionView` with thumbnails from `QLThumbnailGenerator`).
- **P1** Ctrl+Shift+1…8 view switching (map to ⌘1…⌘4 like Finder, plus extras). Ctrl+wheel resizes icons (map to pinch or ⌘+/−).
- **P2** "Apply to all folders" view templates, compact vs. normal spacing toggle, filter-by-value dropdown on column headers.

## 4. Selection
- **P0** Click, Shift-range, ⌘-toggle, rubber band, Select all (⌘A), type-ahead jump.
- **P1** Item checkboxes, Invert selection, Select none.
- **P0** Status bar: item count, selected count, total size of the selection, free space.

## 5. Clipboard
- **P0** Cut / Copy / Paste. Cut shows ghosted (50% alpha) icons until pasted, then moves. macOS has no native cut; Finder emulates it with ⌘C then ⌥⌘V. Implement real cut with internal state plus `NSPasteboard` file URLs, and support both shortcuts.
- **P0** Copy as path (Ctrl+Shift+C maps to ⌥⌘C). Paste into the address bar.
- **P1** Paste shortcut (maps to "Make Alias" via `URL.bookmarkData(options:.suitableForBookmarkFile)` or a symlink), Undo/Redo of file ops (Ctrl+Z / ⌘Z via `UndoManager`).

## 6. File operations
- **P0** Drag & drop: same volume moves, cross-volume copies. Modifiers: Ctrl = copy maps to ⌥, Shift = move maps to ⌘, Alt = link maps to ⌥⌘. Right-drag menu ("Copy here / Move here / Create shortcut") maps to ⌃-drag or a drop menu. Spring-loaded folders.
- **P0** Progress dialog: pause, cancel, a "more details" speed graph (MB/s, time left, items left), multiple jobs queued in one window. Use `copyfile(3)` with `COPYFILE_CLONE` (APFS clone is instant) and a progress callback, run on background actors.
- **P0** Conflict dialog: Replace / Skip / Compare info (size, date, thumbnail for both) / Keep both (auto-rename "(2)"), plus "Do this for all".
- **P0** Delete to Trash (`FileManager.trashItem`), Shift+Del permanent with confirmation (map to ⌥⌘⌫).
- **P1** Recycle Bin view with Restore (needs `~/.Trash` plus the put-back location, which is limited **[partial NM]**).

## 7. Rename
- **P0** F2 inline rename that preselects the stem but not the extension, Tab to the next item, warning when the extension changes. F2 maps to Return (Finder) or F2. Support both.
- **P1** Batch rename: select many, then F2 gives "Name (1), (2)…". Also a Finder-style find/replace/sequence dialog.
- **P2** PowerRename-style regex rename with preview.

## 8. New
- **P0** New folder (Ctrl+Shift+N maps to ⇧⌘N), immediately in rename mode.
- **P1** New ▸ Text document / user templates (Windows `ShellNew` **[NM]**; use a `~/Library/Application Support/macExplorer/Templates` dir instead).

## 9. Properties (Alt+Enter maps to ⌘I)
- **P0** General: name, kind, location, size / size on disk (`totalFileAllocatedSize`), contains N files/folders (async recursive count), created / modified / accessed dates, Read-only / Hidden attributes (`isHiddenKey`, `uchg` flag), Opens with + Change.
- **P1** Details tab: EXIF/ID3/document metadata via `MDItemCopyAttributes` (Spotlight) or ImageIO. Multi-select aggregate properties.
- **P1** Security maps to POSIX owner/group/mode plus ACLs (`acl_get_file`). Windows ACL UI **[NM]**, reinterpreted as Finder's "Sharing & Permissions".
- **P2** Previous Versions maps to Time Machine snapshots (`tmutil`) **[mostly NM]**. Tags, comments, custom icon (`NSWorkspace.setIcon`).

## 10. Open / Open with
- **P0** Open (Enter maps to ⌘↓ or Return-configurable), Open with ▸ app list (`NSWorkspace.urlsForApplications(toOpen:)`), "Choose another app", Always use (`NSWorkspace.setDefaultApplication(at:toOpen:)`, macOS 12+).
- **P1** Open in new window/tab, Open file location (for search/recents), Run as administrator **[NM]**.

## 11. Context menu extras
- **P1** Send to ▸ (Desktop shortcut, Mail recipient, Compressed folder, drives) maps to the Share menu (`NSSharingServicePicker`) plus "Copy to ▸ recent location". Compress to ZIP / Extract all (`/usr/bin/ditto -c -k` or libarchive). Pin to Favorites. Open in Terminal. Win11 "Show more options" two-tier menu (skip it and keep one menu).
- **P2** Finder Quick Actions / Services integration (`NSServices`).

## 12. Tabs & windows (Win11)
- **P1** Tabs (Ctrl+T/W/Tab map to ⌘T/W/⇧⌘]), drag a tab out into a window, restore session. `NSWindow.tabbingMode`, or custom tabs for speed.
- **P2** Dual-pane / split view (not in Explorer, but a common power-user request).

## 13. Panes
- **P1** Preview pane (Alt+P maps to ⇧⌘P) using `QLPreviewView` (Quartz). Details pane (Alt+Shift+P) with metadata and editable tags.
- **P1** Quick Look on Space (`QLPreviewPanel`). Mac users expect it, so consider P0.

## 14. Search
- **P1** Search box (Ctrl+E/F maps to ⌘F) scoped to the current folder and subfolders. Uses `NSMetadataQuery` / `MDQuery` (Spotlight, instant), with a fallback live `fts`/`getattrlistbulk` walk for non-indexed volumes.
- **P1** Filters: `kind:`, `size:>10MB`, `date:last week`, `ext:`, `name:` (Windows AQS mapped to Spotlight predicates). Search history. Saved searches map to Smart Folders.
- **P2** Content search, regex.

## 15. Keyboard (P0 unless noted)
Ctrl+N new window, Ctrl+Shift+N new folder, F2, F5, Del, Shift+Del, Alt+Enter, Alt+↑/←/→, Backspace = back (P1), Ctrl+L/Alt+D/F4 address bar, F6 cycles panes, Ctrl+Shift+E expand tree to current (P1), Ctrl+click column auto-fit (P2), type-ahead. Ship a "Windows keymap / Mac keymap" preference, because Windows keys clash with macOS conventions (Ctrl vs ⌘, Enter = rename in Finder).

## 16. Other
- **P0** Show hidden files toggle (⇧⌘.), show file extensions toggle.
- **P1** Folder size calculation on demand, symlink/alias resolution, `FSEvents` / `DispatchSource` live refresh.
- **P2** Map network drive maps to Connect to Server (`smb://`) **[partial NM]**. Registry-based shell extensions **[NM]**. Win11 Gallery view maps to a photo grid (P2).

## Performance notes for the spec
- Enumerate with `getattrlistbulk(2)` (fastest bulk stat on APFS) instead of `FileManager.contentsOfDirectory` with resource keys.
- Show the first rows before sorting finishes, and sort off the main thread.
- Use cell-reuse tables (AppKit `NSTableView`/`NSOutlineView`, not SwiftUI `List`, for 100k rows).
- Generate thumbnails lazily with `QLThumbnailGenerator` and cancel them when cells scroll off.