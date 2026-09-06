import SwiftUI
import SwiftData

private struct OrganizationRequest: Identifiable {
    enum Kind { case tags, collections }
    let id = UUID()
    let kind: Kind
    let items: [FoodItem]
}

struct LibraryView: View {
    @Environment(ArchiveStore.self) private var store
    @Query private var allItems: [FoodItem]
    var collection: FoodCollection? = nil
    var unsorted = false
    var initiallyArchived = false
    var add: (() -> Void)? = nil
    @State private var search = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @State private var sort: LibrarySort = .recent
    @State private var filter = LibraryFilter()
    @AppStorage("largeGrid") private var large = false
    @State private var anchor: UUID?
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var showFilter = false
    @State private var organization: OrganizationRequest?
    @State private var showReorder = false
    @State private var pendingDeletion: [FoodItem] = []
    @State private var confirmDelete = false

    private var results: [FoodItem] {
        LibraryQuery.results(allItems, search: search, filter: filter, sort: sort, collection: collection, unsorted: unsorted)
    }
    private var selectedItems: [FoodItem] { allItems.filter { selection.contains($0.id) } }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                UtilityActionRow(
                    searching: $searching, selecting: $selecting, sort: $sort, large: $large,
                    filterCount: filter.count, allowsManual: collection != nil,
                    filter: { showFilter = true },
                    reorder: { showReorder = true }
                )
                .padding(.horizontal, ArchiveStyle.inset)

                if searching {
                    HStack {
                        TextField("Title, tag, source, notes…", text: $search)
                            .font(ArchiveStyle.body).focused($searchFocused)
                            .submitLabel(.search).accessibilityIdentifier("librarySearch")
                        IconAction(symbol: "xmark", label: "Clear and close search") {
                            search = ""; searching = false
                        }
                    }
                    .padding(.leading, 12)
                    .overlay(Rectangle().stroke(ArchiveStyle.line))
                    .padding(.horizontal, ArchiveStyle.inset)
                    .padding(.bottom, 12)
                }
                if filter.count > 0 || !search.isEmpty {
                    HStack {
                        Text("\(results.count) RESULTS").font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                        Spacer()
                        TextAction(title: "RESET") { filter = .init(); search = "" }
                    }.padding(.horizontal, ArchiveStyle.inset)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        if results.isEmpty {
                            emptyState
                        } else {
                            MediaGrid(items: results, width: geometry.size.width, large: large) { item in
                                tile(item)
                            }
                            .padding(.horizontal, ArchiveStyle.inset)
                            .padding(.top, 20)
                            .padding(.bottom, 44)
                        }
                        if collection == nil && !unsorted {
                            NavigationLink(value: ArchiveRoute.settings) {
                                Text("SETTINGS / PRIVACY / EXPORT")
                                    .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                                    .frame(minHeight: 44)
                            }.padding(.bottom, 24)
                        }
                    }
                    .scrollPosition(id: $anchor, anchor: .top)
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: large) { _, _ in
                        if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting { selectionBar }
        }
        .navigationTitle(collection?.name.uppercased() ?? (unsorted ? "UNSORTED" : (initiallyArchived ? "ARCHIVED" : "")))
        .archiveScreen()
        .onAppear {
            if initiallyArchived { filter.archived = true }
        }
        .onChange(of: searching) { _, value in searchFocused = value }
        .onChange(of: selecting) { _, value in if !value { selection.removeAll() } }
        .onChange(of: results.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .sheet(item: $logItem) { item in JournalEntryEditor(initialItems: [item]) }
        .sheet(isPresented: $showFilter) { FilterEditor(filter: $filter) }
        .sheet(item: $organization) { request in
            switch request.kind {
            case .tags: TagEditor(items: request.items)
            case .collections: CollectionPicker(items: request.items)
            }
        }
        .sheet(isPresented: $showReorder) {
            if let collection { CollectionOrderEditor(collection: collection) }
        }
        .confirmationDialog("DELETE \(pendingDeletion.count) ITEM(S)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete from library, keep journal history", role: .destructive) {
                store.delete(pendingDeletion, preserveHistory: true)
                selection.removeAll()
            }
            if pendingDeletion.contains(where: { !$0.entries.isEmpty }) {
                Button("Delete items AND all linked entries", role: .destructive) {
                    store.delete(pendingDeletion, preserveHistory: false)
                    selection.removeAll()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeping history retains the original media in your journal. Deleting linked entries also deletes complete meal entries that reference other foods.")
        }
        .archiveErrors()
    }

    @ViewBuilder private var emptyState: some View {
        if filter.count > 0 || !search.isEmpty {
            EmptyStateView(title: "NO MATCHING ITEMS", actionTitle: "CLEAR FILTERS") {
                filter = .init(); search = ""
            }
        } else if let add {
            EmptyStateView(title: "YOUR ARCHIVE IS EMPTY",
                           message: "A place for food worth remembering.\nSave first. Make sense of it later.",
                           actionTitle: "ADD FOOD MEDIA", action: add)
        } else {
            EmptyStateView(title: unsorted ? "NOTHING UNSORTED" : "NO ITEMS YET",
                           message: "Use COLLECT on a food item to add it here.")
        }
    }

    @ViewBuilder private func tile(_ item: FoodItem) -> some View {
        Group {
            if selecting {
                Button { selection.toggle(item.id) } label: {
                    MediaTile(item: item, selected: selection.contains(item.id), selecting: true)
                }.buttonStyle(.plain)
            } else {
                NavigationLink(value: ArchiveRoute.food(item)) { MediaTile(item: item) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("foodTile_" + item.title)
            }
        }
        .contextMenu {
            Button("Log experience", systemImage: "square.and.pencil") {
                // Navigation remains discoverable via the tile; this shortcut opens a native editor.
                logItem = item
            }
            Button(item.isFavorite ? "Unfavorite" : "Favorite", systemImage: "star") {
                store.commit { item.isFavorite.toggle() }
            }
            Button("Tag", systemImage: "number") { organization = OrganizationRequest(kind: .tags, items: [item]) }
            Button("Collect", systemImage: "square.stack") { organization = OrganizationRequest(kind: .collections, items: [item]) }
            Button(item.isArchived ? "Restore to library" : "Archive", systemImage: "archivebox") {
                store.commit { item.isArchived.toggle() }
            }
            if let collection {
                Button("Remove from collection", systemImage: "minus") {
                    store.commit {
                        for member in item.memberships where member.collection?.id == collection.id { store.context.delete(member) }
                    }
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                pendingDeletion = [item]; confirmDelete = true
            }
        }
    }

    @State private var logItem: FoodItem?

    private var selectionBar: some View {
        VStack(spacing: 0) {
            Divider()
            Text("\(selection.count) SELECTED").font(ArchiveStyle.label).padding(.top, 8)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { batchButtons }
                VStack(spacing: 0) { batchButtons }
            }
            .disabled(selection.isEmpty)
        }
        .frame(maxWidth: .infinity).background(.white)
    }
    @ViewBuilder private var batchButtons: some View {
        TextAction(title: "TAG") { organization = OrganizationRequest(kind: .tags, items: selectedItems) }
        TextAction(title: "COLLECT") { organization = OrganizationRequest(kind: .collections, items: selectedItems) }
        TextAction(title: filter.archived ? "RESTORE" : "ARCHIVE") {
            let archived = !filter.archived
            if store.commit({ selectedItems.forEach { $0.isArchived = archived } }) { selection.removeAll() }
        }
        TextAction(title: "DELETE") { pendingDeletion = selectedItems; confirmDelete = true }
    }
}

struct UtilityActionRow: View {
    @Binding var searching: Bool
    @Binding var selecting: Bool
    @Binding var sort: LibrarySort
    @Binding var large: Bool
    let filterCount: Int
    let allowsManual: Bool
    let filter: () -> Void
    let reorder: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                TextAction(title: "SEARCH") { searching.toggle() }
                Spacer(minLength: 8)
                controls
            }
            VStack(spacing: 0) {
                HStack {
                    TextAction(title: "SEARCH") { searching.toggle() }
                    Spacer()
                    TextAction(title: selecting ? "DONE" : "SELECT") { selecting.toggle() }
                }
                HStack { sortMenu; Spacer(); filterButton; Spacer(); viewMenu }
            }
        }
    }
    @ViewBuilder private var controls: some View {
        sortMenu
        filterButton
        TextAction(title: selecting ? "DONE" : "SELECT") { selecting.toggle() }
        viewMenu
    }
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(LibrarySort.allCases.filter { allowsManual || $0 != .manual }) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            if allowsManual { Button("Reorder collection", action: reorder) }
        } label: { Text("SORT").font(ArchiveStyle.label).frame(minWidth: 44, minHeight: 44) }
            .accessibilityValue(sort.rawValue)
    }
    private var filterButton: some View {
        TextAction(title: filterCount == 0 ? "FILTER" : "FILTER \(filterCount)", action: filter)
    }
    private var viewMenu: some View {
        Menu {
            Picker("Grid size", selection: $large) {
                Text("STANDARD").tag(false)
                Text("LARGE").tag(true)
            }
        } label: {
            Image(systemName: large ? "rectangle" : "square.grid.2x2")
                .font(.system(size: 14)).frame(width: 44, height: 44)
        }.accessibilityLabel("View options").accessibilityValue(large ? "Large" : "Standard")
    }
}