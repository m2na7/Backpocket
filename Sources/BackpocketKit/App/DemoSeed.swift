#if DEBUG
import AppKit

/// The fixture content behind `--demo` (see `DebugLaunch`). It only calls the
/// store's own API, so it lives apart from the composition root that invokes
/// it. Debug builds only.
@MainActor
enum DemoSeed {
    /// Fills an empty store with content that shows the product off: real
    /// source apps so icons resolve, varied content kinds, two pins, one image.
    static func seed(into store: Store) async {
        let chrome = CopySource(name: "Google Chrome", bundleID: "com.google.Chrome")
        let cursor = CopySource(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92")
        let code = CopySource(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode")
        let terminal = CopySource(name: "Terminal", bundleID: "com.apple.Terminal")
        let slack = CopySource(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        let figma = CopySource(name: "Figma", bundleID: "com.figma.Desktop")
        let notion = CopySource(name: "Notion", bundleID: "notion.id")

        // Oldest first: every add lands at the front, so the last call ends
        // up at the top of the list.
        store.addNote("First sketch — clipboard history and notes in one panel")
        store.addNote("Design review Thu 2pm — bring the empty-state options")
        store.add("https://react.dev/reference/react/useSyncExternalStore", source: chrome)
        store.add("#2F81F7", source: figma)
        store.add(
            """
            type Result<T, E = Error> =
              | { ok: true; value: T }
              | { ok: false; error: E }
            """,
            source: cursor
        )
        store.add("https://www.typescriptlang.org/docs/handbook/2/generics.html", source: chrome)
        store.addNote("Standup 10:30 — demo the panel, collect feedback")
        store.add("pnpm dlx shadcn@latest add dialog", source: terminal)
        store.add(
            """
            export function useDebounced<T>(value: T, delay = 300): T {
              const [debounced, setDebounced] = useState(value)
              useEffect(() => {
                const id = setTimeout(() => setDebounced(value), delay)
                return () => clearTimeout(id)
              }, [value, delay])
              return debounced
            }
            """,
            source: cursor
        )
        store.add("https://github.com/m2na7/Backpocket/pull/12", source: chrome)
        store.add(
            "{\"name\": \"backpocket\", \"version\": \"1.4.0\", \"channels\": [\"beta\", \"stable\"]}",
            source: code
        )
        store.addNote("Ask design about the empty state — it reads too quiet")
        store.add("git rebase -i origin/main --autosquash", source: terminal)
        store.add(
            "Can you take the flaky test in CI? It fails ~1 in 5 on the runner.",
            source: slack
        )
        store.add("https://news.ycombinator.com/item?id=41802570", source: chrome)
        store.add(
            """
            const Panel = forwardRef<HTMLDivElement, PanelProps>(
              ({ items, onSelect }, ref) => (
                <div ref={ref} role="listbox">
                  {items.map((item) => (
                    <Row key={item.id} item={item} onSelect={onSelect} />
                  ))}
                </div>
              )
            )
            """,
            source: cursor
        )
        store.addNote("Release notes draft: image clips, faster search, new hotkey")
        store.add("https://vercel.com/docs/functions/streaming", source: chrome)
        store.add(
            """
            ## Panel keyboard
            - `Enter` pastes the selected clip
            - `Cmd+Enter` pastes a note
            """,
            source: notion
        )
        store.add("npm error ERESOLVE could not resolve peer react@^19.0.0", source: terminal)
        store.addNote("Ship 0.2 before the conference — cut scope if it slips")
        store.add(
            "The best interface is the one you never notice — it simply keeps up.",
            source: chrome
        )
        if let png = gradientPNG() {
            store.addImage(png, source: figma)
            // Image capture hashes and thumbnails off the main actor, so the
            // row is not in `items` yet. Without this wait the spread below
            // skips it and the demo image alone reads "now" — which makes the
            // screenshots this flag exists for unreproducible.
            await store.imageCapturesDidFinish()
        }

        for prefix in ["git rebase", "#2F81F7"] {
            if let pinned = store.items.first(where: { $0.content.hasPrefix(prefix) }) {
                store.togglePin(pinned)
            }
        }

        // Every add stamped usedAt with "now". Clips and notes are spread
        // differently on purpose: clips expire (default seven days) and would
        // be purged out of the demo before it could be filmed, while notes
        // never expire and are what the notes column groups into Today, Last
        // 7 Days, months and years. So the deep past belongs to the notes and
        // the clips stay inside the retention window.
        //
        // `items` is the pinned block first, then usedAt descending within
        // each block, and Store re-sorts it only in togglePin and undoDelete,
        // so nothing re-sorts it after this spread. Both passes therefore
        // walk it in order and assign strictly descending dates within their
        // own kind: each column lists one kind in `items` order.
        var clipDate = Date().addingTimeInterval(-120)
        var clipGap: TimeInterval = 900
        var noteAge: [TimeInterval] = [
            60 * 30,
            3600 * 26,
            86400 * 4,
            86400 * 26,
            86400 * 200,
            86400 * 400,
        ]
        for item in store.items {
            if item.isNote {
                let age = noteAge.isEmpty ? 86400 * 500 : noteAge.removeFirst()
                item.usedAt = Date().addingTimeInterval(-age)
            } else {
                item.usedAt = clipDate
                clipDate -= clipGap
                // Widening, but capped so the whole spread, not just each
                // gap, stays inside the seven-day default and nothing in the
                // demo is eligible for expiry. At 0.9 days the gaps summed to
                // about 7.3 and the oldest clip was purged on the first open;
                // at 0.75 the oldest sits near 6.4. DemoSeedTests holds it
                // there as clips are added.
                clipGap = min(clipGap * 1.6, 86400 * 0.75)
            }
            item.createdAt = item.usedAt
        }
        store.persistDemoSeed()
    }

    /// 640×400 gradient rendered with CoreGraphics — generated at runtime so
    /// no image asset ships in the bundle for a debug-only feature.
    private static func gradientPNG() -> Data? {
        let width = 640, height = 400
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let gradient = CGGradient(
                colorsSpace: space,
                colors: [
                    CGColor(red: 0.30, green: 0.41, blue: 0.95, alpha: 1),
                    CGColor(red: 0.89, green: 0.37, blue: 0.62, alpha: 1),
                ] as CFArray,
                locations: nil
            )
        else { return nil }

        context.drawLinearGradient(
            gradient,
            start: .zero,
            end: CGPoint(x: width, y: height),
            options: []
        )

        return context.makeImage().flatMap {
            NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
        }
    }
}
#endif
