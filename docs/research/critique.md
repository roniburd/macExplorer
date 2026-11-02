## (1) Claims that look wrong or overstated

- **Speed of `getattrlistbulk`.** The platform report calls it "several times faster than readdir+stat". The perf report measured about 2x (101 ms vs 195 ms). The "7x" figure holds only against Foundation once resource-value reads are counted. All the numbers are warm-cache on an M3 Pro. Nothing was measured cold, on SMB, or on File Provider, so the spec's budgets must say "warm local APFS only".
- **"Fixed layout" with `FSOPT_PACK_INVAL_ATTRS`.** Records stay variable-length: the name is an `attrreference_t` and each record carries its own length. The parser still has to walk by record length.
- **Natural sort.** A hand-rolled sort key (case-fold plus zero-padded digits) will not match Finder for diacritics, punctuation or locale. ICU `ucol_*` lives in `libicucore`, but the macOS SDK has no public headers for it. A safer route is `CFStringTransform`/`CFStringFold` plus numeric padding, then a golden test against `localizedStandardCompare`.
- **TCC "needs an entitlement" (perf report).** Wrong for a non-sandboxed app. Only the `NS*UsageDescription` strings are needed.
- **`NSFileCoordinator` "deadlocks on main".** Overstated. It blocks, and it deadlocks only if a presenter in the same process runs on the queue being blocked.
- **Put Back.** None of the reports verified whether `trashItem` or `recycle` writes Put Back metadata on macOS 26. Prototype this before promising Put Back.
- **`COPYFILE_CLONE` progress.** Clones finish in effectively one step, so per-byte progress callbacks barely fire. The progress UI needs to handle that. Behaviour of `COPYFILE_CLONE` combined with `COPYFILE_RECURSIVE` also needs a test.
- **`.backgroundExtensionEffect()`.** This is SwiftUI. The AppKit equivalent is `NSBackgroundExtensionView`.
- **Contradictions between reports that the spec must settle:**
  - Return: rename vs open.
  - Alias drag modifier: ⌘⌥ vs ⌃⌥.
  - `NSPathControl` vs a custom breadcrumb.
  - POSIX/ACL permissions: editable vs read-only in v1.
- **`NSCollectionView` at 100k items.** Fine for one folder, but flow-layout attribute computation and rubber-band selection at that size are unproven.
- **`urlsForApplications(toOpen:)`.** This is a synchronous LaunchServices call that can take tens of ms. Calling it while building the context menu risks visible lag.

## (2) Gaps the spec must address

- **Undo and an operations journal.** Use `UndoManager` backed by a persisted journal covering move, rename, trash and create. Define what undo means after a partial batch.
- **Crash safety for cross-volume moves:**
  - copy to a temporary name, verify, atomic rename, then delete the source;
  - on next launch, clean up or resume orphaned partial copies;
  - never delete the source after a failed or partial copy.
- **Error taxonomy and UI:**
  - EACCES vs EPERM (TCC or SIP), EROFS, ENOSPC, EBUSY, `uchg` locked files, ENAMETOOLONG, files in use;
  - per-item skip/retry instead of aborting the batch.
- **Copy fidelity:**
  - xattrs, ACLs, resource forks, tags, sparse files, hard links, symlinks inside trees, quarantine propagation;
  - case-only renames, NFC/NFD names, names with newlines, `:`/`/` mapping.
- **Network and FUSE volumes.** A hung `stat` is uninterruptible, so `Task` cancellation cannot stop it. Spec separate threads per volume, a watchdog, and a "volume unresponsive" UI state. Bonjour browsing for "Network" (`NWBrowser`) triggers the Local Network privacy prompt.
- **Large selections:**
  - pasteboard and drag with 10k–100k URLs (avoid one `NSDraggingItem` per file; use a summary drag image);
  - select-all, then status-bar size totals, without hanging.
- **State.** Window/tab restoration (`NSWindowRestoration`), a store for per-folder view state, migration of settings.
- **Localization.** Localized folder names, date and size formatters, RTL layout, pseudo-localization.
- **Testing:**
  - `swift test` for `Core`, run against fixture trees;
  - fuzz and golden tests for the `getattrlistbulk` parser vs `lstat`;
  - a CLI perf benchmark with thresholds wired into CI;
  - XCUITest and Accessibility Inspector need Xcode;
  - FSEvents churn tests (e.g. `node_modules` installs).
- **Distribution:** Developer ID account, notarization, an updater (Sparkle), crash reporting.
- **Trash view.** Must cover `~/.Trash` plus `/Volumes/*/.Trashes/<uid>`.
- **"Reveal in Finder" from other apps.** These requests still go to Finder (there is no public default-file-viewer API). Document this limit.

## (3) Five biggest risks to "extremely fast + native feel"

1. **Hidden synchronous I/O on the main thread inside AppKit.** Context-menu Open With, `NSWorkspace.icon(forFile:)`, pasteboard URL resolution, Quick Look and `NSOpenPanel` can each stall the UI. The "no hangs over 100 ms" goal needs Hangs instrumentation from day one.
2. **Slow or hung network volumes and File Provider files.** Hung mounts block threads uninterruptibly. Touching dataless files triggers downloads. Either one beachballs the app or causes surprise downloads, which is exactly the Finder complaint we are trying to beat.
3. **No full Xcode.** Without Instruments, XCUITest or a stable signing identity, the speed budgets cannot be proven. Ad-hoc signing also re-prompts TCC after every rebuild. Install Xcode before writing any UI code.
4. **Fidelity to Finder in details users notice:**
   - sort order;
   - Put Back;
   - tags and comments write-back;
   - drag-modifier semantics and spring-loading;
   - a custom breadcrumb control that misses Liquid Glass and accessibility behaviour.
   Each mismatch reads as "fake Finder".
5. **Live-update churn.** FSEvents storms in Downloads, build folders or `node_modules` can cause jank on reload, lost selection and scroll jumps. Diffing by `fileID` must keep selection, the row being renamed and the scroll anchor stable under 1k+ events per second.