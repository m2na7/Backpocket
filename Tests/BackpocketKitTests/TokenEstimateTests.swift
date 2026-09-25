import Testing

@testable import BackpocketKit

@Suite("TokenEstimate")
struct TokenEstimateTests {
    @Test func asciiAveragesFourCharsPerToken() {
        let text = String(repeating: "word", count: 100)
        #expect(TokenEstimate.roughCount(text) == 100)
    }

    @Test func cjkCountsRoughlyOneTokenPerCharacter() {
        #expect(TokenEstimate.roughCount("한국어테스트") == 6)
    }

    @Test func emptyIsZero() {
        #expect(TokenEstimate.roughCount("") == 0)
    }
}
