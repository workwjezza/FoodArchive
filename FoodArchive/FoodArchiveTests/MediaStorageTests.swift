import XCTest
import UIKit
@testable import FoodArchive

@MainActor
final class MediaStorageTests: XCTestCase {
    func testTransparentCutoutGetsWhiteThumbnailWithoutChangingOriginal() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 40, y: 40, width: 20, height: 20))
        }
        let data = try XCTUnwrap(image.pngData())
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let payload = try await MediaStorage.shared.ingest(source)
        XCTAssertEqual(try Data(contentsOf: MediaStorage.url(for: payload.originalPath)), data)
        let thumbnail = try XCTUnwrap(UIImage(contentsOfFile: MediaStorage.url(for: payload.thumbnailPath).path)?.cgImage)
        let corner = try XCTUnwrap(thumbnail.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThanOrEqual(pixel[0], 245)
        XCTAssertGreaterThanOrEqual(pixel[1], 245)
        XCTAssertGreaterThanOrEqual(pixel[2], 245)
        try await MediaStorage.shared.remove(paths: [payload.originalPath, payload.thumbnailPath])
    }

    func testVideoImportCreatesPosterAndRetainsDimensionsAndDuration() async throws {
        let source = try XCTUnwrap(Bundle.main.url(forResource: "sample-pasta-study", withExtension: "mp4"))
        let payload = try await MediaStorage.shared.ingest(source)
        XCTAssertEqual(payload.kind, .video)
        XCTAssertEqual(payload.width, 600)
        XCTAssertEqual(payload.height, 600)
        XCTAssertEqual(payload.duration, 3, accuracy: 0.1)
        XCTAssertNotNil(UIImage(contentsOfFile: MediaStorage.url(for: payload.thumbnailPath).path))
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: MediaStorage.url(for: payload.originalPath)))
        try await MediaStorage.shared.remove(paths: [payload.originalPath, payload.thumbnailPath])
    }

    func testUnsupportedFileFailsWithoutChangingSource() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
        let data = Data("Keep this original.".utf8)
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        do {
            _ = try await MediaStorage.shared.ingest(source)
            XCTFail("A text file must not be imported as media.")
        } catch {
            XCTAssertEqual(try Data(contentsOf: source), data)
        }
    }
}