import SwiftUI
import SwiftData

struct JournalEntryEditor: View {
    @Environment(ArchiveStore.self) private var store
    @Environment(DraftStore.self) private var drafts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Query private var allItems: [FoodItem]
    @Query private var allEntries: [JournalEntry]
    @State private var draft: JournalDraft
    @State private var showItems = false
    @State private var showMedia = false
    @State private var confirmClose = false
    @State private var finished = false
    @State private var loaded = false
    @State private var removedNewMedia: [MediaPayload] = []

    init(initialItems: [FoodItem] = [], entry: JournalEntry? = nil, resuming: JournalDraft? = nil) {
        _draft = State(initialValue: resuming ?? JournalDraft(items: initialItems, entry: entry))
    }

    private var linkedItems: [FoodItem] {
        draft.itemIDs.compactMap { id in allItems.first { $0.id == id } }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let preview = draft.attachments.first {
                        MediaStage(path: preview.thumbnailPath, uncropped: true).frame(height: 180)
                    } else if let item = linkedItems.first {
                        MediaStage(asset: item.cover, uncropped: true).frame(height: 180)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("EXPERIENCE").font(ArchiveStyle.label.weight(.medium))
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) { experienceChoices }
                            VStack(alignment: .leading, spacing: 4) { experienceChoices }
                        }
                        DatePicker("WHEN", selection: $draft.occurredAt).font(ArchiveStyle.label)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LINKED FOOD").font(ArchiveStyle.label.weight(.medium))
                        ForEach(linkedItems) { item in
                            HStack {
                                Text(item.title).font(ArchiveStyle.label)
                                Spacer()
                                IconAction(symbol: "minus", label: "Unlink \(item.title)") { draft.itemIDs.removeAll { $0 == item.id } }
                            }
                        }
                        TextAction(title: "LINK EXISTING FOOD") { showItems = true }
                        if linkedItems.isEmpty {
                            Text("Text-only entries are welcome. Food links are optional.")
                                .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                        }
                    }
                    OutlineField(label: "MEAL OCCASION (OPTIONAL)", text: $draft.occasion)
                    OutlineField(label: "PLACE (OPTIONAL)", text: $draft.place)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("REFLECTION (OPTIONAL)").font(ArchiveStyle.label.weight(.medium))
                        TextEditor(text: $draft.reflection).font(.body)
                            .frame(minHeight: 160).padding(8)
                            .overlay(Rectangle().stroke(ArchiveStyle.line))
                            .accessibilityLabel("Reflection").accessibilityIdentifier("reflection")
                    }
                    Picker("PERSONAL RATING", selection: $draft.rating) {
                        Text("None").tag(nil as Int?)
                        ForEach(1...5, id: \.self) { Text("\($0) / 5").tag(Optional($0)) }
                    }.font(ArchiveStyle.label)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(draft.attachments) { payload in
                            HStack(spacing: 16) {
                                MediaStage(path: payload.thumbnailPath).frame(width: 64, height: 64)
                                Text(payload.kind.rawValue.uppercased()).font(ArchiveStyle.label)
                                Spacer()
                                IconAction(symbol: "minus", label: "Remove attachment") {
                                    draft.attachments.removeAll { $0.id == payload.id }
                                    if !draft.originalAttachmentIDs.contains(payload.id) { removedNewMedia.append(payload) }
                                }
                            }
                        }
                        TextAction(title: "ADD PHOTOS / VIDEO") { showMedia = true }
                    }
                    Text("Only the experience and its date are needed. Saving this entry never clears “Want to try.”")
                        .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                    PrimaryAction(title: "SAVE ENTRY", action: save).accessibilityIdentifier("saveEntryBottom")
                }
                .frame(maxWidth: 640).frame(maxWidth: .infinity)
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(draft.editingEntryID == nil ? "LOG EXPERIENCE" : "EDIT ENTRY")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { TextAction(title: "CANCEL") { confirmClose = true } }
                ToolbarItem(placement: .topBarTrailing) { TextAction(title: "SAVE ENTRY", action: save).accessibilityIdentifier("saveEntry") }
            }
            .interactiveDismissDisabled()
            .confirmationDialog("KEEP THIS DRAFT?", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("Keep draft") { if persistDraft() { finished = true; dismiss() } }
                Button("Discard draft", role: .destructive) { discard() }
                Button("Continue editing", role: .cancel) {}
            } message: { Text("Drafts stay on this device. You can resume them from Journal.") }
            .sheet(isPresented: $showItems) { FoodLinkPicker(selectedIDs: $draft.itemIDs) }
            .sheet(isPresented: $showMedia) { ImportView { payloads in draft.attachments.append(contentsOf: payloads) } }
            .onAppear {
                if !loaded {
                    // Resume an existing edit draft rather than overwriting it with the saved entry.
                    if let existing = drafts.drafts.first(where: { $0.id == draft.id }) { draft = existing }
                    loaded = true
                }
            }
            .task(id: draft) {
                guard loaded, !finished else { return }
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    if !finished { _ = persistDraft() }
                } catch is CancellationError { }
                catch { store.errorMessage = error.localizedDescription }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active && !finished { _ = persistDraft() } }
            .archiveScreen().archiveErrors()
        }
    }

    @ViewBuilder private var experienceChoices: some View {
        ForEach(ExperienceKind.allCases) { kind in
            Button { draft.kind = kind } label: {
                Text(kind.rawValue.uppercased()).font(ArchiveStyle.label)
                    .frame(minWidth: 64, minHeight: 44)
                    .padding(.horizontal, 8)
                    .overlay(Rectangle().stroke(draft.kind == kind ? ArchiveStyle.ink : ArchiveStyle.line))
            }.buttonStyle(.plain)
                .accessibilityAddTraits(draft.kind == kind ? .isSelected : [])
        }
    }

    @discardableResult private func persistDraft() -> Bool {
        do {
            try drafts.save(draft)
            if !removedNewMedia.isEmpty {
                store.removeFiles(removedNewMedia.flatMap { [$0.originalPath, $0.thumbnailPath] })
                removedNewMedia = []
            }
            return true
        } catch { store.errorMessage = "Draft could not be saved: \(error.localizedDescription)"; return false }
    }

    private func discard() {
        do {
            try drafts.remove(draft.id)
            let unsaved = draft.attachments.filter { !draft.originalAttachmentIDs.contains($0.id) } + removedNewMedia
            store.removeFiles(unsaved.flatMap { [$0.originalPath, $0.thumbnailPath] })
            finished = true
            dismiss()
        } catch { store.errorMessage = error.localizedDescription }
    }

    private func save() {
        var removedPaths: [String] = []
        let success = store.commit {
            let entry = allEntries.first { $0.id == draft.id } ?? JournalEntry()
            if let editingID = draft.editingEntryID, !allEntries.contains(where: { $0.id == editingID }) {
                throw ArchiveError.missingFile
            }
            for attachment in draft.attachments {
                guard FileManager.default.fileExists(atPath: MediaStorage.url(for: attachment.originalPath).path) else {
                    throw ArchiveError.missingFile
                }
            }
            if entry.modelContext == nil { entry.id = draft.id; store.context.insert(entry) }
            entry.occurredAt = draft.occurredAt
            entry.kindRaw = draft.kind.rawValue
            entry.occasion = draft.occasion
            entry.place = draft.place
            entry.reflection = draft.reflection
            entry.rating = draft.rating
            entry.items = linkedItems
            for old in entry.attachments where !draft.attachments.contains(where: { $0.id == old.id }) {
                removedPaths += [old.originalPath, old.thumbnailPath]
                store.context.delete(old)
            }
            for (position, payload) in draft.attachments.enumerated() {
                if let existing = entry.attachments.first(where: { $0.id == payload.id }) {
                    existing.position = position
                } else { entry.attachments.append(MediaAsset(payload: payload, position: position)) }
            }
        }
        guard success else { return }
        finished = true
        store.removeFiles(removedPaths + removedNewMedia.flatMap { [$0.originalPath, $0.thumbnailPath] })
        do { try drafts.remove(draft.id) }
        catch {
            // Stable entry ID makes retries idempotent if the draft file cannot be removed.
            store.errorMessage = "Entry saved, but its draft could not be removed: \(error.localizedDescription)"
        }
        dismiss()
    }
}

struct FoodLinkPicker: View {
    @Binding var selectedIDs: [UUID]
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FoodItem.title) private var items: [FoodItem]
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List {
                ForEach(items.filter { !$0.isHistoricalOnly && (search.isEmpty || $0.title.localizedStandardContains(search)) }) { item in
                    CheckRow(title: item.title, selected: selectedIDs.contains(item.id)) {
                        if selectedIDs.contains(item.id) { selectedIDs.removeAll { $0 == item.id } }
                        else { selectedIDs.append(item.id) }
                    }
                }
                if items.isEmpty { Text("Save food to your library first, or continue with a text-only entry.").font(ArchiveStyle.label) }
            }.listStyle(.plain).searchable(text: $search)
                .navigationTitle("LINK FOOD")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { TextAction(title: "DONE") { dismiss() } } }
                .archiveScreen()
        }
    }
}