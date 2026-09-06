import Foundation
import Observation

struct JournalDraft: Codable, Equatable, Identifiable {
    var id = UUID()
    var editingEntryID: UUID?
    var occurredAt = Date.now
    var kind = ExperienceKind.ate
    var occasion = ""
    var place = ""
    var reflection = ""
    var rating: Int?
    var itemIDs: [UUID] = []
    var attachments: [MediaPayload] = []
    var originalAttachmentIDs: [UUID] = []
    var updatedAt = Date.now

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Codable payloads contain only value types; compare the full draft deterministically.
        lhs.id == rhs.id && lhs.editingEntryID == rhs.editingEntryID
            && lhs.occurredAt == rhs.occurredAt && lhs.kind == rhs.kind
            && lhs.occasion == rhs.occasion && lhs.place == rhs.place
            && lhs.reflection == rhs.reflection && lhs.rating == rhs.rating
            && lhs.itemIDs == rhs.itemIDs && lhs.attachments.map(\.id) == rhs.attachments.map(\.id)
            && lhs.originalAttachmentIDs == rhs.originalAttachmentIDs
    }

    init(items: [FoodItem] = [], entry: JournalEntry? = nil) {
        if let entry {
            id = entry.id
            editingEntryID = entry.id
            occurredAt = entry.occurredAt
            kind = entry.kind
            occasion = entry.occasion
            place = entry.place
            reflection = entry.reflection
            rating = entry.rating
            itemIDs = entry.items.map(\.id)
            attachments = entry.attachments.sorted { $0.position < $1.position }.map(\.payload)
            originalAttachmentIDs = attachments.map(\.id)
        } else { itemIDs = items.map(\.id) }
    }
}

extension MediaAsset {
    var payload: MediaPayload {
        MediaPayload(id: id, originalPath: originalPath, thumbnailPath: thumbnailPath,
                     kind: kind, width: width, height: height, duration: duration)
    }
}

@MainActor @Observable
final class DraftStore {
    var drafts: [JournalDraft] = []
    let directory: URL
    init(directory: URL = MediaStorage.root.appendingPathComponent("Drafts", isDirectory: true)) { self.directory = directory }

    func load() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { drafts = []; return }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        // A damaged draft is surfaced, never overwritten or silently discarded.
        drafts = try urls.filter { $0.pathExtension == "json" }.map {
            try JSONDecoder().decode(JournalDraft.self, from: Data(contentsOf: $0))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ draft: JournalDraft) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var value = draft
        value.updatedAt = .now
        let data = try JSONEncoder().encode(value)
        try data.write(to: directory.appendingPathComponent("\(value.id).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        drafts.removeAll { $0.id == value.id }
        drafts.insert(value, at: 0)
    }

    func remove(_ id: UUID) throws {
        let url = directory.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        drafts.removeAll { $0.id == id }
    }
}