import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Reproducible artwork for the app icon and a clearly labeled sample motion study.
/// Usage: swift MakePreviewAssets.swift /absolute/path/to/FoodArchive
@main
struct MakePreviewAssets {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "PreviewAssets", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pass the FoodArchive project directory."])
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let app = root.appendingPathComponent("FoodArchive")
        let iconDirectory = app.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
        try FileManager.default.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
        try makeIcon(at: iconDirectory.appendingPathComponent("AppIcon.png"))
        let imageURL = app.appendingPathComponent("Resources/sample-pasta.jpg")
        let videoURL = app.appendingPathComponent("Resources/sample-pasta-study.mp4")
        if FileManager.default.fileExists(atPath: videoURL.path) {
            print("Existing video preserved: \(videoURL.path)")
        } else {
            try await makeVideo(from: imageURL, to: videoURL)
        }
        print("Preview assets ready.")
    }

    private static func makeIcon(at url: URL) throws {
        guard let context = CGContext(data: nil, width: 1024, height: 1024,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        context.setStrokeColor(CGColor(gray: 0.067, alpha: 1))
        context.setLineWidth(13)
        context.strokeEllipse(in: CGRect(x: 192, y: 192, width: 640, height: 640))
        context.setLineWidth(3)
        context.strokeEllipse(in: CGRect(x: 227, y: 227, width: 570, height: 570))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let text = "FA" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 162, weight: .regular),
            .foregroundColor: NSColor(white: 0.067, alpha: 1)
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (1024 - size.width) / 2, y: (1024 - size.height) / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func makeVideo(from imageURL: URL, to videoURL: URL) async throws {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let side = 600
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: side,
            kCVPixelBufferHeightKey as String: side,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32ARGB, nil, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side,
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let scale = max(Double(side) / Double(image.width), Double(side) / Double(image.height))
                * (1 + Double(frame) / 60 * 0.04)
            let width = Double(image.width) * scale, height = Double(image.height) * scale
            context.draw(image, in: CGRect(x: (Double(side) - width) / 2, y: (Double(side) - height) / 2, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 20)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}