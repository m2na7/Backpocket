# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 0.x (latest release) | Yes |
| Anything older | No |

Pre-1.0, only the latest release gets fixes. Upgrade before reporting.

## Reporting a vulnerability

Report privately through GitHub Security Advisories:
<https://github.com/m2na7/Backpocket/security/advisories/new>

Do not open a public issue for a security problem. You'll get an
acknowledgment within 7 days and a fix-or-status answer within 30. If a report
is valid, you'll be credited in the advisory unless you ask not to be.

## Scope

Backpocket keeps your clipboard local: no account, no sync, no server holding
your data, and nothing about what you copy is ever transmitted.

It does make one request on its own. Sparkle asks the appcast whether a newer
build exists — an IP, a timestamp and the app and OS version, nothing more —
and it is enabled by default because that request log is this project's only
count of live installs. Settings > General turns it off, after which the app
makes no unprompted request at all. Updates carry an EdDSA signature checked
against `SUPublicEDKey` in the bundle before anything is installed, so a
compromised or spoofed appcast cannot deliver code; that check is what keeps
an update channel from being a remote execution channel.

The other exception is
"Show link favicons" (Settings > Clipboard), off by default and fully inert
while off — it reads nothing from disk and makes no request. Enabled, it
makes up to three HTTPS requests per linked host, on the default port —
`/favicon.ico`, the site's root page (for a declared icon), then the parent
domain — straight to that site's own host, never a third-party favicon
service, and never local or private hosts; every redirect hop is re-checked
against the same rules and the chain is capped. Results (including misses)
are cached to disk, age- and count-bounded, and clearable from Settings
(also cleared by "Reset everything"). This is the app's only network
surface, so reports against it are security reports too, even when they look
like ordinary bugs:

- A favicon request reaching a host other than the copied link's own (or its
  parent domain), including via a redirect or a declared `<link rel="icon">`
  href that resolves off-host.
- A favicon fetch firing with the setting off, or against a local/private
  host despite the vetting.
- Anything beyond pixels — cookies, headers, identifying state — persisting
  from a favicon fetch or surviving between fetches.

The sensitive surface otherwise is clipboard data handling. Reports in these
areas are security reports even when they look like ordinary bugs:

- Recording content marked `org.nspasteboard.ConcealedType` (or the transient
  and auto-generated markers) — leaking a password manager entry is the worst
  case.
- Clipboard content escaping the SwiftData store — written to logs, temp files,
  or anywhere else on disk.
- The per-app ignore list failing to suppress capture.
- The synthesized Cmd+V path (accessibility permission) pasting into a target
  the user didn't pick.

Out of scope: anything requiring an already-compromised machine — Backpocket's
store is as readable as any other file in the user's home directory, and local
malware can read the pasteboard directly.
