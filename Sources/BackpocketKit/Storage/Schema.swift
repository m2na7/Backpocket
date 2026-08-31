import Foundation
import SwiftData

/// The model's shape history, and the plan that carries a store from one
/// shape to the next.
///
/// Every version keeps its own copy of the model rather than referring back to
/// the live one: the point of a versioned schema is that an old shape stays
/// frozen even as the current model moves on, and a shared declaration would
/// silently rewrite history the next time a field is added.
///
/// Both classes are named `Item`, which is deliberate — SwiftData identifies an
/// entity by the class's own name, not by the enclosing enum, so V3's `Item`
/// and V4's `Item` are the same table and a migration between them is a table
/// alteration rather than a copy into a new entity.

/// The shape before the stored file-copy flag existed.
enum BackpocketSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] { [Item.self] }

    @Model
    final class Item {
        var content: String = ""
        var createdAt: Date = Date()
        var usedAt: Date = Date()
        var isNote: Bool = false
        var isPinned: Bool = false
        var sourceApp: String?
        var sourceBundleID: String?
        var contentHTML: String?
        @Attribute(.externalStorage) var contentRTF: Data? = nil
        @Attribute(.externalStorage) var imageData: Data? = nil
        @Attribute(.externalStorage) var thumbnailData: Data? = nil
        var imageHash: String? = nil

        init(
            content: String,
            isNote: Bool = false,
            isPinned: Bool = false,
            source: CopySource? = nil,
            html: String? = nil,
            rtf: Data? = nil,
            imageData: Data? = nil,
            thumbnailData: Data? = nil,
            imageHash: String? = nil
        ) {
            self.content = content
            self.createdAt = Date()
            self.usedAt = Date()
            self.isNote = isNote
            self.isPinned = isPinned
            self.sourceApp = source?.name
            self.sourceBundleID = source?.bundleID
            self.contentHTML = html
            self.contentRTF = rtf
            self.imageData = imageData
            self.thumbnailData = thumbnailData
            self.imageHash = imageHash
        }
    }
}

/// The current shape. `Item` is a typealias onto this one, so the rest of the
/// app never names a version.
enum BackpocketSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }
    static var models: [any PersistentModel.Type] { [Item.self] }

    /// A clipboard entry or a note, stored in one table.
    /// The app's premise is that they are the same thing, so they are not split.
    /// Never declare `id` on a @Model — it collides with the Identifiable that
    /// PersistentModel already provides, and fetches trap at runtime.
    @Model
    final class Item {
        var content: String = ""
        var createdAt: Date = Date()
        /// Sort key. Copying or pasting refreshes it, so an item moves to the top
        /// without delete-and-reinsert.
        var usedAt: Date = Date()
        var isNote: Bool = false
        var isPinned: Bool = false
        /// App the content was copied from. Empty for notes.
        var sourceApp: String?
        var sourceBundleID: String?
        /// The HTML flavor from the pasteboard, when the source app provided one.
        /// Kept so rich copies can later be pasted as Markdown.
        var contentHTML: String?
        /// The RTF flavor from the pasteboard, when the source app provided one.
        /// Kept so pasting back preserves formatting in RTF-only apps.
        @Attribute(.externalStorage) var contentRTF: Data? = nil
        /// PNG bytes for image clips; nil for text. External storage keeps
        /// megabyte blobs out of the SQLite rows the list queries against.
        @Attribute(.externalStorage) var imageData: Data? = nil
        /// Rendered once at record time — scrolling must never decode the
        /// full-size image.
        @Attribute(.externalStorage) var thumbnailData: Data? = nil
        /// SHA-256 of imageData. Dedup key: comparing megabytes of pixels on
        /// every copy would be too slow.
        var imageHash: String? = nil
        /// Whether the pasteboard really carried files when this was captured.
        /// Stored, because it cannot be re-derived: the TEXT `/Users/you/.ssh/id_rsa`
        /// and a copy of that FILE hold identical content, and treating the former
        /// as a file copy attaches the key instead of typing the path.
        var isFileCopy: Bool = false

        init(
            content: String,
            isNote: Bool = false,
            source: CopySource? = nil,
            isFileCopy: Bool = false,
            html: String? = nil,
            rtf: Data? = nil,
            imageData: Data? = nil,
            thumbnailData: Data? = nil,
            imageHash: String? = nil
        ) {
            self.content = content
            self.createdAt = Date()
            self.usedAt = Date()
            self.isNote = isNote
            self.isPinned = false
            self.sourceApp = source?.name
            self.sourceBundleID = source?.bundleID
            self.isFileCopy = isFileCopy
            self.contentHTML = html
            self.contentRTF = rtf
            self.imageData = imageData
            self.thumbnailData = thumbnailData
            self.imageHash = imageHash
        }
    }
}

/// Carries an existing store forward instead of throwing the user's notes
/// away. Notes are documented as permanent data, so a schema change must
/// never be a data loss event.
enum BackpocketMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [BackpocketSchemaV3.self, BackpocketSchemaV4.self]
    }

    static var stages: [MigrationStage] { [v3ToV4] }

    /// Lightweight, and genuinely so: the only difference is one added
    /// non-optional Bool with a default, which SQLite can add in place and
    /// which every pre-existing row answers with `false`.
    ///
    /// `false` is also the only correct answer, which is why this stage is not
    /// allowed to get cleverer. Inferring file-ness from content that looks
    /// like a path would re-open the bug the stored flag exists to close: the
    /// TEXT `/Users/you/.ssh/id_rsa` would come back as a file copy and paste
    /// the key instead of the path. V3 never recorded the distinction, so
    /// every migrated row must claim the safe side of it.
    static let v3ToV4 = MigrationStage.lightweight(
        fromVersion: BackpocketSchemaV3.self,
        toVersion: BackpocketSchemaV4.self
    )
}
