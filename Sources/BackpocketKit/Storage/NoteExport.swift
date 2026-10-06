import Foundation

/// A portable text-only backup, independent of SwiftData's schema and identifiers.
struct NoteExport: Codable, Sendable {
    struct Note: Codable, Sendable {
        let content: String
        let createdAt: Date
        let usedAt: Date
        let isPinned: Bool
    }

    let formatVersion: Int
    let exportedAt: Date
    let notes: [Note]

    /// The same bound applies to export and import, so every file we write
    /// can be read back. Large or corrupt input must fail before any writes.
    static let maxFileBytes = 256 * 1_024 * 1_024

    @MainActor
    init(items: [Item], exportedAt: Date = Date()) {
        formatVersion = 1
        self.exportedAt = exportedAt
        notes = items.filter(\.isNote).map {
            Note(
                content: $0.content, createdAt: $0.createdAt, usedAt: $0.usedAt,
                isPinned: $0.isPinned)
        }
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maxFileBytes else { throw NoteTransferError.tooLarge }
        return data
    }

    static func read(from url: URL) throws -> NoteExport {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= maxFileBytes else { throw NoteTransferError.tooLarge }
        return try decoded(Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func decoded(_ data: Data) throws -> NoteExport {
        guard data.count <= maxFileBytes else { throw NoteTransferError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive: NoteExport
        do {
            archive = try decoder.decode(NoteExport.self, from: data)
        } catch {
            throw NoteTransferError.invalidFile
        }
        try archive.validate()
        return archive
    }

    func validate() throws {
        guard formatVersion == 1 else { throw NoteTransferError.unsupportedVersion }
        // Keep date arithmetic and note grouping within the ISO calendar's
        // supported years, including when an archive is built programmatically.
        let dates = [exportedAt] + notes.flatMap { [$0.createdAt, $0.usedAt] }
        guard
            dates.allSatisfy({
                $0.timeIntervalSince1970.isFinite
                    && (-62_135_596_800...253_402_300_799).contains($0.timeIntervalSince1970)
            })
        else { throw NoteTransferError.invalidFile }
    }
}

struct NoteImportResult: Equatable, Sendable {
    let imported: Int
    let skipped: Int
}

enum NoteTransferError: Error, LocalizedError, Equatable {
    case invalidFile
    case unsupportedVersion
    case tooLarge
    case temporaryStorage
    case storageFailure

    var errorDescription: String? {
        switch self {
        case .invalidFile: String(localized: "import.invalidFile")
        case .unsupportedVersion: String(localized: "import.unsupportedVersion")
        case .tooLarge: String(localized: "import.tooLarge")
        case .temporaryStorage: String(localized: "import.temporaryStorage")
        case .storageFailure: String(localized: "import.storageFailure")
        }
    }
}
