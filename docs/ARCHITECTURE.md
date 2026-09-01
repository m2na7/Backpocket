# Architecture

This document describes the high-level structure of Backpocket: the map, the
invariants, and the concerns that cut across modules. It is aimed at recurring
contributors, names symbols rather than files (symbols are searchable; file
links go stale), and is updated when the shape of the code changes — not on
every PR.

## Bird's-eye view

Backpocket is a menu-bar app with one job split in two: record what you copy,
and keep what you type. A timer polls `NSPasteboard.changeCount` every 0.5s
(macOS offers no pasteboard change notification; polling is what every
clipboard manager does). New content flows through `ClipboardWatcher`, which
classifies it — text with optional HTML/RTF flavors, or an image — into
`Store`, the single owner of all reads and writes against a SwiftData
container with exactly one `@Model` type, `Item`. The UI is SwiftUI hosted
inside a non-activating AppKit `NSPanel`, so opening the panel never
deactivates the app you are about to paste into. Pasting reverses the flow:
`Store` marks the item used, the panel hides so the previous app is frontmost
again, and `Paster` writes the pasteboard and (optionally) synthesizes Cmd+V.

`AppDelegate` is the composition root: it owns the store, the watcher, and
every window, and wires them together with closures. Nothing else holds more
than one of these.

## Codemap

One bullet per symbol worth knowing about, grouped by module. Within a module
the windows and views come first and the pure value types they were extracted
from come after — that extraction is the project's main testing move, so a new
one belongs on this list next to the view it came out of, with a line saying
what rule it owns. A type that has its own test suite and is not named here is
a bug in this document.

### `App`

- `BackpocketApp` — SwiftUI entry point; the menu-bar extra. The executable
  target is a one-line `main` that calls it.
- `AppDelegate` — composition root. Builds the store, starts the watcher,
  creates the panels, routes paste/edit/detail actions between them.
- `HotKey` — wrapper around Carbon `RegisterEventHotKey`. An NSEvent global
  monitor cannot consume events, so the shortcut would leak through to the
  frontmost app; Carbon is the only API that swallows it.
- `HotKeyBinding` — the global-shortcut struct (key code + modifiers) that
  `HotKey` registers.
- `PanelShortcut` — the rebindable in-panel actions (open links, pin, …),
  each with its own `KeyBinding` struct and default.
- `Onboarding` — the single-task screen shown when the accessibility
  permission is missing.
- `DebugLaunch` — DEBUG-only launch flags (see Testing seams below).

### `Clipboard`

- `ClipboardWatcher` — polls `changeCount`, honors the nspasteboard.org
  marker types, applies the per-app ignore list, and classifies the change
  into `CopiedContent` (`.text` with optional HTML/RTF flavors, or `.image`).
  It owns the flavor-priority rules — consumers never re-read the pasteboard.
  Oversized flavors are dropped whole, never truncated: half a document does
  not parse and half an image is no image.
- `CopySource` — which app the copy came from (name + bundle ID).
- `Paster` — writes the pasteboard (string + rich flavors, or PNG + a TIFF
  rendition for image clips) and synthesizes Cmd+V when automatic pasting is
  on. Automatic pasting is the only thing that needs Accessibility trust.
- `PasteFlavor` — which representation of a stored item leaves the app. The
  narrowest and most consequential decision in the codebase, kept as a value
  rather than as branches inside the app delegate so it can be tested: a
  regression that lets typed text resolve as a file copy pastes the private
  key at `~/.ssh/id_rsa` where the user expected the text of its path.

### `Storage`

- `Item` — the one `@Model`: a clipboard entry *or* a note, in one table,
  distinguished by `isNote`. Image bytes, thumbnails, and RTF live in
  `.externalStorage` so the list's queries never page megabyte blobs.
- `Store` — the single owner of all reads and writes; the UI observes its
  published `items` array. See Invariants for the ordering contract. Takes the
  history limit as an injected closure — note this does not sever Storage from
  Settings, since the default argument still names `HistoryLimit`; it exists
  so a test can supply a limit, and so a Settings change lands on the next
  copy rather than the next launch.
- `DeletionUndo` — the bounded record of what the last few deletes removed, so
  a mis-hit ⌘⌫ can be taken back. SwiftData has no undelete, so it holds the
  row's values and `Store.undoDelete()` re-creates the row from them; a bulk
  delete is one batch and undoes in one step. Owns the retention decision —
  20 seconds, three deletes deep — which is a privacy bound, not a UX one:
  anything held here is content the user asked to destroy.
- `Persistence` — builds the `ModelContainer` at a dedicated path, carrying an
  older store forward through the migration plan (see Cross-cutting concerns).
- `Schema` — the model's shape history as `VersionedSchema`s, plus the
  `SchemaMigrationPlan` that joins them.
- `ImageInfo` — pixel size read from the image header (no decode) and the
  thumbnail rendered once at record time.
- `WebLink` — the one definition of "this text is a lone web URL". Two copies
  of this rule drifted apart once already, with the watcher and `Item` each
  accepting a different set of schemes; both call this now.

### `Panel`

- `BackpocketPanel` — the main popup: a `.nonactivatingPanel` `NSPanel`,
  which is the whole trick that keeps focus in the frontmost app. Also owns
  hold-to-move dragging and auto-hide on losing key status.
- `ContentView` — everything inside the panel: the single field that is both
  search and note entry, the clips and notes lists, selection and hover
  state.
- `ItemRow` — one row of the clips and links lists. `FileClip` and `Thumbnail`
  are defined beside it: both are caches that exist because a row body must
  never touch the filesystem or decode an image per render.
- `NoteRow` (with `NoteSection` and `NoteRowData`) — one row of the notes
  column and the buckets it is grouped into. Rows carry a preformatted time
  label so the body never touches a `DateFormatter`.
- `EnterAction` (with `Pane`) — the pure decision table for what ↩ and ⌘↩ do
  given pane, text, matches, and selection. Fully unit-tested; keep it free
  of UI types.
- `HoverMachine` — arbitration between the pointer and the keyboard for the
  single highlight the panel shows. Keystrokes re-lay the lists out under a
  stationary pointer and the tracking areas then re-fire entry for whatever
  row slid underneath, so once the keyboard takes the highlight, hover entries
  are held; only real hardware travel past a 12pt threshold — which layout
  cannot synthesize, and which outruns trackpad palm jitter — lifts the hold.
  A value type with no SwiftUI and no store, and the panel's trickiest rules:
  fix hover bugs here, not in the view.
- `PaneOrder` — which panes are on screen and where Tab goes next. Links and
  notes are both optional (per preference), so this is the one place that
  knows what "the next pane" means; focusing a pane the user cannot see
  advertises actions against invisible rows.
- `PanelSelection` (with `PaneRows`) — where the selection is and where it goes
  next, over the three lists reduced to identifiers. Taking rows stripped of
  everything else is what keeps the rules testable without a store, a query,
  or a view.
- `SplitDrag` — the notes column's share of the panel width, and the
  arithmetic of dragging the divider. Stored as a fraction so the split
  survives a resize but rendered in points with a floor under each column, so
  the two representations can disagree — which is where every bug in it has
  come from.
- `PasteStack` — the clips collected with ⌘D, in pick order, that releasing ⌘
  pastes joined by newlines. Tracks as it is built whether the handful would
  insert anything, because resolving each id against the store inside a view
  body was O(stack × items) on every render.
- `DetailPanel` — the hover preview card, a child window that is never made
  key (a SwiftUI popover would grab focus and misfire the panel's auto-close).
- `EditPanel` — the note editor; non-activating like the main panel, but it
  does take key focus, so `AppDelegate` suspends the main panel's auto-hide
  while it is open.
- `PanelLists` — pure derivation of what the panel shows (clip/link/note
  partitioning, search filtering, note sectioning) from the store and the
  query, so it is testable without a view. Under `LinkCollection.both` the
  clips and links lists deliberately share rows: one item is two rows, which
  is why nothing downstream may identify a row by its item alone — the pane
  is passed in (`ContentView.column`, `HoverMachine.Entry`) rather than
  worked out from what the row holds.
- `NoteGrouping` — the Apple Notes-style recency buckets (`NoteGroup`) the
  notes column is grouped by, keyed off `usedAt`.
- `RowChrome` — small shared row furniture: the pick-order `StackBadge`, the
  `⌘`-slot `ShortcutChip`, and search-match emphasis.
- `PanelMetrics` — the panel's row grid and section sizing constants, shared
  by the first-run window size and the section frames.
- `PaneChrome` — chrome shared by the panel's two column builders:
  `SectionTitle` and the empty-state `EmptyLine`.
- `FileClip` — resolves and caches a file copy's paths (`Item.fileURLs`) off
  the render path, since touching the filesystem per row render is too slow.
  Defined in `ItemRow`.
- `Thumbnail` — the per-item image thumbnail cache, with eviction. Also
  defined in `ItemRow`.
- `AppIcon` — per-bundle-ID and per-file-path icon caches (`NSWorkspace`
  lookups are too slow to repeat on every row render).
- `Favicons` — the panel's one network-capable component: opt-in link-icon
  fetching (off by default), vetted to the link's own host over HTTPS (with
  redirects checked and capped), backed by a size- and age-bounded on-disk
  cache that also remembers misses so a dead host isn't reprobed every
  launch.

### `Settings`

- `PreferenceStore` — the defaults database every preference read and write
  goes through; no preference reaches `UserDefaults.standard` directly. See
  Testing seams for why the override is a task-local, and for the one
  non-preference defaults read that sits outside this store.
- `PreferenceName` — the preferences as a `CaseIterable` enum of stored
  spellings. `PreferenceKey.all` is derived from `allCases`, so "Reset
  everything" covers a new preference the moment it is declared; the
  hand-kept list it replaced could silently skip whatever nobody remembered.
- `PreferenceKey` — the same spellings as plain `String` constants, for call
  sites that need one (`@AppStorage` in particular). Owns `resetAll(in:)`,
  which wipes `all` plus `AppleLanguages` — not our key, but `AppLanguage`
  writes it, so leaving it behind keeps the UI in a language the reset just
  forgot choosing.
- `ExpiryOption`, `HistoryLimit`, `PasteBehavior`, `PopupPosition`,
  `IgnoredApps`, `AppLanguage`, `LinkCollection`, `LinkClickAction`,
  `LinkRows`, `NotesVisibility`, `NotesFraction`, `PanelSize`,
  `PreviewBehavior` — one small type per preference, each owning its `current`
  read and a `static let default` that both that read's fallback and the
  Settings control's `@AppStorage` initializer name, so the two cannot
  disagree about what an untouched install means. (The two keyboard bindings,
  `HotKeyBinding` and `PanelShortcut`, live in `App` — see above.)
- `AppRestart` — relaunches the app, which a language change requires. It
  quits the old instance only once the replacement has actually opened: on a
  failed relaunch the running instance is all the user has.
- `SettingsWindow` — System Settings-style toolbar tabs via
  `NSTabViewController`. The one window that activates normally: in an
  `LSUIElement` app it would otherwise open behind everything.
- `GeneralPane`, `ShortcutsPane`, `HistoryPane`, `IgnorePane`, `DataPane` —
  the five tabs, in `SettingsView`.

### `Text`

- `ContentFormatter` / `ContentKind` — heuristic prose-vs-code
  classification; surface signals only, no parsing.
- `SyntaxHighlighter` / `CodeLanguage` — detection and GitHub-style
  highlighting for the handful of languages worth telling apart in a preview.
- `TokenEstimate` — a rough LLM token count for the detail card, deliberately
  an approximation (≈4 ASCII characters per token, ≈1 per CJK character)
  rather than a shipped tokenizer: it only has to answer "will this fit in a
  prompt".
- `HTMLToMarkdown` — converts the pasteboard's HTML flavor to Markdown by
  letting Foundation's HTML-tidy parser normalize the fragment into a real
  tree first, so the walk stays simple.

## Invariants

- **One third-party dependency, and it is Sparkle.** Everything else is a
  system framework — SwiftUI, AppKit, SwiftData, Carbon, CryptoKit, ImageIO,
  ServiceManagement, OSLog. Keeping the count at one is deliberate and
  load-bearing for a tool that reads everything you copy: every dependency is
  someone else's code running with the same access. Adding a second needs the
  same argument Sparkle had to win, in an issue, first.
- **The updater is the only unprompted request**, and `Updater` is the only
  place that starts it. It refuses to start against a feed it cannot use,
  because starting on a bad feed hangs the app before its first window. Updates carry
  an EdDSA signature checked against `SUPublicEDKey` before install — that
  check is what separates an update channel from a remote execution channel,
  and nothing may make it conditional.
- **Nothing else reaches the network by default.** The one exception is
  `Favicons`, off unless the
  user turns it on (`FaviconFetching.isEnabled`): over HTTPS, to the link's
  own host — its root page and parent domain included — never a third-party
  favicon service, never local or private hosts, through an ephemeral
  cookie-less session. Everything else: no URLSession, no sockets.
- **A clip and a note are one row.** `Item` is the only model; `isNote` is a
  flag, not a table. Converting a clip to a note mutates in place, keeping
  source and timestamps. This is the product thesis, not a storage shortcut.
- **Notes and pinned items never expire.** `Item.isDisposable` is the single
  gate that expiry, history-limit trimming, and Clear History all go through.
- **`Store.items` is always sorted by `usedAt` descending, maintained
  incrementally.** Every mutation that bumps `usedAt` sets it to `Date()` —
  the global maximum — so `promote(_:)` can move that item to the front and
  the order is preserved without refetching or re-sorting. The guard is
  `isTracked(_:)`: callers hold `Item` references across time (an open editor
  outlives its row), and mutating a reference that trimming or expiry already
  deleted would re-insert the dead model at the front — a ghost row with no
  backing store that also hijacks `add`'s dedup. Writes through stale
  references are dropped instead.
- **Panels never activate the app.** `BackpocketPanel`, `DetailPanel`, and
  `EditPanel` are all non-activating; focus never leaves the paste target.
  `SettingsWindow` is the sole, deliberate exception.
- **Backpocket's own pasteboard writes are never recorded.** Every `Paster`
  write goes inside `ClipboardWatcher.suppressingOwnWrite { … }`, which polls
  first, then writes, then resyncs. The poll first is the point: a copy the
  timer has not seen yet — the user copies in Safari and immediately presses
  the hotkey — is still pending on the pasteboard, and resyncing without
  draining it would discard that copy forever. Do not call
  `skipCurrentChange()` directly; on its own it resyncs past every change
  since the last poll, not just Backpocket's, which is exactly that data loss.
- **nspasteboard.org marker types are honored.** Content flagged
  `ConcealedType` (password managers), `TransientType`, or
  `AutoGeneratedType` is never recorded.

## Cross-cutting concerns

### Concurrency

Everything that touches SwiftData or AppKit is `@MainActor`. `Store` is
main-actor-isolated because the UI is its only consumer, which keeps all
SwiftData access single-threaded by construction — there is no background
queue to race with.

### Schema changes

Notes are permanent data, so a schema change must never be a data loss event.
Every shape the model has ever had is frozen as a `VersionedSchema` in
`Schema.swift`, and `BackpocketMigrationPlan` carries a store from each one to
the next; `Persistence` hands that plan to the `ModelContainer`, so an older
store opens by migrating in place and nothing is moved aside.

Changing `Item` therefore means three edits, not one: add a new
`BackpocketSchemaV<n>` holding the new shape, point the `Item` typealias at it,
and add the stage that reaches it. Additive attributes with defaults migrate
`.lightweight`; anything that has to reinterpret existing rows needs a
`.custom` stage that says what the old data means, because a field V<n-1> never
recorded cannot be guessed from content. A version added without a stage is a
silent regression — a store on it becomes unopenable and drops into the path
below — which is what `everyAdjacentSchemaVersionHasAStage` guards.

Backup-and-reset still exists, but only as a last resort: it runs when a store
will not open even with the plan (a corrupt file, not an old one). The files
are set aside as `.bak` rather than deleted, one attempt per version, and if
even that fails the app opens in memory and raises the flag `Store` surfaces
to the user. A store written by a *newer* build than the one running is the
one case nothing can rescue — SwiftData traps rather than throws on it, and a
trap cannot be caught.

### Localization

Four `.lproj` bundles: `en`, `ko`, `ja`, `zh-Hans`. Every user-visible string
goes through `Localizable.strings` and must land in all four; no string ships
in English only.

`scripts/check-localization.sh` enforces it — key parity across the four files
plus a duplicate-key check — and runs in `make lint` and in CI. It has to: a
key missing from one bundle is not a build error and does not fall back to
English, it renders as the raw identifier.

### Testing seams

- `ClipboardWatcher` takes an injected `NSPasteboard` and a
  `frontmostApplication` closure, so tests run against a private pasteboard
  with a faked copy source.
- `Store` takes a `ModelContext`; tests hand it an in-memory
  `ModelContainer`. It also takes `disposableLimit` as a closure rather than a
  number, so a history-limit change in Settings applies to the very next copy
  instead of to the next launch.
- **Preferences are injected with a task-local, not a settable global.**
  `PreferenceStore.withDefaults(_:_:)` binds a throwaway `UserDefaults` for
  the duration of a body. The distinction is the whole point: swift-testing
  runs suites in parallel, so a settable global would let one suite's
  throwaway store leak into another suite's reads — moving the race rather
  than removing it. A task-local is visible only inside the body that bound
  it, so two suites can hold two different stores in the same instant. Both
  the binding and the accessor are `#if DEBUG`; release compiles down to
  `{ .standard }`.

  This is what let every suite drop `.serialized` — none remains — and it is
  why a test must never reach for `UserDefaults` on its
  own. Prefer parameters over reads where you can: `PanelMetrics.panelHeight`
  takes the row count as an argument, which turned a preference-dependent
  assertion into pure geometry.
- **One defaults read is deliberately outside `PreferenceStore`.**
  `Persistence.resetDefaults` — where the last-resort reset records that it
  has already tried once — falls back to `UserDefaults.standard`. That
  fallback is the app's real one and stays; its test override is scoped the
  same way preferences are. A test does not have to inject one:
  `markResetAttempted` returns early for a throwaway store, so a migration
  test that supplies nothing never reaches the write. Injecting is for tests
  that are exercising the guard itself.
- **`isUsingFallbackStore` is the one shared flag that cannot be scoped.** It
  is real app state that `Store` and the UI read, so it is a plain static and
  has to stay one. What made `MigrationTests` serializable was tests *writing*
  it as a side effect of opening a container; the test entry point now returns
  that value instead of assigning it. `setUsingFallbackStoreForTesting`
  remains for three `StoreTests`, and is safe only because every suite that
  touches it is `@MainActor` with synchronous bodies, which cannot interleave.
  Put an `await` inside one of those bodies and the window opens — at which
  point the flag should be injected into `Store.init` the way the history
  limit already is.
- DEBUG builds accept launch flags (`--open`, `--query=`, `--settings`,
  `--settings-tab=`, `--edit`, `--store=`, `--snapshot=`, `--demo`,
  `--stack=N`) that drive the UI into a known state for screenshot-based
  verification — a shell cannot type into a non-activating panel, so launch
  arguments are the automation interface. They compile out of release builds.
  `--demo` also bypasses the onboarding gate, because the accessibility check
  would otherwise replace the list with onboarding on any machine that has not
  granted the permission. `--snapshot=` captures whichever window the other
  flags opened — the main panel, the editor under `--edit`, or a Settings pane
  under `--settings --settings-tab=N`, with Settings winning when both are
  passed since it is the only one of the three that activates.
  CONTRIBUTING.md documents both for contributors.
