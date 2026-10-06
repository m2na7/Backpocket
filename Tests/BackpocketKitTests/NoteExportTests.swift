import Foundation
import Testing

@testable import BackpocketKit

@MainActor
@Suite struct NoteExportTests {
    @Test func exportPreservesNotesAndMetadataWithoutClipboardContents() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let note = Item(content: "한글 메모\n\"quotes\" and 😀", isNote: true)
        note.isPinned = true
        note.createdAt = date
        note.usedAt = date.addingTimeInterval(60)
        let clip = Item(content: "private clipboard content")
        clip.isPinned = true

        let data = try NoteExport(items: [clip, note], exportedAt: date).encoded()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(NoteExport.self, from: data)

        #expect(result.formatVersion == 1)
        #expect(result.exportedAt == date)
        #expect(result.notes.count == 1)
        let exported = try #require(result.notes.first)
        #expect(exported.content == note.content)
        #expect(exported.createdAt == date)
        #expect(exported.usedAt == date.addingTimeInterval(60))
        #expect(exported.isPinned)
        #expect(!String(decoding: data, as: UTF8.self).contains(clip.content))
    }
}
