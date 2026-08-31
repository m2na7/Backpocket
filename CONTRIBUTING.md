# Contributing to Backpocket

Thanks for helping. A few ground rules keep the project easy to maintain.

## Prerequisites

- macOS 14+
- Xcode 26.4.1 (Swift 6.3.1). CI pins exactly this version, so a different
  toolchain can format code that CI's `swift format lint` then rejects —
  the formatter travels with the toolchain and its output moves between Swift
  releases. The pin lives in `DEVELOPER_DIR` in `.github/workflows/ci.yml` and
  in `.swift-version`; change them together.

**First run needs the Accessibility permission, or it looks broken.** "Paste
automatically" is on by default, and that setting is what requires
Accessibility trust — so on a machine that has never granted it, `make run`
shows the onboarding screen instead of the clipboard list. That is the app
working correctly, not a build failure. Three ways past it:

- Grant the permission (System Settings > Privacy & Security > Accessibility).
- Turn "paste automatically" off in Settings > General. Picking an item then
  only copies it, and no permission is needed.
- Launch with `--demo`. Besides seeding demo items, it bypasses the onboarding
  gate outright, which is why screenshot captures work on a fresh machine.

Related: ad-hoc signatures change on every build, so a grant made against one
build does not cover the next one — System Settings keeps showing the toggle
on while the app is untrusted. `build.sh` avoids this by signing with any
Apple Development identity in your keychain. See the FAQ in README.md if you
land in the stale state anyway.

## Project layout

All logic lives in `Sources/BackpocketKit` so it can be tested; `Sources/Backpocket` stays a thin executable entry point. Add tests under `Tests/BackpocketKitTests`. Inside the kit:

- `App` — process lifecycle: app delegate, global hotkey registration, onboarding, DEBUG launch flags.
- `Clipboard` — pasteboard watching (`changeCount` polling) and paste synthesis into the frontmost app.
- `Panel` — the non-activating `NSPanel` and everything inside it: lists, detail card, note editor, the Enter-action symmetry.
- `Settings` — preference keys, the settings window and its views.
- `Storage` — the SwiftData model (clips and notes are one `Item` table), container setup, and the store.
- `Text` — content classification (prose vs. code), HTML-to-Markdown conversion, syntax highlighting.

`docs/ARCHITECTURE.md` carries the full codemap and the invariants. Read it before changing the store, the panel's focus rules, or the schema.

## Make targets

| Target | Does |
|---|---|
| `make build` | `swift build` |
| `make test` | `swift test` |
| `make coverage` | line coverage per file, worst first (reported, never gated) |
| `make mutants` | whether the tests would catch a bug, not just run the line |
| `make race` | the suite under ThreadSanitizer |
| `make app` | assemble `build/Backpocket.app` |
| `make run` | build and launch |
| `make lint` | `swift format lint --strict` over Sources and Tests, plus `make lint-strings` |
| `make lint-strings` | check `.lproj` key parity (`scripts/check-localization.sh`) |
| `make format` | apply the formatter in place |
| `make icon` | regenerate `Resources/AppIcon.icns` from the icon script |
| `make clean` | delete `.build` and `build` |

## Before opening a PR

- Run `make test` and `make lint` and make sure both pass. CI runs the same
  two, plus `swift build -c release` and `./build.sh release`.
- Bring a test with the change (see below).
- For UI changes, include before/after screenshots. Use the launch flags below
  to drive the panel into a reproducible state for capture.
- Add a line to `CHANGELOG.md` under the unreleased heading at the top if the
  change is user-visible. GitHub's generated release notes are built from labels, and
  labels are applied by the issue templates, not by PRs — so a change that
  isn't written into `CHANGELOG.md` by hand does not reach the release notes
  in any recognizable form.

## Tests

A change that can be tested comes with a test. What that means here:

- **Logic goes in a value type, and the value type gets a suite.** The
  codebase already works this way: `HoverMachine` (pointer-vs-keyboard
  arbitration), `PaneOrder` (Tab order), `PanelLists` (what the panel shows),
  `EnterAction` (what ↩ and ⌘↩ do), and `PasteFlavor` (which representation
  leaves the app) are all pure types with real suites, extracted from views
  precisely so they could be tested. If your fix is a condition inside a
  `body`, the fix is usually to move the condition out first.
- **View wiring is verified by screenshot, not by a test.** There is no
  rendering harness and no snapshot library, and adding one would mean the
  project's first test-only dependency — so nobody expects a unit test for
  layout, styling, or SwiftUI plumbing. Attach before/after images instead.
- **Store and watcher changes are testable and are not exempt.** `Store` takes
  a `ModelContext` (tests hand it an in-memory container) and
  `ClipboardWatcher` takes an injected `NSPasteboard` plus a
  `frontmostApplication` closure. Both have substantial suites already.

If you conclude a change genuinely cannot be tested, say so in the PR and say
why. That is a reviewable claim; silence is not.

## DEBUG launch flags

Debug builds accept launch flags that put the UI into a known state, so screenshots don't depend on manual clicking. They compile out of release builds.

| Flag | Effect |
|---|---|
| `--open` | open the panel pinned to the top-left corner |
| `--edit` | also open the note editor |
| `--settings` | also open the settings window; `--settings-tab=N` picks a tab |
| `--query=text` | pre-fill the search field |
| `--store=/tmp/x` | use a throwaway store instead of your real history |
| `--demo` | seed the store with fixed demo items, and bypass the onboarding screen — combine with `--store=` for reproducible screenshots |
| `--stack=N` | pre-collect the first N clips into the paste stack |
| `--snapshot=/tmp/x.png` | render the panel to a PNG and exit; works even when no display is awake |

### What `--snapshot=` captures

`--snapshot=` captures whichever window the other flags opened, so all three
surfaces are automatable:

| Flags | What lands in the PNG |
|---|---|
| `--open --demo --snapshot=x.png` | the main panel |
| `--open --edit --demo --snapshot=x.png` | the note editor |
| `--open --settings --settings-tab=N --demo --snapshot=x.png` | that Settings pane |

One thing to know: `--settings` wins over `--edit` when both are passed —
Settings is the one window that activates, so it is the one actually on
screen.

The Settings capture is the whole window, title bar and toolbar included, so
the tab strip is in the image and the highlighted tab says which pane you are
looking at. The panel and editor captures are their content, which is all
there is — neither window has a title bar.

Snapshots render in the machine's own locale — there is no `--lang=` flag —
so a Mac set to Korean produces Korean screenshots. Switch the app language in
Settings > General before capturing if you need English.

## Adding a preference

Four edits, all in `Settings/`:

1. Add a case to `PreferenceName` (give it a raw value only when the stored
   spelling differs from the case name — several do, for historical reasons).
2. Add the matching `PreferenceKey` constant. This mirror exists because
   `@AppStorage` needs a plain `String`; it is the one duplication left.
3. Add the small type that owns the preference: a `static let default` and a
   `current` that reads `PreferenceStore.defaults`.
4. Add the control in `SettingsView`, whose `@AppStorage` initializer names
   that same `default` constant rather than repeating the literal.

You do **not** have to touch the reset path. `PreferenceKey.all` is derived
from `PreferenceName.allCases`, so "Reset everything" picks the new preference
up as soon as step 1 lands.

Two rules. Read through `PreferenceStore.defaults`, never
`UserDefaults.standard` — no preference touches the latter directly, and
adding one that does reintroduces the cross-suite test race the store exists
to prevent.
And in tests, bind a throwaway store with `PreferenceStore.withDefaults(_:_:)`
rather than writing to the real one; see Testing seams in
`docs/ARCHITECTURE.md` for why it is a task-local.

### Three tools CI does not run

None of these gate a PR. Reach for them when a change warrants it.

`make coverage` — line coverage per file. Read the per-file column, not the
total: it maps how much of the app has been moved into testable shapes.
Extracted value types sit near 100%, and the files still near zero hold no
view body at all. Useful for spotting a value type that *slid* — one that was
covered and now is half-covered has grown logic nobody tested.

`make race` — the suite under ThreadSanitizer. Worth running when you touch
clipboard capture, which hashes and thumbnails off the main actor while
`Store` serialises those captures by hand. `--sanitize=address` is worth one
too on the image and pasteboard paths. Both are clean today.

`make mutants` — the one that answers what coverage cannot. It changes an
operator, runs the suite, and reports whether anything failed; a survivor is
a line the tests run without checking. `ItemRow.swift` once read 94% covered
and caught none of five mutations, including its `==` — the thing SwiftUI
consults to decide whether to redraw a row. Slow, so point it at your change:
`make mutants FILES=Sources/.../Foo.swift`.

Two cautions on survivors. Some are *equivalent* mutants that change no
behaviour, and a test that kills one only pins an implementation detail.
And almost every real one has been the same shape — a cap exercised well
inside its range and never at its edge. If you add a limit, test it AT the
limit.

## Localization

Every user-visible string goes through `Localizable.strings` and must land in all four `.lproj` files: `en`, `ko`, `ja`, `zh-Hans`. No string ships in English only.

This is enforced: `make lint` runs `scripts/check-localization.sh`, which fails
when the four files disagree on which keys exist. A missing key does not fall
back to English — it renders as the raw identifier, so `footer.items %lld`
would ship to Korean users as that literal text.

## Code style

- Comments are in English and explain **why**, never what — reserve them for non-obvious traps, tradeoffs, and external constraints.
- No new dependencies without prior discussion in an issue. There is exactly one — Sparkle, for updates — and keeping the count that low is deliberate: this tool reads everything you copy, so every dependency is someone else's code with the same access.
- 4-space indentation, no emoji in code.
