/// A dictionary that refuses to grow past a ceiling.
///
/// The row caches in front of it are read on every render and live as long as
/// the panel does, which is the whole session — without a bound, entries for
/// long-deleted clips pile up for weeks. Reaching the ceiling drops everything
/// rather than evicting a victim: picking one costs a recency stamp per entry
/// and a scan to find the oldest, and the values here all re-derive lazily
/// from data the row already holds, so a wholesale flush is the cheaper miss.
struct BoundedCache<Key: Hashable, Value> {
    private var entries: [Key: Value] = [:]
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    var count: Int { entries.count }

    subscript(key: Key) -> Value? { entries[key] }

    /// Stores `value`, flushing first if the cache is already full, so it
    /// never holds more than `limit` entries.
    mutating func insert(_ value: Value, for key: Key) {
        if entries.count >= limit { entries.removeAll() }
        entries[key] = value
    }
}
