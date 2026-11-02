# File-system layer research: fast enumeration and rendering

## Toolchain
- `xcode-select -p` returns `/Library/Developer/CommandLineTools`. Only the Command Line Tools are installed; there is no full Xcode in /Applications.
- Swift 6.4 is installed (arm64-apple-macosx26.0). Machine: M3 Pro, macOS 26.7.2.
- What this means: `swiftc`/SPM builds work, and AppKit apps can be built with SPM plus a hand-made `.app` bundle. Instruments, xctrace, Interface Builder, asset catalogs, signing UI and SwiftUI previews all need full Xcode, so install it before UX or profiling work.

## Measured numbers (my own benchmarks)
One flat folder of 100k files on local APFS, warm cache, `-O` build. The benchmark programs are in /tmp/mxbench/src; the test data was deleted afterwards.

| API | 100k entries |
|---|---|
| `readdir` (names only) | 40 ms |
| `readdir` + `fstatat` | 195 ms |
| `fts_open`/`fts_read` (one level, `FTS_PHYSICAL`) | 125 ms |
| **`getattrlistbulk`** (name, objtype, mtime, crtime, flags, fileid, datalength; 256 KB buffer) | **101 ms** |
| `FileManager.contentsOfDirectory(atPath:)` | 300 ms |
| `contentsOfDirectory(at:includingPropertiesForKeys:)`, 5 keys | 270 ms, plus **437 ms** to read the prefetched `resourceValues` |
| `FileManager.enumerator(at:…, .skipsSubdirectoryDescendants)` | 650 ms |
| `.typeIdentifierKey` per URL, not prefetched | **4,540 ms**. Never do this. |

Sorting and type costs:

| Operation | Cost |
|---|---|
| Sort by `localizedStandardCompare` (Finder's natural sort) | **703 ms**. Too slow to use as the comparator. |
| Index sort over precomputed lowercased keys | **11 ms** |
| Sort 100k Ints (size or date columns) | 12 ms |
| `UTType(filenameExtension:)` | ~1.4 µs uncached; cache it per extension |
| `NSWorkspace.icon(forFile:)` | **~80 µs/file**, so 2,000 files take 160 ms |
| `NSWorkspace.icon(for: UTType)` | 0.03 ms, cached |
| `NSImage` → `cgImage` rasterize | ~95 µs each |
| `du -sk /Applications` (folder-size reference) | 7.6 s cold |

**Conclusion:** `getattrlistbulk(2)` returns one syscall's worth of packed records per call. It is about 2x faster than `readdir`+`stat` and 7x faster than the Foundation APIs once you count resource-value access. Use it for the hot path. Use `fts` only for recursive work such as folder sizes and copies.

## Recommended architecture

**1. `DirectoryReader`** (Swift calling C, or a small C file in an SPM target)
- Call `getattrlistbulk` with `ATTR_CMN_RETURNED_ATTRS | NAME | OBJTYPE | FILEID | MODTIME | CRTIME | FLAGS | ACCESSMASK`, plus `ATTR_FILE_DATALENGTH`/`ALLOCSIZE` and `ATTR_DIR_ENTRYCOUNT`. Use `FSOPT_PACK_INVAL_ATTRS` so records keep a fixed layout.
- Run it on a dedicated serial queue per directory (an actor or `DispatchQueue` with `.userInitiated` QoS). It must never run on the main thread.
- **Stream** results: emit a batch every ~2,000 entries or every 8 ms, whichever comes first. The first batch drives first paint; the rest are appended.
- Fallback: `readdir` + `fstatat` for file systems that return `ENOTSUP` (some SMB/FUSE mounts).

**2. Row storage (struct-of-arrays, no per-row objects)**
- One `Entry` struct per row of about 48 bytes: `fileID: UInt64`, `size: Int64`, `mtime`/`ctime: Int64`, `nameOffset: UInt32`, `nameLen: UInt16`, `kind: UInt8`, `flags: UInt32`, `typeIndex: UInt16` (index into an interned UTType table).
- Names live in one contiguous UTF-8 arena, `[UInt8]`. `String`s are created only for visible cells.
- 100k rows come to about 5 MB plus the arena, against more than 60 MB for 100k `URL` objects.
- The sort order is a separate `[UInt32]` permutation, so re-sorting never moves the entries.

**3. Sorting**
- At read time, build a sort key per name off-main: Unicode-folded, case-insensitive, with digit runs zero-padded so "file2" sorts before "file10". Alternatively use ICU `ucol_getSortKey` with `UCOL_NUMERIC_COLLATION`.
- Sorting the index with memcmp then takes about 10–20 ms. `DispatchQueue.concurrentPerform` can generate the keys across cores.
- Keep "folders first" as a key prefix byte.
- Do not use `localizedStandardCompare` as the comparator. Use it only to verify that our order matches Finder's.

**4. Rendering**
- Use AppKit `NSTableView`/`NSOutlineView` (view-based, `usesAutomaticRowHeights = false`, fixed row height) with cell reuse. Pull data in `tableView(_:viewFor:row:)` from the struct-of-arrays store.
- Do not use SwiftUI `List`/`Table` for the file list. It diffs identity across 100k rows and stalls. SwiftUI is fine for the chrome, the properties sheet and settings.
- Use `NSCollectionView` for the icon grid.
- Update with `insertRows`/`removeRows`, or `reloadData` when the table is empty, inside `beginUpdates`. Never reload per entry.

**5. Icons**
- Tier 0: a per-UTType icon from `NSWorkspace.icon(for:)`, cached in a dictionary keyed by type index and pixel size, and pre-rasterized to a `CGImage` once.
- Tier 1, only for visible rows and only for items with a custom icon: `NSWorkspace.icon(forFile:)` on a background queue. This covers `.app`, `.icns`, items with the custom-icon flag (from `ATTR_CMN_FINDERINFO`), and volumes.
- Tier 2, the thumbnails phase: `QLThumbnailGenerator.shared.generateBestRepresentation`, with requests cancelled when rows scroll off-screen. Keep an `NSCache` LRU keyed by `(fileID, mtime, size)`.

**6. Live updates**
- Use `FSEventStreamCreate` with `kFSEventStreamCreateFlagFileEvents | NoDefer` and 50–100 ms latency on the visible directories. A per-directory `DispatchSource.makeFileSystemObjectSource(.write)` is cheaper for the current folder alone.
- On an event, re-run `getattrlistbulk` and diff by `fileID` against the current entries. Unchanged `fileID` with a different mtime or size is an update; a missing one is a delete; a new one is an insert.
- Apply minimal table row changes and coalesce bursts with a 100 ms debounce.
- If the stream reports `MustScanSubDirs` or `UserDropped`, do a full re-read.

**7. Folder sizes**
- Compute lazily and off-main with `fts` (`FTS_PHYSICAL | FTS_XDEV`) or recursive `getattrlistbulk`, summing `ATTR_FILE_ALLOCSIZE`.
- Make it cancellable through `Task` cancellation, cache it by `fileID`, and invalidate it from FSEvents.
- Show the size progressively in the Properties dialog. In list view, show it only on request (a Finder-style "Calculate all sizes" option).

**8. Main-thread rules**
- No synchronous file-system calls on the main thread. That includes `resourceValues`, `FileManager.fileExists`, and `NSWorkspace.icon(forFile:)`.
- Network volumes get a timeout and a spinner.
- Swift 6 strict concurrency: make the readers actors, make batches `Sendable`, and have the UI store be `@MainActor`.

## Language choice
Swift with C interop is the right fit. The syscalls are C, the UI has to be AppKit, and Rust adds an FFI boundary with no throughput gain because the syscall itself is the cost. Avoid Foundation `URL` on hot paths.

## Measurement
- Use `OSSignposter` intervals: `enumerate`, `firstBatch`, `sortKeys`, `sort`, `firstPaint` (closed in the next runloop turn after `reloadData`), `iconFill`.
- View them in Instruments (Time Profiler, os_signpost, Hangs, Allocations); `xctrace record` works from the CLI once Xcode is installed.
- Use `XCTMetric`/`measure` in XCTest for regressions, plus a CLI benchmark target run against fixture folders of 1k, 10k and 100k entries. Create the fixtures in a temp directory.
- MetricKit `MXHangDiagnostic` covers field data.

## Performance budgets (M-series, local SSD, warm cache)

| Event | Budget |
|---|---|
| Path entered → first rows painted, 10k items | **< 50 ms** (the first batch arrives in ~5 ms) |
| 100k items: first paint | < 50 ms (streaming) |
| 100k items: fully listed and sorted | < 250 ms |
| Re-sort by column, 100k | < 30 ms |
| Scrolling | 120 fps on ProMotion, i.e. under 8 ms per frame; cell configuration < 0.5 ms |
| Hangs | none over 100 ms on the main thread |
| Icons on screen | type icons in the first frame; custom icons < 100 ms; thumbnails < 300 ms |
| FSEvent change → UI update | < 150 ms |
| Memory per 100k-entry folder | < 20 ms worth of… correction: < 20 MB, excluding thumbnails |

## Risks
- `getattrlistbulk` buffer parsing is error-prone. Unit-test it against `lstat` output.
- iCloud/File Provider dataless files report `SF_DATALESS`; never read their contents during enumeration.
- Full Disk Access and TCC prompts on ~/Desktop, ~/Documents and ~/Downloads need an entitlement and onboarding plan.
- App Sandbox would block arbitrary path navigation. Ship unsandboxed with Developer ID and notarization.