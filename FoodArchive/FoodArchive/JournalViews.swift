import SwiftUI
import SwiftData

struct JournalView: View {
    @Environment(DraftStore.self) private var drafts
    @Query(sort: \JournalEntry.occurredAt, order: .reverse) private var entries: [JournalEntry]
    let add: () -> Void
    @State private var kind: ExperienceKind?
    @State private var tagID: UUID?
    @State private var itemID: UUID?
    @State private var day = Date.now
    @State private var limitDay = false
    @State private var filters = false
    @State private var calendar = false
    @State private var resuming: JournalDraft?
    private var filtered: [JournalEntry] {
        entries.filter { entry in
            (kind == nil || entry.kind == kind)
                && (tagID == nil || entry.items.contains { $0.tags.contains { $0.id == tagID } })
                && (itemID == nil || entry.items.contains { $0.id == itemID })
                && (!limitDay || Calendar.current.isDate(entry.occurredAt, inSameDayAs: day))
        }
    }
    private var filterCount: Int { [kind != nil, tagID != nil, itemID != nil, limitDay].filter { $0 }.count }
    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    TextAction(title: limitDay ? day.formatted(date: .abbreviated, time: .omitted).uppercased() : "ALL DATES") { calendar = true }
                    Spacer()
                    navigationControls
                }
                VStack {
                    TextAction(title: "CHOOSE DATE") { calendar = true }
                    HStack { navigationControls }
                }
            }.padding(.horizontal, 20)
            if filterCount > 0 {
                HStack {
                    Text("\(filtered.count) ENTRIES").font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                    Spacer()
                    TextAction(title: "CLEAR ALL") { kind = nil; tagID = nil; itemID = nil; limitDay = false }
                }.padding(.horizontal, 20)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 36) {
                    if !drafts.drafts.isEmpty {
                        Menu {
                            ForEach(drafts.drafts) { draft in
                                Button(draft.occurredAt.formatted(date: .abbreviated, time: .shortened) + " · " + (draft.reflection.isEmpty ? "Unfinished entry" : String(draft.reflection.prefix(32)))) {
                                    resuming = draft
                                }
                            }
                        } label: {
                            Text("DRAFTS \(drafts.drafts.count)").font(ArchiveStyle.label)
                                .frame(minHeight: 44).accessibilityIdentifier("journalDrafts")
                        }
                    }
                    if filtered.isEmpty {
                        EmptyStateView(title: limitDay ? "NO ENTRIES FOR THIS DATE" : "NO EXPERIENCES YET",
                                       message: "What you ate. What you cooked.\nWhat you want to remember.",
                                       actionTitle: "ADD ENTRY", action: add)
                    } else {
                        JournalTimeline(entries: filtered)
                    }
                }
                .frame(maxWidth: 640).frame(maxWidth: .infinity)
                .padding(20).padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $filters) { JournalFilterEditor(kind: $kind, tagID: $tagID, itemID: $itemID) }
        .sheet(isPresented: $calendar) {
            NavigationStack {
                VStack(spacing: 24) {
                    DatePicker("Date", selection: $day, displayedComponents: .date).datePickerStyle(.graphical)
                    Toggle("Only show this day", isOn: $limitDay).font(ArchiveStyle.label)
                    PrimaryAction(title: "SHOW DATE") { limitDay = true; calendar = false }
                    TextAction(title: "ALL DATES") { limitDay = false; calendar = false }
                }.padding(20).navigationTitle("JOURNAL DATE")
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { TextAction(title: "DONE") { calendar = false } } }
                    .archiveScreen()
            }.presentationDetents([.large])
        }
        .sheet(item: $resuming) { draft in JournalEntryEditor(resuming: draft) }
        .archiveScreen()
    }
    @ViewBuilder private var navigationControls: some View {
        TextAction(title: filterCount == 0 ? "FILTER" : "FILTER \(filterCount)") { filters = true }
        NavigationLink(value: ArchiveRoute.summary) {
            Text("SUMMARY").font(ArchiveStyle.label).frame(minHeight: 44)
        }
    }
}

struct JournalTimeline: View {
    let entries: [JournalEntry]
    private var days: [Date] { Set(entries.map { Calendar.current.startOfDay(for: $0.occurredAt) }).sorted(by: >) }
    var body: some View {
        ForEach(days, id: \.self) { day in
            VStack(alignment: .leading, spacing: 24) {
                Text(day.formatted(date: .abbreviated, time: .omitted).uppercased())
                    .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(entries.filter { Calendar.current.isDate($0.occurredAt, inSameDayAs: day) }
                    .sorted { $0.occurredAt == $1.occurredAt ? $0.id.uuidString < $1.id.uuidString : $0.occurredAt > $1.occurredAt }) { entry in
                    NavigationLink(value: ArchiveRoute.entry(entry)) { JournalRow(entry: entry) }
                        .buttonStyle(.plain).accessibilityIdentifier("journalEntry_" + entry.id.uuidString)
                }
            }
        }
    }
}

struct JournalRow: View {
    let entry: JournalEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let cover = entry.cover {
                MediaStage(asset: cover).aspectRatio(1.25, contentMode: .fit)
            }
            Text(entry.title.uppercased()).font(ArchiveStyle.label.weight(.medium))
            Text(entry.kind.rawValue.uppercased() + " · " + entry.occurredAt.formatted(date: .omitted, time: .shortened))
                .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
            if !entry.reflection.isEmpty { Text(entry.reflection).font(.body).lineLimit(4) }
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.bottom, 12)
            .accessibilityElement(children: .combine)
    }
}

struct JournalDetailView: View {
    let entry: JournalEntry
    @Environment(ArchiveStore.self) private var store
    @Environment(DraftStore.self) private var drafts
    @Environment(\.dismiss) private var dismiss
    @State private var edit = false
    @State private var deleting = false
    private var media: [MediaAsset] {
        let assets = entry.attachments.sorted { $0.position < $1.position }
        return assets.isEmpty ? entry.items.compactMap(\.cover) : assets
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !media.isEmpty { MediaGallery(assets: media) }
                Text(entry.title.uppercased()).font(ArchiveStyle.title)
                Text(entry.kind.rawValue.uppercased() + " · " + entry.occurredAt.formatted(date: .abbreviated, time: .shortened).uppercased())
                    .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                if !entry.occasion.isEmpty { Text(entry.occasion).font(ArchiveStyle.label) }
                if !entry.place.isEmpty { Text(entry.place).font(ArchiveStyle.label) }
                if !entry.reflection.isEmpty { Text(entry.reflection).font(.body).textSelection(.enabled) }
                if let rating = entry.rating { Text("PERSONAL RATING \(rating) / 5").font(ArchiveStyle.label) }
                if !entry.items.isEmpty {
                    Text("LINKED FOOD").font(ArchiveStyle.label.weight(.medium))
                    ForEach(entry.items) { item in
                        NavigationLink(value: ArchiveRoute.food(item)) {
                            HStack {
                                Text(item.title.uppercased()).font(ArchiveStyle.label)
                                Spacer()
                                Image(systemName: "chevron.right")
                            }.frame(minHeight: 44)
                        }
                    }
                }
            }.frame(maxWidth: 640).frame(maxWidth: .infinity).padding(20)
        }
        .navigationTitle("EXPERIENCE").toolbar(.visible, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Menu("Entry options", systemImage: "ellipsis") {
                Button("Edit entry") { edit = true }
                ShareLink(item: entry.title + "\n" + entry.occurredAt.formatted() + "\n" + entry.reflection) {
                    Text("Share entry text")
                }
                Button("Delete entry", role: .destructive) { deleting = true }
            }.labelStyle(.iconOnly)
        } }
        .sheet(isPresented: $edit) { JournalEntryEditor(entry: entry) }
        .confirmationDialog("DELETE THIS ENTRY?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete entry", role: .destructive) {
                do {
                    if let draft = drafts.drafts.first(where: { $0.id == entry.id }) {
                        try drafts.remove(draft.id)
                        store.removeFiles(draft.attachments.filter { !draft.originalAttachmentIDs.contains($0.id) }.flatMap { [$0.originalPath, $0.thumbnailPath] })
                    }
                    store.deleteEntry(entry)
                    if store.errorMessage == nil { dismiss() }
                } catch { store.errorMessage = error.localizedDescription }
            }
        } message: { Text("Your saved food items remain. This experience and its own attachments are removed.") }
        .archiveScreen().archiveErrors()
    }
}

struct JournalFilterEditor: View {
    @Binding var kind: ExperienceKind?
    @Binding var tagID: UUID?
    @Binding var itemID: UUID?
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(sort: \FoodItem.title) private var items: [FoodItem]
    var body: some View {
        NavigationStack {
            List {
                Section("EXPERIENCE") {
                    Picker("Type", selection: $kind) {
                        Text("All").tag(nil as ExperienceKind?)
                        ForEach(ExperienceKind.allCases) { Text($0.rawValue.uppercased()).tag(Optional($0)) }
                    }
                }
                Section("LINKED FOOD") {
                    Picker("Food", selection: $itemID) {
                        Text("All").tag(nil as UUID?)
                        ForEach(items) { Text($0.title).tag(Optional($0.id)) }
                    }
                    Picker("Tag", selection: $tagID) {
                        Text("All").tag(nil as UUID?)
                        ForEach(tags) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                TextAction(title: "CLEAR ALL") { kind = nil; tagID = nil; itemID = nil }
            }.listStyle(.plain).font(ArchiveStyle.label)
                .navigationTitle("JOURNAL FILTER")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { TextAction(title: "DONE") { dismiss() } } }
                .archiveScreen()
        }
    }
}

struct JournalSummaryView: View {
    @Query(sort: \JournalEntry.occurredAt, order: .reverse) private var allEntries: [JournalEntry]
    @State private var start = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: .now)) ?? .now
    @State private var end = Date.now
    private var entries: [JournalEntry] {
        let from = Calendar.current.startOfDay(for: min(start, end))
        let through = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: max(start, end)))!
        return allEntries.filter { $0.occurredAt >= from && $0.occurredAt < through }
    }
    private var foods: [FoodItem] {
        var seen = Set<UUID>()
        return entries.flatMap(\.items).filter { seen.insert($0.id).inserted }
            .sorted { a, b in
                let ac = occurrences(a.id).count, bc = occurrences(b.id).count
                return ac == bc ? a.title.localizedStandardCompare(b.title) == .orderedAscending : ac > bc
            }
    }
    private var tags: [Tag] {
        var seen = Set<UUID>()
        return foods.flatMap(\.tags).filter { seen.insert($0.id).inserted }
            .sorted { a, b in
                let ac = tagged(a.id).count, bc = tagged(b.id).count
                return ac == bc ? a.name < b.name : ac > bc
            }
    }
    private func occurrences(_ id: UUID) -> [JournalEntry] { entries.filter { $0.items.contains { $0.id == id } } }
    private func tagged(_ id: UUID) -> [JournalEntry] { entries.filter { $0.items.contains { $0.tags.contains { $0.id == id } } } }

    var body: some View {
        List {
            Section("PERIOD") {
                DatePicker("From", selection: $start, displayedComponents: .date)
                DatePicker("Through", selection: $end, displayedComponents: .date)
            }
            Section("EXPERIENCES") {
                summaryLink("ENTRIES", entries)
                summaryLink("COOKING", entries.filter { $0.kind == .cooked })
                summaryLink("EATING", entries.filter { $0.kind == .ate })
                summaryLink("OTHER", entries.filter { $0.kind == .other })
            }
            Section("MOST REVISITED FOOD") {
                ForEach(foods.prefix(10)) { item in summaryLink(item.title.uppercased(), occurrences(item.id)) }
            }
            Section("MOST-USED TAGS") {
                ForEach(tags.prefix(10)) { tag in summaryLink(tag.name.uppercased(), tagged(tag.id)) }
            }
            Section {
                Text("Counts reflect recorded experiences, not saved images. Each tag is counted once per entry. Tap any number to see its records.")
                    .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
            }
        }.listStyle(.plain).font(ArchiveStyle.label)
            .navigationTitle("SUMMARY").toolbar(.visible, for: .navigationBar)
            .archiveScreen()
    }
    private func summaryLink(_ title: String, _ records: [JournalEntry]) -> some View {
        NavigationLink(value: ArchiveRoute.records(title, Set(records.map(\.id)))) {
            HStack { Text(title); Spacer(); Text("\(records.count)").monospacedDigit() }.frame(minHeight: 44)
        }
    }
}

struct JournalRecordsView: View {
    let title: String
    let ids: Set<UUID>
    @Query(sort: \JournalEntry.occurredAt, order: .reverse) private var entries: [JournalEntry]
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 36) {
                if ids.isEmpty { EmptyStateView(title: "NO ENTRIES IN THIS PERIOD") }
                JournalTimeline(entries: entries.filter { ids.contains($0.id) })
            }.frame(maxWidth: 640).frame(maxWidth: .infinity).padding(20)
        }.navigationTitle(title).archiveScreen()
    }
}