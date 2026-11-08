# MacExplorer user guide

Everything MacExplorer does, in detail. For a quick start, see the [README](README.md).

## Views & Tabs (Phase 2)

- **Tabs.** Every window is a native macOS tab group. ⌘T opens a new tab on the current folder (on `--root` in
  sandbox mode), ⌃Tab / ⌃⇧Tab move to the next / previous tab, ⌘W closes the tab, and ⇧⌘\ shows all tabs.
  Middle-click a folder in the content area, the sidebar or the folder tree to open it in a new tab; ⌘-click opens
  a new tab in the sidebar and the tree (in the content area ⌘-click still toggles the selection). "Open in New
  Tab" is also in the context menu. To open a dragged folder as a tab, drop it on the "＋" New Tab toolbar button
  (the P2-06 spike: AppKit's tab bar has no public drop target). Conflict and error dialogs of a job are shown on
  the tab that started it, which is selected first; if that tab has closed they go to the Operations panel.
- **Per-folder views.** Each folder remembers its view mode, columns, sort, icon size, density, Group by and "Calculate
  Folder Sizes" (keyed by volume UUID + file ID where IDs are stable, by path elsewhere). A folder you never changed
  follows Finder's view of it, application folders open as large icons, and everything else follows the defaults.
  View › Use as Default for All Folders makes the current view the default; View › Apply to All Folders… also forgets
  every folder's own view; View › Reset View for This Folder forgets this one's.
- **Group by** (View › Group By, or the context menu): Kind, Date Modified (Today, Yesterday, Earlier this Week…),
  Size buckets or Name (first letter), with floating group rows you can collapse. VoiceOver reads a group row as
  "<title>, <n> items, collapsed/expanded".
- **Quick Look.** Space opens and closes the Quick Look panel for the selection, and the arrow keys move through
  the items. While you are type-selecting (the last letter was typed less than a second ago) Space is part of the
  name, so `my f` reaches `my file.txt`.
- **Folder sizes.** View › Calculate Folder Sizes scans each folder of the current folder on a background lane:
  hard links count once, symlinks are never followed, other volumes are not entered, and iCloud placeholders are
  not downloaded. A size with unreadable or not-downloaded parts shows as "≥ 1.2 MB". Results are cached and
  updated through the file-system watcher; sorting by Size uses them.
- **More columns** (right-click a column header): Tags, Date Last Opened, Permissions (rwx), Owner, Comments, and
  Path in search results. All of them sort; their values are read in the background and refresh when another app
  changes only a tag or comment.
- **Copy Path As ▸** (Edit menu and context menu): POSIX Path (⇧⌘C, "Copy as Path"), ~ Path, File URL, Name,
  Quoted for Shell.
- **Thumbnails** in Icons view replace type icons for visible items once Quick Look has made them (never for iCloud
  placeholders); scrolling away cancels the request, and a 64 MB cache keeps recent ones.
- **Columns view** (⌘3, View › as Columns): one column per folder level. Selecting a folder opens the next column,
  → / ← move into and out of columns, and each column's trailing handle resizes it (double-click fits the names).

## Search & Preview (Phase 3)

- **Search field** (⌘F). Type to search; Esc clears it and returns to the folder. The scope bar under the toolbar
  has the scope chips **This Folder / Subfolders / This Mac**, a **Name / Contents** toggle, filters, progress,
  **Stop** and **Save**; the same choices are in View › Search. Which engine runs:

  | Scope | Name | Contents |
  |---|---|---|
  | This Folder | instant in-memory filter of the listed folder (every keystroke) | Spotlight, direct children only; a volume that isn't indexed falls back to the name filter with a notice |
  | Subfolders | our own crawler (parallel directory reads, packages and hidden folders skipped by default, symlinks never followed, other volumes never entered) | Spotlight inside the folder; not indexed → the crawler by name, with a notice |
  | This Mac | Spotlight over the whole Mac ("Spotlight is turned off" when indexing is off) | Spotlight |

  Every search other than the instant filter is debounced (250 ms) and shows its results in Details with a
  **Path** column. Retyping or changing the scope cancels the running search; its late results never appear.
- **Syntax** (close to Explorer's Advanced Query Syntax; terms are ANDed):

  | Token | Meaning |
  |---|---|
  | `word`, `"two words"` | a name term (Name mode) or content term (Contents mode); `*` and `?` make it a whole-name glob (`*.pdf`, `report?.doc`, `IMG_*`), case- and accent-insensitive |
  | `name:x`, `name:"a b"` | a name term in both modes |
  | `kind:` / `type:` + `folder document text pdf image movie audio archive app code` (plurals and synonyms work, comma-separated) | OR within one token and across repeated `kind:` tokens |
  | `ext:` / `extension:` + `pdf`, `.pdf`, `*.pdf`, `jpg,png` | OR |
  | `size:` + `>10MB` `>=1.5GB` `<1KB` `<=100` `=0` `1MB..10MB` `10MB` (±0.5 unit) `empty tiny small medium large huge gigantic` | repeated `size:` tokens intersect |
  | `modified:` / `date:`, `created:` + `today yesterday thisweek lastweek thismonth lastmonth thisyear lastyear last7days last30days`, `2026-01-31`, `>2026-01-31`, `>=`, `<`, `<=`, `2026-01-01..2026-01-31` | repeated tokens intersect |
  | unknown key (`foo:bar`), quoted `"kind:image"` | a literal term |
  | a known key with a bad value (`size:big`, `kind:spaceship`) | ignored, with "Didn't understand 'size:big'" under the field |

  Sizes are decimal like the sizes the app shows (`KB` = 1,000 bytes, `MB`, `GB`, `TB`); `KiB`, `MiB`, `GiB`, `TiB`
  are binary. Size words: empty < 1 B, tiny < 16 KB, small < 1 MB, medium < 128 MB, large < 1 GB, huge < 4 GB,
  gigantic ≥ 4 GB.
- **Filters** (the scope bar's Filters button): kind, date modified and created ranges, size range and extension,
  combined with the typed query.
- **Saved searches.** File › Save Search… (or Save in the scope bar) adds the search to the sidebar's **SEARCHES**
  section. Click one to run it again; rename, reorder (drag) or remove it from its context menu. Del on a saved
  search removes only the saved search, never a file.
- **Working with results.** Results follow file operations without re-running: trashed and moved items disappear,
  renamed ones show their new names. Double-click a folder result to open it and ⌘[ to return to the same results.
  Go › **Open Containing Folder** (⌥⌘R) opens the item's folder with the item selected. View › Search › **Stop
  Search** cancels a running search. A search stops at **100,000 results** and says "Showing the first 100,000
  results. Refine your search."
- **Preview pane** (View › Show Preview Pane, ⌥P, like Explorer). It shows the selection: text and code as a fast
  preview of the first 256 KB (with a note when the file is longer), other types in Quick Look, folders and
  multiple items as a summary, and a details grid underneath (size, dates, dimensions or duration). An iCloud
  file that is not downloaded is never read: the pane offers a **Download** button instead. ⌥P typed while a text
  field has focus types "π" and leaves the pane alone. The pane's visibility and width are remembered.
- **Spotlight notes.** Contents and This Mac need Spotlight indexing (`mdutil -s /` shows the state; macExplorer
  only ever runs `mdutil -s`). Volumes that aren't indexed fall back to name search with a notice. Protected
  folders (Desktop, Documents, Downloads, iCloud Drive without a recorded grant, and app data under `~/Library`)
  are skipped by Subfolders search without asking for access, and counted in "N folders were skipped".
- All new commands (preview pane, Open Containing Folder, the search scopes and modes, Stop, Save Search) can be
  rebound in Settings › Shortcuts.

## Updates

MacExplorer checks for updates once a day and downloads them in the background. When one is ready, a
**Restart to Update** button appears in the toolbar. Choose **Release** or **Beta** in Settings › General › Updates.
Moving from Beta back to Release never downgrades: you stay on your beta until a newer release ships.

## Feedback and crashes

Help › **Report a Bug…** / **Request a Feature…** (also in the toolbar's **Send Feedback** menu) open a prefilled
GitHub issue (you need a GitHub account and you review everything before submitting). If MacExplorer crashes, it
offers to report it the next time you open it; turn this off in Settings › Advanced.

## Things macExplorer does not do

- **It does not replace Finder as the system file viewer.** macOS has no public API for that, so "Show in Finder"
  in other apps, the Dock's Finder icon and Open/Save panels still use Finder.
- **Cut in macExplorer, paste in Finder copies.** Cut writes the file URLs plus a private marker that only
  macExplorer understands. Finder sees ordinary file URLs and copies them. To move from macExplorer to Finder, drag
  the items, or copy them and use Finder's ⌥⌘V (Move Item Here). The other way round works: Finder ⌘C, then
  macExplorer ⌥⌘V (Move Item Here) moves.
- Libraries, Previous Versions, NTFS security tabs, drive letters, Mac App Store distribution, macOS before 26.
- "Put Back" from the Trash is not offered; undo restores trashed items instead.
- **Very large copies are slower to paste elsewhere.** Above 5,000 items, copy, cut and drag write each file URL as
  a promise that macExplorer fills in when another app asks for it (writing 100k items up front takes over 20 s).
  Pasting inside macExplorer is unaffected. Pasting those items in another app, or quitting macExplorer while they
  are on the clipboard, takes about 1 ms per item. Above 5,000 items the clipboard also has no plain-text list of
  the paths.

Function keys: F2 (rename) and F5 (refresh) need fn held, unless "Use F1, F2, etc. keys as standard function keys"
is on in Keyboard settings. Development builds are ad-hoc signed, so macOS may ask again for folder access after a
rebuild.

