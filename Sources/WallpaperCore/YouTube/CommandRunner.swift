import Foundation

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(exitCode: Int32, standardOutput: Data, standardError: Data) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol CommandRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?
    ) async throws -> CommandResult
}

public struct FoundationCommandRunner: CommandRunning {
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?
    ) async throws -> CommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectoryURL
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()

            let outputTask = Task.detached {
                outputPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let errorTask = Task.detached {
                errorPipe.fileHandleForReading.readDataToEndOfFile()
            }

            process.waitUntilExit()
            let output = await outputTask.value
            let error = await errorTask.value

            return CommandResult(
                exitCode: process.terminationStatus,
                standardOutput: output,
                standardError: error
            )
        }.value
    }
}

public protocol YouTubeHelperLocating: Sendable {
    func executableURL() -> URL?
}

public protocol YouTubeFFmpegLocating: Sendable {
    func executableURL() -> URL?
}

public struct DefaultYouTubeHelperLocator: YouTubeHelperLocating, @unchecked Sendable {
    private let fileManager: FileManager
    private let bundle: Bundle

    public init(fileManager: FileManager = .default, bundle: Bundle = .main) {
        self.fileManager = fileManager
        self.bundle = bundle
    }

    public func executableURL() -> URL? {
        var candidates: [URL] = []

        if let bundled = bundle.url(
            forResource: "yt-dlp_macos",
            withExtension: nil,
            subdirectory: "Helpers"
        ) {
            candidates.append(bundled)
        }

        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"),
            URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        ])

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

public struct DefaultYouTubeFFmpegLocator: YouTubeFFmpegLocating, @unchecked Sendable {
    private let fileManager: FileManager
    private let bundle: Bundle

    public init(fileManager: FileManager = .default, bundle: Bundle = .main) {
        self.fileManager = fileManager
        self.bundle = bundle
    }

    public func executableURL() -> URL? {
        var candidates: [URL] = []

        if let bundled = bundle.url(
            forResource: "ffmpeg",
            withExtension: nil,
            subdirectory: "Helpers"
        ) {
            candidates.append(bundled)
        }
        if let explicitPath = ProcessInfo.processInfo.environment["WALLPAPER_STUDIO_FFMPEG"] {
            candidates.append(URL(fileURLWithPath: explicitPath))
        }

        candidates.append(contentsOf: [
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Vendor/ffmpeg"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        ])

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
