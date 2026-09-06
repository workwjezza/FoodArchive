import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(ArchiveStore.self) private var store
    @Environment(DraftStore.self) private var drafts
    @Query private var items: [FoodItem]
    @State private var busy = false
    @State private var exportURL: URL?
    @State private var confirmSamples = false
    @State private var status = ""

    var body: some View {
        List {
            Section("FOOD ARCHIVE") {
                Text("A quiet record of food worth remembering.").font(ArchiveStyle.body)
                Text("LOCAL FIRST · NO ACCOUNT").font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
            }
            Section("PRIVACY") {
                Text("Imported media and journal writing stay in this app’s local storage. No analytics, advertising SDK, AI upload, or account is included.")
                Text("iOS device backups may include this data according to your system settings. This is not an encrypted vault or a cloud-sync service.")
                Text("Photos uses Apple’s private picker. Camera access is requested only on capture. Loading a link preview contacts that website; opening a source or sharing an export leaves the app.")
                if let url = URL(string: UIApplication.openSettingsURLString) { Link("OPEN IOS SETTINGS", destination: url).frame(minHeight: 44) }
            }
            Section("EXPORT") {
                Text("Export a ZIP containing structured JSON, original files, thumbnails, and journal drafts. Keep it somewhere private. Restore/import of an archive ZIP is not yet implemented.")
                TextAction(title: busy ? "PREPARING…" : "PREPARE EXPORT") { export() }.disabled(busy)
                if let exportURL {
                    ShareLink(item: exportURL) { Text("SHARE EXPORT").frame(minHeight: 44) }
                }
            }
            Section("SAMPLE ARCHIVE") {
                Text("Optional, bundled food photographs and an original kitchen-note image. These are sample items, not claims about what you ate. Loading them creates no journal experiences.")
                TextAction(title: "LOAD SAMPLE ARCHIVE") { confirmSamples = true }.disabled(busy)
                Text("Photos: Unsplash. Sources and licensing are included with this project and on each sample item.")
                    .foregroundStyle(ArchiveStyle.secondary)
            }
            Section("NOT INCLUDED YET") {
                Text("Cloud sync, automatic tagging, background removal, a Share Extension, and authenticated social-platform downloads are deliberately deferred.")
            }
            if !status.isEmpty { Section { Text(status) } }
        }
        .listStyle(.plain).font(ArchiveStyle.label)
        .navigationTitle("SETTINGS").toolbar(.visible, for: .navigationBar)
        .confirmationDialog("ADD SAMPLE FOOD?", isPresented: $confirmSamples, titleVisibility: .visible) {
            Button("Load samples") {
                busy = true
                Task {
                    defer { busy = false }
                    do { try await SampleData.load(into: store); status = "SAMPLE ITEMS ADDED" }
                    catch { store.errorMessage = error.localizedDescription }
                }
            }
        } message: { Text("This adds sample images to your library without changing your existing records.") }
        .archiveScreen().archiveErrors()
    }

    private func export() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let snapshot = try ExportSnapshot.make(context: store.context, drafts: drafts.drafts)
                exportURL = try await ArchiveExporter.shared.export(metadata: snapshot.data, paths: snapshot.paths)
                status = "EXPORT READY"
            } catch { store.errorMessage = "Export failed: \(error.localizedDescription)" }
        }
    }
}

enum ExportSnapshot {
    @MainActor static func make(context: ModelContext, drafts: [JournalDraft]) throws -> (data: Data, paths: [String]) {
        let items = try context.fetch(FetchDescriptor<FoodItem>())
        let tags = try context.fetch(FetchDescriptor<Tag>())
        let collections = try context.fetch(FetchDescriptor<FoodCollection>())
        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        let assets = try context.fetch(FetchDescriptor<MediaAsset>())
        func optional(_ value: Any?) -> Any { value ?? NSNull() }
        let itemRows: [[String: Any]] = items.map {
            ["id": $0.id.uuidString, "title": $0.title, "savedAt": $0.savedAt.ISO8601Format(),
             "sourceURL": $0.sourceURL, "sourceName": $0.sourceName, "notes": $0.notes,
             "favorite": $0.isFavorite, "wantToTry": $0.wantToTry, "archived": $0.isArchived,
             "historicalOnly": $0.isHistoricalOnly, "coverID": optional($0.coverID?.uuidString),
             "tags": $0.tags.map { $0.id.uuidString }, "assets": $0.orderedAssets.map { $0.id.uuidString }]
        }
        let assetRows: [[String: Any]] = assets.map {
            ["id": $0.id.uuidString, "originalPath": $0.originalPath, "thumbnailPath": $0.thumbnailPath,
             "type": $0.kindRaw, "width": $0.width, "height": $0.height, "duration": $0.duration,
             "position": $0.position, "isolated": $0.isIsolated, "cropX": $0.cropX, "cropY": $0.cropY]
        }
        let collectionRows: [[String: Any]] = collections.map {
            ["id": $0.id.uuidString, "name": $0.name, "coverItemID": optional($0.coverItemID?.uuidString),
             "memberships": $0.memberships.compactMap { member -> [String: Any]? in
                 guard let item = member.item else { return nil }
                 return ["id": member.id.uuidString, "itemID": item.id.uuidString, "position": member.position]
             }]
        }
        let entryRows: [[String: Any]] = entries.map {
            ["id": $0.id.uuidString, "occurredAt": $0.occurredAt.ISO8601Format(), "type": $0.kindRaw,
             "occasion": $0.occasion, "place": $0.place, "reflection": $0.reflection, "rating": optional($0.rating),
             "itemIDs": $0.items.map { $0.id.uuidString }, "attachments": $0.attachments.map { $0.id.uuidString }]
        }
        let draftEncoder = JSONEncoder()
        draftEncoder.dateEncodingStrategy = .iso8601
        let draftJSON = try JSONSerialization.jsonObject(with: draftEncoder.encode(drafts))
        let object: [String: Any] = [
            "schemaVersion": 1, "exportedAt": Date.now.ISO8601Format(), "mediaDirectory": "Media",
            "items": itemRows, "assets": assetRows, "collections": collectionRows, "entries": entryRows,
            "tags": tags.map { ["id": $0.id.uuidString, "name": $0.name, "normalizedName": $0.normalizedName] },
            "drafts": draftJSON
        ]
        let paths = assets.flatMap { [$0.originalPath, $0.thumbnailPath] }
            + drafts.flatMap(\.attachments).flatMap { [$0.originalPath, $0.thumbnailPath] }
        return (try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), Array(Set(paths)))
    }
}

actor ArchiveExporter {
    static let shared = ArchiveExporter()
    func export(metadata: Data, paths: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID())", isDirectory: true)
        let directory = root.appendingPathComponent("FoodArchive", isDirectory: true)
        let media = directory.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try metadata.write(to: directory.appendingPathComponent("archive.json"), options: .atomic)
        for path in paths {
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: MediaStorage.url(for: path), to: media.appendingPathComponent(path))
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("FoodArchive-\(UUID()).zip")
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &coordinatorError) { zipped in
            do { try FileManager.default.copyItem(at: zipped, to: output) }
            catch { copyError = error }
        }
        if let error = coordinatorError ?? copyError as NSError? { throw error }
        guard FileManager.default.fileExists(atPath: output.path) else { throw ArchiveError.missingFile }
        return output
    }
}

@MainActor
enum SampleData {
    struct Sample {
        let file: String
        let title: String
        let source: String
        var isolated = false
        var fileExtension = "jpg"
    }
    static let samples = [
        Sample(file: "sample-salad", title: "Green bowl", source: "https://images.unsplash.com/photo-1546069901-ba9599a7e63c", isolated: true),
        Sample(file: "sample-toast", title: "Morning toast", source: "https://images.unsplash.com/photo-1484723091739-30a097e8f929"),
        Sample(file: "sample-croissant", title: "Bakery visit", source: "https://images.unsplash.com/photo-1555507036-ab1f4038808a"),
        Sample(file: "sample-pasta", title: "Sunday pasta", source: "https://images.unsplash.com/photo-1473093295043-cdd812d0e601", isolated: true),
        Sample(file: "sample-ramen", title: "Ramen", source: "https://images.unsplash.com/photo-1569718212165-3a8278d5f624"),
        Sample(file: "sample-pasta-study", title: "Pasta study", source: "https://images.unsplash.com/photo-1473093295043-cdd812d0e601#motion-study", fileExtension: "mp4")
    ]

    static func load(into store: ArchiveStore) async throws {
        let existing = try store.context.fetch(FetchDescriptor<FoodItem>())
        var imports: [(Sample, MediaPayload)] = []
        do {
            for sample in samples where !existing.contains(where: { $0.sourceURL == sample.source }) {
                guard let url = Bundle.main.url(forResource: sample.file, withExtension: sample.fileExtension) else { throw ArchiveError.missingFile }
                imports.append((sample, try await MediaStorage.shared.ingest(url)))
            }
            if !existing.contains(where: { $0.sourceName == "Food Archive · original sample note" }) {
                let note = try noteImage()
                defer { try? FileManager.default.removeItem(at: note) }
                imports.append((Sample(file: "note", title: "Kitchen notes", source: ""),
                                try await MediaStorage.shared.ingest(note)))
            }
            let success = store.commit {
                for (index, pair) in imports.enumerated() {
                    let (sample, payload) = pair
                    let item = FoodItem(title: sample.title, savedAt: .now.addingTimeInterval(Double(-index * 3600)))
                    item.sourceURL = sample.source
                    item.sourceName = sample.file == "note" ? "Food Archive · original sample note" : "Unsplash · sample photograph"
                    item.notes = sample.fileExtension == "mp4"
                        ? "Sample motion study generated from a licensed Unsplash still photograph, not recorded cooking footage. No experience was logged."
                        : "Sample media. No experience was logged. You can rename, organize, or delete this item."
                    let asset = MediaAsset(payload: payload)
                    asset.isIsolated = sample.isolated
                    store.context.insert(item)
                    item.assets.append(asset)
                }
            }
            if !success { throw NSError(domain: "FoodArchive", code: 1, userInfo: [NSLocalizedDescriptionKey: store.errorMessage ?? "Sample save failed."]) }
        } catch {
            store.removeFiles(imports.flatMap { [$0.1.originalPath, $0.1.thumbnailPath] })
            throw error
        }
    }

    private static func noteImage() throws -> URL {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 650, height: 900))
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 650, height: 900))
            let text = "KITCHEN NOTES\n\n06 SEPTEMBER\n\nTomatoes at room temperature.\nToast until the edges catch.\nSalt just before serving.\n\n\nNEXT TIME\n\nMore lemon.\nLess hurry."
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 14
            (text as NSString).draw(in: CGRect(x: 52, y: 72, width: 546, height: 750), withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 24, weight: .regular),
                .foregroundColor: UIColor(white: 0.1, alpha: 1), .paragraphStyle: paragraph
            ])
        }
        guard let data = image.jpegData(compressionQuality: 0.95) else { throw ArchiveError.unreadableImage }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        try data.write(to: url)
        return url
    }
}