# macOS Platform Constraints & APIs for macExplorer

## Toolchain status (checked)
- `xcode-select -p` points to `/Library/Developer/CommandLineTools`. **Full Xcode is not installed** (nothing in `/Applications` matches "xcode", and `xcodebuild` errors out).
- Swift 6.4 (swiftlang-6.4.0.34.1) targeting arm64-apple-macosx26.0. macOS 26.7.2 (25G332).
- What this means: SwiftPM can build an AppKit/SwiftUI executable, but there are no `.xcodeproj` files, asset catalogs, Interface Builder, Instruments GUI or notarization UI. You can still package a `.app` by hand (Info.plist, entitlements), sign with `codesign` and notarize with `xcrun notarytool`, if CLT includes them; this needs checking. **Recommendation: install Xcode 26** for Instruments (needed to prove the 100k-entry speed goal), signing and asset catalogs.

## 1. Sandbox vs Developer ID
- **App Sandbox (Mac App Store):** file access only through `NSOpenPanel` grants plus security-scoped bookmarks (`URL.bookmarkData(options: .withSecurityScope)` / `startAccessingSecurityScopedResource()`). A file manager can't browse `/` freely, can't see other apps' containers and can't do privileged operations.
- **Store examples:** Commander One and ForkLift ship Store builds with fewer features and ask for a root "grant" folder. Their full versions, and Path Finder, are sold directly.
- **Recommendation: no sandbox, Developer ID signing + hardened runtime + notarization** (`notarytool submit --wait`, then `stapler staple`). Keep a Store build as a later option.
- Hardened runtime still applies. Add `com.apple.security.automation.apple-events` only if you script Finder (needed for Put Back, see §4).

## 2. TCC / privacy
Even without the sandbox, TCC controls access to:
- `~/Desktop`, `~/Documents`, `~/Downloads`
- iCloud Drive
- removable volumes and network volumes
- Photos/Mail/Messages data, `~/Library/Safari`, Time Machine

Behaviour and pitfalls:
- The first access triggers a separate system prompt per location. Add the `NS*FolderUsageDescription` keys (`NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription`).
- **Full Disk Access** can't be requested from code. Detect it by trying to read a protected path such as `~/Library/Containers/com.apple.stocks` or `~/Library/Safari`. Then deep-link the user to `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
- Show an onboarding screen for this.
- Prompts are tied to the code signature, so ad-hoc dev builds re-prompt after every rebuild. Sign with a stable identity.
- A denied read returns `EPERM`, which looks like "folder empty". Show an explicit "no permission" state instead.

## 3. Live updates
- **FSEvents** (`FSEventStreamCreate` with `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer`, latency about 50–100 ms, `FSEventStreamSetDispatchQueue`):
  - Watches a whole subtree, merges bursts of changes, and survives large changes.
  - Events can arrive merged or with `MustScanSubDirs`, so treat them as hints and re-stat the affected entries.
  - No events on many SMB/NFS shares, so fall back to polling.
- **`DispatchSource.makeFileSystemObjectSource`** (kqueue `EVFILT_VNODE`, `.write/.rename/.delete`):
  - One file descriptor per watched dir, reporting "dir changed" with no names, so you must diff.
  - Good for the single open folder; a bad fit for the tree.
- **Plan:** one FSEvents stream per window over the visible roots, diff against the cached listing, apply minimal row updates.

## 4. File operations
- **Fast listing:**
  - `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:)` with prefetched keys is fine.
  - For 100k entries, use `getattrlistbulk(2)` (one syscall returns name, type, size, dates and flags for many entries). It is several times faster than `readdir` + `stat`, and much faster than URL APIs.
  - Load icons and kinds lazily, only for visible rows.
- **NSFileCoordinator:**
  - Use `coordinate(writingItemAt:options: .forMoving)` for moves and renames inside iCloud Drive or folders other apps are presenting.
  - Skip it for bulk local copies (too slow, and can deadlock if called on the main thread).
- **Trash:**
  - `FileManager.trashItem(at:resultingItemURL:)` works per volume and returns the new URL, which enables undo via `NSUndoManager`.
  - **Pitfall:** "Put Back" metadata (`.DS_Store` `ptbL`/`ptbN`) is written only when *Finder* trashes. Options are `NSWorkspace.recycle(_:completionHandler:)` (behaviour varies) or scripting Finder with `tell application "Finder" to delete` (needs an Apple Events permission prompt). Otherwise, keep your own Put Back log.
- **Copy:**
  - Use `copyfile(3)` with `COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE` (APFS clones are instant and share blocks). `COPYFILE_CLONE_FORCE` fails instead of falling back to a real copy.
  - Progress comes from a `copyfile_callback_t` (`COPYFILE_STATE_STATUS_CB`, `COPYFILE_PROGRESS`), which also allows cancel and skip.
  - `clonefile(2)` alone clones single items on the same volume.
  - Run copies on a background operation queue and show progress via `Progress` / `NSProgress` publishing (`Progress.publish()` makes Finder-style progress appear on the icons).
- **Move:**
  - Same volume: `rename(2)`, which is atomic.
  - Different volume: copy, verify, then delete the source. Detect this with `URLResourceKey.volumeIdentifierKey`.
- **Conflict resolution:**
  - Use `renamex_np` with `RENAME_EXCL` / `RENAME_SWAP`.
  - Offer Keep Both / Replace / Skip / Apply to all / Merge folders (Finder can't merge folders, which is a selling point).
- **Pitfalls:** case-insensitive APFS (renaming `a` to `A`), Unicode normalization (NFD vs NFC names from SMB), names with `:` vs `/`, and `EXDEV`.

## 5. Open / Open With / defaults
- `NSWorkspace.shared.open(_:configuration:completionHandler:)` and `open(_:withApplicationAt:configuration:)`.
- `urlsForApplications(toOpen: URL)` / `urlForApplication(toOpen:)` list candidate apps and the default (these replace the deprecated `LSCopyApplicationURLsForURL`).
- To change defaults: `setDefaultApplication(at:toOpen: UTType)` or `toOpenContentType:` (macOS 12+). macOS may show a confirmation dialog.
- Types: `UTType(filenameExtension:)` and `URLResourceValues.contentType`.
- Reveal: `activateFileViewerSelecting`.

## 6. Get Info data
- **`URLResourceValues` keys:** `fileSizeKey`, `totalFileAllocatedSizeKey`, `creationDateKey`, `contentModificationDateKey`, `contentAccessDateKey`, `addedToDirectoryDateKey`, `localizedTypeDescriptionKey`, `tagNamesKey`, `labelNumberKey`, `isHiddenKey`, `hasHiddenExtensionKey`, `isPackageKey`, `isAliasFileKey`, `isSymbolicLinkKey`, `volumeAvailableCapacityForImportantUsageKey`, `fileSecurityKey` (`NSFileSecurity` exposes the ACL via `CFFileSecurityCopyAccessControlList`), `isUserImmutableKey` (the Locked flag, `UF_IMMUTABLE`; set it via `chflags` / `setResourceValues`).
- **Folder sizes:** must be computed with a recursive `getattrlistbulk` walk, cancelable.
- **Permissions:** POSIX via `FileManager.attributesOfItem` (`.posixPermissions`, `.ownerAccountName`). Editing permissions on files you don't own needs authorization; ship read-only for v1.
- **Xattrs:** `listxattr` / `getxattr`. Tags live in `com.apple.metadata:_kMDItemUserTags`; write them via `URLResourceValues.tagNames`, not raw xattrs.
- **Finder comments:** `kMDItemFinderComment`, readable via `MDItemCopyAttribute`. Writing back reliably requires Finder AppleScript; Spotlight is read-only. Also show "Where from" (`kMDItemWhereFroms`), image dimensions and duration from `MDItem`.
- **Quarantine:** `com.apple.quarantine` xattr.

## 7. Aliases, symlinks, bookmarks
- Symlinks: `destinationOfSymbolicLink` / `resolvingSymlinksInPath`.
- Aliases: `URL.resolveAliasFile(at:)`, `bookmarkData(options: .suitableForBookmarkFile)` + `writeBookmarkData` to create one.
- Store sidebar favorites as bookmarks (they survive renames and moves).
- Pitfall: avoid symlink loops during recursion (track `fileResourceIdentifierKey`).

## 8. Volumes
- Enumerate with `FileManager.mountedVolumeURLs(includingResourceValuesForKeys:[.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeTotalCapacityKey], options: [.skipHiddenVolumes])`.
- Track changes with `NSWorkspace.didMountNotification` / `didUnmountNotification` / `didRenameVolumeNotification`.
- Eject with `NSWorkspace.unmountAndEjectDevice(at:)`, which throws with a "busy" error. For richer feedback (which process blocks it), use DiskArbitration (`DADiskUnmount` + `DADiskEject`, `DARegisterDiskAppearedCallback`).
- Network: open `smb://` via `NSWorkspace.open` or `NetFSMountURLAsync`.

## 9. iCloud Drive / File Provider
- Placeholders are dataless files (`SF_DATALESS`, `URLResourceKey.ubiquitousItemDownloadingStatusKey`, `isUbiquitousItemKey`).
- **Never read their contents** during listing, thumbnails or size scans; that triggers downloads. Pass `getattrlistbulk` options carefully and check `SF_DATALESS` in `st_flags`.
- Download: `FileManager.startDownloadingUbiquitousItem(at:)`. Evict: `evictUbiquitousItem`.
- Show cloud badges.
- `~/Library/CloudStorage` (Dropbox, OneDrive, Google Drive) uses the same File Provider rules.

## 10. Packages and hidden files
- Treat `isPackageKey == true` items (`.app`, `.bundle`, `.photoslibrary`, `.rtfd`) as files. Double-click opens them; add a "Show Package Contents" command.
- Hidden: dotfiles plus `UF_HIDDEN` (`isHiddenKey`). Toggle with ⌘⇧. like Finder.
- Hide `.DS_Store`, `.localized`, `Icon\r`.
- Use `localizedNameKey` for display (e.g. "Applications", the localized system folder names), but navigate by the real path in the address bar.

## Extra pitfalls
- Do all file I/O off the main actor (Swift 6 strict concurrency helps here). Network volumes can block `stat` for seconds; use timeouts and cancellation.
- Get file icons from `NSWorkspace.icon(forFile:)` or `URLResourceValues.effectiveIcon` on a background queue, cached per UTType. QuickLook thumbnails: `QLThumbnailGenerator`.
- Custom icons (phase 2): `NSWorkspace.setIcon(_:forFile:)`.
- For drag and drop, use `NSFilePromiseProvider` / `NSFilePromiseReceiver` (Mail, Photos), `NSPasteboard` file URLs (`.fileURL`), and `NSDraggingSession` operation masks (⌥ = copy, ⌘ = move).
- Cut/paste has no system-level concept; implement it as copy plus a move flag, like Finder's ⌥⌘V.