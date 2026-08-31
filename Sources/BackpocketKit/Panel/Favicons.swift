import AppKit
import CoreGraphics
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Fetches and caches link favicons. Opt-in: with the setting off (the
/// default) this file makes no network request and reads nothing from disk,
/// so "zero network calls" stays true out of the box and turning the setting
/// back off makes the feature inert rather than merely quiet.
///
/// What a lookup does, at most: three GETs to the link's own host over HTTPS
/// on the default port — /favicon.ico, the ROOT page (never the copied URL's
/// own path, which can carry private tokens) to read its declared
/// <link rel="icon">, and the parent domain's /favicon.ico for hosts behind a
/// login wall. Successes and failures alike are written to
/// Application Support/Backpocket/Favicons, keyed by host, and expire after
/// two weeks; the directory is capped and `clearCachedIcons()` empties it.
///
/// The security posture, in order of importance:
/// - HTTPS only, straight to the link's own host — never a third-party
///   favicon service, so the domains a user copies leak to no one new. Every
///   redirect hop is vetted against the same rules, and the chain is capped.
/// - Local and private hosts (localhost, `*.local`, `.onion`, IP literals in
///   any notation) are never contacted — a clipboard full of dev URLs must
///   not probe the LAN.
/// - An ephemeral session with cookies disabled: no identifying state rides
///   along with the request, and nothing persists between fetches.
/// - The read itself is bounded, so a server cannot stream for the whole
///   resource timeout, and only a declared image type within sane pixel
///   dimensions is decoded, then re-encoded to a small PNG: whatever bytes
///   the server sent, only pixels survive.
@MainActor
final class Favicons {
    static let shared = Favicons()

    private nonisolated static let maxBytes = 512_000
    /// Only the head matters; markup past this is never parsed.
    private nonisolated static let htmlCap = 262_144
    /// Far larger than any real favicon. The gate is against a small file
    /// that declares enormous dimensions, which costs gigabytes to decode.
    private nonisolated static let maxPixelSide = 2048
    fileprivate nonisolated static let maxRedirects = 3
    /// Disk entries expire so an icon captured through a captive portal or a
    /// TLS-terminating proxy cannot be the site's icon forever.
    private nonisolated static let maxCacheAge: TimeInterval = 14 * 24 * 60 * 60
    private nonisolated static let maxCacheEntries = 256
    private nonisolated static let side = 64

    /// Servers that serve markup or octet-stream for an icon are treated as
    /// having no icon: the bytes reach ImageIO only when they claim to be one
    /// of these, and ImageIO must then agree.
    private nonisolated static let imageMIMETypes: Set<String> = [
        "image/png", "image/jpeg", "image/gif", "image/x-icon",
        "image/vnd.microsoft.icon", "image/bmp", "image/tiff", "image/webp",
    ]
    private nonisolated static let imageSourceTypes: Set<String> = [
        "public.png", "public.jpeg", "com.compuserve.gif", "com.microsoft.ico",
        "public.tiff", "com.microsoft.bmp", "org.webmproject.webp",
    ]

    private var cache: [String: NSImage] = [:]
    /// Hosts known to have no usable icon. Backed by dated markers on disk so
    /// a dead host is not re-probed with three requests on every launch.
    private var failed: Set<String> = []
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private var waiters = FetchWaiters()

    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        // Offline must fail fast into the avatar, not queue up waiting.
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// A whole list scrolling into view would otherwise start three requests
    /// per visible row at once.
    private nonisolated static let limiter = FetchLimiter(limit: 3)

    func icon(for url: URL) async -> NSImage? {
        // The preference gates the disk cache too: with it off nothing an
        // earlier opt-in left behind is read, and the feature is inert.
        guard FaviconFetching.isEnabled else { return nil }
        guard
            let host = Self.normalizedHost(url.host(percentEncoded: false)),
            Self.isFetchable(host: host)
        else { return nil }

        if let hit = cache[host] { return hit }
        if failed.contains(host) { return nil }

        switch await Self.diskEntry(host: host) {
        case .icon(let png):
            guard let image = NSImage(data: png) else { break }
            cache[host] = image
            return image
        case .miss:
            failed.insert(host)
            return nil
        case nil:
            break
        }

        return await fetch(host: host)
    }

    /// Empties every record this file keeps: the in-memory icons, the known
    /// failures, and the on-disk directory. Settings and the reset path call
    /// this, so the feature leaves nothing behind.
    @MainActor static func clearCachedIcons() {
        shared.cache.removeAll()
        shared.failed.removeAll()
        for task in shared.inFlight.values { task.cancel() }
        shared.inFlight.removeAll()
        shared.waiters = FetchWaiters()
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    /// Joins the one download per host, and lets a closing panel stop it:
    /// abandoning the last waiter cancels the work instead of leaving it to
    /// run out the resource timeout.
    private func fetch(host: String) async -> NSImage? {
        let task: Task<Data?, Never>
        if let existing = inFlight[host] {
            task = existing
        } else {
            task = Task { await Self.download(host: host) }
            inFlight[host] = task
        }

        waiters.join(host)
        defer {
            if waiters.leave(host) { inFlight[host] = nil }
        }

        let png = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelIfSoleWaiter(host: host) }
        }

        guard let png, let image = NSImage(data: png) else {
            if !Task.isCancelled { failed.insert(host) }
            return nil
        }
        cache[host] = image
        return image
    }

    private func cancelIfSoleWaiter(host: String) {
        guard waiters.isSole(host) else { return }
        inFlight[host]?.cancel()
    }

    /// The three attempts, off the main actor and behind the fetch limit.
    /// Sites that fail all three keep the globe, and the failure is dated on
    /// disk so the next launch does not repeat them.
    private nonisolated static func download(host: String) async -> Data? {
        await limiter.run {
            var components = URLComponents()
            components.scheme = "https"
            // The copied URL's port is deliberately dropped: the cache is
            // keyed by host, and speaking TLS to whatever port a link named
            // is a port probe the user never asked for.
            components.host = host
            guard let base = components.url else { return nil }

            var png = await imageData(at: base.appending(path: "favicon.ico"))

            // Sites like calendar.google.com serve HTML at /favicon.ico and
            // declare the real icon in <head> instead.
            if png == nil, !Task.isCancelled, let declared = await declaredIconURL(under: base) {
                png = await imageData(at: declared)
            }

            // A page behind a login wall exposes no icon to an anonymous
            // fetch; the parent domain's is still the right brand.
            if png == nil, !Task.isCancelled, let parent = parentDomainFavicon(host: host) {
                png = await imageData(at: parent)
            }

            guard let png else {
                if !Task.isCancelled { recordMiss(host: host) }
                return nil
            }
            store(png: png, host: host)
            return png
        }
    }

    /// One bounded GET; nil unless the body survives the image sanitizer.
    private nonisolated static func imageData(at url: URL) async -> Data? {
        guard let data = await body(at: url, cap: maxBytes, accepting: imageMIMETypes) else {
            return nil
        }
        return sanitizedPNG(from: data)
    }

    /// Fetches the site's root page and reads the icon its <head> declares.
    private nonisolated static func declaredIconURL(under base: URL) async -> URL? {
        guard
            let data = await body(
                at: base, cap: htmlCap, accepting: ["text/html", "application/xhtml+xml"],
                resolvedBase: base)
        else { return nil }

        let html = String(decoding: data.body, as: UTF8.self)
        // Redirects may have landed elsewhere; relative hrefs belong there.
        return iconHref(in: html).flatMap { declaredIcon(href: $0, base: data.page) }
    }

    private nonisolated static func body(
        at url: URL, cap: Int, accepting types: Set<String>
    ) async -> Data? {
        await body(at: url, cap: cap, accepting: types, resolvedBase: nil)?.body
    }

    /// Bounds the read itself rather than the finished body: a hostile server
    /// must not be able to stream for the full resource timeout, so the
    /// transfer is aborted the moment it passes the cap — or immediately, if
    /// it announces a length past it.
    private nonisolated static func body(
        at url: URL, cap: Int, accepting types: Set<String>, resolvedBase: URL?
    ) async -> (body: Data, page: URL)? {
        guard let (bytes, response) = try? await session.bytes(from: url, delegate: RedirectGuard())
        else { return nil }

        guard
            let http = response as? HTTPURLResponse,
            acceptsHeaders(
                status: http.statusCode,
                mime: response.mimeType,
                declaredLength: response.expectedContentLength,
                cap: cap,
                accepting: types)
        else {
            bytes.task.cancel()
            return nil
        }

        var data = Data()
        data.reserveCapacity(min(cap, 65_536))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > cap {
                    bytes.task.cancel()
                    return nil
                }
            }
        } catch {
            return nil
        }
        return (data, response.url ?? resolvedBase ?? url)
    }

    /// Whether the headers alone admit the body, before a byte of it is read.
    /// Everything here is a promise about what gets decoded, so it is a
    /// function of the headers rather than a clause inside the transfer: a
    /// non-200, a type the sanitizer would refuse anyway, or a body the server
    /// itself announces as past the cap.
    ///
    /// A server that declares no length at all sends -1, which passes: the
    /// only honest answer to "how big is it" is unknown, and the streaming cap
    /// is what stops it. Rejecting -1 here would refuse every chunked reply.
    nonisolated static func acceptsHeaders(
        status: Int, mime: String?, declaredLength: Int64, cap: Int, accepting types: Set<String>
    ) -> Bool {
        guard status == 200, let mime = mime?.lowercased(), types.contains(mime) else {
            return false
        }
        return declaredLength <= Int64(cap)
    }

    /// ponytail: "last two labels" is not the public-suffix list — a co.kr
    /// host falls back to co.kr and fails harmlessly. Adopt the PSL if that
    /// ever matters.
    nonisolated static func parentDomainFavicon(host: String) -> URL? {
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return nil }

        let parent = labels.suffix(2).joined(separator: ".")
        guard isFetchable(host: parent) else { return nil }
        return URL(string: "https://\(parent)/favicon.ico")
    }

    /// The first <link rel="…icon…"> href in the markup, if any.
    nonisolated static func iconHref(in html: String) -> String? {
        let link = #"<link\b[^>]*\brel=["'][^"']*icon[^"']*["'][^>]*>"#
        guard
            let tagRange = html.range(of: link, options: [.regularExpression, .caseInsensitive])
        else { return nil }

        let tag = html[tagRange]
        guard
            let hrefRange = tag.range(
                of: #"href=["'][^"']+["']"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }

        return String(tag[hrefRange].dropFirst(6).dropLast(1))
    }

    /// A declared href is still untrusted markup: it resolves against the
    /// root, upgrades to HTTPS, and its host passes the same vetting as the
    /// link's own — a page cannot point the fetcher at the LAN.
    nonisolated static func declaredIcon(href: String, base: URL) -> URL? {
        guard
            let resolved = URL(string: href, relativeTo: base)?.absoluteURL,
            var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
            let host = normalizedHost(components.host),
            isFetchable(host: host)
        else { return nil }

        components.scheme = "https"
        components.host = host
        return components.url
    }

    /// One spelling of a host before anything compares it: a trailing dot
    /// names the same machine to a resolver but defeats every suffix check,
    /// and a percent escape hides a literal from every character test.
    nonisolated static func normalizedHost(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var host = (raw.removingPercentEncoding ?? raw).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    /// Never contact anything that is not a plain public hostname. Rejecting
    /// every IP literal is deliberate: a favicon is not worth the ability to
    /// probe addresses.
    nonisolated static func isFetchable(host: String) -> Bool {
        guard let host = normalizedHost(host) else { return false }
        if host == "localhost" { return false }

        let privateSuffixes = [
            ".local", ".internal", ".home.arpa", ".test", ".localhost", ".onion",
        ]
        if privateSuffixes.contains(where: host.hasSuffix) { return false }

        // Anything outside a hostname's alphabet is an encoding trick, a
        // literal, or not a name at all. Internationalized domains reach here
        // already punycoded, so they are unaffected.
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        if host.contains(where: { !allowed.contains($0) }) { return false }

        if isAddressLiteral(host) { return false }

        return host.contains(".")
    }

    /// The resolver's own parser, not a digits-and-dots test: 0x7f.0.0.1 and
    /// 2130706433 are both 127.0.0.1 but read as names to a naive check.
    private nonisolated static func isAddressLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        if inet_aton(host, &v4) != 0 { return true }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, host, &v6) == 1
    }

    /// Keeps only pixels, and only after the cheap checks: the declared type
    /// must be an image ImageIO admits to knowing, and its declared
    /// dimensions must be sane, before anything is decoded. Also the size
    /// gate: an over-cap or undecodable response yields nil, not a file.
    ///
    /// The two size gates are named rather than inline for the reason
    /// `acceptsHeaders` is: their boundaries are the whole point of them, and
    /// an assertion reaching them through real encoded bytes can only ever
    /// land well inside the range. There is no icon file that weighs exactly
    /// half a megabyte, and a 2048-pixel one that also fits under the byte cap
    /// takes a compressible image built to order.
    nonisolated static func acceptsByteCount(_ count: Int) -> Bool {
        count > 0 && count <= maxBytes
    }

    /// The gate against a small file that declares enormous dimensions, which
    /// costs gigabytes to decode.
    nonisolated static func acceptsPixelSize(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maxPixelSide && height <= maxPixelSide
    }

    nonisolated static func sanitizedPNG(from data: Data) -> Data? {
        guard
            acceptsByteCount(data.count),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source) as String?,
            imageSourceTypes.contains(type),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            acceptsPixelSize(width: width, height: height)
        else { return nil }

        // ImageIO throughout rather than NSImage.draw: this runs off the main
        // actor, where AppKit drawing is not a documented guarantee.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source, 0, thumbnailOptions as CFDictionary),
            let context = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        context.interpolationQuality = .high
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: side, height: side))

        let png = NSMutableData()
        guard
            let scaled = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(
                png, UTType.png.identifier as CFString, 1, nil)
        else { return nil }

        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return png as Data
    }

    // MARK: - Disk cache

    /// Internal rather than private only so the disk cache can be read back
    /// directly, for the reason `RedirectGuard` is: a host recorded as having
    /// no icon must not be re-probed with three requests on every launch, and
    /// the alternative to asserting on it here is a real fetch.
    enum DiskEntry: Sendable, Equatable {
        case icon(Data)
        case miss
    }

    #if DEBUG
    /// Where the disk cache lives, when a test needs it somewhere else.
    ///
    /// `clearCachedIcons` removes this directory outright, and the real one
    /// sits inside the running app's Application Support folder, one path
    /// component away from the store holding the user's clips and notes. A
    /// test that exercised clearing against the real path would wipe the
    /// data of whoever ran `swift test` — a contributor's own history.
    ///
    /// A task-local rather than a settable global, for the reason
    /// `PreferenceStore` is: swift-testing runs suites in parallel, so a
    /// global here is not an override, it is a shared variable. This one was
    /// written as a global first and caught a real test doing exactly that —
    /// `cacheFileNameNeverEscapesTheDirectory` asserts on the directory's
    /// name and read another suite's temporary path roughly one run in
    /// twenty. A task-local is visible only inside the body that bound it, so
    /// two suites can hold two directories in the same instant.
    /// Redirects the disk cache for the duration of `body`.
    nonisolated static func withCacheDirectory<R>(
        _ url: URL, _ body: () throws -> R
    ) rethrows -> R {
        try FaviconCacheOverride.$directory.withValue(url) { try body() }
    }

    /// The same, for a body that suspends — `diskEntry` is async, and a
    /// task-local stays bound across an await inside the operation.
    ///
    /// Main-actor isolated where the synchronous one is not: the tests that
    /// need this are, and a nonisolated version would have their closures
    /// crossing an isolation boundary for no reason.
    static func withCacheDirectory<R>(
        _ url: URL, _ body: () async throws -> R
    ) async rethrows -> R {
        try await FaviconCacheOverride.$directory.withValue(url) { try await body() }
    }
    #endif

    nonisolated static var cacheDirectory: URL {
        #if DEBUG
        if let override = FaviconCacheOverride.directory { return override }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Backpocket/Favicons")
    }

    nonisolated static func cacheFile(for host: String) -> URL {
        cacheDirectory.appending(path: cacheName(for: host) + ".png")
    }

    private nonisolated static func missFile(for host: String) -> URL {
        cacheDirectory.appending(path: cacheName(for: host) + ".miss")
    }

    private nonisolated static func cacheName(for host: String) -> String {
        String(host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
    }

    /// nil when there is nothing usable — including an entry past its age,
    /// which is left for the prune to remove.
    nonisolated static func diskEntry(host: String) async -> DiskEntry? {
        if let png = freshContents(of: cacheFile(for: host)) { return .icon(png) }
        if freshContents(of: missFile(for: host)) != nil { return .miss }
        return nil
    }

    /// Whether an entry has aged out, and so is neither served nor kept.
    ///
    /// One rule rather than the two spellings the reader and the prune used to
    /// carry separately, and `now` is a parameter because the boundary is the
    /// part worth testing: without it the only reachable cases are entries
    /// written seconds ago, which is the middle of the range and not where a
    /// comparison goes wrong.
    nonisolated static func isExpired(modified: Date, now: Date = .now) -> Bool {
        now.timeIntervalSince(modified) >= maxCacheAge
    }

    private nonisolated static func freshContents(of file: URL) -> Data? {
        guard
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
            !isExpired(modified: modified)
        else { return nil }
        return try? Data(contentsOf: file)
    }

    private nonisolated static func store(png: Data, host: String) {
        prepareDirectory()
        try? png.write(to: cacheFile(for: host), options: .atomic)
        try? FileManager.default.removeItem(at: missFile(for: host))
        prune()
    }

    private nonisolated static func recordMiss(host: String) {
        prepareDirectory()
        try? Data().write(to: missFile(for: host), options: .atomic)
        prune()
    }

    private nonisolated static func prepareDirectory() {
        try? FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// The record of which domains were copied must not grow without bound
    /// or outlive its usefulness, so entries go by age first and by count
    /// second, oldest out.
    nonisolated static func prune() {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return }

        var dated: [(file: URL, modified: Date)] = []
        for file in files {
            let modified =
                (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
            if isExpired(modified: modified) {
                try? FileManager.default.removeItem(at: file)
            } else {
                dated.append((file, modified))
            }
        }

        guard dated.count > maxCacheEntries else { return }
        for entry in dated.sorted(by: { $0.modified < $1.modified })
            .prefix(dated.count - maxCacheEntries)
        {
            try? FileManager.default.removeItem(at: entry.file)
        }
    }
}

/// Every guarantee this file makes about where a request goes has to hold on
/// each hop, not only the first: without a delegate URLSession follows up to
/// twenty redirects unchecked, and a public site can point one straight back
/// into the user's own network.
/// Internal rather than private only so the vetting can be exercised
/// directly: every rule here is a promise about where bytes travel, and the
/// alternative is a real redirecting server in the test suite.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var hops = 0

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        hops += 1
        let exhausted = hops > Favicons.maxRedirects
        lock.unlock()

        guard
            !exhausted,
            let url = request.url,
            url.scheme?.lowercased() == "https",
            let host = Favicons.normalizedHost(url.host(percentEncoded: false)),
            Favicons.isFetchable(host: host)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// How many rows are still waiting on each host's one shared download.
///
/// Split out from the tasks themselves because the interesting part is
/// arithmetic, and arithmetic that is easy to get wrong by one: a panel
/// closing mid-fetch must cancel the download nobody is waiting for any more,
/// and must NOT cancel one another visible row is still waiting on.
struct FetchWaiters {
    private var counts: [String: Int] = [:]

    mutating func join(_ host: String) {
        counts[host, default: 0] += 1
    }

    /// Records a waiter leaving, and answers whether it was the last one — the
    /// caller drops the shared task on true.
    mutating func leave(_ host: String) -> Bool {
        let remaining = (counts[host] ?? 1) - 1
        guard remaining > 0 else {
            counts[host] = nil
            return true
        }
        counts[host] = remaining
        return false
    }

    /// Whether a waiter about to give up is the only one, and so may cancel
    /// the download rather than leave it running for nobody.
    ///
    /// The boundary is 1 and not 0 because the asker is still counted: it is
    /// deciding whether to leave, and has not left yet.
    func isSole(_ host: String) -> Bool {
        (counts[host] ?? 0) <= 1
    }
}

/// Caps how many hosts are fetched at once. Waiters are served in arrival
/// order; a cancelled one still takes its turn, then returns immediately.
///
/// Internal rather than private only so the cap can be exercised directly,
/// for the reason `RedirectGuard` is: "at most three at once" is a promise
/// about what this app does to a network, and the alternative is inferring it
/// from three real downloads.
actor FetchLimiter {
    private let limit: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        if active >= limit {
            await withCheckedContinuation { waiting.append($0) }
        }
        active += 1
        defer {
            active -= 1
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        return await work()
    }
}

/// Whether link rows may fetch favicons over the network. Off by default —
/// the app's privacy promise is zero network calls unless asked.
enum FaviconFetching {
    static let `default` = false

    static var isEnabled: Bool {
        PreferenceStore.defaults.object(forKey: PreferenceKey.fetchFavicons) as? Bool ?? `default`
    }
}

// MARK: - Views

/// A link row's leading icon: the cached favicon when there is one, the
/// globe otherwise. Rows behind an Equatable gate still update — the async
/// load lands in this view's own state.
struct FaviconView: View {
    let url: URL

    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 17, height: 17)
        .task(id: url) { icon = await Favicons.shared.icon(for: url) }
    }
}

#if DEBUG
/// Where the favicon disk cache lives, when a test needs it somewhere else.
///
/// `clearCachedIcons` removes that directory outright, and the real one sits
/// inside the running app's Application Support folder, one path component
/// away from the store holding the user's clips and notes — so a test that
/// exercised clearing against the real path would wipe the data of whoever
/// ran `swift test`.
///
/// A task-local rather than a settable global, for the reason
/// `PreferenceStore` is: swift-testing runs suites in parallel, so a global
/// here would not be an override, it would be a shared variable. This was
/// written as a global first and caught a real test doing exactly that —
/// `cacheFileNameNeverEscapesTheDirectory` asserts on the directory's name
/// and read another suite's temporary path roughly one run in twenty.
///
/// Declared outside `Favicons` because that type is `@MainActor`, and a
/// task-local nested inside it inherits the isolation its projected value
/// then cannot shed — while `cacheDirectory` is read from the nonisolated
/// download path.
enum FaviconCacheOverride {
    @TaskLocal static var directory: URL?
}
#endif
