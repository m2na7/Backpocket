# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.4] - 2026-09-02

### Fixed
- `Cmd+Backspace` while searching cleared the search field again instead of deleting a clip. The panel had been claiming the key unconditionally, so the ordinary way to clear what you had typed destroyed the top item — and since Escape closes the panel rather than emptying the field, there was no other way to clear a search. A collected handful still takes the key first, and a delete shortcut rebound away from `Cmd+Backspace` keeps deleting the row even mid-search.

## [0.1.3] - 2026-09-01

### Added
- Deleting is undoable. `Cmd+Z` puts back what the last delete took — the whole batch at once if several rows went together — with its timestamps, pin state and source app intact. The window is short and the depth is three on purpose: holding deleted content any longer would quietly undo what expiry and Clear History are for. `Cmd+Z` still belongs to the search field whenever the field has something to undo.
- The panel reads properly under VoiceOver. Each row announces what it is, what it holds and the state its trailing column shows — an image with its dimensions, a file with its name, a pinned row as pinned — and the edit and delete actions that only appear on hover are now reachable.

### Changed
- Link rows fetch favicons by default. A column of identical globes was not worth having. Each fetch does tell the linked site that this machine holds that link, so it stays a switch in Settings > Clipboard; existing installs keep whatever they had set.

## [0.1.2] - 2026-09-01

### Changed
- New app icon. The menu-bar mark is unchanged — it is a monochrome template
  image and always was.

## [0.1.1] - 2026-09-01

No change to the app itself — this release exists to carry the first public
README and to prove the release pipeline end to end, cask and update feed
included. Updating from 0.1.0 gains you nothing but costs you nothing.

## [0.1.0] - 2026-08-31

First release.

### Added
- Non-activating menu-bar panel (`Shift+Cmd+V`) that never steals focus from the frontmost app. The shortcut is rebindable to any combination with ⌘, ⌃, or ⌥; one another app already owns is rejected rather than silently swallowed.
- Unified input field: search clipboard history, or press Enter on no match to save a note.
- Enter symmetry — clips: Enter pastes; notes: Enter edits, Cmd+Enter pastes — with a return-action preview chip (hold Cmd to peek at the inverse). Cmd+Enter saves what is typed in the field as a note.
- `Cmd+1..9` instant paste, and a paste stack: `Cmd+D` (or `Cmd`-click) collects items in pick order, releasing `Cmd` pastes them joined by newlines, `Cmd+Backspace` clears, `Esc` drops.
- Notes column grouped by recency the way the Notes app does it — Today / Last 7 Days / Previous 30 Days / months / year+month — with headers always visible. Hovering or focusing it with Tab widens it (240 → 410pt) into two-line rows with timestamps and character counts; the highlighted note previews up to four lines, and hover reveals edit and delete on the row. Cmd-click opens the editor directly. Drag a clip onto the column to convert it, keeping source app and timestamps.
- Images arrive with a list thumbnail and full preview in the detail card, deduplicated by content hash, and paste back as PNG plus a TIFF rendition.
- File copies keep the file itself rather than the text path macOS puts on the clipboard, so a Finder copy lands in Slack as an attachment. The row shows the file's icon and name.
- Rich copies keep both HTML and RTF, so they paste back rich — or as clean Markdown on demand, with a rough LLM token estimate in the detail card.
- Link collection (Settings > Clipboard): URL-only clips file under their own section, `Tab` cycles clipboard → links → notes, and `Cmd+O` opens the selected link. Three modes: links in both lists (the default), the links section only, or no links section. Links stay ordinary clips, so paste, pinning, note conversion, and expiry keep working. Favicons are a separate opt-in, off by default, fetched over HTTPS from the link's own host and never a third-party service.
- Hover detail card (0.5s) with auto-detected syntax highlighting for Swift, TypeScript, JavaScript, JSON, Markdown, and Shell, in GitHub-style light and dark colors.
- Adjustable layout: drag the panel's edges to resize and the middle divider to set the notes column's width; Settings > Clipboard picks the links section's row count (3–10). All remembered across launches.
- Retention rules: notes and pinned items never expire; clipboard history auto-expires (default 7 days).
- Privacy: nothing about what you copy leaves the machine — no account, no sync, no server, the opt-in favicon fetch above being the one exception. Respects `org.nspasteboard.ConcealedType`, `TransientType`, and `AutoGeneratedType`; per-app ignore list; the accessibility permission is needed only when "paste automatically" is enabled.
- Automatic updates via Sparkle: Backpocket checks an appcast for newer builds and verifies each one's EdDSA signature before installing, with "Check for Updates…" in the menu. On by default — that request is also how the project counts live installs — and switchable off under Settings > General.
- Localization: English, Korean, Japanese, and Simplified Chinese.
