import CryptoKit
import Darwin
import Foundation

struct LoginWallpaperStatus: Equatable {
    let isInstalled: Bool
    let isReady: Bool
    let installedAt: Date?

    static let notInstalled = LoginWallpaperStatus(
        isInstalled: false,
        isReady: false,
        installedAt: nil
    )
}

enum LoginWallpaperError: Error, LocalizedError {
    case helperMissing
    case rendererMissing
    case videoRequired
    case configurationWriteFailed
    case verificationFailed
    case administratorOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            "The Lock Screen installer component is missing. Reinstall Wallpaper Studio from the DMG."
        case .rendererMissing:
            "The Login Window video renderer is missing. Reinstall Wallpaper Studio from the DMG."
        case .videoRequired:
            "Choose a video from the Library for the Lock Screen."
        case .configurationWriteFailed:
            "The Login Window video settings couldn't be prepared."
        case .verificationFailed:
            "The Lock Screen poster was copied, but the installation couldn't be verified."
        case let .administratorOperationFailed(message):
            message.isEmpty
                ? "The Lock Screen update was cancelled or denied."
                : "The Lock Screen update failed: \(message)"
        }
    }
}

private struct InstalledLoginWallpaperState: Codable {
    let schemaVersion: Int
    let installedAt: Date
    let videoSHA256: String
    let configurationSHA256: String
    let rendererPath: String
    let agentPath: String
}

private struct InstalledPosterState: Codable {
    let targetPath: String
    let backupExisted: Bool
    let userID: UInt32
}

/// Detects and removes obsolete Lock Screen integrations from earlier builds.
final class LoginWallpaperService: @unchecked Sendable {
    private let fileManager: FileManager

    private let supportURL = URL(
        fileURLWithPath: "/Library/Application Support/Wallpaper Studio/Login Wallpaper",
        isDirectory: true
    )
    private let agentURL = URL(
        fileURLWithPath: "/Library/LaunchAgents/com.wallpaperstudio.login-wallpaper.plist"
    )
    private let legacyAerialStateURL = URL(
        fileURLWithPath: "/Library/Application Support/Wallpaper Studio/Aerial/State.plist"
    )
    private let legacyAerialDaemonURL = URL(
        fileURLWithPath: "/Library/LaunchDaemons/com.wallpaperstudio.aerial-maintainer.plist"
    )
    private let posterSupportURL = URL(
        fileURLWithPath: "/Library/Application Support/Wallpaper Studio/Lock Poster",
        isDirectory: true
    )
    private let posterDaemonURL = URL(
        fileURLWithPath: "/Library/LaunchDaemons/com.wallpaperstudio.lock-poster.plist"
    )

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var status: LoginWallpaperStatus {
        let posterStateURL = posterSupportURL.appendingPathComponent("State.plist")
        let installedPosterURL = posterSupportURL.appendingPathComponent("Selected.png")
        if let data = try? Data(contentsOf: posterStateURL),
           let state = try? PropertyListDecoder().decode(InstalledPosterState.self, from: data)
        {
            let targetURL = URL(fileURLWithPath: state.targetPath)
            let ready = fileManager.fileExists(atPath: posterDaemonURL.path)
                && fileManager.contentsEqual(
                    atPath: installedPosterURL.path,
                    andPath: targetURL.path
                )
            return LoginWallpaperStatus(isInstalled: true, isReady: ready, installedAt: nil)
        }
        let stateURL = supportURL.appendingPathComponent("State.plist")
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? PropertyListDecoder().decode(
                  InstalledLoginWallpaperState.self,
                  from: data
              )
        else {
            let hasLegacyInstallation = fileManager.fileExists(atPath: supportURL.path)
                || fileManager.fileExists(atPath: agentURL.path)
                || fileManager.fileExists(atPath: legacyAerialStateURL.path)
                || fileManager.fileExists(atPath: legacyAerialDaemonURL.path)
            return hasLegacyInstallation
                ? LoginWallpaperStatus(isInstalled: true, isReady: false, installedAt: nil)
                : .notInstalled
        }
        let videoURL = supportURL.appendingPathComponent("Background.mov")
        let configurationURL = supportURL.appendingPathComponent("Configuration.plist")
        let rendererURL = URL(fileURLWithPath: state.rendererPath)
        let declaredAgentURL = URL(fileURLWithPath: state.agentPath)
        let isReady = fileManager.fileExists(atPath: rendererURL.path)
            && declaredAgentURL.standardizedFileURL == agentURL.standardizedFileURL
            && fileManager.fileExists(atPath: agentURL.path)
            && Self.sha256(of: videoURL) == state.videoSHA256
            && Self.sha256(of: configurationURL) == state.configurationSHA256
        return LoginWallpaperStatus(
            isInstalled: true,
            isReady: isReady,
            installedAt: state.installedAt
        )
    }

    var hasLegacyIntegration: Bool {
        fileManager.fileExists(atPath: supportURL.path)
            || fileManager.fileExists(atPath: agentURL.path)
            || fileManager.fileExists(atPath: legacyAerialStateURL.path)
            || fileManager.fileExists(atPath: legacyAerialDaemonURL.path)
    }

    func installPoster(_ posterURL: URL) async throws {
        guard fileManager.fileExists(atPath: posterURL.path) else {
            throw LoginWallpaperError.videoRequired
        }
        let helperURL = try bundledHelperURL()
        try await Self.runAsAdministrator(
            executable: helperURL,
            arguments: ["install-poster", posterURL.path, String(getuid())]
        )
        guard status.isReady else { throw LoginWallpaperError.verificationFailed }
    }

    func uninstall() async throws {
        let helperURL = try bundledHelperURL()
        try await Self.runAsAdministrator(
            executable: helperURL,
            arguments: ["uninstall", String(getuid())]
        )
    }

    private func bundledHelperURL() throws -> URL {
        guard let resources = Bundle.main.resourceURL else {
            throw LoginWallpaperError.helperMissing
        }
        let helper = resources
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("LoginWallpaperInstaller")
        guard fileManager.isExecutableFile(atPath: helper.path) else {
            throw LoginWallpaperError.helperMissing
        }
        return helper
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let data = try? handle.read(upToCount: 4 * 1_024 * 1_024) else { return nil }
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func runAsAdministrator(executable: URL, arguments: [String]) async throws {
        try await Task.detached(priority: .userInitiated) {
            let appleScript = """
            on run argv
                set commandText to quoted form of item 1 of argv
                repeat with argumentIndex from 2 to count of argv
                    set commandText to commandText & " " & quoted form of item argumentIndex of argv
                end repeat
                do shell script commandText with administrator privileges
            end run
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript, executable.path] + arguments
            let errorPipe = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                throw LoginWallpaperError.administratorOperationFailed(error.localizedDescription)
            }
            guard process.terminationStatus == 0 else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw LoginWallpaperError.administratorOperationFailed(message)
            }
        }.value
    }
}
