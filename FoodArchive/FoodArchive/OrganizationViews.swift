import SwiftUI
import SwiftData

struct FilterEditor: View {
    @Binding var filter: LibraryFilter
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(sort: \FoodCollection.name) private var collections: [FoodCollection]
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("OR within a section. AND between sections. Tags can match ANY or ALL.")
                        .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                    TextAction(title: "CLEAR ALL") { filter = .init() }
                }
                Section("MEDIA TYPE") {
                    ForEach(MediaKind.allCases) { kind in
                        CheckRow(title: kind.rawValue.uppercased(), selected: filter.media.contains(kind)) { filter.media.toggle(kind) }
                    }
                }
                Section("TAGS") {
                    Picker("Match", selection: $filter.allTags) {
                        Text("ANY").tag(false); Text("ALL").tag(true)
                    }
                    ForEach(tags) { tag in
                        CheckRow(title: tag.name.uppercased(), selected: filter.tagIDs.contains(tag.id)) { filter.tagIDs.toggle(tag.id) }
                    }
                }
                Section("COLLECTIONS") {
                    ForEach(collections) { collection in
                        CheckRow(title: collection.name.uppercased(), selected: filter.collectionIDs.contains(collection.id)) {
                            filter.collectionIDs.toggle(collection.id)
                        }
                    }
                }
                Section("HISTORY & INTENT") {
                    Picker("Logged", selection: $filter.logged) {
                        Text("Any").tag(nil as Bool?)
                        Text("Logged").tag(true as Bool?)
                        Text("Not logged").tag(false as Bool?)
                    }
                    Toggle("Want to try", isOn: $filter.wantToTry)
                    Toggle("Favorites", isOn: $filter.favorites)
                    Toggle("Show archived instead of active", isOn: $filter.archived)
                }
                Section("SAVED DATE") {
                    Toggle("Limit date range", isOn: $filter.dateEnabled)
                    if filter.dateEnabled {
                        DatePicker("From", selection: $filter.startDate, displayedComponents: .date)
                        DatePicker("Through", selection: $filter.endDate, displayedComponents: .date)
                    }
                }
            }
            .font(ArchiveStyle.label).listStyle(.plain)
            .navigationTitle("FILTER \(filter.count)")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { TextAction(title: "DONE") { dismiss() } } }
            .archiveScreen()
        }
    }
}

struct TagEditor: View {
    let items: [FoodItem]
    @Environment(ArchiveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.name) private var tags: [Tag]
    @State private var name = ""

    private var matches: [Tag] { tags.filter { name.isEmpty || $0.name.localizedStandardContains(name) } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Tags apply to \(items.count) selected item(s). A check means every selected item has the tag.")
                        .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                    OutlineField(label: "TAG NAME", text: $name).autocorrectionDisabled()
                    if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        TextAction(title: "ADD TAG") {
                            if store.commit({
                                let tag = try store.tag(named: name)
                                for item in items where !item.tags.contains(where: { $0.id == tag.id }) { item.tags.append(tag) }
                            }) { name = "" }
                        }.accessibilityIdentifier("addTag")
                    }
                    ForEach(matches) { tag in
                        let selected = items.allSatisfy { $0.tags.contains(where: { $0.id == tag.id }) }
                        CheckRow(title: tag.name.uppercased(), selected: selected) {
                            store.commit {
                                for item in items {
                                    if selected { item.tags.removeAll { $0.id == tag.id } }
                                    else if !item.tags.contains(where: { $0.id == tag.id }) { item.tags.append(tag) }
                                }
                            }
                        }
                    }
                    Text("Removing a tag here does not delete the global tag.")
                        .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                }.padding(20)
            }
            .navigationTitle("TAG")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { TextAction(title: "DONE") { dismiss() } } }
            .archiveScreen().archiveErrors()
        }
    }
}

struct CollectionPicker: View {
    let items: [FoodItem]
    @Environment(ArchiveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FoodCollection.name) private var collections: [FoodCollection]
    @State private var name = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("One food can live in several collections. Its media stays in one place.")
                        .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                    OutlineField(label: "COLLECTION NAME", text: $name)
                    TextAction(title: "CREATE COLLECTION") {
                        if store.commit({
                            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { throw ArchiveError.emptyTitle }
                            let collection = FoodCollection(name: trimmed)
                            store.context.insert(collection)
                            store.add(items, to: collection)
                        }) { name = "" }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("createCollection")
                    ForEach(items.isEmpty ? [] : collections) { collection in
                        let selected = items.allSatisfy { item in item.memberships.contains { $0.collection?.id == collection.id } }
                        CheckRow(title: collection.name.uppercased(), selected: selected) {
                            store.commit {
                                if selected {
                                    for item in items {
                                        for member in item.memberships where member.collection?.id == collection.id {
                                            store.context.delete(member)
                                        }
                                    }
                                } else { store.add(items, to: collection) }
                            }
                        }
                    }
                    Text(items.isEmpty
                         ? "Add food from the library using COLLECT."
                         : "Unchecking removes membership only, not the food or its history.")
                        .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                }.padding(20)
            }
            .navigationTitle(items.isEmpty ? "NEW COLLECTION" : "COLLECT")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { TextAction(title: "DONE") { dismiss() } } }
            .archiveScreen().archiveErrors()
        }
    }
}

struct CollectionsView: View {
    @Environment(ArchiveStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @Query(sort: \FoodCollection.name) private var collections: [FoodCollection]
    @Query private var items: [FoodItem]
    @State private var showCreate = false
    @State private var renaming: FoodCollection?
    @State private var name = ""
    @State private var deleting: FoodCollection?
    private var unsortedCount: Int { items.filter { !$0.isHistoricalOnly && !$0.isArchived && $0.tags.isEmpty && $0.memberships.isEmpty }.count }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                HStack {
                    NavigationLink(value: ArchiveRoute.unsorted) {
                        Text("UNSORTED \(unsortedCount)").font(ArchiveStyle.label).frame(minHeight: 44)
                    }
                    Spacer()
                    NavigationLink(value: ArchiveRoute.tags) { Text("TAGS").font(ArchiveStyle.label).frame(minHeight: 44) }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 300 : 145), spacing: 20)], spacing: 36) {
                    ForEach(collections) { collection in
                        VStack(spacing: 4) {
                            NavigationLink(value: ArchiveRoute.collection(collection)) {
                                VStack(spacing: 14) {
                                    if let cover = collection.orderedItems.first(where: { $0.id == collection.coverItemID })?.cover
                                        ?? collection.orderedItems.first?.cover {
                                        MediaStage(asset: cover).aspectRatio(1, contentMode: .fit)
                                    } else {
                                        Color.white.aspectRatio(1, contentMode: .fit)
                                            .overlay(Text("EMPTY").font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary))
                                    }
                                    CatalogCaption(title: collection.name, subtitle: "\(collection.orderedItems.count) ITEMS")
                                }
                            }.buttonStyle(.plain)
                            Menu {
                                Button("Rename") { name = collection.name; renaming = collection }
                                Button("Delete collection", role: .destructive) { deleting = collection }
                            } label: {
                                Image(systemName: "ellipsis").frame(width: 44, height: 44)
                            }.accessibilityLabel("Options for \(collection.name)")
                        }
                    }
                }
                if collections.isEmpty {
                    EmptyStateView(title: "MAKE ROOM FOR A COLLECTION",
                                   message: "A city. A season. Something to cook next.",
                                   actionTitle: "CREATE COLLECTION") { showCreate = true }
                }
                NavigationLink(value: ArchiveRoute.archived) {
                    Text("ARCHIVED ITEMS").font(ArchiveStyle.label).frame(minHeight: 44)
                }
                NavigationLink(value: ArchiveRoute.settings) {
                    Text("SETTINGS / PRIVACY / EXPORT").font(ArchiveStyle.label)
                        .foregroundStyle(ArchiveStyle.secondary).frame(minHeight: 44)
                }
            }.padding(20)
        }
        .navigationTitle("COLLECTIONS").toolbar(.visible, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            IconAction(symbol: "plus", label: "New collection") { showCreate = true }
        } }
        .sheet(isPresented: $showCreate) { CollectionPicker(items: []) }
        .alert("RENAME COLLECTION", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Save") {
                if let renaming {
                    store.commit {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { throw ArchiveError.emptyTitle }
                        renaming.name = trimmed
                    }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("DELETE COLLECTION?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete collection", role: .destructive) {
                if let deleting { store.commit { store.context.delete(deleting) } }
                deleting = nil
            }
        } message: { Text("Food items, original media, and journal entries will not be deleted.") }
        .archiveScreen().archiveErrors()
    }
}

struct TagManager: View {
    @Environment(ArchiveStore.self) private var store
    @Query(sort: \Tag.name) private var tags: [Tag]
    @State private var name = ""
    @State private var renaming: Tag?
    @State private var deleting: Tag?
    var body: some View {
        List {
            Section("CREATE TAG") {
                TextField("Tag name", text: $name).accessibilityIdentifier("newTagName")
                TextAction(title: "CREATE") {
                    if store.commit({ _ = try store.tag(named: name) }) { name = "" }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(tags) { tag in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tag.name.uppercased())
                        Text("\(tag.items.count) ITEMS").foregroundStyle(ArchiveStyle.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Rename") { name = tag.name; renaming = tag }
                        Button("Delete tag", role: .destructive) { deleting = tag }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .accessibilityLabel("Options for \(tag.name)")
                }
            }
        }.listStyle(.plain).font(ArchiveStyle.label)
            .navigationTitle("TAGS")
            .alert("RENAME TAG", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $name)
                Button("Save") {
                    if let renaming, store.commit({ try store.rename(renaming, to: name) }) { name = "" }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil; name = "" }
            }
            .confirmationDialog("DELETE TAG?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete tag", role: .destructive) {
                    if let deleting { store.commit { store.context.delete(deleting) } }
                    deleting = nil
                }
            } message: { Text("This removes tag associations only. Your food and journal remain.") }
            .archiveScreen().archiveErrors()
    }
}

struct CollectionOrderEditor: View {
    let collection: FoodCollection
    @Environment(ArchiveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(collection.orderedItems) { item in
                    HStack {
                        Text(item.title).font(ArchiveStyle.label)
                        Spacer()
                        Menu {
                            Button("Move earlier") { store.commit { store.reorder(collection, item: item, offset: -1) } }
                            Button("Move later") { store.commit { store.reorder(collection, item: item, offset: 1) } }
                            Button("Use as collection cover") { store.commit { collection.coverItemID = item.id } }
                            Button("Remove from collection") {
                                store.commit {
                                    for member in item.memberships where member.collection?.id == collection.id { store.context.delete(member) }
                                }
                            }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .accessibilityLabel("Move or remove \(item.title)")
                    }
                }
                .onMove { source, destination in
                    var members = collection.memberships.sorted { $0.position < $1.position }
                    members.move(fromOffsets: source, toOffset: destination)
                    store.commit { for (index, member) in members.enumerated() { member.position = index } }
                }
            }.listStyle(.plain)
                .navigationTitle("MANUAL ORDER")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                    ToolbarItem(placement: .topBarTrailing) { TextAction(title: "DONE") { dismiss() } }
                }
                .archiveScreen().archiveErrors()
        }
    }
}