import SwiftUI

struct FoodDetailView: View {
    let item: FoodItem
    @Environment(ArchiveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var log = false
    @State private var tags = false
    @State private var collect = false
    @State private var edit = false
    @State private var cover = false
    @State private var deletion = false

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 16) {
                    MediaGallery(assets: item.orderedAssets)
                    VStack(spacing: 8) {
                        Text(item.archiveCode).font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                        Text(item.title.uppercased()).font(ArchiveStyle.title).multilineTextAlignment(.center)
                        Text("SAVED " + item.savedAt.formatted(date: .abbreviated, time: .omitted).uppercased())
                            .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                    }
                    TextAction(title: "LOG EXPERIENCE") { log = true }.accessibilityIdentifier("logExperience")
                    HStack(spacing: 36) {
                        TextAction(title: "TAG") { tags = true }
                        TextAction(title: "COLLECT") { collect = true }
                    }
                }

                VStack(alignment: .leading, spacing: 32) {
                    if item.isHistoricalOnly {
                        detailSection("HISTORICAL RECORD", "Removed from your library. Original media is retained for these experiences.")
                    }
                    if !item.sourceURL.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SOURCE").font(ArchiveStyle.label.weight(.medium))
                            if !item.sourceName.isEmpty { Text(item.sourceName).font(ArchiveStyle.label) }
                            if let url = URL(string: item.sourceURL) {
                                Link("OPEN SOURCE", destination: url).font(ArchiveStyle.label).frame(minHeight: 44)
                            }
                        }
                    }
                    if !item.tags.isEmpty { detailSection("TAGS", item.tags.map { $0.name.uppercased() }.sorted().joined(separator: " / ")) }
                    if !item.memberships.isEmpty {
                        detailSection("COLLECTIONS", item.memberships.compactMap { $0.collection?.name.uppercased() }.sorted().joined(separator: " / "))
                    }
                    if !item.notes.isEmpty { detailSection("NOTES", item.notes) }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("HISTORY").font(ArchiveStyle.label.weight(.medium))
                        Text("\(item.entries.count) EXPERIENCES" + (item.hasTried ? " · TRIED" : ""))
                            .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                        if item.wantToTry { Text("WANT TO TRY").font(ArchiveStyle.label) }
                        if item.isFavorite { Text("FAVORITE").font(ArchiveStyle.label) }
                        if item.entries.isEmpty {
                            Text("Saved, not yet logged. An image is not an experience.")
                                .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                        }
                        ForEach(item.entries.sorted { $0.occurredAt > $1.occurredAt }) { entry in
                            NavigationLink(value: ArchiveRoute.entry(entry)) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(entry.kind.rawValue.uppercased() + " · " + entry.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(ArchiveStyle.label)
                                    if !entry.reflection.isEmpty {
                                        Text(entry.reflection).font(.body).lineLimit(3).foregroundStyle(ArchiveStyle.secondary)
                                    }
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.vertical, 8)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxWidth: 640, alignment: .leading)
            }.padding(.horizontal, 20).padding(.bottom, 44)
        }
        .navigationTitle("").toolbar(.visible, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { overflow } }
        .sheet(isPresented: $log) { JournalEntryEditor(initialItems: [item]) }
        .sheet(isPresented: $tags) { TagEditor(items: [item]) }
        .sheet(isPresented: $collect) { CollectionPicker(items: [item]) }
        .sheet(isPresented: $edit) { FoodMetadataEditor(item: item) }
        .sheet(isPresented: $cover) { CoverEditor(item: item) }
        .confirmationDialog("DELETE FOOD ITEM?", isPresented: $deletion, titleVisibility: .visible) {
            Button("Delete from library, keep history", role: .destructive) {
                store.delete([item], preserveHistory: true)
                if store.errorMessage == nil { dismiss() }
            }
            if !item.entries.isEmpty {
                Button("Delete item AND all linked entries", role: .destructive) {
                    store.delete([item], preserveHistory: false)
                    if store.errorMessage == nil { dismiss() }
                }
            }
        } message: {
            Text("Keeping history retains media in your journal. Deleting linked entries removes complete meal records, even those linked to other foods.")
        }
        .archiveScreen().archiveErrors()
    }

    private var overflow: some View {
        Menu("Food options", systemImage: "ellipsis") {
            Button("Edit title, source & notes") { edit = true }
            Button("Edit cover") { cover = true }.disabled(item.assets.isEmpty)
            Button(item.isFavorite ? "Remove favorite" : "Favorite") { store.commit { item.isFavorite.toggle() } }
            Button(item.wantToTry ? "Remove want to try" : "Want to try") { store.commit { item.wantToTry.toggle() } }
            if let url = URL(string: item.sourceURL), !item.sourceURL.isEmpty { Link("Open source", destination: url) }
            if let asset = item.cover {
                ShareLink(item: MediaStorage.url(for: asset.originalPath)) { Label("Share original", systemImage: "square.and.arrow.up") }
            } else if !item.sourceURL.isEmpty, let url = URL(string: item.sourceURL) {
                ShareLink(item: url) { Label("Share source", systemImage: "square.and.arrow.up") }
            }
            Button(item.isArchived ? "Restore to library" : "Archive") {
                store.commit { item.isArchived.toggle(); item.isHistoricalOnly = false }
            }
            Button("Delete", role: .destructive) { deletion = true }
        }.labelStyle(.iconOnly)
    }

    private func detailSection(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(ArchiveStyle.label.weight(.medium))
            Text(value).font(title == "NOTES" ? .body : ArchiveStyle.label)
                .foregroundStyle(ArchiveStyle.secondary).textSelection(.enabled)
        }
    }
}

struct FoodMetadataEditor: View {
    let item: FoodItem
    @Environment(ArchiveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var source = ""
    @State private var attribution = ""
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    OutlineField(label: "TITLE", text: $title)
                    OutlineField(label: "SOURCE URL", text: $source).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    OutlineField(label: "SOURCE / CREATOR / RESTAURANT", text: $attribution)
                    OutlineField(label: "NOTES", text: $notes, axis: .vertical)
                    PrimaryAction(title: "SAVE CHANGES") {
                        if store.commit({
                            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { throw ArchiveError.emptyTitle }
                            if !source.isEmpty { _ = try SourceLink.validated(source) }
                            item.title = trimmed
                            item.sourceURL = source.trimmingCharacters(in: .whitespacesAndNewlines)
                            item.sourceName = attribution
                            item.notes = notes
                        }) { dismiss() }
                    }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
                .navigationTitle("EDIT FOOD")
                .toolbar { ToolbarItem(placement: .topBarLeading) { TextAction(title: "CANCEL") { dismiss() } } }
                .onAppear { title = item.title; source = item.sourceURL; attribution = item.sourceName; notes = item.notes }
                .archiveScreen().archiveErrors()
        }
    }
}

struct CoverEditor: View {
    let item: FoodItem
    @Environment(ArchiveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var isolated = false
    @State private var x = 0.5
    @State private var y = 0.5
    private var selected: MediaAsset? { item.assets.first { $0.id == selectedID } ?? item.cover }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if let selected {
                        MediaStage(asset: selected, presentationOverride: isolated, cropOverride: CGPoint(x: x, y: y))
                            .aspectRatio(1, contentMode: .fit).frame(maxWidth: 360)
                    }
                    Picker("Cover attachment", selection: $selectedID) {
                        ForEach(Array(item.orderedAssets.enumerated()), id: \.element.id) { index, asset in
                            Text("Media \(index + 1)").tag(Optional(asset.id))
                        }
                    }
                    Toggle("Isolated object · keep entire image", isOn: $isolated).font(ArchiveStyle.label)
                    if !isolated {
                        VStack(alignment: .leading) {
                            Text("COVER CROP · HORIZONTAL").font(ArchiveStyle.label)
                            Slider(value: $x).accessibilityLabel("Horizontal cover crop")
                            Text("COVER CROP · VERTICAL").font(ArchiveStyle.label)
                            Slider(value: $y).accessibilityLabel("Vertical cover crop")
                        }
                    }
                    Text("Only the library preview changes. Your original and detail media remain uncropped.")
                        .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                    PrimaryAction(title: "SAVE COVER") {
                        if store.commit({
                            item.coverID = selected?.id
                            selected?.isIsolated = isolated
                            selected?.cropX = x
                            selected?.cropY = y
                        }) { dismiss() }
                    }
                }.padding(20)
            }
            .navigationTitle("EDIT COVER")
            .toolbar { ToolbarItem(placement: .topBarLeading) { TextAction(title: "CANCEL") { dismiss() } } }
            .onAppear { selectedID = item.cover?.id; load() }
            .onChange(of: selectedID) { _, _ in load() }
            .archiveScreen().archiveErrors()
        }
    }
    private func load() { isolated = selected?.isIsolated ?? false; x = selected?.cropX ?? 0.5; y = selected?.cropY ?? 0.5 }
}