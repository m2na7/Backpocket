import AppKit
import Foundation
import Testing

@testable import BackpocketKit

/// The highest number of bodies that were inside the limiter at one moment.
private actor ConcurrencyPeak {
    private var active = 0
    private(set) var peak = 0

    func enter() {
        active += 1
        peak = max(peak, active)
    }

    func leave() {
        active -= 1
    }
}

@Suite struct FaviconsTests {
    @Test func publicHostsAreFetchable() {
        #expect(Favicons.isFetchable(host: "github.com"))
        #expect(Favicons.isFetchable(host: "sub.domain.example.co.kr"))
    }

    @Test func localAndPrivateHostsAreNever() {
        #expect(!Favicons.isFetchable(host: "localhost"))
        #expect(!Favicons.isFetchable(host: "myapp.localhost"))
        #expect(!Favicons.isFetchable(host: "printer.local"))
        #expect(!Favicons.isFetchable(host: "vault.internal"))
        #expect(!Favicons.isFetchable(host: "router.home.arpa"))
        #expect(!Favicons.isFetchable(host: "staging.test"))
        // Bare names without a dot cannot be public.
        #expect(!Favicons.isFetchable(host: "intranet"))
        #expect(!Favicons.isFetchable(host: ""))
    }

    @Test func ipLiteralsAreNever() {
        #expect(!Favicons.isFetchable(host: "127.0.0.1"))
        #expect(!Favicons.isFetchable(host: "192.168.0.10"))
        // Public IPs too — a favicon is not worth probing addresses.
        #expect(!Favicons.isFetchable(host: "8.8.8.8"))
        #expect(!Favicons.isFetchable(host: "::1"))
        #expect(!Favicons.isFetchable(host: "2606:4700::6810:84e5"))
    }

    /// Real encoded bytes: a stub blob is rejected by the decode guard, so it
    /// would keep passing with the size cap deleted.
    private func tiffData(side: Int) throws -> Data {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: side,
                pixelsHigh: side,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
        return try #require(bitmap.tiffRepresentation)
    }

    @Test func sanitizedPNGRejectsNonImagesAndOversize() throws {
        #expect(Favicons.sanitizedPNG(from: Data("<html>not an icon".utf8)) == nil)
        #expect(Favicons.sanitizedPNG(from: Data()) == nil)

        // A decodable image past the cap — the case the cap exists for.
        let oversize = try tiffData(side: 400)
        #expect(oversize.count > 512_000)
        #expect(Favicons.sanitizedPNG(from: oversize) == nil)
    }

    @Test func sanitizedPNGReencodesARealIconToASmallPNG() throws {
        let png = try #require(Favicons.sanitizedPNG(from: try tiffData(side: 16)))

        #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        // Whatever arrived, only pixels survive — redrawn at the icon size.
        let decoded = try #require(NSBitmapImageRep(data: png))
        #expect(decoded.pixelsWide == 64)
        #expect(decoded.pixelsHigh == 64)
    }

    @Test func theSizeGatesAdmitTheirLimitAndRefuseOneMore() {
        // Reached through real encoded bytes these can only be exercised well
        // inside their range: no icon weighs exactly half a megabyte. Both
        // caps are spelled out so that widening either has to be a deliberate
        // edit here too.
        #expect(Favicons.acceptsByteCount(512_000))
        #expect(!Favicons.acceptsByteCount(512_001))
        // An empty body is not a zero-byte icon, it is no icon.
        #expect(!Favicons.acceptsByteCount(0))

        #expect(Favicons.acceptsPixelSize(width: 2048, height: 2048))
        #expect(!Favicons.acceptsPixelSize(width: 2049, height: 2048))
        #expect(!Favicons.acceptsPixelSize(width: 2048, height: 2049))
        // The gate is against a small file declaring enormous dimensions, so
        // a declared side of zero is as wrong as one past the cap.
        #expect(!Favicons.acceptsPixelSize(width: 0, height: 64))
    }

    @Test func iconHrefFindsTheFirstDeclaredIcon() {
        let html = """
            <head><link rel="preload" href="app.css">
            <LINK REL='Shortcut Icon' HREF='https://cdn.example.com/fav.ico?v=1'>
            <link rel="icon" href="/second.png"></head>
            """
        #expect(Favicons.iconHref(in: html) == "https://cdn.example.com/fav.ico?v=1")
        #expect(Favicons.iconHref(in: #"<link rel="stylesheet" href="a.css">"#) == nil)
    }

    @Test func declaredIconResolvesUpgradesAndVetsTheHost() throws {
        let base = try #require(URL(string: "https://calendar.google.com/"))

        #expect(
            Favicons.declaredIcon(href: "/icons/fav.png", base: base)?.absoluteString
                == "https://calendar.google.com/icons/fav.png"
        )
        // A cross-host icon is the site's own choice, but never over plain HTTP.
        #expect(
            Favicons.declaredIcon(href: "http://cdn.example.com/f.ico", base: base)?
                .absoluteString == "https://cdn.example.com/f.ico"
        )
        // Markup must not be able to point the fetcher at the LAN.
        #expect(Favicons.declaredIcon(href: "http://192.168.0.1/f.ico", base: base) == nil)
        #expect(Favicons.declaredIcon(href: "data:image/png;base64,AAAA", base: base) == nil)
    }

    @Test func parentDomainFallbackStopsAtTheApex() {
        #expect(
            Favicons.parentDomainFavicon(host: "calendar.google.com")?.absoluteString
                == "https://google.com/favicon.ico"
        )
        #expect(Favicons.parentDomainFavicon(host: "google.com") == nil)
        #expect(Favicons.parentDomainFavicon(host: "app.corp.local") == nil)
    }

    @Test func cacheFileNameNeverEscapesTheDirectory() {
        let file = Favicons.cacheFile(for: "evil/..\\host?.com")
        #expect(file.lastPathComponent == "evil_.._host_.com.png")
        #expect(file.deletingLastPathComponent().lastPathComponent == "Favicons")
    }

    @Test func aTrailingDotCannotSlipPastTheSuffixChecks() {
        // "printer.local." names the same machine to a resolver but defeats
        // every hasSuffix test, and "127.0.0.1." still parses as an address.
        #expect(!Favicons.isFetchable(host: "printer.local."))
        #expect(!Favicons.isFetchable(host: "secret.onion."))
        #expect(!Favicons.isFetchable(host: "localhost."))
        #expect(!Favicons.isFetchable(host: "127.0.0.1."))
        // A public host with a trailing dot is still that public host.
        #expect(Favicons.isFetchable(host: "github.com."))
    }

    @Test func addressLiteralsInEveryNotationAreRejected() {
        // The resolver's own parser, not a digits-and-dots test: each of these
        // is 127.0.0.1 to inet_aton but reads as a name to a naive check, and
        // a favicon is not worth a request to the user's own machine.
        #expect(!Favicons.isFetchable(host: "0x7f.0.0.1"))
        #expect(!Favicons.isFetchable(host: "0177.0.0.1"))
        #expect(!Favicons.isFetchable(host: "2130706433"))
        #expect(!Favicons.isFetchable(host: "127.1"))
        #expect(!Favicons.isFetchable(host: "::ffff:127.0.0.1"))
        #expect(!Favicons.isFetchable(host: "fe80::1"))
    }

    @Test func onionAndPercentEncodedHostsAreRejected() {
        #expect(!Favicons.isFetchable(host: "facebookcorewwwi.onion"))
        // A percent escape hides a literal from every character test, so the
        // host is decoded before anything compares it.
        #expect(Favicons.normalizedHost("EXAMPLE%2ECOM") == "example.com")
        #expect(!Favicons.isFetchable(host: "127%2E0%2E0%2E1"))
        // Anything outside a hostname's alphabet is an encoding trick.
        #expect(!Favicons.isFetchable(host: "exa mple.com"))
        #expect(!Favicons.isFetchable(host: "user@example.com"))
    }

    @Test func normalizedHostFoldsCaseAndRejectsEmptiness() {
        #expect(Favicons.normalizedHost("GitHub.COM") == "github.com")
        #expect(Favicons.normalizedHost("example.com...") == "example.com")
        #expect(Favicons.normalizedHost(".") == nil)
        #expect(Favicons.normalizedHost("") == nil)
        #expect(Favicons.normalizedHost(nil) == nil)
    }

    @Test func onlyTheLastWaiterLeavingMayCancelTheSharedDownload() {
        var waiters = FetchWaiters()

        // One row asking: it is alone, so giving up may cancel the download
        // rather than leave it running out the resource timeout for nobody.
        waiters.join("example.com")
        #expect(waiters.isSole("example.com"))

        // A second row joins the same download, and now neither may cancel it
        // out from under the other. The regression is a panel scrolling one
        // link row away and blanking the icon on one still on screen.
        waiters.join("example.com")
        #expect(!waiters.isSole("example.com"))

        // Leaving reports whether the shared task goes with it.
        let secondLeft = waiters.leave("example.com")
        #expect(secondLeft == false)
        #expect(waiters.isSole("example.com"))
        let lastLeft = waiters.leave("example.com")
        #expect(lastLeft)

        // A host nobody is waiting on is not somehow still mid-flight.
        #expect(waiters.isSole("never-asked.example"))
    }

    @Test func waitersAreCountedPerHostRatherThanInTotal() {
        var waiters = FetchWaiters()
        waiters.join("a.example")
        waiters.join("b.example")

        // Two rows on two hosts are each the only waiter on their own, so a
        // busy list does not stop either from cancelling its own download.
        #expect(waiters.isSole("a.example"))
        let aLeft = waiters.leave("a.example")
        #expect(aLeft)
        #expect(waiters.isSole("b.example"))
    }

    @Test func headersAloneCanRuleOutABodyBeforeAByteIsRead() {
        func accepts(_ status: Int, _ mime: String?, _ length: Int64) -> Bool {
            Favicons.acceptsHeaders(
                status: status, mime: mime, declaredLength: length, cap: 100,
                accepting: ["image/png"])
        }

        // Exactly at the cap is admitted and one byte past it is refused
        // outright, so a server cannot spend the whole resource timeout
        // streaming a body that was never going to be accepted.
        #expect(accepts(200, "image/png", 100))
        #expect(!accepts(200, "image/png", 101))

        // An undeclared length is -1, not zero, and has to pass: rejecting it
        // would refuse every chunked reply. The streaming cap catches those.
        #expect(accepts(200, "image/png", -1))

        // Markup served where an icon was asked for is not an icon, and an
        // error page is not one either however small it is.
        #expect(!accepts(200, "text/html", 10))
        #expect(!accepts(200, nil, 10))
        #expect(!accepts(404, "image/png", 10))

        // Header casing is the server's business, not a reason to fail.
        #expect(accepts(200, "IMAGE/PNG", 10))
    }

    @Test func aCachedIconExpiresAtTwoWeeksAndNotBefore() {
        // Spelled out rather than read from the constant, so that lengthening
        // the expiry has to be a deliberate edit here too. An icon captured
        // through a captive portal must not be the site's icon forever.
        let twoWeeks: TimeInterval = 14 * 24 * 60 * 60
        let written = Date(timeIntervalSince1970: 1_000_000)

        #expect(!Favicons.isExpired(modified: written, now: written))
        #expect(!Favicons.isExpired(modified: written, now: written + twoWeeks - 1))
        #expect(Favicons.isExpired(modified: written, now: written + twoWeeks))
        #expect(Favicons.isExpired(modified: written, now: written + twoWeeks + 1))

        // A clock that moved backwards leaves entries dated in the future.
        // Those are odd but not expired, and throwing them away would empty
        // the cache on every launch until the clock caught up.
        #expect(!Favicons.isExpired(modified: written, now: written - 1))
    }

    /// "At most three hosts at once" is a promise about what this app does to
    /// a network — a whole list scrolling into view would otherwise start
    /// three requests per visible row.
    @Test func theFetchLimiterNeverRunsMoreThanItsLimitAtOnce() async {
        let limiter = FetchLimiter(limit: 3)
        let tracker = ConcurrencyPeak()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await limiter.run {
                        await tracker.enter()
                        // Suspend rather than sleep: the bound below is an
                        // invariant the limiter enforces, so no scheduling
                        // outcome can break it. The crowd is only here to
                        // give a broken limiter room to exceed it.
                        for _ in 0..<50 { await Task.yield() }
                        await tracker.leave()
                    }
                }
            }
        }

        #expect(await tracker.peak <= 3)
        // And the limit is a cap, not a queue of one: twelve callers through
        // a limit of three must actually overlap, or the assertion above is
        // being satisfied by a limiter that serialized everything.
        #expect(await tracker.peak > 1)
    }

    /// Each guarantee about where bytes travel has to hold on every hop:
    /// without vetting, URLSession follows up to twenty redirects unchecked
    /// and a public site can point one straight back into the user's network.
    @MainActor
    @Test func redirectsAreVettedByTheSameRulesAsTheFirstRequest() async {
        func followed(_ target: String, guard vetting: RedirectGuard) async -> Bool {
            await withCheckedContinuation { continuation in
                vetting.urlSession(
                    .shared,
                    task: URLSession.shared.dataTask(with: URL(string: "https://example.com")!),
                    willPerformHTTPRedirection: HTTPURLResponse(),
                    newRequest: URLRequest(url: URL(string: target)!)
                ) { request in
                    continuation.resume(returning: request != nil)
                }
            }
        }

        #expect(await followed("https://cdn.example.com/f.ico", guard: RedirectGuard()))
        // Downgrading to plain HTTP, or being aimed at the LAN, ends the chain.
        #expect(await followed("http://cdn.example.com/f.ico", guard: RedirectGuard()) == false)
        #expect(await followed("https://192.168.0.1/f.ico", guard: RedirectGuard()) == false)
        #expect(await followed("https://printer.local/f.ico", guard: RedirectGuard()) == false)
    }

    @MainActor
    @Test func theRedirectChainIsCapped() async {
        let vetting = RedirectGuard()

        func hop() async -> Bool {
            await withCheckedContinuation { continuation in
                vetting.urlSession(
                    .shared,
                    task: URLSession.shared.dataTask(with: URL(string: "https://example.com")!),
                    willPerformHTTPRedirection: HTTPURLResponse(),
                    newRequest: URLRequest(url: URL(string: "https://example.com/next")!)
                ) { continuation.resume(returning: $0 != nil) }
            }
        }

        // Three hops (Favicons.maxRedirects) are allowed; the fourth is a
        // loop, and following it would hold a connection open until the
        // resource timeout. Spelled out rather than read from the constant so
        // that raising the cap has to be a deliberate edit here too.
        for _ in 0..<3 {
            #expect(await hop())
        }
        #expect(await hop() == false)
    }
}

/// The opt-in gate. "Zero network calls unless asked" is the app's stated
/// privacy promise, so these pin the default and the inertness — not the
/// fetch, which is never exercised here.
@MainActor
@Suite("FaviconFetching")
struct FaviconFetchingTests {
    /// nil means the key is absent, as on a fresh install. The store belongs
    /// to this call, so an absent key really is absent rather than whatever a
    /// parallel test last wrote.
    ///
    /// The caller's position is forwarded: taken here it would name one store
    /// for every test in this suite, which is exactly the sharing the scratch
    /// store exists to avoid.
    private func withFetching<R>(
        _ enabled: Bool?,
        fileID: String = #fileID,
        line: Int = #line,
        _ body: () async throws -> R
    ) async throws -> R {
        try await withScratchPreferences(fileID: fileID, line: line) { defaults in
            if let enabled {
                defaults.set(enabled, forKey: PreferenceKey.fetchFavicons)
            }
            return try await body()
        }
    }

    @Test func fetchingIsOffOnAFreshInstall() async throws {
        // The one assertion that keeps the promise true out of the box: a
        // default flipped to true ships a network feature nobody enabled.
        try await withFetching(nil) {
            #expect(!FaviconFetching.isEnabled)
        }
    }

    @Test func thePreferenceTurnsFetchingOnAndOffAgain() async throws {
        try await withFetching(true) { #expect(FaviconFetching.isEnabled) }
        try await withFetching(false) { #expect(!FaviconFetching.isEnabled) }
    }

    @Test func withTheSettingOffALookupIsInertForEveryHost() async throws {
        try await withFetching(false) {
            // The gate is checked before the host rules, the memory cache and
            // the disk cache, so turning the setting back off makes the
            // feature inert rather than merely quiet — nothing an earlier
            // opt-in left on disk is read.
            let url = URL(string: "https://github.com/m2na7/backpocket")!
            #expect(await Favicons.shared.icon(for: url) == nil)
        }
    }

    @Test func withTheSettingOnAnUnfetchableHostStillNeverStartsALookup() async throws {
        try await withFetching(true) {
            // The host rules are the second gate. A LAN address must not be
            // contacted even by a user who opted in.
            #expect(await Favicons.shared.icon(for: URL(string: "https://192.168.0.5/")!) == nil)
            #expect(await Favicons.shared.icon(for: URL(string: "https://localhost/")!) == nil)
            #expect(await Favicons.shared.icon(for: URL(string: "https://secret.onion/")!) == nil)
        }
    }

    /// Redirects the disk cache into a throwaway directory for the duration.
    ///
    /// Every test below that touches clearing must go through this. The real
    /// cache directory is inside the running app's Application Support folder,
    /// beside the store holding the user's clips and notes, and clearing
    /// removes the directory outright — so a test that used the real path
    /// would delete the data of whoever ran `swift test`.
    private func withTemporaryCache(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "backpocket-favicons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Scoped, not assigned: the suites around this one run in parallel,
        // and a test that reads `cacheDirectory` for its own reasons must not
        // see this one's temporary path.
        try Favicons.withCacheDirectory(directory) { try body(directory) }
    }

    /// The same, for a body that suspends.
    private func withTemporaryCache(_ body: (URL) async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "backpocket-favicons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Favicons.withCacheDirectory(directory) { try await body(directory) }
    }

    @Test func clearingDeletesTheCachedFilesThemselves() throws {
        try withTemporaryCache { directory in
            // Written through the same name mapping the cache uses, so this
            // pins the real file layout rather than an invented one.
            let icon = Favicons.cacheFile(for: "example.com")
            let miss = directory.appending(path: "dead_host.miss")
            try Data([0x89, 0x50]).write(to: icon)
            try Data().write(to: miss)
            #expect(FileManager.default.fileExists(atPath: icon.path(percentEncoded: false)))

            Favicons.clearCachedIcons()

            // Asserted on the filesystem, not through `icon(for:)`. The old
            // test asked whether a lookup returned nil with the setting off,
            // which the opt-in gate guarantees on its own — it passed against
            // a clearCachedIcons() that did nothing at all.
            #expect(!FileManager.default.fileExists(atPath: icon.path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: miss.path(percentEncoded: false)))
        }
    }

    @Test func clearingDoesNotDisturbTheRestOfApplicationSupport() throws {
        try withTemporaryCache { directory in
            // The cache directory is removed whole, so a sibling standing in
            // for the store must survive. Nothing here writes near the real
            // Application Support folder; this pins the blast radius.
            let sibling = directory.deletingLastPathComponent()
                .appending(path: "backpocket-sibling-\(UUID().uuidString)")
            try Data("the user's notes".utf8).write(to: sibling)
            defer { try? FileManager.default.removeItem(at: sibling) }

            Favicons.clearCachedIcons()

            #expect(
                try Data(contentsOf: sibling) == Data("the user's notes".utf8))
        }
    }

    @Test func adeadHostIsRememberedAsDeadRatherThanReProbed() async throws {
        // Three requests per launch per dead host is the cost of getting this
        // backwards, and the other direction is worse: read the absence of a
        // marker as a recorded failure and no host is ever fetched at all.
        try await withTemporaryCache { directory in
            #expect(await Favicons.diskEntry(host: "never-seen.example") == nil)

            try Data().write(to: directory.appending(path: "dead.example.miss"))
            #expect(await Favicons.diskEntry(host: "dead.example") == .miss)

            // Written through the same name mapping the cache uses, so this
            // pins the real file layout rather than an invented one.
            let png = Data([0x89, 0x50, 0x4E, 0x47])
            try png.write(to: Favicons.cacheFile(for: "live.example"))
            #expect(await Favicons.diskEntry(host: "live.example") == .icon(png))
        }
    }

    @Test func pruningDropsTheOldestEntriesOnceTheDirectoryIsOverItsCap() throws {
        // The record of which domains were copied must not grow without
        // bound. Getting the count wrong in the other direction empties the
        // cache outright on the first write past the cap, which turns every
        // launch back into a full round of fetches.
        try withTemporaryCache { directory in
            let now = Date.now
            for index in 0..<260 {
                let file = directory.appending(path: "host\(index).png")
                try Data([0x89]).write(to: file)
                // Oldest first, all comfortably inside the two-week expiry so
                // this pins the count rule and not the age one.
                try FileManager.default.setAttributes(
                    [.modificationDate: now.addingTimeInterval(TimeInterval(index - 300))],
                    ofItemAtPath: file.path(percentEncoded: false))
            }

            Favicons.prune()

            let left = try FileManager.default.contentsOfDirectory(
                atPath: directory.path(percentEncoded: false))
            #expect(left.count == 256)
            // The four oldest are the ones that went.
            #expect(!left.contains("host0.png"))
            #expect(!left.contains("host3.png"))
            #expect(left.contains("host4.png"))
            #expect(left.contains("host259.png"))
        }
    }

    @Test func clearingLeavesNothingBehind() async throws {
        // Settings and "Reset everything" both call this; a cache that
        // survived would keep serving icons from hosts the user just wiped.
        try withTemporaryCache { _ in
            Favicons.clearCachedIcons()
        }

        try await withFetching(false) {
            #expect(await Favicons.shared.icon(for: URL(string: "https://github.com/")!) == nil)
        }
    }
}
