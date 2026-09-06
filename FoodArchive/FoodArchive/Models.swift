import Foundation
import SwiftData

enum MediaKind: String, Codable, CaseIterable, Identifiable {
    case image, video
    var id: String { rawValue }
}

enum ExperienceKind: String, Codable, CaseIterable, Identifiable {
    case ate, cooked, other
    var id: String { rawValue }
}

@Model
final class FoodItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var savedAt: Date
    var sourceURL: String
    var sourceName: String
    var notes: String
    var isFavorite: Bool
    var wantToTry: Bool
    var isArchived: Bool
    /// Retained only to keep journal history intact after a library deletion.
    var isHistoricalOnly: Bool
    var coverID: UUID?
    @Relationship(deleteRule: .cascade, inverse: \MediaAsset.foodItem)
    var assets: [MediaAsset] = []
    @Relationship(deleteRule: .nullify, inverse: \Tag.items)
    var tags: [Tag] = []
    @Relationship(deleteRule: .cascade, inverse: \CollectionMembership.item)
    var memberships: [CollectionMembership] = []
    var entries: [JournalEntry] = []

    init(title: String, savedAt: Date = .now, id: UUID = UUID()) {
        self.id = id
        self.title = title
        self.savedAt = savedAt
        sourceURL = ""
        sourceName = ""
        notes = ""
        isFavorite = false
        wantToTry = false
        isArchived = false
        isHistoricalOnly = false
    }

    var orderedAssets: [MediaAsset] {
        assets.sorted { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }
    }
    var cover: MediaAsset? { assets.first { $0.id == coverID } ?? orderedAssets.first }
    var archiveCode: String { "FD-" + String(id.uuidString.prefix(6)) }
    var lastLoggedAt: Date? { entries.map(\.occurredAt).max() }
    var hasTried: Bool { entries.contains { $0.kind != .other } }
}

@Model
final class MediaAsset {
    @Attribute(.unique) var id: UUID
    var originalPath: String
    var thumbnailPath: String
    var kindRaw: String
    var width: Int
    var height: Int
    var duration: Double
    var position: Int
    var isIsolated: Bool
    var cropX: Double
    var cropY: Double
    var foodItem: FoodItem?
    var journalEntry: JournalEntry?

    init(payload: MediaPayload, position: Int = 0) {
        id = payload.id
        originalPath = payload.originalPath
        thumbnailPath = payload.thumbnailPath
        kindRaw = payload.kind.rawValue
        width = payload.width
        height = payload.height
        duration = payload.duration
        self.position = position
        isIsolated = false
        cropX = 0.5
        cropY = 0.5
    }
    var kind: MediaKind { MediaKind(rawValue: kindRaw) ?? .image }
}

@Model
final class Tag {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var normalizedName: String
    var name: String
    var items: [FoodItem] = []

    init(name: String) {
        id = UUID()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        normalizedName = Self.normalize(name)
    }
    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

@Model
final class FoodCollection {
    @Attribute(.unique) var id: UUID
    var name: String
    var coverItemID: UUID?
    @Relationship(deleteRule: .cascade, inverse: \CollectionMembership.collection)
    var memberships: [CollectionMembership] = []

    init(name: String) {
        id = UUID()
        self.name = name
    }
    var orderedItems: [FoodItem] {
        memberships.sorted {
            $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position
        }.compactMap(\.item).filter { !$0.isHistoricalOnly }
    }
}

@Model
final class CollectionMembership {
    @Attribute(.unique) var id: UUID
    var position: Int
    var item: FoodItem?
    var collection: FoodCollection?

    init(item: FoodItem, collection: FoodCollection, position: Int) {
        id = UUID()
        self.item = item
        self.collection = collection
        self.position = position
    }
}

@Model
final class JournalEntry {
    @Attribute(.unique) var id: UUID
    var occurredAt: Date
    var kindRaw: String
    var occasion: String
    var place: String
    var reflection: String
    var rating: Int?
    @Relationship(deleteRule: .nullify, inverse: \FoodItem.entries)
    var items: [FoodItem] = []
    @Relationship(deleteRule: .cascade, inverse: \MediaAsset.journalEntry)
    var attachments: [MediaAsset] = []

    init(occurredAt: Date = .now, kind: ExperienceKind = .ate) {
        id = UUID()
        self.occurredAt = occurredAt
        kindRaw = kind.rawValue
        occasion = ""
        place = ""
        reflection = ""
    }
    var kind: ExperienceKind { ExperienceKind(rawValue: kindRaw) ?? .other }
    var title: String {
        let names = items.map(\.title)
        return names.isEmpty ? (occasion.isEmpty ? "Journal entry" : occasion) : names.joined(separator: " + ")
    }
    var cover: MediaAsset? { attachments.sorted { $0.position < $1.position }.first ?? items.first?.cover }
}

struct MediaPayload: Codable, Sendable, Identifiable {
    var id: UUID
    var originalPath: String
    var thumbnailPath: String
    var kind: MediaKind
    var width: Int
    var height: Int
    var duration: Double
}

enum ArchiveSchema {
    static var schema: Schema {
        Schema([FoodItem.self, MediaAsset.self, Tag.self, FoodCollection.self, CollectionMembership.self, JournalEntry.self])
    }
    static func container(inMemory: Bool = false) throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory))
    }
}