import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreTransferable
import CryptoKit

enum ArchiveError: LocalizedError {
    case unsupportedMedia, unreadableImage, invalidURL, emptyTitle, duplicateTag, missingFile
    var errorDescription: String? {
        switch self {
        case .unsupportedMedia: "This file is not a supported image or video."
        case .unreadableImage: "The image could not be read. The original selection has not been changed."
        case .invalidURL: "Enter a complete http or https source URL."
        case .emptyTitle: "Please enter a name."
        case .duplicateTag: "A tag with this name already exists."
        case .missingFile: "The original media is unavailable. You can still edit this record."
        }
    }
}

/// PhotosPicker's temporary URL is copied before the transfer callback returns.
struct ImportedFile: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { received in
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: target)
            return ImportedFile(url: target)
        }
    }
}

actor MediaStorage {
    static let shared = MediaStorage()
    nonisolated static var root: URL {
        var folder = "FoodArchiveMedia"
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { folder = "FoodArchiveUITestMedia" }
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { folder = "FoodArchivePreviewMedia" }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folder, isDirectory: true)
    }
    nonisolated static func url(for path: String) -> URL { root.appendingPathComponent(path) }

    func ingest(_ source: URL) async throws -> MediaPayload {
        try Task.checkCancellation()
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: source.pathExtension)
            ?? (try? source.resourceValues(forKeys: [.contentTypeKey]).contentType)
        let kind: MediaKind
        if type?.conforms(to: .movie) == true { kind = .video }
        else if type?.conforms(to: .image) == true { kind = .image }
        else { throw ArchiveError.unsupportedMedia }

        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let id = UUID()
        let digest = try checksum(source)
        let originalPath = "\(digest)_\(id.uuidString).\(source.pathExtension)"
        let thumbnailPath = "\(id.uuidString).jpg"
        let original = Self.url(for: originalPath)
        let thumbnail = Self.url(for: thumbnailPath)
        do {
            try FileManager.default.copyItem(at: source, to: original)
            let image: CGImage
            let width: Int
            let height: Int
            var duration: Double = 0
            if kind == .image {
                guard let input = CGImageSourceCreateWithURL(original as CFURL, nil),
                      let preview = Self.downsample(input, pixels: 900) else { throw ArchiveError.unreadableImage }
                image = preview
                let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any]
                width = properties?[kCGImagePropertyPixelWidth] as? Int ?? preview.width
                height = properties?[kCGImagePropertyPixelHeight] as? Int ?? preview.height
            } else {
                let asset = AVURLAsset(url: original)
                let loadedDuration = try await asset.load(.duration).seconds
                duration = loadedDuration.isFinite ? max(0, loadedDuration) : 0
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 900, height: 900)
                let result = try await generator.image(at: .zero)
                image = result.image
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    let size = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let displayed = size.applying(transform)
                    width = Int(abs(displayed.width))
                    height = Int(abs(displayed.height))
                } else {
                    width = image.width
                    height = image.height
                }
            }
            try Task.checkCancellation()
            guard let destination = CGImageDestinationCreateWithURL(thumbnail as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw ArchiveError.unreadableImage }
            CGImageDestinationAddImage(destination, Self.onWhite(image), [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ArchiveError.unreadableImage }
            return MediaPayload(id: id, originalPath: originalPath, thumbnailPath: thumbnailPath,
                                kind: kind, width: width, height: height, duration: duration)
        } catch {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: thumbnail)
            throw error
        }
    }

    private func checksum(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func downsample(_ source: CGImageSource, pixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    /// JPEG has no alpha. Composite transparent cutouts onto the canvas, not black.
    nonisolated private static func onWhite(_ image: CGImage) -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    func imageData(path: String, maximumPixels: Int = 900) throws -> Data {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(Self.url(for: path) as CFURL, nil),
              let image = Self.downsample(source, pixels: maximumPixels),
              let data = UIImage(cgImage: Self.onWhite(image)).jpegData(compressionQuality: 0.9)
        else { throw ArchiveError.missingFile }
        return data
    }

    func remove(paths: [String]) throws {
        for path in Set(paths) where !path.isEmpty {
            let url = Self.url(for: path)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()
    init() {
        cache.totalCostLimit = 48 * 1024 * 1024
        cache.countLimit = 120
    }
    func image(path: String) async throws -> UIImage {
        if let image = cache.object(forKey: path as NSString) { return image }
        let data = try await MediaStorage.shared.imageData(path: path)
        try Task.checkCancellation()
        guard let image = UIImage(data: data) else { throw ArchiveError.unreadableImage }
        cache.setObject(image, forKey: path as NSString, cost: Int(image.size.width * image.size.height * 4))
        return image
    }
}