import AppKit
import ImageIO
import SwiftUI

/// Child window showing an item's detail to the right of the main panel.
/// A SwiftUI popover is not an option here: it grabs key focus, which
/// misfires the main panel's auto-close.
@MainActor
final class DetailPanel {
    /// Dead zone crossed while moving the mouse from a row to the card;
    /// within this margin the pointer still counts as over the card.
    private static let slack: CGFloat = 20

    private var panel: NSPanel?
    private var pointerWatch: Timer?
    /// What the visible card describes, so the grace period can tell a
    /// pointer traveling toward the card from an item that has been deleted
    /// out from under it.
    private weak var shownItem: Item?
    /// The panel the card is attached to, and whether the card is currently
    /// drawn over it rather than beside it.
    private weak var parent: NSWindow?
    private var overlapsParent = false

    func show(item: Item, near parent: NSWindow, anchored: Bool) {
        pointerWatch?.invalidate()
        pointerWatch = nil
        self.parent = parent
        shownItem = item

        let screen = parent.screen ?? NSScreen.main
        let place = DetailPlacement(
            parent: parent.frame,
            visible: screen?.visibleFrame ?? parent.frame,
            prefersRight: item.isNote
        )
        var cardLimit = place.limit
        // Built once: the text pipeline behind it (formatting, kind and
        // language detection, syntax coloring) is the card's whole cost, and
        // nothing it produces depends on the card's size.
        var content = detailContent(
            for: item,
            limit: cardLimit,
            // One decode serves both branches, so it is sized for the larger
            // of the two rather than re-read when the card moves to center.
            decodePixels: Self.decodePixels(
                in: [cardLimit, place.centeredLimit],
                scale: screen?.backingScaleFactor ?? 2
            )
        )

        var anchor = DetailPlacement.anchor(
            at: NSEvent.mouseLocation, in: parent.frame, anchored: anchored)

        // A fixed width would become a hard cap and clip the content. Measure
        // the natural size and only wrap in a scroll view past the limit.
        var natural = NSHostingView(rootView: content.measured).fittingSize

        // Content the sidecar would have to cut moves to the screen's center
        // instead, where most of the display is available. No tail there —
        // it no longer sits beside the row it describes.
        let centered = natural.width > cardLimit.width || natural.height > cardLimit.height
        if centered {
            anchor = nil
            cardLimit = place.centeredLimit
            // Only a bitmap is laid out against the limit; text measures the
            // same at any card size, so re-measuring it would buy nothing —
            // and the long clips that reach this branch are the slowest.
            // The bitmap re-measure stays a real layout pass: it costs about
            // 0.3 ms, where deriving the new size arithmetically would have
            // to reproduce the footer's contribution to the card's width.
            if content.image != nil {
                content.imageMax = Self.imageMax(in: cardLimit)
                natural = NSHostingView(rootView: content.measured).fittingSize
            }
        }

        let scrollable = natural.width > cardLimit.width || natural.height > cardLimit.height

        let panel = self.panel ?? makePanel()
        self.panel = panel

        let size = NSSize(
            width: min(max(natural.width, DetailPlacement.minWidth), cardLimit.width)
                + (anchor == nil ? 0 : BubbleShape.tailWidth),
            height: min(max(natural.height, 44), cardLimit.height)
        )
        let origin =
            centered
            ? place.centeredOrigin(size: size)
            : place.origin(size: size, anchor: anchor)

        // Where the tail sits, measured down from the card's top edge —
        // clamped clear of the rounded corners.
        var tailFromTop: CGFloat?
        if let anchor {
            let fromTop = origin.y + size.height - anchor
            tailFromTop = min(max(fromTop, 16), size.height - 16)
        }

        panel.contentView = NSHostingView(
            rootView: DetailShell(
                scrollable: scrollable,
                tailEdge: tailFromTop == nil ? nil : (place.side == .right ? .left : .right),
                tailFromTop: tailFromTop ?? 0,
                pop: !panel.isVisible
            ) { content }
        )
        panel.setContentSize(size)

        overlapsParent = centered || NSRect(origin: origin, size: size).intersects(parent.frame)

        // Never make this key — if the main panel lost focus, everything
        // would close.
        if panel.isVisible {
            panel.setFrameOrigin(origin)
            panel.order(.above, relativeTo: parent.windowNumber)
        } else {
            // Tooltip entrance: fade in while sliding the last few points out
            // from the panel's edge; a centered card just fades and pops.
            let slide: CGFloat = centered ? 0 : (place.side == .right ? -6 : 6)
            panel.setFrameOrigin(NSPoint(x: origin.x + slide, y: origin.y))
            panel.alphaValue = 0
            panel.order(.above, relativeTo: parent.windowNumber)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(
                    NSRect(origin: origin, size: size), display: true)
            }
        }
    }

    /// Image clips show their pixels; the stored text is only a placeholder,
    /// so the whole text pipeline (formatting, highlighting) is skipped.
    private func detailContent(
        for item: Item, limit: NSSize, decodePixels: Int
    ) -> DetailContent {
        if let data = item.imageData, let image = Self.cardImage(from: data, pixels: decodePixels) {
            // Decoded here, once per show — never during a render pass.
            return DetailContent(
                text: "",
                highlighted: nil,
                language: nil,
                image: image,
                imageMax: Self.imageMax(in: limit),
                imageStats: imageStats(data: data),
                meta: DetailMeta(item)
            )
        }

        // A link's card leads with the domain over the exact URL; the text
        // pipeline would classify a URL as code ("://" is a code marker) and
        // mono-highlight it, which reads as noise for an address.
        if let url = item.linkURL {
            return DetailContent(
                text: item.content.trimmingCharacters(in: .whitespacesAndNewlines),
                highlighted: nil,
                language: nil,
                // percentEncoded: false — an IDN host would otherwise render
                // its percent-escapes as the card's headline.
                linkHost: url.host(percentEncoded: false) ?? url.absoluteString,
                meta: DetailMeta(item)
            )
        }

        // The card is for skimming; laying out a huge item in full delays its
        // appearance — and the text below is laid out twice (once to measure,
        // once to show). Cut at the same cap as syntax coloring
        // (SyntaxHighlighter.limit).
        let body = ContentFormatter.detail(of: String(item.content.prefix(6_000)))
        // Classified on the same capped head as the body — kind() runs JSON
        // parsing and marker scans, and the card must appear without walking
        // a 200k clip on the main thread.
        let isCode = ContentFormatter.kind(of: String(item.content.prefix(6_000))).isMonospaced
        let language = isCode ? CodeLanguage.detect(body) : nil

        return DetailContent(
            text: body,
            highlighted: language.map { SyntaxHighlighter.highlight(body, language: $0) },
            language: language,
            meta: DetailMeta(item)
        )
    }

    /// Inset for the card's padding and footer so a measured bitmap stays
    /// within the limit — a hover card that scrolls an image is unusable.
    private static func imageMax(in limit: NSSize) -> CGSize {
        CGSize(width: limit.width - 24, height: limit.height - 60)
    }

    /// Longest side, in device pixels, the card can actually put on screen.
    /// The card scales the bitmap down into `imageMax` points and the display
    /// draws `scale` pixels per point; every pixel decoded past that is read
    /// and thrown away.
    private static func decodePixels(in limits: [NSSize], scale: CGFloat) -> Int {
        let longest = limits.map { imageMax(in: $0) }
            .reduce(0) { max($0, $1.width, $1.height) }
        return Int((longest * scale).rounded(.up))
    }

    /// Decoded to fit the card, not to fit the file. Reading a retina
    /// screenshot at full size costs ~23 MB of pixels the card immediately
    /// scales down to a few hundred points; ImageIO can decode straight to
    /// the size that will be drawn instead.
    ///
    /// The thumbnail the schema already stores cannot serve here: its longest
    /// side is 240 px against the roughly 1,700 px this card draws on a
    /// retina display, so the preview would be visibly soft — the thumbnail
    /// is sized for rows, and a row is an order of magnitude smaller.
    ///
    /// `size` is left at whatever the full-size image reports, so the card
    /// lays out to exactly the same points as before; only the resolution
    /// behind those points changes.
    static func cardImage(from data: Data, pixels: Int) -> NSImage? {
        // Reads the header only — the pixels stay undecoded until something
        // draws them, which is the cost this whole function exists to cap.
        guard let full = NSImage(data: data) else { return nil }
        guard let source = ImageInfo.pixelSize(of: data),
            max(source.width, source.height) > pixels
        else { return full }

        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ] as CFDictionary
        guard
            let reader = CGImageSourceCreateWithData(data as CFData, nil),
            let scaled = CGImageSourceCreateThumbnailAtIndex(reader, 0, options)
        else { return full }

        let image = NSImage(size: full.size)
        image.addRepresentation(NSBitmapImageRep(cgImage: scaled))
        return image
    }

    /// "{W}×{H} · {size}" for the footer. A token estimate over pixels would
    /// be meaningless, so this replaces it.
    private func imageStats(data: Data) -> String? {
        guard let size = ImageInfo.pixelSize(of: data) else { return nil }
        let bytes = ByteCountFormatter.string(
            fromByteCount: Int64(data.count),
            countStyle: .file
        )
        return "\(size.width)×\(size.height) · \(bytes)"
    }

    func hide() {
        pointerWatch?.invalidate()
        pointerWatch = nil
        shownItem = nil
        panel?.orderOut(nil)
    }

    /// Keeps the card open while the mouse is moving onto it. The card never
    /// takes key focus, so hover is judged manually from the pointer
    /// location rather than from focus changes.
    func hideUnlessPointerInside() {
        guard let panel, panel.isVisible else { return }

        guard isAlive, pointerIsInside(panel) else {
            hide()
            return
        }

        // Polling, and it has to be. Nothing else can report the pointer
        // leaving the card: the panel sets `ignoresMouseEvents`, so it gets
        // no tracking events of its own, and ContentView's `.mouseMoved`
        // monitor is a LOCAL monitor — once the pointer is off the main panel
        // it is usually over another app, whose events never reach us. The
        // only other caller of this method is the dwell task, which is keyed
        // on the hovered row and has already settled on nil by the time the
        // grace period starts. Drop this and a card the pointer wandered off
        // of stays on screen until something else happens to close it.
        //
        // It is not a third standing timer: it exists only while a card is up
        // and the pointer is on it, and it retires itself on the first tick
        // that says otherwise.
        guard pointerWatch == nil else { return }
        pointerWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                if !self.isAlive || !self.pointerIsInside(panel) {
                    self.hide()
                }
            }
        }
    }

    /// The card describes one item. Once that item leaves the store there is
    /// nothing left to grant a grace period to — ⌘⌫ with the pointer resting
    /// on the card would otherwise leave it standing over a deleted row.
    private var isAlive: Bool {
        guard let shownItem else { return false }
        return !shownItem.isDeleted
    }

    private func pointerIsInside(_ panel: NSPanel) -> Bool {
        DetailPlacement.pointerIsOnCard(
            at: NSEvent.mouseLocation,
            card: panel.frame,
            parent: parent?.frame,
            overlapsParent: overlapsParent,
            slack: Self.slack
        )
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: DetailPlacement.minWidth, height: 120),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Click-through, always. A centered card covers the list, and a
        // hover preview that eats the click under it is far worse than one
        // that cannot scroll — overflowing content already gets the roomier
        // centered card.
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        return panel
    }
}

// MARK: Geometry

/// Which side of the panel the card takes, how large it may grow there, and
/// where it lands — as arithmetic over two rectangles.
///
/// A value type with no window and no screen behind it: every one of these
/// rules used to be reachable only by dragging the panel to the edge of a
/// second display, and the card once landed half off-screen from a branch
/// nothing could exercise.
struct DetailPlacement: Equatable {
    /// Narrower than this and the card is not worth reading, so a side with
    /// less room than this loses to the other one.
    static let minWidth: CGFloat = 260
    static let maxWidth: CGFloat = 720
    static let gap: CGFloat = 8

    enum Side: Equatable {
        case right
        case left
    }

    let parent: CGRect
    let visible: CGRect
    /// Notes live in the panel's right column and clips and links in the
    /// left, so the card lands on the side of the section being hovered and
    /// the eye never has to cross the panel.
    let prefersRight: Bool

    private var rightSpace: CGFloat { visible.maxX - parent.maxX - Self.gap * 2 }
    private var leftSpace: CGFloat { parent.minX - visible.minX - Self.gap * 2 }

    /// Chosen UP FRONT so the card's width can be capped to that side's
    /// actual free space. The other side is only a fallback for when the
    /// preferred one cannot hold a readable card — and even then it has to
    /// be the roomier of the two.
    var side: Side {
        let preferred: Side = prefersRight ? .right : .left
        let preferredSpace = prefersRight ? rightSpace : leftSpace
        let otherSpace = prefersRight ? leftSpace : rightSpace

        guard preferredSpace >= Self.minWidth || preferredSpace >= otherSpace else {
            return prefersRight ? .left : .right
        }
        return preferred
    }

    /// The hovered row's vertical center, for the card to point its tail at —
    /// or nil, meaning top-aligned with no tail.
    ///
    /// Only a hover has a row under the pointer to point at. A keyboard
    /// preview would otherwise grow a tail aimed at wherever the mouse
    /// happens to be resting, which is nowhere in particular; and a pointer
    /// outside the panel is not on a row either, whatever put the card up.
    static func anchor(at mouse: CGPoint, in parent: CGRect, anchored: Bool) -> CGFloat? {
        anchored && parent.contains(mouse) ? mouse.y : nil
    }

    /// Whether the pointer counts as resting on the card, which is what
    /// buys the card its grace period while the pointer travels onto it.
    ///
    /// `slack` is the dead zone crossed on the way: inside that margin the
    /// pointer still counts as over the card.
    static func pointerIsOnCard(
        at mouse: CGPoint,
        card: CGRect,
        parent: CGRect?,
        overlapsParent: Bool,
        slack: CGFloat
    ) -> Bool {
        // The grace only makes sense for a sidecar. A card drawn over the
        // panel contains the list itself, so this test would report "on the
        // card" for a pointer really on a row, and nothing could retire it.
        guard !overlapsParent else { return false }
        // Beside the panel, the panel wins the overlap: a pointer on a row is
        // on a row, even once the slack margin has reached across the gap.
        guard !(parent?.contains(mouse) ?? false) else { return false }
        return card.insetBy(dx: -slack, dy: -slack).contains(mouse)
    }

    /// How large the sidecar card may grow on the side it took.
    var limit: CGSize {
        CGSize(
            width: min(Self.maxWidth, max(side == .right ? rightSpace : leftSpace, Self.minWidth)),
            // Matching the main panel keeps the card a sidecar, not a tower.
            height: max(parent.height, 240)
        )
    }

    /// The roomier limit for content the sidecar would have to cut, which
    /// moves to the middle of the screen instead.
    var centeredLimit: CGSize {
        CGSize(width: min(visible.width - 120, 880), height: visible.height * 0.8)
    }

    func centeredOrigin(size: CGSize) -> CGPoint {
        CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
    }

    /// `anchor` is the hovered row's vertical center in screen coordinates,
    /// or nil for a keyboard preview with no row under the pointer.
    func origin(size: CGSize, anchor: CGFloat?) -> CGPoint {
        // The tail bridges most of the gap, so an anchored card sits closer.
        let gap = anchor == nil ? Self.gap : 2
        let x = side == .right ? parent.maxX + gap : parent.minX - size.width - gap
        // Centered on the hovered row; top-aligned to the panel otherwise.
        let y = anchor.map { $0 - size.height / 2 } ?? (parent.maxY - size.height)

        // Clamped onto the screen either way — a cramped side never pushes
        // the card off the edge. The lower bound wins a card taller or wider
        // than the screen, which keeps its top-left corner reachable.
        return CGPoint(
            x: min(max(x, visible.minX), max(visible.maxX - size.width, visible.minX)),
            y: min(max(y, visible.minY), max(visible.maxY - size.height, visible.minY))
        )
    }
}

// MARK: Shell

/// Card chrome: material background, rounded border, a scroll view only when
/// the content exceeds the size limit — and, when hover anchored the card to
/// a row, a speech-bubble tail pointing back at it.
private enum TailEdge {
    case left
    case right
}

private struct DetailShell<Content: View>: View {
    let scrollable: Bool
    let tailEdge: TailEdge?
    /// The tail's center, measured down from the card's top edge.
    let tailFromTop: CGFloat
    /// True on a fresh appearance; row-to-row moves must not re-pop.
    let pop: Bool
    let content: Content

    @State private var appeared: Bool

    init(
        scrollable: Bool,
        tailEdge: TailEdge?,
        tailFromTop: CGFloat,
        pop: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.scrollable = scrollable
        self.tailEdge = tailEdge
        self.tailFromTop = tailFromTop
        self.pop = pop
        self.content = content()
        _appeared = State(initialValue: !pop)
    }

    var body: some View {
        // One shape for card and tail together: material and border are each
        // drawn exactly once, so the tail can never sit a shade off the card.
        let bubble = BubbleShape(tailEdge: tailEdge, tailFromTop: tailFromTop)

        Group {
            if scrollable {
                ScrollView([.vertical, .horizontal]) { content }
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, tailEdge == .left ? BubbleShape.tailWidth : 0)
        .padding(.trailing, tailEdge == .right ? BubbleShape.tailWidth : 0)
        .clipShape(bubble)
        .background(.regularMaterial, in: bubble)
        .overlay(bubble.stroke(.separator, lineWidth: 0.5))
        .scaleEffect(
            appeared ? 1 : 0.92,
            anchor: tailEdge == nil ? .center : (tailEdge == .right ? .trailing : .leading)
        )
        .onAppear {
            guard !appeared else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.68)) {
                appeared = true
            }
        }
    }
}

/// The card and its tail as ONE continuous outline — a rounded rect whose
/// tail edge takes a detour out to the tip.
private struct BubbleShape: Shape {
    static let tailWidth: CGFloat = 9
    static let tailHeight: CGFloat = 18

    let tailEdge: TailEdge?
    let tailFromTop: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 10
        var card = rect
        if tailEdge == .left { card.origin.x += Self.tailWidth }
        if tailEdge != nil { card.size.width -= Self.tailWidth }

        guard let tailEdge else {
            return Path(roundedRect: card, cornerRadius: radius)
        }

        let top = tailFromTop - Self.tailHeight / 2
        let bottom = tailFromTop + Self.tailHeight / 2

        var path = Path()
        if tailEdge == .left {
            path.move(to: CGPoint(x: card.minX, y: top))
            path.addArc(
                tangent1End: CGPoint(x: card.minX, y: card.minY),
                tangent2End: CGPoint(x: card.minX + radius, y: card.minY), radius: radius)
            path.addArc(
                tangent1End: CGPoint(x: card.maxX, y: card.minY),
                tangent2End: CGPoint(x: card.maxX, y: card.minY + radius), radius: radius)
            path.addArc(
                tangent1End: CGPoint(x: card.maxX, y: card.maxY),
                tangent2End: CGPoint(x: card.maxX - radius, y: card.maxY), radius: radius)
            path.addArc(
                tangent1End: CGPoint(x: card.minX, y: card.maxY),
                tangent2End: CGPoint(x: card.minX, y: card.maxY - radius), radius: radius)
            path.addLine(to: CGPoint(x: card.minX, y: bottom))
            path.addLine(to: CGPoint(x: rect.minX, y: tailFromTop))
        } else {
            path.move(to: CGPoint(x: card.maxX, y: bottom))
            path.addArc(
                tangent1End: CGPoint(x: card.maxX, y: card.maxY),
                tangent2End: CGPoint(x: card.maxX - radius, y: card.maxY), radius: radius)
            path.addArc(
                tangent1End: CGPoint(x: card.minX, y: card.maxY),
                tangent2End: CGPoint(x: card.minX, y: card.maxY - radius), radius: radius)
            path.addArc(
                tangent1End: CGPoint(x: card.minX, y: card.minY),
                tangent2End: CGPoint(x: card.minX + radius, y: card.minY), radius: radius)
            path.addArc(
                tangent1End: CGPoint(x: card.maxX, y: card.minY),
                tangent2End: CGPoint(x: card.maxX, y: card.minY + radius), radius: radius)
            path.addLine(to: CGPoint(x: card.maxX, y: top))
            path.addLine(to: CGPoint(x: rect.maxX, y: tailFromTop))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: Body (reports its natural size, without any scrolling)

/// The item as of the show. A value, not the model: the card outlives a
/// delete by design (the pointer may be traveling onto it), and a SwiftData
/// change notification can re-run the body — against an object that is gone.
struct DetailMeta {
    let isNote: Bool
    let sourceApp: String?
    let sourceBundleID: String?
    let createdAt: Date
    let characters: Int
    /// Counted here rather than in the footer: the body runs at least twice
    /// per show, and this walks the whole content.
    let tokens: Int

    init(_ item: Item) {
        isNote = item.isNote
        sourceApp = item.sourceApp
        sourceBundleID = item.sourceBundleID
        createdAt = item.createdAt
        characters = item.content.count
        tokens = TokenEstimate.roughCount(item.content)
    }
}

/// Detail body plus metadata footer; measured unscrolled so the panel can
/// size itself to the content.
struct DetailContent: View {
    /// Prose wraps at this width; code lines are never broken.
    private static let wrapWidth: CGFloat = 460

    let text: String
    let highlighted: AttributedString?
    let language: CodeLanguage?
    /// Drops the syntax coloring for the sizing pass. SwiftUI lays out a
    /// 6,000-character clip in ~185 ms once it carries the highlighter's
    /// ~2,500 attribute runs, against ~5 ms for the identical plain string —
    /// and the card is measured before it is shown, so the panel used to pay
    /// that twice. The colors move no glyphs: the runs carry foreground
    /// colors and a bold intent, and the monospaced face keeps its advance
    /// width when bold, so both strings measure to the same size.
    /// DetailPlacementTests pins that equality across every language.
    private var measuring = false
    /// Decoded once in show(); nil for text items.
    var image: NSImage? = nil
    /// Cap the image scales down to — the card must never scroll a bitmap.
    var imageMax: CGSize = .zero
    /// Precomputed "{W}×{H} · {size}" so the footer never touches imageData.
    var imageStats: String? = nil
    /// The link's domain; non-nil switches the card to its link layout.
    var linkHost: String? = nil
    let meta: DetailMeta

    /// Spelled out because `measuring` is nobody else's to set: the sizing
    /// twin is reached through `measured`, never built directly.
    init(
        text: String,
        highlighted: AttributedString?,
        language: CodeLanguage?,
        image: NSImage? = nil,
        imageMax: CGSize = .zero,
        imageStats: String? = nil,
        linkHost: String? = nil,
        meta: DetailMeta
    ) {
        self.text = text
        self.highlighted = highlighted
        self.language = language
        self.image = image
        self.imageMax = imageMax
        self.imageStats = imageStats
        self.linkHost = linkHost
        self.meta = meta
    }

    /// The same card, cheap enough to lay out purely to learn its size.
    var measured: DetailContent {
        var copy = self
        copy.measuring = true
        return copy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            body(for: highlighted)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
            footer

            if linkHost != nil {
                Divider()
                openHint
            }
        }
    }

    @ViewBuilder
    private func body(for highlighted: AttributedString?) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                // Small images stay at natural size; only oversized ones
                // scale down to the panel's limit.
                .frame(
                    maxWidth: min(imageMax.width, image.size.width),
                    maxHeight: min(imageMax.height, image.size.height)
                )
        } else if let linkHost {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "globe")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(linkHost)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: Self.wrapWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let highlighted {
            Group {
                if measuring {
                    Text(text)
                } else {
                    Text(highlighted)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .fixedSize(horizontal: true, vertical: true)
        } else {
            Text(text)
                .font(.callout)
                .frame(maxWidth: Self.wrapWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 13, height: 13)
            }

            Text(meta.isNote ? String(localized: "notes.title") : (meta.sourceApp ?? "—"))

            Text("·")
            Text(meta.createdAt, format: .relative(presentation: .named))

            if let language, language != .generic {
                Text("·")
                Text(language.rawValue)
            }

            if linkHost != nil {
                Text("·")
                Text("kind.link")
            }

            Spacer(minLength: 8)

            if let imageStats {
                Text(imageStats)
            } else {
                Text(verbatim: "\(meta.characters)")
                Text("·")
                Text("detail.tokens \(meta.tokens)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Mirrors the panel footer's key-chip style; the card ignores mouse
    /// events by design, so this is a hint, not a button. Reads the live
    /// binding — the shortcut is rebindable, and a card advertising the
    /// default next to a footer showing the real key would be a lie.
    private var openHint: some View {
        HStack(spacing: 5) {
            Text(PanelShortcut.openLink.current.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.06))
                )
            Text("ctx.openLink")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appIcon: NSImage? {
        // Through the shared cache: body runs twice per show (measure, then
        // display), and NSWorkspace lookups are too slow to repeat.
        AppIcon.icon(for: meta.sourceBundleID)
    }
}
