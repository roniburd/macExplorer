# Tech stack research: macExplorer

## Environment
- macOS 26.7.2 (25G332), Apple Silicon, Swift 6.4 (`arm64-apple-macosx26.0`).
- **Full Xcode is not installed.** `xcode-select -p` returns `/Library/Developer/CommandLineTools`, `ls /Applications | grep -i xcode` finds nothing, and `xcodebuild` fails because it needs Xcode.
- The CommandLineTools SDKs are MacOSX26, 26.5 and 27.0. I compiled a test file in /tmp, since deleted, that imports `AppKit`, `SwiftUI` and `QuickLookUI` and creates an `NSTableView`. It built with `swiftc -O` and ran.
- `actool` (asset catalogs) and `ibtool` (XIB/storyboard) are missing. `codesign` is present.
- Rust is not installed (no `cargo` or `rustc`).
- What this means: SwiftPM plus a hand-built `.app` bundle works today if the UI is built in code (no XIBs) and the app icon is a prebuilt `.icns` made with `iconutil`. Xcode becomes necessary for Instruments time profiling, the debugger UI, notarization and asset catalogs.

## Options compared

| Criterion | (a) Swift + AppKit | (b) SwiftUI (+AppKit hybrid) | (c) Rust (objc2 / cacao / Tauri) | (d) C++/ObjC++ |
|---|---|---|---|---|
| 100k-row list | Excellent. `NSTableView`/`NSOutlineView` are virtualized with view reuse (`makeView(withIdentifier:owner:)`). They only ask the data source for visible rows (`numberOfRows`, `tableView(_:viewFor:row:)`), so cost does not grow with folder size. | Pure `Table`/`List` is risky at this size (pitfalls below). Fine if the main list is an `NSViewRepresentable` wrapping `NSTableView`. | objc2 can call the same `NSTableView`, but delegate subclassing in Rust is very verbose. cacao is unmaintained and missing many APIs. A Tauri webview needs a JS virtual list and has no native cells. | Same speed as (a), much more boilerplate. |
| Startup | About 100-200 ms to first window for a small Mach-O app. | Similar. The SwiftUI graph adds a little. | objc2 is similar to (a). Tauri/WKWebView adds 300-600 ms plus a web process. | Same as (a). |
| Native feel | Complete: `NSMenu` context menus, `NSPasteboard` with `NSPasteboardItem`/`NSFilePromiseProvider`, `NSDraggingSession`, spring-loaded folders, `QLPreviewPanel`, `NSServicesMenuRequestor`, `NSWorkspace.icon(forFile:)`, `NSPathControl`, `NSAccessibility` built in, type-select, column autosave (`autosaveName`). | Good for the shell (`NavigationSplitView`, settings, inspector/properties sheets). Weak for drag and drop (`Transferable` has no file promises or drag operation masks) and for advanced table behaviour. | Everything has to be bridged by hand. A webview never feels like Finder: drag and drop to and from Finder is crippled, and there is no real Quick Look panel or Services menu. | Complete. |
| Dev velocity | Medium. Verbose, but there is a lot of documentation and Finder-clone prior art. | High for forms and settings. | Low for objc2/cacao. High for Tauri UI, but the native integration then fights you. | Lowest. |
| Build without Xcode | `swift build` plus a script that assembles `Contents/MacOS`, `Info.plist`, `Resources` and runs `codesign --sign -`. Works. | Same. `#Preview` canvas needs Xcode. | `cargo` plus `cargo-bundle`. Works, but Rust has to be installed. | Clang via CLT. Works. |

## Known SwiftUI Table/List pitfalls on macOS
1. **Identity diffing is O(n).** Every state change to the collection behind `Table(rows)`, `List` or `ForEach` re-diffs all IDs. With 100k rows, sorting, renaming one file or FSEvents updates cause frame hitches and multi-second stalls. Lazy row bodies do not help because the diff over IDs is eager.
2. **Selection is a `Set<ID>` binding.** Select-all on 100k items and shift-click ranges are slow, and every change invalidates the view.
3. **Sorting via `sortOrder: [KeyPathComparator]`** means re-sorting the whole model array and re-diffing it, with no stable incremental reload such as `reloadData(forRowIndexes:columnIndexes:)`.
4. **Missing APIs:**
   - no per-row drag image or file-promise drags;
   - no drop-on-row versus between-row control (`setDropRow(_:dropOperation:)`);
   - no type-select, no `rowHeight`/`usesAutomaticRowHeights` tuning, limited column customization (`TableColumnCustomization`, macOS 14+);
   - no hidden-but-sortable columns;
   - no inline edit-on-click-delay like Finder rename.
5. **`OutlineGroup` / `List(children:)`** builds the children key path eagerly and does not load lazily on expand the way `NSOutlineView`'s `outlineView(_:numberOfChildrenOfItem:)` does. That is bad for a lazy filesystem tree.
6. **Observation/`@Observable` fan-out.** Observing one large model object makes every visible row depend on it unless the state is split per row.
7. **`.contextMenu(forSelectionType:menu:primaryAction:)`** works, but menus are rebuilt per invocation and lack `NSMenuDelegate` `menuNeedsUpdate` dynamics ("Open With" submenu from `NSWorkspace.urlsForApplications(toOpen:)`).

## Rust core + Swift UI via FFI: is it worth it?
**No, not for v1.** Listing a directory is bound by system calls, not language speed. The fastest path is the same from Swift and Rust:
- `getattrlistbulk(2)` returns name, type, size, dates and file ID in bulk with one syscall per batch.
- `fts`/`readdir` plus `fstatat` is the fallback.
- `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:)` with prefetched `URLResourceKey`s is simpler but slower.

Swift with `withUnsafeTemporaryAllocation` and C interop (`Darwin`) matches Rust here. A UniFFI or swift-bridge layer adds a build step, marshalling cost per row (strings), two toolchains and harder debugging. Rust only becomes worth it if a large standalone engine appears later, such as a full-text or content search index. That engine could then be a separate Rust static library behind a narrow C ABI.

## Performance architecture for any stack
- Columnar model: arrays of name, size, mtime, kind and flags, with names interned as UTF-8 buffers and `String` created lazily for visible rows.
- Directory enumeration and sorting run off the main thread (Swift concurrency actor). The first screenful is published within about 16 ms, then `noteNumberOfRowsChanged()` as the rest arrives.
- Icons: `NSWorkspace.icon(for: UTType)` cached per type, with per-file icons and thumbnails (`QLThumbnailGenerator`) fetched lazily for visible rows only.
- Live updates via `FSEventStream` (`kFSEventStreamCreateFlagFileEvents`) or a `DispatchSource` (`.write` on the directory fd), applied as diffs with `insertRows`/`removeRows`.
- File operations: `FileManager` `copyItem`/`moveItem`/`trashItem(at:resultingItemURL:)`, or `copyfile(3)` with `COPYFILE_CLONE` for instant APFS clones plus progress callbacks.
- Properties: `URLResourceValues` and `NSWorkspace` for the "Open With" default (`setDefaultApplication(at:toOpen:)`, macOS 12+).

## Recommendation
**Swift 6 + AppKit-first hybrid.**
- **AppKit for the performance-critical and interaction-heavy surfaces:**
  - main browser in `NSTableView` (details view), `NSOutlineView` for the folder tree and sidebar, and `NSCollectionView` with a compositional/flow layout for the icon view;
  - address bar as an `NSTextField` or `NSComboBox` with completion that switches to an `NSPathControl` breadcrumb when not focused;
  - toolbar via `NSToolbar` with `NSWindow` tabbing (`tabbingMode`), which gives tabs almost for free;
  - context menus as `NSMenu`, and drag and drop via `NSPasteboardWriting` with `NSFilePromiseProvider`.
- **SwiftUI hosted with `NSHostingView`/`NSHostingController`** for low-volume UI: Properties/Get Info window, Settings, preview inspector, empty states.
- **Structure:** a SwiftPM workspace with a `Core` library (enumeration, file ops, model; unit-testable with `swift test`), an `App` executable target, and a `scripts/bundle.sh` that builds the `.app` and ad-hoc signs it.
- **Rejected:** Tauri (not native enough and slower to start), pure SwiftUI (pitfalls 1-5 at 100k rows), C++ (no gain), Rust core (no measurable gain for I/O-bound work, at a real cost in complexity).

**Advisories:**
- Install full Xcode before profiling (Instruments) and before notarized distribution.
- Without Xcode, avoid XIBs and asset catalogs.
- Accessing protected folders such as Desktop, Documents and Downloads triggers TCC prompts. The app needs a stable code signature so permissions persist, and Full Disk Access should be documented.
- Shipping outside the App Store (non-sandboxed) is recommended because App Sandbox would cripple a file manager.

No files were created in the repo at /Users/roniburd/dev/macExplorer.