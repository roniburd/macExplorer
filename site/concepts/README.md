# MacExplorer website: three concepts

Each concept is a single self-contained page in its own folder, using the same real screenshots from
`site/assets/shots/` (made with `site/tools/make-demo-folder.sh` against a throwaway demo home folder).
Open them locally with `python3 -m http.server -d site 8000` and visit `/concepts/a-phrasebook/`, etc.

All three borrow the same structure from the references: maccy.app's short "why" blocks and blunt copy
("one job… Period."), and multitouch.app's heading, a few bullets, one big screenshot per feature.

## A. Phrasebook: "Speaks Explorer. Lives on a Mac."

The audience is someone who moved from Windows. The page is a bilingual phrasebook: every entry is a thing
you want to do, how Finder makes you say it, and how MacExplorer lets you say it.

- Color: steel paper `#E6EBF0`, ink navy `#15233F`, highlighter `#FFE15A` (marks the MacExplorer column),
  red pencil `#B3261E` (marks the Finder detours), rule grey `#B9C3CE`.
- Type: Archivo (semi-condensed, heavy) for headwords; Source Serif 4 for entries and body.
- Layout: left-aligned dictionary entries in three columns (intent / Finder / MacExplorer); a screenshot
  sits in the margin of the entry it explains.
- The memorable thing: the yellow highlighter running down the MacExplorer column.

```
 MacExplorer                                 Download
 Speaks Explorer. Lives on a Mac.
 [big screenshot, tilted page-corner]
 ─────────────────────────────────────────────────────
 cut  (v.)   Finder: ⌘C, then ⌥⌘V    ▌⌘X, ⌘V ▐   [shot]
 go to (v.)  Finder: ⇧⌘G sheet        ▌type it ▐
 ...
```

## B. The window: the page is a MacExplorer window

The site is drawn as the app: a Liquid Glass window on a desktop. The sidebar is a folder tree of the page's
sections, the address bar shows where you are (and you can type in it), and each section is a "folder" whose
contents are screenshots and short notes. Closest to multitouch.app: one big screenshot per feature.

- Color: desktop dusk `#1F3557` to `#6F8FBF`, glass `rgba(246,248,252,.78)`, text `#1D1D1F`, accent
  folder-blue `#2F7CF6`, folder yellow for the icon tint `#F3C04A`.
- Type: the system UI face (SF Pro on a Mac), because looking native is the point.
- Layout: a fixed window frame; sidebar left, content right, status bar at the bottom that counts sections.
- The memorable thing: the address bar you can type into to jump around the page.

```
 ● ● ●  ◀ ▶ ↑ [ MacExplorer › Why we built it ⌄ ]      [⌕]
 ┌─ Folders ─────┬───────────────────────────────────────┐
 │ ▾ MacExplorer │  Why we built it                       │
 │   Why         │  [screenshot]                          │
 │   Cut & paste │                                        │
 │   Address bar │                                        │
 ├───────────────┴───────────────────────────────────────┤
 │ 6 sections · 1 selected · free and open source         │
```

## C. Keystrokes: "⌘X works now."

maccy.app's restraint. Text-led, big keycaps as the headline device. Each feature is introduced by the keys
that do it, because the keys are the feature. The hero is a tiny live demo: press ⌘X on the page and the rows
ghost; press ⌘V and they move.

- Color: aluminium `#E3E5E8`, keycap white `#FAFAFB`, graphite `#26292E`, folder yellow `#F2B632`,
  muted `#6B7079`.
- Type: Schibsted Grotesk throughout, heavy for keycaps and headlines, regular for body.
- Layout: one narrow centred column for text; screenshots break out wider.
- The memorable thing: physical-looking keycaps that press when you press them.

```
        [⌘][X]   [⌘][V]
        Cut and paste files. On a Mac.
        [ live mini list: press ⌘X, ⌘V ]
        Download  ·  brew install …
   ─── [⌘][L]  Type a path  ─── [screenshot] ───
```

## Review against the brief

- First draft of A used a cream background with a serif display; that is a generic default. Changed to a
  cool steel paper and a condensed grotesk for headwords, so it reads as a reference book, not a magazine.
- First draft of B used a gradient wash behind cards. Removed the cards: the gradient is now only the
  desktop behind a single window, which is the subject itself.
- First draft of C put numbered markers on features. Features aren't a sequence, so the keys replaced them.
