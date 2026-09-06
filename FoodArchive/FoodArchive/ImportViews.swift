import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import LinkPresentation

struct ImportView: View {
    /// Attachment mode uses exactly the same local import pipeline, without creating FoodItems.
    var onAttach: (([MediaPayload]) -> Void)? = nil
    @Environment(ArchiveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Query private var existingAssets: [MediaAsset]
    @State private var picks: [PhotosPickerItem] = []
    @State private var payloads: [MediaPayload] = []
    @State private var title = "Untitled food"
    @State private var grouped = false
    @State private var isolated = false
    @State private var files = false
    @State private var camera = false
    @State private var link = false
    @State private var journal = false
    @State private var busy = false
    @State private var progress = ""
    @State private var failures: [String] = []
    @State private var retryURLs: [URL] = []
    @State private var confirmDiscard = false

    private var duplicateCount: Int {
        var fingerprints = Set(existingAssets.map { String($0.originalPath.prefix(64)) })
        var count = 0
        for payload in payloads {
            if !fingerprints.insert(String(payload.originalPath.prefix(64))).inserted { count += 1 }
        }
        return count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(spacing: 4) {
                        PhotosPicker(selection: $picks, maxSelectionCount: 30, matching: .any(of: [.images, .videos]),
                                     preferredItemEncoding: .current) {
                            choice("PHOTO LIBRARY", symbol: "photo.on.rectangle")
                        }.disabled(busy).accessibilityIdentifier("photoLibrary")
                        Button { requestCamera() } label: { choice("CAMERA", symbol: "camera") }.disabled(busy)
                        Button { files = true } label: { choice("FILES", symbol: "doc") }.disabled(busy)
                        if onAttach == nil {
                            Button { link = true } label: { choice("SAVE LINK", symbol: "link") }.disabled(busy)
                            Button { journal = true } label: { choice("NEW JOURNAL ENTRY", symbol: "square.and.pencil") }.disabled(busy)
                        }
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                            Button("IMPORT TEST PHOTO") {
                                if let url = Bundle.main.url(forResource: "sample-toast", withExtension: "jpg") {
                                    importURLs([url])
                                } else { failures = ["Bundled test image is missing."] }
                            }.accessibilityIdentifier("importTestPhoto").frame(minHeight: 44)
                        }
                        #endif
                    }.buttonStyle(.plain).font(ArchiveStyle.label)

                    if busy {
                        HStack(spacing: 12) { ProgressView(); Text(progress).font(ArchiveStyle.label) }
                    }
                    if !failures.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("IMPORT FAILED").font(ArchiveStyle.label.weight(.medium))
                            ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                                Text(failure).font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                            }
                            if !retryURLs.isEmpty { TextAction(title: "TRY AGAIN") { importURLs(retryURLs) }.disabled(busy) }
                            Text("Successful files remain below. You can also choose media again from Photos or Files.")
                                .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                        }
                    }
                    if !payloads.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 16) {
                                ForEach(payloads) { payload in
                                    VStack {
                                        MediaStage(path: payload.thumbnailPath, isolated: isolated)
                                            .frame(width: 112, height: 112)
                                        TextAction(title: "REMOVE") {
                                            payloads.removeAll { $0.id == payload.id }
                                            store.removeFiles([payload.originalPath, payload.thumbnailPath])
                                        }.accessibilityLabel("Remove imported media")
                                    }
                                }
                            }
                        }
                        Text("\(payloads.count) ASSET(S) READY").font(ArchiveStyle.label)
                        if duplicateCount > 0 {
                            Text("\(duplicateCount) possible duplicate(s). Nothing will be merged. Remove unwanted copies above or save them separately.")
                                .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                        }
                        if onAttach == nil {
                            OutlineField(label: "TITLE", text: $title)
                            if payloads.count > 1 {
                                Picker("Save as", selection: $grouped) {
                                    Text("Separate food items").tag(false)
                                    Text("One food, multiple attachments").tag(true)
                                }.font(ArchiveStyle.label).pickerStyle(.menu)
                            }
                            Toggle("Isolated objects · aspect fit", isOn: $isolated).font(ArchiveStyle.label)
                        }
                    } else if !busy {
                        Text("Images and videos. No tags required.\nOriginals stay on this device.")
                            .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary).padding(.top, 16)
                    }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom) {
                    if !payloads.isEmpty {
                        PrimaryAction(title: onAttach == nil ? "SAVE TO ARCHIVE" : "ATTACH MEDIA") { save() }
                            .disabled(busy).accessibilityIdentifier("saveImport")
                            .padding(.horizontal, 20).padding(.vertical, 12).background(.white)
                    }
                }
                .navigationTitle(onAttach == nil ? "ADD FOOD MEDIA" : "ADD ATTACHMENTS")
                .toolbar { ToolbarItem(placement: .topBarLeading) {
                    TextAction(title: "CANCEL") {
                        if payloads.isEmpty { dismiss() } else { confirmDiscard = true }
                    }.disabled(busy)
                } }
                .interactiveDismissDisabled(busy || !payloads.isEmpty)
                .confirmationDialog("DISCARD IMPORTED MEDIA?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("Discard", role: .destructive) {
                        store.removeFiles(payloads.flatMap { [$0.originalPath, $0.thumbnailPath] })
                        payloads = []
                        dismiss()
                    }
                    Button("Keep editing", role: .cancel) {}
                }
                .fileImporter(isPresented: $files, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let urls): importURLs(urls)
                    case .failure(let error): failures = [error.localizedDescription]
                    }
                }
                .fullScreenCover(isPresented: $camera) {
                    CameraCapture { result in
                        camera = false
                        switch result {
                        case .success(let url): if let url { importURLs([url]) }
                        case .failure(let error): failures = [error.localizedDescription]
                        }
                    }.ignoresSafeArea()
                }
                .sheet(isPresented: $link) { SaveLinkView() }
                .sheet(isPresented: $journal) { JournalEntryEditor() }
                .onChange(of: picks) { _, selected in importPhotos(selected) }
                .archiveScreen().archiveErrors()
        }
    }

    private func choice(_ label: String, symbol: String) -> some View {
        HStack {
            Image(systemName: symbol).frame(width: 24)
            Text(label)
            Spacer()
            Image(systemName: "chevron.right").font(.caption)
        }.frame(minHeight: 52).contentShape(Rectangle())
    }

    private func importPhotos(_ selected: [PhotosPickerItem]) {
        guard !selected.isEmpty, !busy else { return }
        busy = true; failures = []; retryURLs = []
        Task {
            for (index, pick) in selected.enumerated() {
                progress = "IMPORTING \(index + 1) / \(selected.count)"
                do {
                    guard let file = try await pick.loadTransferable(type: ImportedFile.self) else { throw ArchiveError.unsupportedMedia }
                    defer { try? FileManager.default.removeItem(at: file.url) }
                    let payload = try await MediaStorage.shared.ingest(file.url)
                    payloads.append(payload)
                } catch { failures.append("Asset \(index + 1): \(error.localizedDescription)") }
            }
            busy = false
            picks = []
        }
    }

    private func importURLs(_ urls: [URL]) {
        guard !busy else { return }
        busy = true; failures = []; retryURLs = []
        Task {
            for (index, url) in urls.enumerated() {
                progress = "IMPORTING \(index + 1) / \(urls.count)"
                do { payloads.append(try await MediaStorage.shared.ingest(url)) }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)"); retryURLs.append(url) }
            }
            busy = false
        }
    }

    private func requestCamera() {
        #if targetEnvironment(simulator)
        failures = ["Camera is unavailable here. Use Photo Library or Files instead."]
        #else
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            failures = ["Camera is unavailable here. Use Photo Library or Files instead."]
            return
        }
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted { camera = true }
            else { failures = ["Camera access is denied. Use Photo Library or Files, or enable camera access in iOS Settings."] }
        }
        #endif
    }

    private func save() {
        if let onAttach { onAttach(payloads); payloads = []; dismiss() }
        else if store.commit({ try store.importItems(payloads: payloads, grouped: grouped, title: title, isolated: isolated) }) {
            payloads = []
            dismiss()
        }
    }
}

struct CameraCapture: UIViewControllerRepresentable {
    let completion: (Result<URL?, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.delegate = context.coordinator
        picker.videoQuality = .typeHigh
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: (Result<URL?, Error>) -> Void
        init(completion: @escaping (Result<URL?, Error>) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(.success(nil)) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            do {
                let url: URL
                if let movie = info[.mediaURL] as? URL {
                    url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(movie.pathExtension)
                    try FileManager.default.copyItem(at: movie, to: url)
                } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.98) {
                    url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
                    try data.write(to: url, options: .atomic)
                } else { throw ArchiveError.unsupportedMedia }
                completion(.success(url))
            } catch { completion(.failure(error)) }
        }
    }
}

enum SourceLink {
    static func validated(_ string: String) throws -> URL {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { throw ArchiveError.invalidURL }
        return url
    }
}

struct SaveLinkView: View {
    @Environment(ArchiveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var title = ""
    @State private var attribution = ""
    @State private var notes = ""
    @State private var preview: MediaPayload?
    @State private var status = ""
    @State private var loading = false
    @State private var provider = LPMetadataProvider()
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    OutlineField(label: "SOURCE URL", text: $source).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextAction(title: loading ? "LOADING…" : "LOAD AVAILABLE PREVIEW") { fetchPreview() }.disabled(loading)
                    Text("Loading a preview contacts the source website. You can save only the link instead. Private and blocked sources may not provide a preview.")
                        .font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary)
                    if let preview { MediaStage(path: preview.thumbnailPath).frame(height: 200) }
                    if !status.isEmpty { Text(status).font(ArchiveStyle.label).foregroundStyle(ArchiveStyle.secondary) }
                    OutlineField(label: "TITLE (OPTIONAL)", text: $title)
                    OutlineField(label: "CREATOR / SOURCE (OPTIONAL)", text: $attribution)
                    OutlineField(label: "NOTES", text: $notes, axis: .vertical)
                    PrimaryAction(title: "SAVE LINK") {
                        if store.commit({
                            let url = try SourceLink.validated(source)
                            let item = FoodItem(title: title.isEmpty ? (url.host ?? "Saved link") : title)
                            item.sourceURL = url.absoluteString
                            item.sourceName = attribution.isEmpty ? (url.host ?? "") : attribution
                            item.notes = notes
                            store.context.insert(item)
                            if let preview { item.assets.append(MediaAsset(payload: preview)) }
                        }) { saved = true; dismiss() }
                    }.disabled(loading)
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
                .navigationTitle("SAVE LINK")
                .toolbar { ToolbarItem(placement: .topBarLeading) { TextAction(title: "CANCEL") { dismiss() }.disabled(loading) } }
                .interactiveDismissDisabled(loading)
                .onDisappear {
                    provider.cancel()
                    if !saved, let preview { store.removeFiles([preview.originalPath, preview.thumbnailPath]) }
                }
                .archiveScreen().archiveErrors()
        }
    }
    private func fetchPreview() {
        loading = true
        status = ""
        Task {
            defer { loading = false }
            do {
                let url = try SourceLink.validated(source)
                provider = LPMetadataProvider()
                provider.timeout = 12
                let metadata = try await provider.startFetchingMetadata(for: url)
                if title.isEmpty { title = metadata.title ?? "" }
                if attribution.isEmpty { attribution = metadata.url?.host ?? url.host ?? "" }
                if let imageProvider = metadata.imageProvider {
                    let image: UIImage = try await withCheckedThrowingContinuation { continuation in
                        imageProvider.loadObject(ofClass: UIImage.self) { object, error in
                            if let image = object as? UIImage { continuation.resume(returning: image) }
                            else { continuation.resume(throwing: error ?? ArchiveError.unreadableImage) }
                        }
                    }
                    guard let data = image.jpegData(compressionQuality: 0.95) else { throw ArchiveError.unreadableImage }
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
                    try data.write(to: url)
                    defer { try? FileManager.default.removeItem(at: url) }
                    let imported = try await MediaStorage.shared.ingest(url)
                    if let preview { store.removeFiles([preview.originalPath, preview.thumbnailPath]) }
                    preview = imported
                } else { status = "PREVIEW UNAVAILABLE · Save the link and open its source any time." }
            } catch { status = "PREVIEW UNAVAILABLE · \(error.localizedDescription) You can still save a valid source link." }
        }
    }
}