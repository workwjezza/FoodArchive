import SwiftUI
import AVKit

struct MediaStage: View {
    var asset: MediaAsset?
    var path: String? = nil
    var isolated: Bool = false
    var uncropped: Bool = false
    var presentationOverride: Bool? = nil
    var cropOverride: CGPoint? = nil
    @State private var image: UIImage?
    @State private var failed = false

    private var imagePath: String? { path ?? asset?.thumbnailPath }
    private var fitsObject: Bool { presentationOverride ?? (isolated || asset?.isIsolated == true) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white
                if let image {
                    if uncropped || fitsObject {
                        Image(uiImage: image).resizable().scaledToFit()
                            .padding(fitsObject ? geometry.size.width * 0.10 : 0)
                    } else {
                        let scale = max(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                        let width = image.size.width * scale
                        let height = image.size.height * scale
                        Image(uiImage: image).resizable()
                            .frame(width: width, height: height)
                            .position(
                                x: geometry.size.width / 2 - (width - geometry.size.width) * ((cropOverride?.x ?? asset?.cropX ?? 0.5) - 0.5),
                                y: geometry.size.height / 2 - (height - geometry.size.height) * ((cropOverride?.y ?? asset?.cropY ?? 0.5) - 0.5)
                            )
                    }
                } else if failed || imagePath == nil {
                    VStack(spacing: 10) {
                        Image(systemName: imagePath == nil ? "link" : "photo")
                        Text("PREVIEW\nUNAVAILABLE").font(ArchiveStyle.label).multilineTextAlignment(.center)
                    }.foregroundStyle(ArchiveStyle.secondary)
                } else {
                    ArchiveStyle.placeholder
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: imagePath) {
            image = nil
            failed = false
            guard let imagePath else { return }
            do { image = try await ThumbnailCache.shared.image(path: imagePath) }
            catch is CancellationError { }
            catch { failed = true }
        }
        .accessibilityHidden(true)
    }
}

struct MediaTile: View {
    let item: FoodItem
    var selected = false
    var selecting = false
    var body: some View {
        VStack(spacing: 14) {
            MediaStage(asset: item.cover)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    if let cover = item.cover, cover.kind == .video {
                        Text(String(format: "%d:%02d", Int(cover.duration) / 60, Int(cover.duration) % 60))
                            .font(.system(.caption2, design: .monospaced))
                            .padding(5).background(.white)
                    } else if item.assets.count > 1 {
                        Image(systemName: "square.on.square").font(.caption)
                            .padding(7).background(.white)
                    }
                }
                .overlay {
                    if selected { Rectangle().stroke(ArchiveStyle.ink, lineWidth: 1) }
                }
                .overlay(alignment: .topTrailing) {
                    if selecting {
                        Image(systemName: selected ? "checkmark.square.fill" : "square")
                            .padding(8).background(.white)
                    }
                }
            CatalogCaption(title: item.title)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(selected ? "Selected" : (item.cover?.kind == .video ? "Video" : "\(item.assets.count) images"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct MediaGrid<Tile: View>: View {
    let items: [FoodItem]
    let width: CGFloat
    var large = false
    @ViewBuilder var tile: (FoodItem) -> Tile
    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: [GridItem] {
        let available = max(0, width - ArchiveStyle.inset * 2)
        let minimum: CGFloat = typeSize.isAccessibilitySize ? 320 : (large ? 340 : (width > 600 ? 200 : 140))
        let count = max(1, Int((available + ArchiveStyle.gap) / (minimum + ArchiveStyle.gap)))
        return Array(repeating: GridItem(.flexible(), spacing: ArchiveStyle.gap, alignment: .top), count: count)
    }
    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: 36) {
            ForEach(items) { item in tile(item).id(item.id) }
        }.scrollTargetLayout()
    }
}

struct MediaGallery: View {
    let assets: [MediaAsset]
    @State private var page = 0
    @State private var viewing: MediaAsset?

    var body: some View {
        VStack(spacing: 8) {
            if assets.isEmpty {
                MediaStage().frame(height: 300)
            } else {
                TabView(selection: $page) {
                    ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                        Button { viewing = asset } label: {
                            MediaStage(asset: asset, uncropped: true)
                                .overlay {
                                    if asset.kind == .video {
                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 44)).symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, ArchiveStyle.ink)
                                    }
                                }
                        }.buttonStyle(.plain)
                            .accessibilityLabel(asset.kind == .video ? "Play video \(index + 1)" : "Open photo \(index + 1), zoom available")
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 340)
                HStack(spacing: 16) {
                    if assets.count > 1 {
                        IconAction(symbol: "chevron.left", label: "Previous media") { page = max(0, page - 1) }
                            .disabled(page == 0)
                    }
                    Text("\(page + 1) / \(assets.count)").font(ArchiveStyle.label)
                        .foregroundStyle(ArchiveStyle.secondary)
                        .accessibilityLabel("Media \(page + 1) of \(assets.count)")
                    if assets.count > 1 {
                        IconAction(symbol: "chevron.right", label: "Next media") { page = min(assets.count - 1, page + 1) }
                            .disabled(page == assets.count - 1)
                    }
                }
            }
        }
        .fullScreenCover(item: $viewing) { asset in
            FullScreenMedia(asset: asset)
        }
    }
}

struct FullScreenMedia: View {
    let asset: MediaAsset
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var zoom: CGFloat = 1

    var body: some View {
        NavigationStack {
            Group {
                if let error {
                    EmptyStateView(title: "MEDIA UNAVAILABLE", message: error)
                } else if asset.kind == .video {
                    VideoPlayer(player: player)
                } else if let image {
                    ZoomablePhoto(image: image, zoom: $zoom)
                } else { ProgressView().tint(ArchiveStyle.ink) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .archiveScreen()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { TextAction(title: "CLOSE") { dismiss() } }
                if asset.kind == .image {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        IconAction(symbol: "minus.magnifyingglass", label: "Zoom out") { zoom = max(1, zoom - 1) }
                        IconAction(symbol: "plus.magnifyingglass", label: "Zoom in") { zoom = min(6, zoom + 1) }
                    }
                }
            }
            .task {
                let url = MediaStorage.url(for: asset.originalPath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    error = ArchiveError.missingFile.localizedDescription
                    return
                }
                if asset.kind == .video {
                    player = AVPlayer(url: url)
                    player?.play() // The viewer opens only after an explicit play action.
                } else {
                    do {
                        let data = try await MediaStorage.shared.imageData(path: asset.originalPath, maximumPixels: 4096)
                        image = UIImage(data: data)
                    } catch { self.error = error.localizedDescription }
                }
            }
            .onDisappear { player?.pause(); player = nil }
        }
    }
}

struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    @Binding var zoom: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = PhotoScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.delegate = context.coordinator
        scroll.backgroundColor = .white
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.photo.image = image
        scroll.photo.contentMode = .scaleAspectFit
        scroll.addSubview(scroll.photo)
        context.coordinator.photo = scroll.photo
        return scroll
    }
    func updateUIView(_ uiView: UIScrollView, context: Context) {
        if context.coordinator.lastRequestedZoom != zoom {
            uiView.setZoomScale(zoom, animated: false)
            context.coordinator.lastRequestedZoom = zoom
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var photo: UIImageView?
        var lastRequestedZoom: CGFloat = 1
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { photo }
    }
    final class PhotoScrollView: UIScrollView {
        let photo = UIImageView()
        private var previousSize = CGSize.zero
        override func layoutSubviews() {
            super.layoutSubviews()
            if previousSize != bounds.size {
                previousSize = bounds.size
                zoomScale = 1
                photo.frame = CGRect(origin: .zero, size: bounds.size)
                contentSize = bounds.size
            }
        }
    }
}