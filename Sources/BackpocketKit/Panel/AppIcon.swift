import AppKit

/// NSWorkspace lookups are too slow to repeat on every row render.
///
/// Both caches are bounded by the same type the row caches use, so the
/// eviction rule is stated and tested in one place rather than reimplemented
/// here. Neither is likely to reach its ceiling — an app icon per distinct
/// source app, a file icon per copied path — but "unlikely to grow" is not a
/// bound, and this process runs for weeks.
@MainActor
enum AppIcon {
    /// Keyed by bundle identifier, so it grows with the number of apps the
    /// user has ever copied from, not with the size of the history.
    private static var cache = BoundedCache<String, NSImage?>(limit: 256)

    /// A file copy's own icon, kept apart from the bundle cache: paths churn
    /// as clips expire, and a per-path entry would otherwise outlive its clip
    /// for the whole process.
    private static var fileCache = BoundedCache<String, NSImage>(limit: 256)

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        // Two levels of optional: the outer is "not cached", the inner is
        // "cached, and the answer was no icon". Flattening them would re-ask
        // NSWorkspace on every render for an app it has already refused.
        if let cached = cache[bundleID] { return cached }

        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache.insert(icon, for: bundleID)
        return icon
    }

    static func icon(forFile path: String) -> NSImage {
        if let cached = fileCache[path] { return cached }

        let icon = NSWorkspace.shared.icon(forFile: path)
        fileCache.insert(icon, for: path)
        return icon
    }
}
