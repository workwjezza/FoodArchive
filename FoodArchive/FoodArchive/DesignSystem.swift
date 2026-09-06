import SwiftUI

enum ArchiveStyle {
    static let canvas = Color.white
    static let ink = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let secondary = Color(red: 0.4, green: 0.4, blue: 0.4)
    static let line = Color(red: 229 / 255, green: 229 / 255, blue: 229 / 255)
    static let placeholder = Color(red: 245 / 255, green: 245 / 255, blue: 245 / 255)
    static let inset: CGFloat = 20
    static let gap: CGFloat = 20
    static let label = Font.system(.footnote, design: .monospaced)
    static let body = Font.system(.body, design: .monospaced)
    static let title = Font.system(.title3, design: .monospaced).weight(.medium)
}

struct TextAction: View {
    let title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(ArchiveStyle.label)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct IconAction: View {
    let symbol: String
    let label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 19, weight: .regular))
                .frame(width: 48, height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
}

struct PrimaryAction: View {
    let title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(ArchiveStyle.label.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.vertical, 4)
                .foregroundStyle(.white).background(ArchiveStyle.ink)
        }.buttonStyle(.plain)
    }
}

enum ArchiveMode: String, CaseIterable { case library = "LIBRARY", journal = "JOURNAL" }

struct ArchiveModeSelector: View {
    @Binding var mode: ArchiveMode
    var body: some View {
        HStack(spacing: 8) {
            ForEach(ArchiveMode.allCases, id: \.self) { destination in
                if destination == .journal { Text("/").foregroundStyle(ArchiveStyle.secondary).accessibilityHidden(true) }
                Button { mode = destination } label: {
                    Text(destination.rawValue)
                        .font(ArchiveStyle.label.weight(mode == destination ? .medium : .regular))
                        .foregroundStyle(mode == destination ? ArchiveStyle.ink : ArchiveStyle.secondary)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == destination ? .isSelected : [])
                .accessibilityIdentifier(destination.rawValue.lowercased() + "Tab")
            }
        }
    }
}

struct ArchiveHeader: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var mode: ArchiveMode
    let add: () -> Void
    let collections: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if typeSize.isAccessibilitySize {
                HStack {
                    addButton
                    Spacer()
                    Text("FOOD ARCHIVE").font(ArchiveStyle.label)
                    Spacer()
                    collectionButton
                }
                ArchiveModeSelector(mode: $mode)
            } else {
                HStack(spacing: 0) {
                    addButton
                    Spacer(minLength: 0)
                    ArchiveModeSelector(mode: $mode)
                    Spacer(minLength: 0)
                    collectionButton
                }.frame(minHeight: 52)
            }
        }
        .padding(.horizontal, 8)
        .background(ArchiveStyle.canvas)
    }

    private var addButton: some View {
        IconAction(symbol: "plus", label: mode == .library ? "Add food media" : "Add journal entry", action: add)
            .accessibilityIdentifier("addButton")
    }
    private var collectionButton: some View {
        IconAction(symbol: "square.stack", label: "Collections and organization", action: collections)
            .accessibilityIdentifier("collectionsButton")
    }
}

struct CatalogCaption: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(spacing: 6) {
            Text(title.uppercased()).font(ArchiveStyle.label)
                .multilineTextAlignment(.center).lineLimit(2)
            if let subtitle {
                Text(subtitle).font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                    .multilineTextAlignment(.center)
            }
        }.frame(maxWidth: .infinity)
    }
}

struct OutlineField: View {
    let label: String
    @Binding var text: String
    var axis: Axis = .horizontal
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(ArchiveStyle.label.weight(.medium))
            TextField(label, text: $text, axis: axis)
                .font(ArchiveStyle.body).padding(12)
                .frame(minHeight: 48, alignment: .topLeading)
                .lineLimit(axis == .vertical ? 4...12 : 1...1)
                .overlay(Rectangle().stroke(ArchiveStyle.line, lineWidth: 1))
                .accessibilityIdentifier(label.lowercased().replacingOccurrences(of: " ", with: "_"))
        }
    }
}

struct EmptyStateView: View {
    let title: String
    var message: String = ""
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Text(title).font(ArchiveStyle.label.weight(.medium)).multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message).font(ArchiveStyle.label)
                    .foregroundStyle(ArchiveStyle.secondary).multilineTextAlignment(.center)
            }
            if let actionTitle, let action { TextAction(title: actionTitle, action: action) }
        }.frame(maxWidth: .infinity).padding(.horizontal, 28).padding(.vertical, 72)
    }
}

struct CheckRow: View {
    let title: String
    let selected: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).font(ArchiveStyle.label)
                Spacer()
                Image(systemName: selected ? "checkmark.square" : "square")
                    .accessibilityHidden(true)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct StoreErrorModifier: ViewModifier {
    @Environment(ArchiveStore.self) private var store
    func body(content: Content) -> some View {
        content.alert("COULD NOT COMPLETE", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

extension View {
    func archiveErrors() -> some View { modifier(StoreErrorModifier()) }
    func archiveScreen() -> some View {
        background(ArchiveStyle.canvas)
            .foregroundStyle(ArchiveStyle.ink)
            .tint(ArchiveStyle.ink)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ArchiveStyle.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

extension Set {
    mutating func toggle(_ value: Element) {
        if contains(value) { remove(value) } else { insert(value) }
    }
}

#Preview("Header • accessible") {
    ArchiveHeader(mode: .constant(.library), add: {}, collections: {})
        .environment(\.dynamicTypeSize, .accessibility2)
        .preferredColorScheme(.light)
}