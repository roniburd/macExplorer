# UX / Visual Design Direction for macExplorer

**Environment check:** macOS 26.7.2 (25G332), arm64, Swift 6.4. `xcode-select -p` points to `/Library/Developer/CommandLineTools`, and there is no Xcode.app in `/Applications`, so **full Xcode is not installed**. SwiftPM plus AppKit/SwiftUI will compile with the Command Line Tools. Some things need Xcode 26: `actool` (asset catalogs), Icon Composer (layered Liquid Glass app icon), Instruments (needed to prove the speed target), `xcodebuild` and previews. Install Xcode before polishing the UI or doing performance work.

## 1. Lessons from existing Mac file managers
| App | Does well | Does poorly |
|---|---|---|
| **Path Finder** | Dual pane, drop stack, path bar, lots of info panels | Cluttered chrome with too many modules; feels slow and non-native; inspector overload |
| **ForkLift 4** | Clean native look, tabs, sync and remote, sidebar like Finder's | Tree view is weak; address editing is hidden |
| **Commander One** | Fast two-panel, F-key ops, queue for file operations | Looks dated, Windows-like; poor Mac fit |
| **Marta** | Very fast, keyboard-first, scriptable, command palette | Spare UI; the tree and drag & drop are secondary |
| **QSpace** | Multi-pane grids, editable path, close to Finder | Layout presets get confusing; settings are dense |
| **Nimble Commander** | Extremely fast native AppKit, handles huge folders | Utilitarian, plenty of chrome, steep learning curve |

**What to take:** Nimble's AppKit speed, Marta's command palette, ForkLift's native chrome, QSpace's editable path, Commander One's visible operation queue. **What to avoid:** Path Finder's clutter and custom-drawn (non-native) controls.

## 2. Design principles
1. **Native AppKit chrome first.** `NSWindow` with `NSToolbar` (unified style), `NSSplitViewController` holding sidebar, content and inspector items, `NSOutlineView`/`NSTableView` (view-based, cell reuse) for the list. SwiftUI only for Properties and Settings. This keeps Liquid Glass "free" and the list fast.
2. **Liquid Glass (macOS 26):** the toolbar and sidebar float as glass over the content. Use `NSSplitViewItem(sidebarWithViewController:)` and `NSSplitViewItem(inspectorWithViewController:)`, and let content extend under the toolbar via `NSScrollView` automatic insets / `.backgroundExtensionEffect()`. Group toolbar buttons with `NSToolbarItemGroup` so they form glass capsules. Use `NSGlassEffectView` only for custom floating elements such as the operations HUD. Never put glass on top of glass, and never on list rows.
3. **SF Symbols everywhere** (`NSImage(systemSymbolName:)`): `chevron.left/right`, `arrow.up`, `sidebar.left`, `list.bullet`, `square.grid.2x2`, `rectangle.split.3x1`, `sidebar.right`, `magnifyingglass`, `folder`, `externaldrive`, `icloud`, `network`, `trash`, `info.circle`, `square.and.arrow.up`. Use monochrome rendering in the toolbar and hierarchical rendering in the sidebar.
4. **Density:** three row heights: Compact 20pt (Explorer-like), Regular 24pt (Finder default), Comfortable 30pt. Set them through `NSTableView.rowSizeStyle` plus a custom `rowHeight`. Map them to `NSControl.ControlSize` (.small/.regular/.large). Toggle with ⌘⌥1/2/3.
5. **Dark mode and accent colour:** semantic colours only (`.labelColor`, `.secondaryLabelColor`, `.separatorColor`, `.controlAccentColor`, `NSColor.alternatingContentBackgroundColors`). Use `.unemphasizedSelectedContentBackgroundColor` when the window is inactive. Honour "Reduce transparency" (glass falls back to opaque automatically), "Increase contrast" and the tinted/clear icon modes.
6. **Keyboard first:** every action is in the main menu, so it can be rebound in System Settings and found with Help search.
   - **Finder keys:** ⌘↑/⌘↓ up/open, ⌘[ ⌘] back/forward, ⌘⌫ trash, ⌘C/⌘V, ⌘⌥V move (cut), ⌘I properties, Space Quick Look.
   - **Explorer extras:** ⌘L / ⌘⇧G focus the address bar, F2 or Return to rename (configurable), Return/⌘O open (selectable mode), ⌘⇧N new folder, ⌘T tab, ⌘K command palette, type-to-select, ←/→ in the tree to collapse/expand.
   - **Focus:** Tab/⇧Tab cycles sidebar → tree → list → preview.
7. **Accessibility:** native controls give VoiceOver roles. Add `setAccessibilityLabel` to icon-only buttons, rotor-friendly table headers, Dynamic Type through the `.body` text style, minimum hit targets of 24pt, never colour-only status (use tags plus a symbol), and full keyboard access.

## 3. Main window wireframe
```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  [◀ ▶ ↑]  [ 💻 > Users > roni > dev > macExplorer ⌄ ]⟳  [☰ ▦ ⫴] [⌕ Search… ]│ ← unified glass toolbar
│         Tab: macExplorer ×  │ Downloads × │ +                                    │ ← optional tab bar
├───────────────────┬──────────────────────────────────────────────┬───────────────┤
│ FAVORITES         │ Name ▲            │ Date Modified │Size │Kind│  PREVIEW /    │
│  ⌂ roni           │ ▸ 📁 Sources      │ Today 10:02   │ --  │Fold│  DETAILS      │
│  🖥 Desktop       │ ▾ 📁 Docs         │ Yesterday     │ --  │Fold│  ┌─────────┐  │
│  📄 Documents     │     📄 spec.md    │ Yesterday     │ 4 KB│MD  │  │ thumb   │  │
│  ⬇ Downloads      │ 📄 Package.swift  │ 1 Nov 2026    │ 1 KB│Swft│  └─────────┘  │
│ LOCATIONS         │ 🖼 icon.png       │ 30 Oct 2026   │88 KB│PNG │  spec.md      │
│  💽 Macintosh HD  │                   │               │     │    │  4 KB · MD    │
│  ☁ iCloud Drive   │                   │               │     │    │  Created …    │
│  🌐 Network       │                   │               │     │    │  Modified …   │
│ TAGS  ● Red ● Blue│                   │               │     │    │  Tags  [+]    │
│ FOLDERS (tree)    │                   │               │     │    │               │
│  ▾ 💽 Macintosh HD│                   │               │     │    │               │
│    ▾ Users        │                   │               │     │    │               │
│      ▸ roni       │                   │               │     │    │               │
├───────────────────┴──────────────────────────────────────────────┴───────────────┤
│ 5 items · 1 selected (4 KB) · 212 GB available     ⟳ Copying 3 of 120 ▮▮▮▯ 64%  ▦│ ← status bar
└──────────────────────────────────────────────────────────────────────────────────┘
```
- **Address bar:** a breadcrumb made of segmented `NSPathControl`-style buttons. Each segment opens a menu of its child folders, as in Explorer. Clicking empty space or pressing ⌘L turns it into an editable `NSTextField` that accepts `~`, `/`, `smb://` and env-style paths, with autocomplete from `contentsOfDirectory` in a dropdown. Esc reverts, and an invalid path shakes the field and shows red text.
- **Left pane:** a single source-list `NSOutlineView` with collapsible sections (Favorites, Locations, Tags, Folders). Folders is a lazily loaded tree that syncs to the current folder (auto-reveal can be turned off).
- **Columns:** right-click the header to choose columns (Name, Date Modified, Created, Last Opened, Size, Kind, Tags, Extension, Path, Permissions, Owner, Comments). Columns can be reordered, resized and saved per folder or globally. Folder sizes are computed async with a spinner. Show a "+ N items" count in the status bar as results stream in.
- **Status bar:** item count, selection size, free space, and a progress meter for running operations that opens a queue popover (pause, cancel, conflict prompts).
- **View modes:** list (details), icons, columns (Miller), gallery (phase 2). Panes are toggled by the toolbar segments.

## 4. Context-menu structure (`NSMenu`, built per selection)
```
Open                         ⌘O
Open With ▸  [default app ✓, …recommended, Other…, App Store]
Open in New Tab / Window     ⌘⏎
Show in Enclosing Folder     ⌘R   (search/recents only)
──────────
Cut                          ⌘X   (dims item until pasted)
Copy                         ⌘C
Paste / Paste Item Here      ⌘V   / Move Item Here ⌘⌥V
Copy Path ▸  [POSIX path ⌘⌥C, ~ path, file URL, name only]
Duplicate                    ⌘D
Make Alias / Create Symlink
──────────
Rename…                      F2 / ⏎
Move to Trash                ⌘⌫   (Delete Immediately… ⌥⌘⌫)
──────────
Compress "x" / Extract Here
New ▸  [Folder ⌘⇧N, Folder with Selection, Text File, Empty File]
──────────
Properties…  (Get Info)      ⌘I
Quick Look                   Space
Tags ▸ [colour dots], Tags…
Share ▸ (NSSharingServicePicker)
──────────
Open Terminal Here / Copy to ▸ / Move to ▸ (recent destinations)
Services ▸ / Quick Actions ▸  (system)
```
- **Empty-space menu:** Paste, New ▸, View as ▸, Sort by ▸, Group by ▸, Show View Options, Properties of folder.
- **Drag & drop:** ⌥ copies, ⌘ moves, ⌃⌥ makes an alias. Spring-loaded folders, a drop highlight on tree nodes, and a badge with item count plus an operation symbol.

## 5. Properties window (SwiftUI `Form`, non-modal, one per item; multi-select gives summed values)
```
┌─ spec.md Properties ───────────────────────────────┐
│ [General] [Permissions] [Details] [Open With]      │  ← segmented / TabView
├────────────────────────────────────────────────────┤
│  [icon 64]  [ spec.md                 ]  ⊠ Locked  │
│  Kind:      Markdown document                      │
│  Location:  ~/dev/macExplorer/Docs  [Reveal]       │
│  Size:      4,096 bytes (8 KB on disk)             │
│  Contains:  — (folders: 12 files, 3 folders ⟳)     │
│  Created / Modified / Opened: …                    │
│  Tags: ● Blue [+]     Comments: [            ]     │
│  ☐ Hide extension   ☐ Stationery   ☐ Hidden        │
├── Permissions ─────────────────────────────────────┤
│  Owner [roni ⌄] R/W   Group [staff ⌄] Read  Everyone│
│  ACLs list (+/−)   [Apply to enclosed items…]  🔒   │
├── Details ─────────────────────────────────────────┤
│  UTType, xattrs, inode, quarantine/where-from,     │
│  EXIF/media metadata (MDItem)                      │
├── Open With ───────────────────────────────────────┤
│  [App ⌄]  [Change All…]  (NSWorkspace.setDefault…) │
└────────────────────────────────────────────────────┘
```
- Changes apply live, as in Finder. Edits that need privileges go through an authorization prompt.

## 6. Phase-2 UX hooks to reserve now
- Preview pane (QLPreviewView)
- Custom icons (drop onto the Properties icon; `NSWorkspace.setIcon`)
- Search scope chips in the toolbar (This folder / Mac / Name vs Contents, driven by `NSMetadataQuery`)
- Tabs (`NSWindow.tabbingMode`)
- Dual-pane toggle
- Command palette (⌘K)