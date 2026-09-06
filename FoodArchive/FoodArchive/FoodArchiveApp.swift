import SwiftUI
import SwiftData

@main
struct FoodArchiveApp: App {
    var body: some Scene {
        WindowGroup {
            ArchiveBootstrap()
                .preferredColorScheme(.light)
        }
    }
}

struct ArchiveBootstrap: View {
    @State private var container: ModelContainer?
    @State private var store: ArchiveStore?
    @State private var drafts = DraftStore()
    @State private var failure: String?

    var body: some View {
        Group {
            if let container, let store {
                ArchiveRootView()
                    .modelContainer(container)
                    .environment(store)
                    .environment(drafts)
            } else if let failure {
                EmptyStateView(title: "ARCHIVE COULD NOT OPEN", message: failure,
                               actionTitle: "TRY AGAIN", action: open)
            } else { ProgressView().task { open() } }
        }.tint(ArchiveStyle.ink).background(.white)
    }

    @MainActor private func open() {
        do {
            let container: ModelContainer
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("FoodArchiveUITests.sqlite")
                if ProcessInfo.processInfo.arguments.contains("--reset-ui-tests") {
                    for suffix in ["", "-wal", "-shm"] {
                        let file = URL(fileURLWithPath: url.path + suffix)
                        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                    }
                    if FileManager.default.fileExists(atPath: MediaStorage.root.path) {
                        try FileManager.default.removeItem(at: MediaStorage.root)
                    }
                    UserDefaults.standard.removeObject(forKey: "largeGrid")
                }
                container = try ModelContainer(for: ArchiveSchema.schema, configurations:
                    ModelConfiguration(schema: ArchiveSchema.schema, url: url))
            } else { container = try ArchiveSchema.container() }
            #else
            container = try ArchiveSchema.container()
            #endif
            self.container = container
            let store = ArchiveStore(context: container.mainContext)
            self.store = store
            do { try drafts.load() }
            catch { store.errorMessage = "Drafts could not be loaded. Their files have been preserved: \(error.localizedDescription)" }
            failure = nil
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing")
                && ProcessInfo.processInfo.arguments.contains("--sample-archive") {
                Task {
                    do { try await SampleData.load(into: store) }
                    catch { store.errorMessage = error.localizedDescription }
                }
            }
            #endif
        } catch { failure = error.localizedDescription }
    }
}

enum ArchiveRoute: Hashable {
    case food(FoodItem), entry(JournalEntry), collection(FoodCollection)
    case collections, settings, tags, unsorted, archived, summary
    case records(String, Set<UUID>)
}

struct ArchiveRootView: View {
    @State private var mode = ArchiveMode.library
    @State private var importing = false
    @State private var journal = false
    @State private var path: [ArchiveRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if mode == .library {
                    LibraryView(add: { importing = true })
                } else {
                    JournalView(add: { journal = true })
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                ArchiveHeader(mode: $mode, add: {
                    if mode == .library { importing = true } else { journal = true }
                }, collections: { path.append(.collections) })
            }
            .toolbar(path.isEmpty ? .hidden : .visible, for: .navigationBar)
            .navigationDestination(for: ArchiveRoute.self) { route in
                switch route {
                case .food(let item): FoodDetailView(item: item)
                case .entry(let entry): JournalDetailView(entry: entry)
                case .collection(let collection): LibraryView(collection: collection)
                case .collections: CollectionsView()
                case .settings: SettingsView()
                case .tags: TagManager()
                case .unsorted: LibraryView(unsorted: true)
                case .archived: LibraryView(initiallyArchived: true)
                case .summary: JournalSummaryView()
                case .records(let title, let ids): JournalRecordsView(title: title, ids: ids)
                }
            }
            .sheet(isPresented: $importing) { ImportView() }
            .sheet(isPresented: $journal) { JournalEntryEditor() }
            .archiveScreen()
        }.tint(ArchiveStyle.ink)
    }
}

struct ArchivePreview: View {
    @State private var container: ModelContainer?
    @State private var store: ArchiveStore?
    @State private var drafts = DraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PreviewDrafts"))
    @State private var failure: String?
    var body: some View {
        Group {
            if let container, let store {
                ArchiveRootView().modelContainer(container).environment(store).environment(drafts)
            } else if let failure { Text(failure) }
            else { ProgressView() }
        }
        .preferredColorScheme(.light)
        .task {
            do {
                let container = try ArchiveSchema.container(inMemory: true)
                let store = ArchiveStore(context: container.mainContext)
                try await SampleData.load(into: store)
                self.store = store
                self.container = container
            } catch { failure = error.localizedDescription }
        }
    }
}

#Preview("Food archive • iPhone") { ArchivePreview() }
#Preview("Food archive • large type") {
    ArchivePreview().environment(\.dynamicTypeSize, .accessibility2)
}