import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WallpaperCore

@Suite("Native media processor")
struct NativeMediaProcessorTests {
    @Test("Prepares a real image with poster and thumbnail")
    func preparesImage() async throws {
        let temporary = try TemporaryDirectory()
        let sourceURL = temporary.url.appendingPathComponent("source.png")
        let outputURL = temporary.url.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try Self.writeTestImage(to: sourceURL)

        let prepared = try await NativeMediaProcessor().prepare(
            sourceURL: sourceURL,
            kind: .image,
            outputDirectory: outputURL,
            quality: .efficient
        ) { _ in }

        #expect(prepared.pixelSize == PixelSize(width: 64, height: 48))
        #expect(FileManager.default.fileExists(
            atPath: outputURL.appendingPathComponent(prepared.preparedFilename).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: outputURL.appendingPathComponent(prepared.posterFilename).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: outputURL.appendingPathComponent(prepared.thumbnailFilename).path
        ))
    }

    @Test("Prepares an opt-in real video regression fixture")
    func preparesExternalRegressionVideoWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["WALLPAPER_STUDIO_REGRESSION_VIDEO"]
        else {
            return
        }

        let temporary = try TemporaryDirectory()
        let outputURL = temporary.url.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let prepared = try await NativeMediaProcessor().prepare(
            sourceURL: URL(fileURLWithPath: path),
            kind: .video,
            outputDirectory: outputURL,
            quality: .native
        ) { _ in }

        #expect(prepared.kind == .video)
        #expect(prepared.pixelSize == PixelSize(width: 3840, height: 2160))
        #expect(FileManager.default.fileExists(
            atPath: outputURL.appendingPathComponent(prepared.preparedFilename).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: outputURL.appendingPathComponent(prepared.posterFilename).path
        ))
    }

    private static func writeTestImage(to url: URL) throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: 64,
                height: 48,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw MediaProcessingError.invalidImage
        }

        context.setFillColor(red: 0.12, green: 0.36, blue: 0.82, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              )
        else {
            throw MediaProcessingError.invalidImage
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaProcessingError.invalidImage
        }
    }
}
