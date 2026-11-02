# Finder inventory and Mac user expectations: research report (track: Finder features)

## Environment check
- `xcode-select -p` returns `/Library/Developer/CommandLineTools`. **Full Xcode is not installed** (no Xcode in /Applications). Only the Command Line Tools are present.
- Swift 6.4 (swiftlang-6.4.0.34.1) targets arm64-apple-macosx26.0. The OS is macOS 26.7.2 (25G332).
- What this means: `swift build` and SwiftPM work, and AppKit/SwiftUI can be imported from the CLT SDK. There is no Interface Builder, asset catalog compiler (`actool`), Instruments GUI, or `xcodebuild` archive/notarize flow. We would need to bundle the .app by hand (Info.plist plus `codesign`) or install Xcode before polishing and distributing.

## Finder feature inventory

**Sidebar**
- Sections: Favorites (Recents, AirDrop, Applications, Desktop, Documents, Downloads, Home), iCloud (iCloud Drive, Shared), Locations (Mac volume, external and network volumes with eject buttons, Network), Tags.
- Users customize it by dragging folders in or out, reordering, and hiding sections (Settings ▸ Sidebar). Sections collapse on hover-click.
- Sources: `FileManager.mountedVolumeURLs(includingResourceValuesForKeys:options:)`, `NSWorkspace.didMountNotification` / `didUnmountNotification`, `URLResourceKey.volumeIsEjectableKey` / `volumeIsRemovableKey`. Eject goes through `NSWorkspace.unmountAndEjectDevice(at:)`. The Finder favorites list itself (LSSharedFileList) is deprecated and private, so we keep our own list.

**Views**
- Icon view (Cmd+1): size slider, grid, arrange, label position.
- List view (Cmd+2): disclosure triangles; Option+Right expands everything; column headers you can sort and add or remove (Name, Date Modified, Created, Last Opened, Added, Size, Kind, Version, Comments, Tags); "Calculate all sizes" option.
- Column view (Cmd+3): Miller columns with a preview column.
- Gallery view (Cmd+4): large preview with metadata.
- Group By (Kind, Date, Size, Tags, Application). Per-folder view settings are stored in `.DS_Store`. View Options panel (Cmd+J).

**Chrome**
- Path bar (View ▸ Show Path Bar, Option+Cmd+P): a breadcrumb you can click and drop onto, but not type into.
- Status bar (Cmd+/): "N items, X GB available", plus an icon-size slider.
- Toolbar can be customized. Window title has a proxy icon; Cmd-click the title shows a path popup.
- Tabs: Cmd+T new, Cmd+Shift+\ show all, drag between windows, Window ▸ Merge All Windows.

**Inspection and metadata**
- Quick Look: Space, Option+Space for full screen, arrow keys to step through. API: `QLPreviewPanel`.
- Get Info (Cmd+I) shows name and extension, Open With plus "Change All…", Sharing & Permissions, Locked, Stationery, comments, and Option+Cmd+I opens a live Inspector. Preview pane (Shift+Cmd+P).
- Tags and colors: `URLResourceKey.tagNamesKey`, `labelNumberKey`.
- Custom icons: paste onto the Get Info icon; API `NSWorkspace.setIcon(_:forFile:options:)`.

**Interaction**
- Spring-loaded folders: hover while dragging opens the folder; Space forces it open.
- Drag modifiers: Option copies; Cmd moves, which forces a move across volumes (the default across volumes is copy); Cmd+Option makes an alias. Plain drag within the same volume moves. In the API these map to `NSDragOperation.copy`, `.move`, `.link`.
- Cmd+Delete moves to Trash (`FileManager.trashItem` or `NSWorkspace.recycle`). Option+Cmd+Delete deletes immediately. Cmd+Z undoes moves, renames, and trashing. Put Back works from the Trash.
- Return renames, Cmd+O or Cmd+Down opens, Cmd+Up goes to the parent folder, Cmd+[ and Cmd+] go back and forward, Cmd+D duplicates, Cmd+L makes an alias, Cmd+R shows the original.
- Cmd+Shift+G opens Go to Folder (it has autocomplete and accepts `~`). Cmd+Shift+. toggles hidden files.
- Type-to-select. Option+Cmd+C copies the pathname. Cmd+Shift+N creates a new folder; Ctrl+Cmd+N creates a new folder containing the selection.
- Copy, then Option+Cmd+V, is Finder's hidden "move".

**Integrations**
- Services menu (`NSServicesMenuRequestor`).
- Share menu (`NSSharingServicePicker`).
- Quick Actions and Automator/Shortcuts actions, plus Finder Sync extension badges.
- Smart Folders (`.savedSearch` files backed by Spotlight `NSMetadataQuery` / MDQuery).
- Recents (a Spotlight query on `kMDItemLastUsedDate`).
- Open With (`NSWorkspace.urlsForApplications(toOpen:)`, `open(_:withApplicationAt:configuration:)`).
- Compress (Archive Utility). Burn. Connect to Server (Cmd+K: smb://, afp://, nfs://).
- Dropping a file onto an app icon opens it with that app.

## Top power-user complaints (our opportunity)
1. **No real Cut.** Cmd+X does nothing on files; Option+Cmd+V is hidden.
2. **No editable address bar.** Go to Folder is a modal sheet, and the path bar is read-only.
3. **Weak tree.** No persistent folder-tree pane; the sidebar is just a flat list of favorites.
4. **No folder sizes by default.** "Calculate all sizes" is slow and blocks.
5. **Slow on network/SMB/NAS shares and huge folders.** Beachballs, `.DS_Store` writes on shares, a long "Preparing…" phase.
6. **Inconsistent per-folder views.** `.DS_Store` makes views "forget" their settings, and "Use as Defaults" is confusing.
7. **No "New File" in the context menu**, unlike Explorer's New ▸ Text Document.
8. **Copy dialogs.** Conflicts are resolved one file at a time ("Keep Both / Stop / Replace"), with no queue, pause, or speed readout. A failure partway through aborts the whole job.
9. **Hidden paths everywhere.** Copying the full path is buried behind Option; there's no visible path in the title.
10. **Weak search scoping.** Search defaults to "This Mac", has no wildcard or regex, and gives no filename-only fast mode.
11. **Folders are mixed with files in sorting.** You can only switch this on with "Keep folders on top", which is a global setting.
12. **No dual pane, no batch rename with preview** (Finder's version is basic), **no checksums or permissions editing** beyond a few presets.

## Recommendation

**Keep these Finder conventions, which are non-negotiable for Mac users:**
- Return renames and Cmd+O / Cmd+Down opens. Never make Return open.
- Space for Quick Look (`QLPreviewPanel`).
- Cmd+Delete moves to Trash with undo (`NSUndoManager`) and Put Back.
- Cmd+1 to Cmd+4 view switching. List view with disclosure triangles.
- Drag modifier semantics (Option=copy, Cmd=move, Cmd+Opt=alias) and spring-loaded folders.
- Sidebar look and sections (Favorites, iCloud, Locations, Tags) with drag-to-customize.
- Cmd+I Get Info layout, tags and colors, Cmd+Shift+G, Cmd+Shift+., Cmd+[ / Cmd+], Cmd+Up, Cmd+T tabs.
- Native Services, Share, and Quick Actions menus, plus a native NSWindow toolbar style (unified, with Liquid Glass on Tahoe).
- Type-to-select. Proxy icon in the title bar.

**Deliberately follow Explorer here:**
- **Real Cut/Paste.** Cmd+X marks the files (shown ghosted) and Cmd+V moves them. Keep Option+Cmd+V too.
- **Editable address bar.** It shows breadcrumbs by default; a click, Cmd+L, or Cmd+Shift+G turns it into a text field with path autocomplete, `~`, env-style shortcuts, and pasted paths. Every crumb gets a dropdown chevron listing sibling folders.
- **Persistent folder tree in the nav pane**, below or merged with the Finder sidebar sections. It expands lazily and syncs with the current folder.
- **Details view as the default**, with right-click column chooser, per-column widths, and folders-first sorting (toggle per window). Folder sizes are computed asynchronously and cached.
- **Context menu** gets: New ▸ Folder / Text File / templates, Copy as Path, Open in Terminal, Open With ▸ list, Properties.
- **Copy/move queue:** a single progress panel with pause, throughput, and a conflict policy that applies to the whole batch ("apply to all", skip, rename, compare). Errors don't abort the whole job.
- **Status bar:** items, selected count, selected size, and free space.
- **Properties:** size and file count calculated live, editable POSIX permissions/ACL, checksum tab.
- **View state** is stored in our own database, not `.DS_Store`, and we never write to network shares.

**Speed targets that answer the complaints:**
- Enumerate directories with `getattrlistbulk(2)` or `fts`, streamed into a virtualized `NSTableView` / `NSOutlineView` (cell reuse, not SwiftUI `List`).
- Watch for changes with FSEvents (`FSEventStreamCreate`) or `DispatchSource` vnode watchers.
- Load icons and thumbnails lazily with `QLThumbnailGenerator` and `NSWorkspace.icon(forFile:)`, cached per UTType.
- All I/O runs off the main thread with cancellation, so slow network folders never beachball the UI.