import Foundation

public struct YouTubeMetadata: Codable, Hashable, Sendable {
    public let videoID: String
    public let title: String
    public let channel: String?
    public let duration: TimeInterval?
    public let thumbnailURL: URL?
    public let webpageURL: URL

    public init(
        videoID: String,
        title: String,
        channel: String?,
        duration: TimeInterval?,
        thumbnailURL: URL?,
        webpageURL: URL
    ) {
        self.videoID = videoID
        self.title = title
        self.channel = channel
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.webpageURL = webpageURL
    }
}

public struct MediaRightsConfirmation: Sendable, Equatable {
    public static let currentVersion = 1

    public let acceptedVersion: Int
    public let confirmedAt: Date

    public init(acceptedVersion: Int, confirmedAt: Date = .now) {
        self.acceptedVersion = acceptedVersion
        self.confirmedAt = confirmedAt
    }

    public static func confirmedNow() -> MediaRightsConfirmation {
        MediaRightsConfirmation(acceptedVersion: currentVersion)
    }
}

public enum YouTubeImportPhase: Sendable, Equatable {
    case validatingURL
    case readingMetadata
    case downloading(progress: Double?)
    case preparingMedia(ImportPhase)
    case completed
}

public enum YouTubeHelperStatus: Sendable, Equatable {
    case unavailable
    case ready(version: String)
    case failed(reason: String)
}

public struct YouTubeDownload: Sendable, Equatable {
    public let metadata: YouTubeMetadata
    public let fileURL: URL

    public init(metadata: YouTubeMetadata, fileURL: URL) {
        self.metadata = metadata
        self.fileURL = fileURL
    }
}

public enum YouTubeImportError: Error, Equatable, LocalizedError {
    case invalidURL
    case rightsConfirmationRequired
    case helperUnavailable
    case metadataUnavailable(String)
    case videoTooLong(limit: TimeInterval)
    case downloadFailed(String)
    case downloadedFileMissing
    case downloadedFileTooLarge(limitBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a valid YouTube video, Short, Live, or youtu.be URL."
        case .rightsConfirmationRequired:
            "Confirm that you own the video or have permission to download and use it."
        case .helperUnavailable:
            "The YouTube import helper is not installed in this build."
        case let .metadataUnavailable(message):
            "YouTube metadata could not be loaded: \(message)."
        case let .videoTooLong(limit):
            "The video is longer than the \(Int(limit / 60))-minute import limit."
        case let .downloadFailed(message):
            "The YouTube video could not be downloaded: \(message)."
        case .downloadedFileMissing:
            "The YouTube helper finished without producing a video file."
        case let .downloadedFileTooLarge(limitBytes):
            "The downloaded video exceeds the \(limitBytes / 1_000_000_000) GB import limit."
        }
    }
}

public struct YouTubeImportService: Sendable {
    public struct Limits: Sendable, Equatable {
        public var maximumDuration: TimeInterval
        public var maximumFileSize: Int64

        public init(
            maximumDuration: TimeInterval = 2 * 60 * 60,
            maximumFileSize: Int64 = 2_000_000_000
        ) {
            self.maximumDuration = maximumDuration
            self.maximumFileSize = maximumFileSize
        }
    }

    private let commandRunner: any CommandRunning
    private let helperLocator: any YouTubeHelperLocating
    private let ffmpegLocator: any YouTubeFFmpegLocating
    private let limits: Limits

    public init(
        commandRunner: any CommandRunning = FoundationCommandRunner(),
        helperLocator: any YouTubeHelperLocating = DefaultYouTubeHelperLocator(),
        ffmpegLocator: any YouTubeFFmpegLocating = DefaultYouTubeFFmpegLocator(),
        limits: Limits = Limits()
    ) {
        self.commandRunner = commandRunner
        self.helperLocator = helperLocator
        self.ffmpegLocator = ffmpegLocator
        self.limits = limits
    }

    public func helperStatus() async -> YouTubeHelperStatus {
        guard let helperURL = helperLocator.executableURL() else {
            return .unavailable
        }

        do {
            let result = try await commandRunner.run(
                executableURL: helperURL,
                arguments: ["--version"],
                currentDirectoryURL: nil
            )
            guard result.exitCode == 0 else {
                return .failed(reason: Self.safeErrorMessage(from: result.standardError))
            }

            let version = String(data: result.standardOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let version, !version.isEmpty else {
                return .failed(reason: "The helper did not report a version.")
            }
            return .ready(version: String(version.prefix(80)))
        } catch {
            return .failed(reason: "The helper could not be started.")
        }
    }

    public func inspect(_ rawURL: String) async throws -> YouTubeMetadata {
        let youtubeURL = try YouTubeURL(rawURL)
        guard let helperURL = helperLocator.executableURL() else {
            throw YouTubeImportError.helperUnavailable
        }

        let result = try await commandRunner.run(
            executableURL: helperURL,
            arguments: [
                "--ignore-config",
                "--no-playlist",
                "--skip-download",
                "--dump-single-json",
                "--no-warnings",
                youtubeURL.normalizedURL.absoluteString
            ],
            currentDirectoryURL: nil
        )

        guard result.exitCode == 0 else {
            throw YouTubeImportError.metadataUnavailable(Self.safeErrorMessage(from: result.standardError))
        }

        let metadata: YouTubeMetadata
        do {
            let payload = try JSONDecoder().decode(YTDLPMetadata.self, from: result.standardOutput)
            metadata = YouTubeMetadata(
                videoID: payload.id,
                title: payload.title,
                channel: payload.channel ?? payload.uploader,
                duration: payload.duration,
                thumbnailURL: payload.thumbnail.flatMap(URL.init(string:)),
                webpageURL: payload.webpageURL.flatMap(URL.init(string:)) ?? youtubeURL.normalizedURL
            )
        } catch {
            throw YouTubeImportError.metadataUnavailable("The helper returned an invalid response.")
        }

        if let duration = metadata.duration, duration > limits.maximumDuration {
            throw YouTubeImportError.videoTooLong(limit: limits.maximumDuration)
        }
        return metadata
    }

    public func download(
        _ rawURL: String,
        to destinationDirectory: URL,
        rightsConfirmation: MediaRightsConfirmation,
        progress: @escaping @Sendable (YouTubeImportPhase) -> Void = { _ in }
    ) async throws -> YouTubeDownload {
        guard rightsConfirmation.acceptedVersion == MediaRightsConfirmation.currentVersion else {
            throw YouTubeImportError.rightsConfirmationRequired
        }

        progress(.validatingURL)
        let youtubeURL = try YouTubeURL(rawURL)
        guard let helperURL = helperLocator.executableURL() else {
            throw YouTubeImportError.helperUnavailable
        }

        progress(.readingMetadata)
        let metadata = try await inspect(youtubeURL.normalizedURL.absoluteString)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        progress(.downloading(progress: nil))
        let outputTemplate = destinationDirectory
            .appendingPathComponent("youtube-source.%(ext)s")
            .path
        var downloadArguments = [
            "--ignore-config",
            "--no-playlist",
            "--no-warnings",
            "--newline",
            "--restrict-filenames",
            "--max-filesize", String(limits.maximumFileSize)
        ]
        if let ffmpegURL = ffmpegLocator.executableURL() {
            downloadArguments += [
                "--ffmpeg-location", ffmpegURL.path,
                "--format", "bestvideo*+bestaudio/best",
                "--format-sort", "res,fps,hdr:12,vbr,abr",
                "--merge-output-format", "mp4"
            ]
        } else {
            // Maximum video quality remains available even in an unpackaged
            // development build that does not contain the merging helper.
            downloadArguments += ["--format", "bestvideo*/best"]
        }
        downloadArguments += [
            "--output", outputTemplate,
            youtubeURL.normalizedURL.absoluteString
        ]
        let result = try await commandRunner.run(
            executableURL: helperURL,
            arguments: downloadArguments,
            currentDirectoryURL: destinationDirectory
        )

        guard result.exitCode == 0 else {
            throw YouTubeImportError.downloadFailed(Self.safeErrorMessage(from: result.standardError))
        }

        let candidates = try FileManager.default.contentsOfDirectory(
            at: destinationDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter {
            $0.lastPathComponent.hasPrefix("youtube-source.") && $0.pathExtension != "part"
        }

        guard let fileURL = candidates.first else {
            throw YouTubeImportError.downloadedFileMissing
        }

        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw YouTubeImportError.downloadedFileMissing
        }
        if Int64(values.fileSize ?? 0) > limits.maximumFileSize {
            try? FileManager.default.removeItem(at: fileURL)
            throw YouTubeImportError.downloadedFileTooLarge(limitBytes: limits.maximumFileSize)
        }

        progress(.completed)
        return YouTubeDownload(metadata: metadata, fileURL: fileURL)
    }

    public func importIntoLibrary(
        _ rawURL: String,
        library: MediaLibrary,
        directories: AppDirectories,
        rightsConfirmation: MediaRightsConfirmation,
        quality: MediaQuality = .original,
        progress: @escaping @Sendable (YouTubeImportPhase) -> Void = { _ in }
    ) async throws -> MediaItem {
        let jobDirectory = directories.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: jobDirectory) }

        let download = try await download(
            rawURL,
            to: jobDirectory,
            rightsConfirmation: rightsConfirmation,
            progress: progress
        )

        let origin = MediaOrigin.youtube(
            videoID: download.metadata.videoID,
            webpageURL: download.metadata.webpageURL,
            channel: download.metadata.channel
        )
        return try await library.importLocalFile(
            download.fileURL,
            title: download.metadata.title,
            origin: origin,
            quality: quality
        ) { phase in
            progress(.preparingMedia(phase))
        }
    }

    private static func safeErrorMessage(from data: Data) -> String {
        let raw = String(data: data, encoding: .utf8) ?? "Unknown helper error."
        let singleLine = raw
            .split(whereSeparator: \Character.isNewline)
            .suffix(3)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(600))
    }
}

private struct YTDLPMetadata: Decodable {
    let id: String
    let title: String
    let channel: String?
    let uploader: String?
    let duration: TimeInterval?
    let thumbnail: String?
    let webpageURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case channel
        case uploader
        case duration
        case thumbnail
        case webpageURL = "webpage_url"
    }
}
