import XCTest
import SwiftData
import UIKit
@testable import FoodArchive

@MainActor
final class ArchivePersistenceTests: XCTestCase {
    private func makeStore() throws -> ArchiveStore {
        let container = try ArchiveSchema.container(inMemory: true)
        return ArchiveStore(context: container.mainContext)
    }

    private func payload(_ kind: MediaKind = .image) -> MediaPayload {
        MediaPayload(id: UUID(), originalPath: UUID().uuidString + ".jpg",
                     thumbnailPath: UUID().uuidString + ".jpg", kind: kind,
                     width: 1200, height: 1600, duration: kind == .video ? 12 : 0)
    }

    func testRepeatedExperiencesAndEditingSurviveDiskReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.sqlite")
        let foodID = UUID()
        let firstID = UUID()
        try autoreleasepool {
            let container = try ModelContainer(for: ArchiveSchema.schema, configurations:
                ModelConfiguration(schema: ArchiveSchema.schema, url: url))
            let context = container.mainContext
            let food = FoodItem(title: "Miso Ramen", id: foodID)
            food.wantToTry = true
            context.insert(food)
            let first = JournalEntry(occurredAt: Date(timeIntervalSince1970: 1000), kind: .ate)
            first.id = firstID
            first.reflection = "Firmer noodles next time."
            let second = JournalEntry(occurredAt: Date(timeIntervalSince1970: 2000), kind: .cooked)
            context.insert(first); context.insert(second)
            first.items = [food]; second.items = [food]
            try context.save()
            first.reflection = "Edited, with original capitalization."
            try context.save()
        }
        let reopened = try ModelContainer(for: ArchiveSchema.schema, configurations:
            ModelConfiguration(schema: ArchiveSchema.schema, url: url))
        let food = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<FoodItem>()).first)
        let entries = try reopened.mainContext.fetch(FetchDescriptor<JournalEntry>())
        XCTAssertEqual(food.id, foodID)
        XCTAssertEqual(food.title, "Miso Ramen")
        XCTAssertEqual(food.entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
        XCTAssertEqual(entries.first { $0.id == firstID }?.reflection, "Edited, with original capitalization.")
        XCTAssertEqual(food.lastLoggedAt, Date(timeIntervalSince1970: 2000))
        XCTAssertTrue(food.wantToTry, "Logging must not silently clear intent.")
        XCTAssertTrue(food.hasTried)
    }

    func testCollectionDeletionPreservesFoodAndOtherMemberships() throws {
        let store = try makeStore()
        let food = FoodItem(title: "Toast")
        let a = FoodCollection(name: "Breakfast")
        let b = FoodCollection(name: "Weekend")
        XCTAssertTrue(store.commit {
            store.context.insert(food); store.context.insert(a); store.context.insert(b)
            store.add([food], to: a); store.add([food], to: b); store.add([food], to: b)
        })
        XCTAssertEqual(food.memberships.count, 2, "Adding twice must not duplicate membership.")
        XCTAssertTrue(store.commit { store.context.delete(a) })
        let reloaded = try XCTUnwrap(store.context.fetch(FetchDescriptor<FoodItem>()).first)
        XCTAssertEqual(reloaded.memberships.count, 1)
        XCTAssertEqual(reloaded.memberships.first?.collection?.name, "Weekend")
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<FoodItem>()), 1)
    }

    func testTagNormalizationRenameAndDeletionOnlyRemoveAssociations() throws {
        let store = try makeStore()
        let food = FoodItem(title: "Pasta")
        var original: Tag!
        XCTAssertTrue(store.commit {
            store.context.insert(food)
            original = try store.tag(named: "  Japanese  ")
            let duplicate = try store.tag(named: "JAPANESE")
            XCTAssertEqual(original.id, duplicate.id)
            food.tags = [original]
        })
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<Tag>()), 1)
        XCTAssertTrue(store.commit { try store.rename(original, to: "Noodles") })
        XCTAssertEqual(original.normalizedName, "noodles")
        XCTAssertTrue(store.commit { store.context.delete(original) })
        XCTAssertEqual(food.tags.count, 0)
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<FoodItem>()), 1)
    }

    func testDuplicateRenameIsRejectedWithoutChangingData() throws {
        let store = try makeStore()
        let a = Tag(name: "Breakfast"), b = Tag(name: "Dinner")
        XCTAssertTrue(store.commit { store.context.insert(a); store.context.insert(b) })
        XCTAssertFalse(store.commit { try store.rename(b, to: "BREAKFAST") })
        XCTAssertEqual(b.name, "Dinner")
        XCTAssertNotNil(store.errorMessage)
    }

    func testCombinedFiltersUseOrWithinAndAcrossCategories() throws {
        let store = try makeStore()
        let a = FoodItem(title: "Ramen"), b = FoodItem(title: "Toast"), c = FoodItem(title: "Soup")
        let japanese = Tag(name: "Japanese"), quick = Tag(name: "Quick")
        let collection = FoodCollection(name: "Want to cook")
        XCTAssertTrue(store.commit {
            [a, b, c].forEach { store.context.insert($0) }
            store.context.insert(japanese); store.context.insert(quick); store.context.insert(collection)
            a.tags = [japanese, quick]; b.tags = [quick]; c.tags = [japanese]
            a.assets = [MediaAsset(payload: payload())]
            b.assets = [MediaAsset(payload: payload(.video))]
            c.assets = [MediaAsset(payload: payload())]
            a.isFavorite = true; b.isFavorite = true
            store.add([a, b], to: collection)
        })
        var filter = LibraryFilter()
        filter.tagIDs = [japanese.id, quick.id]
        filter.collectionIDs = [collection.id]
        filter.favorites = true
        XCTAssertEqual(Set(LibraryQuery.results([a, b, c], filter: filter).map(\.id)), Set([a.id, b.id]))
        filter.allTags = true
        XCTAssertEqual(LibraryQuery.results([a, b, c], filter: filter).map(\.id), [a.id])
        filter.allTags = false
        filter.media = [.video]
        XCTAssertEqual(LibraryQuery.results([a, b, c], filter: filter).map(\.id), [b.id])
        filter.media = [.image, .video]
        XCTAssertEqual(LibraryQuery.results([a, b, c], filter: filter).count, 2)
    }

    func testRecentlyLoggedPlacesNeverLoggedLastDeterministically() throws {
        let store = try makeStore()
        let a = FoodItem(title: "Logged", savedAt: Date(timeIntervalSince1970: 10))
        let b = FoodItem(title: "New", savedAt: Date(timeIntervalSince1970: 30))
        let c = FoodItem(title: "Old", savedAt: Date(timeIntervalSince1970: 20))
        XCTAssertTrue(store.commit {
            [a, b, c].forEach { store.context.insert($0) }
            let entry = JournalEntry(occurredAt: Date(timeIntervalSince1970: 100))
            store.context.insert(entry); entry.items = [a]
        })
        XCTAssertEqual(LibraryQuery.results([c, b, a], sort: .logged).map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(a.savedAt, Date(timeIntervalSince1970: 10))
    }

    func testSearchIncludesCollectionSourceNotesAndTags() throws {
        let store = try makeStore()
        let food = FoodItem(title: "Lunch")
        let collection = FoodCollection(name: "Tokyo")
        XCTAssertTrue(store.commit {
            store.context.insert(food); store.context.insert(collection)
            food.notes = "Firm noodles"; food.sourceName = "Small restaurant"
            food.tags = [try store.tag(named: "Japanese")]
            store.add([food], to: collection)
        })
        for query in ["tokyo", "NOODLES", "restaurant", "japanese", "Lunch"] {
            XCTAssertEqual(LibraryQuery.results([food], search: query).count, 1)
        }
        XCTAssertTrue(LibraryQuery.results([food], search: "missing").isEmpty)
    }

    func testImportGroupingDoesNotCreateEatingHistory() throws {
        let store = try makeStore()
        XCTAssertTrue(store.commit {
            try store.importItems(payloads: [payload(), payload(.video)], grouped: false, title: "Food", isolated: false)
        })
        var foods = try store.context.fetch(FetchDescriptor<FoodItem>())
        XCTAssertEqual(foods.count, 2)
        XCTAssertTrue(foods.allSatisfy { $0.assets.count == 1 && $0.entries.isEmpty && !$0.hasTried })
        XCTAssertTrue(store.commit {
            try store.importItems(payloads: [payload(), payload()], grouped: true, title: "One meal", isolated: true)
        })
        foods = try store.context.fetch(FetchDescriptor<FoodItem>())
        XCTAssertEqual(foods.count, 3)
        XCTAssertEqual(foods.first { $0.title == "One meal" }?.assets.count, 2)
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<JournalEntry>()), 0)
    }

    func testHistoryPreservingDeleteHidesFoodWithoutBreakingJournal() throws {
        let store = try makeStore()
        let food = FoodItem(title: "Ramen")
        let entry = JournalEntry()
        XCTAssertTrue(store.commit {
            store.context.insert(food); store.context.insert(entry)
            food.assets = [MediaAsset(payload: payload())]
            entry.items = [food]
        })
        store.delete([food], preserveHistory: true)
        XCTAssertTrue(LibraryQuery.results([food]).isEmpty)
        XCTAssertEqual(entry.items.first?.title, "Ramen")
        XCTAssertEqual(entry.items.first?.assets.count, 1)
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<JournalEntry>()), 1)
    }

    func testDestructiveDeleteRemovesLinkedMealButNotOtherFood() throws {
        let store = try makeStore()
        let a = FoodItem(title: "A"), b = FoodItem(title: "B")
        let entry = JournalEntry()
        XCTAssertTrue(store.commit {
            store.context.insert(a); store.context.insert(b); store.context.insert(entry)
            entry.items = [a, b]
        })
        store.delete([a], preserveHistory: false)
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<JournalEntry>()), 0)
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<FoodItem>()).map(\.title), ["B"])
    }

    func testUnsortedAndManualOrdering() throws {
        let store = try makeStore()
        let a = FoodItem(title: "A"), b = FoodItem(title: "B"), c = FoodItem(title: "C")
        let collection = FoodCollection(name: "Order")
        XCTAssertTrue(store.commit {
            [a, b, c].forEach { store.context.insert($0) }
            store.context.insert(collection)
            store.add([a, b], to: collection)
        })
        XCTAssertEqual(LibraryQuery.results([a, b, c], unsorted: true).map(\.id), [c.id])
        XCTAssertTrue(store.commit { store.reorder(collection, item: b, offset: -1) })
        XCTAssertEqual(LibraryQuery.results([a, b], sort: .manual, collection: collection).map(\.id), [b.id, a.id])
    }

    func testDraftRoundTripPreservesTextDateAndLinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let drafts = DraftStore(directory: directory)
        var draft = JournalDraft()
        draft.reflection = "Mixed CASE remains."
        draft.itemIDs = [UUID(), UUID()]
        draft.kind = .cooked
        draft.rating = nil
        try drafts.save(draft)
        let reopened = DraftStore(directory: directory)
        try reopened.load()
        XCTAssertEqual(reopened.drafts.first, draft)
        try reopened.remove(draft.id)
        try drafts.load()
        XCTAssertTrue(drafts.drafts.isEmpty)
    }

    func testImageImportPreservesOriginalAndCreatesBoundedThumbnail() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1400, height: 1000)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1400, height: 1000))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try await MediaStorage.shared.ingest(url)
        XCTAssertEqual(try Data(contentsOf: MediaStorage.url(for: imported.originalPath)), data)
        let thumbnail = try XCTUnwrap(UIImage(contentsOfFile: MediaStorage.url(for: imported.thumbnailPath).path))
        XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height), 900)
        XCTAssertEqual(imported.kind, .image)
        try await MediaStorage.shared.remove(paths: [imported.originalPath, imported.thumbnailPath])
    }

    func testSourceURLsRejectUnsafeSchemes() throws {
        XCTAssertThrowsError(try SourceLink.validated("javascript:alert(1)"))
        XCTAssertThrowsError(try SourceLink.validated("file:///private/data"))
        XCTAssertThrowsError(try SourceLink.validated("not a url"))
        XCTAssertEqual(try SourceLink.validated(" https://example.org/food ").host, "example.org")
    }

    func testExportContainsRelationshipsAndProducesZip() async throws {
        let store = try makeStore()
        let food = FoodItem(title: "Exported")
        XCTAssertTrue(store.commit { store.context.insert(food) })
        let snapshot = try ExportSnapshot.make(context: store.context, drafts: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual((json["items"] as? [[String: Any]])?.first?["title"] as? String, "Exported")
        let zip = try await ArchiveExporter.shared.export(metadata: snapshot.data, paths: [])
        defer { try? FileManager.default.removeItem(at: zip) }
        XCTAssertEqual(Array(try Data(contentsOf: zip).prefix(2)), [0x50, 0x4b])
    }
}