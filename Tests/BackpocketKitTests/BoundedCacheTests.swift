import Testing

@testable import BackpocketKit

/// The ceiling behind both row caches. It used to live inline in `ItemRow`, as
/// a shared static that nothing could count entries in — so the one thing it
/// exists to guarantee, that a session-long cache stops growing, went
/// unasserted while the render tests walked over the line on every row.
@Suite struct BoundedCacheTests {
    /// Filling it to the ceiling keeps everything: a cache that flushed early
    /// would re-decode a thumbnail or re-stat a file on renders it should have
    /// answered from memory.
    @Test func everythingUpToTheLimitIsKept() {
        var cache = BoundedCache<Int, Int>(limit: 3)
        for key in 0..<3 { cache.insert(key, for: key) }

        #expect(cache.count == 3)
        #expect((0..<3).allSatisfy { cache[$0] == $0 })
        #expect(cache[7] == nil)
    }

    /// And the boundary: the insertion that would carry it past the limit
    /// flushes instead. Tested here rather than a step inside the range,
    /// because a bound that holds one entry more than it says is a bound
    /// nobody can reason about from the call site.
    @Test func theInsertionPastTheLimitFlushesEverything() {
        var cache = BoundedCache<Int, Int>(limit: 3)
        for key in 0..<4 { cache.insert(key, for: key) }

        #expect(cache.count == 1)
        #expect(cache[3] == 3)
        #expect((0..<3).allSatisfy { cache[$0] == nil })
    }

    /// A flush is a miss, not a loss: the value is re-derived and stored
    /// again, which is what makes dropping the whole table an acceptable
    /// eviction policy in the first place.
    @Test func akeyLostToAflushCanBeStoredAgain() {
        var cache = BoundedCache<Int, String>(limit: 2)
        cache.insert("first", for: 0)
        cache.insert("second", for: 1)
        cache.insert("third", for: 2)
        #expect(cache[0] == nil)

        cache.insert("first", for: 0)
        #expect(cache[0] == "first")
    }
}
