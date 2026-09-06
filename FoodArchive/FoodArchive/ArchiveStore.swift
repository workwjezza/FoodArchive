import Foundation
import SwiftData
import Observation

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent = "Recently saved", oldest = "Oldest saved", title = "Title A–Z"
    case logged = "Recently logged", frequent = "Most frequently logged", manual = "Manual order"
    var id: String { rawValue }
}

struct LibraryFilter: Equatable {
    var media: Set<MediaKind> = []
    var tagIDs: Set<UUID> = []
    var collectionIDs: Set<UUID> = []
    var allTags = false
    var logged: Bool?
    var wantToTry = false
    var favorites = false
    var archived = false
    var dateEnabled = false
    var startDate = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    var endDate = Date.now

    var count: Int {
        [!media.isEmpty, !tagIDs.isEmpty, !collectionIDs.isEmpty, logged != nil,
         wantToTry, favorites, archived, dateEnabled].filter { $0 }.count
    }

    func matches(_ item: FoodItem) -> Bool {
        guard !item.isHistoricalOnly, item.isArchived == archived else { return false }
        if !media.isEmpty && !item.assets.contains(where: { media.contains($0.kind) }) { return false }
        let itemTags = Set(item.tags.map(\.id))
        if !tagIDs.isEmpty && (allTags ? !tagIDs.isSubset(of: itemTags) : tagIDs.isDisjoint(with: itemTags)) { return false }
        if !collectionIDs.isEmpty && !item.memberships.contains(where: { membership in
            membership.collection.map { collectionIDs.contains($0.id) } ?? false
        }) { return false }
        if let logged, logged != !item.entries.isEmpty { return false }
        if wantToTry && !item.wantToTry { return false }
        if favorites && !item.isFavorite { return false }
        if dateEnabled {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: min(startDate, endDate))
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(startDate, endDate)))!
            if item.savedAt < start || item.savedAt >= end { return false }
        }
        return true
    }
}

enum LibraryQuery {
    static func results(_ items: [FoodItem], search: String = "", filter: LibraryFilter = .init(),
                        sort: LibrarySort = .recent, collection: FoodCollection? = nil, unsorted: Bool = false) -> [FoodItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = items.filter { item in
            guard filter.matches(item) else { return false }
            if unsorted && (!item.tags.isEmpty || !item.memberships.isEmpty) { return false }
            if let collection, !item.memberships.contains(where: { $0.collection?.id == collection.id }) { return false }
            if query.isEmpty { return true }
            let haystack = [item.title, item.notes, item.sourceURL, item.sourceName]
                + item.tags.map(\.name) + item.memberships.compactMap { $0.collection?.name }
            return haystack.contains { $0.localizedStandardContains(query) }
        }
        func recent(_ a: FoodItem, _ b: FoodItem) -> Bool {
            a.savedAt == b.savedAt ? a.id.uuidString < b.id.uuidString : a.savedAt > b.savedAt
        }
        return filtered.sorted { a, b in
            switch sort {
            case .recent: return recent(a, b)
            case .oldest: return a.savedAt == b.savedAt ? a.id.uuidString < b.id.uuidString : a.savedAt < b.savedAt
            case .title:
                let comparison = a.title.localizedStandardCompare(b.title)
                return comparison == .orderedSame ? recent(a, b) : comparison == .orderedAscending
            case .logged:
                if a.lastLoggedAt == b.lastLoggedAt { return recent(a, b) }
                return (a.lastLoggedAt ?? .distantPast) > (b.lastLoggedAt ?? .distantPast)
            case .frequent:
                return a.entries.count == b.entries.count ? recent(a, b) : a.entries.count > b.entries.count
            case .manual:
                let ap = a.memberships.first { $0.collection?.id == collection?.id }?.position ?? Int.max
                let bp = b.memberships.first { $0.collection?.id == collection?.id }?.position ?? Int.max
                return ap == bp ? recent(a, b) : ap < bp
            }
        }
    }
}

@MainActor @Observable
final class ArchiveStore {
    /// ModelContext does not keep an in-memory container alive on every supported OS.
    private let container: ModelContainer
    let context: ModelContext
    var errorMessage: String?

    init(context: ModelContext) {
        container = context.container
        self.context = context
        context.autosaveEnabled = false
    }

    @discardableResult
    func commit(_ changes: () throws -> Void) -> Bool {
        do {
            try changes()
            try context.save()
            return true
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            return false
        }
    }

    func tag(named name: String) throws -> Tag {
        let normalized = Tag.normalize(name)
        guard !normalized.isEmpty else { throw ArchiveError.emptyTitle }
        let all = try context.fetch(FetchDescriptor<Tag>())
        if let existing = all.first(where: { $0.normalizedName == normalized }) { return existing }
        let tag = Tag(name: name)
        context.insert(tag)
        return tag
    }

    func rename(_ tag: Tag, to name: String) throws {
        let normalized = Tag.normalize(name)
        guard !normalized.isEmpty else { throw ArchiveError.emptyTitle }
        let all = try context.fetch(FetchDescriptor<Tag>())
        guard !all.contains(where: { $0.id != tag.id && $0.normalizedName == normalized }) else {
            throw ArchiveError.duplicateTag
        }
        tag.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tag.normalizedName = normalized
    }

    func add(_ items: [FoodItem], to collection: FoodCollection) {
        var position = (collection.memberships.map(\.position).max() ?? -1) + 1
        for item in items where !item.memberships.contains(where: { $0.collection?.id == collection.id }) {
            let membership = CollectionMembership(item: item, collection: collection, position: position)
            context.insert(membership)
            position += 1
        }
    }

    func reorder(_ collection: FoodCollection, item: FoodItem, offset: Int) {
        var ordered = collection.memberships.sorted { $0.position < $1.position }
        guard let index = ordered.firstIndex(where: { $0.item?.id == item.id }) else { return }
        let target = max(0, min(ordered.count - 1, index + offset))
        ordered.swapAt(index, target)
        for (position, membership) in ordered.enumerated() { membership.position = position }
    }

    /// History-preserving deletion keeps a hidden snapshot entity and its originals.
    /// Destructive deletion explicitly removes all linked entries, including multi-item meals.
    func delete(_ items: [FoodItem], preserveHistory: Bool) {
        var paths: [String] = []
        let succeeded = commit {
            var deletedEntries = Set<UUID>()
            for item in items {
                if preserveHistory && !item.entries.isEmpty {
                    item.isHistoricalOnly = true
                    item.isArchived = true
                    for membership in item.memberships { context.delete(membership) }
                } else {
                    for entry in item.entries where !deletedEntries.contains(entry.id) {
                        deletedEntries.insert(entry.id)
                        paths += entry.attachments.flatMap { [$0.originalPath, $0.thumbnailPath] }
                        context.delete(entry)
                    }
                    paths += item.assets.flatMap { [$0.originalPath, $0.thumbnailPath] }
                    context.delete(item)
                }
            }
        }
        if succeeded { removeFiles(paths) }
    }

    func deleteEntry(_ entry: JournalEntry) {
        let paths = entry.attachments.flatMap { [$0.originalPath, $0.thumbnailPath] }
        if commit({ context.delete(entry) }) { removeFiles(paths) }
    }

    func removeFiles(_ paths: [String]) {
        Task {
            do { try await MediaStorage.shared.remove(paths: paths) }
            catch { errorMessage = "The record was updated, but unused media could not be cleaned up: \(error.localizedDescription)" }
        }
    }

    func importItems(payloads: [MediaPayload], grouped: Bool, title: String, isolated: Bool) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ArchiveError.emptyTitle }
        let groups = grouped ? [payloads] : payloads.map { [$0] }
        for (index, group) in groups.enumerated() where !group.isEmpty {
            let item = FoodItem(title: groups.count > 1 ? "\(title) \(index + 1)" : title)
            context.insert(item)
            for (position, payload) in group.enumerated() {
                let asset = MediaAsset(payload: payload, position: position)
                asset.isIsolated = isolated
                item.assets.append(asset)
            }
        }
    }
}