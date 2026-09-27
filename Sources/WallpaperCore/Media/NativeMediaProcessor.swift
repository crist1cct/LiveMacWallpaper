@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct NativeMediaProcessor: MediaProcessing {
    private let ffmpegURL: URL?
    private let commandRunner: any CommandRunning

    public init(
        ffmpegURL: URL? = nil,
        commandRunner: any CommandRunning = FoundationCommandRunner()
    ) {
        self.ffmpegURL = ffmpegURL ?? Self.locateFFmpeg()
        self.commandRunner = commandRunner
    }

    public func prepare(
        sourceURL: URL,
        kind: MediaKind,
        outputDirectory: URL,
        quality: MediaQuality,
        progress: @escaping @Sendable (ImportPhase) -> Void
    ) async throws -> PreparedMedia {
        switch kind {
        case .image:
            return try prepareImage(
                sourceURL: sourceURL,
                outputDirectory: outputDirectory,
                progress: progress
            )
        case .video:
            return try await prepareVideo(
                sourceURL: sourceURL,
                outputDirectory: outputDirectory,
                quality: quality,
                progress: progress
            )
        }
    }

    private func prepareImage(
        sourceURL: URL,
        outputDirectory: URL,
        progress: @escaping @Sendable (ImportPhase) -> Void
    ) throws -> PreparedMedia {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw MediaProcessingError.invalidImage
        }

        progress(.generatingPreview)
        guard let poster = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 720,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary
              )
        else {
            throw MediaProcessingError.previewGenerationFailed
        }

        let preparedExtension = safeExtension(sourceURL.pathExtension, fallback: "img")
        let preparedFilename = "prepared.\(preparedExtension)"
        let preparedURL = outputDirectory.appendingPathComponent(preparedFilename)
        if preparedURL != sourceURL {
            try FileManager.default.copyItem(at: sourceURL, to: preparedURL)
        }

        let posterFilename = "poster.jpg"
        let thumbnailFilename = "thumbnail.jpg"
        try writeJPEG(poster, to: outputDirectory.appendingPathComponent(posterFilename), quality: 0.9)
        try writeJPEG(thumbnail, to: outputDirectory.appendingPathComponent(thumbnailFilename), quality: 0.82)

        return PreparedMedia(
            kind: .image,
            duration: nil,
            pixelSize: PixelSize(width: width, height: height),
            codec: nil,
            preparedFilename: preparedFilename,
            thumbnailFilename: thumbnailFilename,
            posterFilename: posterFilename
        )
    }

    private func prepareVideo(
        sourceURL: URL,
        outputDirectory: URL,
        quality: MediaQuality,
        progress: @escaping @Sendable (ImportPhase) -> Void
    ) async throws -> PreparedMedia {
        progress(.inspecting)

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceTrack = tracks.first else {
            throw MediaProcessingError.missingVideoTrack
        }

        let naturalSize = try await sourceTrack.load(.naturalSize)
        let transform = try await sourceTrack.load(.preferredTransform)
        let formatDescriptions = try await sourceTrack.load(.formatDescriptions)
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let displaySize = PixelSize(
            width: max(1, Int(abs(transformed.width).rounded())),
            height: max(1, Int(abs(transformed.height).rounded()))
        )
        let codec = formatDescriptions.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
        let sourcePreview = try? await generatePreviewImage(asset: asset, duration: duration)

        let composition = AVMutableComposition()
        guard let destinationTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MediaProcessingError.unreadableMedia
        }

        let timeRange = CMTimeRange(start: .zero, duration: duration)
        try destinationTrack.insertTimeRange(timeRange, of: sourceTrack, at: .zero)
        destinationTrack.preferredTransform = transform

        // Keep the source audio for the native Library preview. Desktop and
        // Screen Saver playback remain muted by their respective renderers.
        if let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let destinationAudioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? destinationAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
        }

        progress(.preparing(progress: nil))
        let preparedFilename = try await preparePlayableVideo(
            sourceURL: sourceURL,
            composition: composition,
            outputDirectory: outputDirectory,
            quality: quality,
            pixelSize: displaySize,
            allowsPassthrough: sourcePreview != nil
        )

        progress(.generatingPreview)
        let previewImage: CGImage
        if let sourcePreview {
            previewImage = sourcePreview
        } else {
            let preparedURL = outputDirectory.appendingPathComponent(preparedFilename)
            do {
                let preparedAsset = AVURLAsset(url: preparedURL)
                let preparedDuration = try await preparedAsset.load(.duration)
                previewImage = try await generatePreviewImage(
                    asset: preparedAsset,
                    duration: preparedDuration
                )
            } catch {
                throw MediaProcessingError.previewGenerationFailed
            }
        }

        let posterFilename = "poster.jpg"
        let thumbnailFilename = "thumbnail.jpg"
        try writeJPEG(previewImage, to: outputDirectory.appendingPathComponent(posterFilename), quality: 0.9)

        let thumbnail = scaledImage(previewImage, maximumPixelSize: 720) ?? previewImage
        try writeJPEG(thumbnail, to: outputDirectory.appendingPathComponent(thumbnailFilename), quality: 0.82)

        let preparedCodec = await videoCodec(
            at: outputDirectory.appendingPathComponent(preparedFilename)
        )

        return PreparedMedia(
            kind: .video,
            duration: duration.seconds.isFinite ? duration.seconds : nil,
            pixelSize: displaySize,
            codec: preparedCodec ?? codec,
            preparedFilename: preparedFilename,
            thumbnailFilename: thumbnailFilename,
            posterFilename: posterFilename
        )
    }

    private func preparePlayableVideo(
        sourceURL: URL,
        composition: AVComposition,
        outputDirectory: URL,
        quality: MediaQuality,
        pixelSize: PixelSize,
        allowsPassthrough: Bool
    ) async throws -> String {
        let fileTypes: [(type: AVFileType, extensionName: String)] = [
            (.mov, "mov"),
            (.mp4, "mp4")
        ]

        for preset in exportPresets(
            for: quality,
            pixelSize: pixelSize,
            allowsPassthrough: allowsPassthrough
        ) {
            for fileType in fileTypes {
                try Task.checkCancellation()
                let compatible = await AVAssetExportSession.compatibility(
                    ofExportPreset: preset,
                    with: composition,
                    outputFileType: fileType.type
                )
                guard compatible,
                      let exportSession = AVAssetExportSession(asset: composition, presetName: preset)
                else {
                    continue
                }

                let filename = "prepared.\(fileType.extensionName)"
                let outputURL = outputDirectory.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: outputURL)

                do {
                    try await exportSession.export(to: outputURL, as: fileType.type)
                    return filename
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: outputURL)
                    throw CancellationError()
                } catch {
                    try? FileManager.default.removeItem(at: outputURL)
                    continue
                }
            }
        }

        if let ffmpegURL {
            let filename = "prepared.mp4"
            let outputURL = outputDirectory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: outputURL)
            if await transcodeWithFFmpeg(
                executableURL: ffmpegURL,
                sourceURL: sourceURL,
                outputURL: outputURL,
                quality: quality
            ) {
                return filename
            }
            throw MediaProcessingError.fallbackTranscodeFailed
        }

        guard allowsPassthrough else {
            throw MediaProcessingError.fallbackTranscoderUnavailable
        }

        // If AVFoundation decoded the source successfully, retaining the original is
        // a safe final fallback even when its container cannot be remuxed.
        if sourceURL.deletingLastPathComponent().standardizedFileURL
            == outputDirectory.standardizedFileURL {
            return sourceURL.lastPathComponent
        }
        let sourceExtension = safeExtension(sourceURL.pathExtension, fallback: "media")
        let filename = "prepared.\(sourceExtension)"
        let outputURL = outputDirectory.appendingPathComponent(filename)
        do {
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.copyItem(at: sourceURL, to: outputURL)
            return filename
        } catch {
            throw MediaProcessingError.exportFailed(error.localizedDescription)
        }
    }

    private func exportPresets(
        for quality: MediaQuality,
        pixelSize: PixelSize,
        allowsPassthrough: Bool
    ) -> [String] {
        let preferred: [String]
        switch quality {
        case .efficient:
            preferred = [
                AVAssetExportPresetHEVC1920x1080,
                AVAssetExportPreset1920x1080,
                AVAssetExportPresetHighestQuality
            ]
        case .native:
            if max(pixelSize.width, pixelSize.height) > 1920 {
                preferred = [
                    AVAssetExportPresetHEVC3840x2160,
                    AVAssetExportPreset3840x2160,
                    AVAssetExportPresetHEVCHighestQuality,
                    AVAssetExportPresetHighestQuality
                ]
            } else {
                preferred = [
                    AVAssetExportPresetHEVC1920x1080,
                    AVAssetExportPreset1920x1080,
                    AVAssetExportPresetHEVCHighestQuality,
                    AVAssetExportPresetHighestQuality
                ]
            }
        case .original:
            preferred = [
                AVAssetExportPresetPassthrough,
                AVAssetExportPresetHEVCHighestQuality,
                AVAssetExportPresetHighestQuality
            ]
        }

        if allowsPassthrough, !preferred.contains(AVAssetExportPresetPassthrough) {
            return preferred + [AVAssetExportPresetPassthrough]
        }
        return allowsPassthrough
            ? preferred
            : preferred.filter { $0 != AVAssetExportPresetPassthrough }
    }

    private func generatePreviewImage(asset: AVAsset, duration: CMTime) async throws -> CGImage {
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 1920, height: 1920)
        let seconds = duration.seconds.isFinite ? min(1, max(0, duration.seconds * 0.1)) : 0
        return try await imageGenerator.image(
            at: CMTime(seconds: seconds, preferredTimescale: 600)
        ).image
    }

    private func videoCodec(at url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first
        else {
            return nil
        }
        return fourCC(CMFormatDescriptionGetMediaSubType(description))
    }

    private func transcodeWithFFmpeg(
        executableURL: URL,
        sourceURL: URL,
        outputURL: URL,
        quality: MediaQuality
    ) async -> Bool {
        // Try to retain the original audio stream first. If its codec cannot be
        // placed in MP4, repeat without audio so visual import still succeeds.
        for preservesAudio in [true, false] {
            let commonArguments = ffmpegCommonArguments(
                sourceURL: sourceURL,
                outputURL: outputURL,
                quality: quality,
                preservesAudio: preservesAudio
            )
            let videoEncoders = [
                [
                    "-c:v", "h264_videotoolbox",
                    "-allow_sw", "1",
                    "-b:v", bitrate(for: quality),
                    "-pix_fmt", "yuv420p",
                    "-tag:v", "avc1"
                ],
                [
                    "-c:v", "mpeg4",
                    "-q:v", "3",
                    "-pix_fmt", "yuv420p",
                    "-tag:v", "mp4v"
                ]
            ]

            for videoEncoder in videoEncoders {
                try? FileManager.default.removeItem(at: outputURL)
                let arguments = commonArguments.encoderPrefix
                    + videoEncoder
                    + commonArguments.outputSuffix
                if let result = try? await commandRunner.run(
                    executableURL: executableURL,
                    arguments: arguments,
                    currentDirectoryURL: outputURL.deletingLastPathComponent()
                ), result.exitCode == 0, Self.isNonemptyFile(outputURL) {
                    return true
                }
            }
        }

        try? FileManager.default.removeItem(at: outputURL)
        return false
    }

    private func ffmpegCommonArguments(
        sourceURL: URL,
        outputURL: URL,
        quality: MediaQuality,
        preservesAudio: Bool
    ) -> (encoderPrefix: [String], outputSuffix: [String]) {
        var prefix = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-i", sourceURL.path,
            "-map", "0:v:0"
        ]
        var suffix: [String] = []
        if preservesAudio {
            prefix += ["-map", "0:a:0?"]
            suffix += ["-c:a", "copy"]
        } else {
            prefix += ["-an"]
        }
        if let scaleFilter = scaleFilter(for: quality) {
            prefix += ["-vf", scaleFilter]
        }
        return (
            prefix,
            suffix + ["-movflags", "+faststart", outputURL.path]
        )
    }

    private func scaleFilter(for quality: MediaQuality) -> String? {
        switch quality {
        case .efficient:
            "scale=1920:1080:force_original_aspect_ratio=decrease:force_divisible_by=2"
        case .native:
            "scale=3840:2160:force_original_aspect_ratio=decrease:force_divisible_by=2"
        case .original:
            nil
        }
    }

    private func bitrate(for quality: MediaQuality) -> String {
        switch quality {
        case .efficient: "8M"
        case .native: "20M"
        case .original: "24M"
        }
    }

    private static func locateFFmpeg() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(
            forResource: "ffmpeg",
            withExtension: nil,
            subdirectory: "Helpers"
        ) {
            candidates.append(bundled)
        }
        if let explicitPath = ProcessInfo.processInfo.environment["WALLPAPER_STUDIO_FFMPEG"] {
            candidates.append(URL(fileURLWithPath: explicitPath))
        }
        candidates += [
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Vendor/ffmpeg"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func isNonemptyFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        else {
            return false
        }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    private func writeJPEG(_ image: CGImage, to url: URL, quality: Double) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw MediaProcessingError.previewGenerationFailed
        }

        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw MediaProcessingError.previewGenerationFailed
        }
    }

    private func scaledImage(_ image: CGImage, maximumPixelSize: Int) -> CGImage? {
        let largest = max(image.width, image.height)
        guard largest > maximumPixelSize else { return image }
        let scale = CGFloat(maximumPixelSize) / CGFloat(largest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))

        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func safeExtension(_ value: String, fallback: String) -> String {
        let lowercased = value.lowercased()
        let allowed = CharacterSet.alphanumerics
        guard !lowercased.isEmpty,
              lowercased.unicodeScalars.allSatisfy(allowed.contains)
        else {
            return fallback
        }
        return lowercased
    }

    private func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(value)
    }
}
