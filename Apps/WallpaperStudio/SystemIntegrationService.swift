import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ServiceManagement
import WallpaperCore

@MainActor
final class SystemIntegrationService {
    static let rendererBundleIdentifier = "com.wallpaperstudio.renderer"
    static let configurationChangedNotification = Notification.Name(
        "com.wallpaperstudio.configurationChanged"
    )
    static let rendererReadyNotification = Notification.Name(
        "com.wallpaperstudio.rendererReady"
    )
    static let screenSaverConfigurationChangedNotification = Notification.Name(
        "com.wallpaperstudio.screenSaverConfigurationChanged"
    )

    private var rendererProcess: Process?

    var rendererURL: URL? {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/WallpaperRenderer.app")
    }

    var screenSaverSourceURL: URL? {
        Bundle.main.url(forResource: "Wallpaper Studio", withExtension: "saver")
    }

    var installedScreenSaverURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Screen Savers/Wallpaper Studio.saver")
    }

    var isScreenSaverInstalled: Bool {
        FileManager.default.fileExists(atPath: installedScreenSaverURL.path)
    }

    var isScreenSaverCurrent: Bool {
        guard let source = screenSaverSourceURL,
              let sourceVersion = Bundle(url: source)?.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String,
              let installedVersion = Bundle(url: installedScreenSaverURL)?.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String
        else {
            return false
        }
        return sourceVersion == installedVersion
    }

    var isScreenSaverSelected: Bool {
        let indexURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: indexURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else {
            return false
        }
        return Self.contains("com.apple.wallpaper.choice.screen-saver", in: root)
            && Self.contains(installedScreenSaverURL.absoluteString, in: root)
    }

    var loginItemStatus: SMAppService.Status {
        SMAppService.loginItem(identifier: Self.rendererBundleIdentifier).status
    }

    func setLoginItemEnabled(_ enabled: Bool) throws {
        let service = SMAppService.loginItem(identifier: Self.rendererBundleIdentifier)
        if enabled {
            guard let rendererURL,
                  FileManager.default.fileExists(atPath: rendererURL.path)
            else {
                throw SystemIntegrationError.rendererMissing
            }
            try service.register()
            startRendererIfAvailable()
        } else {
            try service.unregister()
            for application in NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.rendererBundleIdentifier
            ) {
                application.terminate()
            }
        }
    }

    @discardableResult
    func startRendererIfAvailable() -> Bool {
        guard let rendererURL else { return false }
        if isOwnRendererRunning(rendererURL: rendererURL) {
            return true
        }
        return launchRendererExecutable(from: rendererURL)
    }

    func startRendererAndWaitUntilReady(
        profileID: UUID,
        expectedDisplayIDs: Set<String>
    ) async -> Bool {
        guard let rendererURL,
              FileManager.default.fileExists(atPath: rendererURL.path)
        else {
            return false
        }

        let waiter = RendererReadinessWaiter(
            profileID: profileID,
            expectedDisplayIDs: expectedDisplayIDs
        )
        return await waiter.wait {
            if self.isOwnRendererRunning(rendererURL: rendererURL) {
                self.notifyRenderer()
            } else if !self.launchRendererExecutable(from: rendererURL) {
                waiter.finish(false)
            }
        }
    }

    func notifyRenderer() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.configurationChangedNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func isOwnRendererRunning(rendererURL: URL) -> Bool {
        let expectedURL = rendererURL.standardizedFileURL
        return NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.rendererBundleIdentifier
        ).contains { application in
            application.bundleURL?.standardizedFileURL == expectedURL
        }
    }

    private func launchRendererExecutable(from rendererURL: URL) -> Bool {
        let executableURL = rendererURL
            .appendingPathComponent("Contents/MacOS/WallpaperRenderer")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return false
        }

        let process = Process()
        process.executableURL = executableURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            rendererProcess = process
            return process.isRunning
        } catch {
            return false
        }
    }

    func installScreenSaver() throws {
        guard let source = screenSaverSourceURL,
              FileManager.default.fileExists(atPath: source.path)
        else {
            throw SystemIntegrationError.screenSaverMissing
        }

        let destination = installedScreenSaverURL
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".WallpaperStudio-\(UUID().uuidString).saver")
        try FileManager.default.copyItem(at: source, to: temporary)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        terminateLegacyScreenSaverHost()
    }

    func configureScreenSaver(
        item: MediaItem,
        mediaURL: URL,
        configuration: DestinationConfiguration,
        cacheDirectory: URL
    ) async throws {
        let playbackURL: URL
        if item.kind == .video {
            playbackURL = try await ScreenSaverMediaOptimizer().optimize(
                sourceURL: mediaURL,
                item: item,
                displayTarget: configuration.displayTarget,
                displays: DisplayCatalog.connectedDisplays,
                cacheDirectory: cacheDirectory
            )
        } else {
            playbackURL = mediaURL
        }
        try ScreenSaverRuntimeStore.sharedForCurrentUser().configure(
            item: item,
            sourceURL: playbackURL,
            scaling: configuration.scaling,
            zoom: configuration.zoom,
            horizontalPosition: configuration.horizontalPosition,
            verticalPosition: configuration.verticalPosition,
            muteVideo: true,
            volume: 0,
            displayTarget: configuration.displayTarget
        )
        guard try ScreenSaverRuntimeStore.sharedForCurrentUser().load()?.configuration.displayTarget
            == configuration.displayTarget
        else {
            throw SystemIntegrationError.screenSaverVerificationFailed
        }
        notifyScreenSaver()
    }

    func clearScreenSaverConfiguration() throws {
        try ScreenSaverRuntimeStore.sharedForCurrentUser().clear()
        notifyScreenSaver()
    }

    func notifyScreenSaver() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.screenSaverConfigurationChangedNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    func startScreenSaver() async throws -> NSRunningApplication {
        let engineURL = URL(
            fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: engineURL.path) else {
            throw SystemIntegrationError.screenSaverEngineMissing
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: engineURL,
                configuration: configuration
            ) { application, error in
                if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(
                        throwing: error ?? SystemIntegrationError.screenSaverEngineMissing
                    )
                }
            }
        }
    }

    func requestNativeLockScreen() throws {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw SystemIntegrationError.lockScreenPermissionRequired
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 12,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 12,
                  keyDown: false
              )
        else {
            throw SystemIntegrationError.lockScreenRequestFailed
        }
        keyDown.flags = [.maskCommand, .maskControl]
        keyUp.flags = [.maskCommand, .maskControl]
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    func waitForTermination(of application: NSRunningApplication) async {
        while !application.isTerminated {
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
        }
    }

    func waitForSessionReactivation() async {
        let waiter = SessionReactivationWaiter()
        await waiter.wait()
    }

    private func terminateLegacyScreenSaverHost() {
        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.ScreenSaver.Engine.legacyScreenSaver"
        ) {
            application.terminate()
        }
    }

    func openScreenSaverSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLockScreenSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealApplicationSupport(_ directories: AppDirectories) {
        NSWorkspace.shared.activateFileViewerSelecting([directories.root])
    }

    private static func contains(_ expected: String, in value: Any) -> Bool {
        if let string = value as? String { return string == expected }
        if let data = value as? Data,
           let nested = try? PropertyListSerialization.propertyList(from: data, format: nil)
        {
            return contains(expected, in: nested)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains { contains(expected, in: $0) }
        }
        if let array = value as? [Any] {
            return array.contains { contains(expected, in: $0) }
        }
        return false
    }
}

@MainActor
private final class SessionReactivationWaiter {
    private var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.finish()
                }
            }
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        continuation.resume()
    }
}

@MainActor
private final class RendererReadinessWaiter {
    private let profileID: UUID
    private let expectedDisplayIDs: Set<String>
    private var observer: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<Bool, Never>?

    init(profileID: UUID, expectedDisplayIDs: Set<String>) {
        self.profileID = profileID
        self.expectedDisplayIDs = expectedDisplayIDs
    }

    func wait(start: () -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            observer = DistributedNotificationCenter.default().addObserver(
                forName: SystemIntegrationService.rendererReadyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let readyProfileID = notification.userInfo?["profileID"] as? String
                let readyDisplayIDs = Set(
                    notification.userInfo?["displayIDs"] as? [String] ?? []
                )
                MainActor.assumeIsolated {
                    guard let self,
                          readyProfileID == self.profileID.uuidString,
                          readyDisplayIDs == self.expectedDisplayIDs
                    else {
                        return
                    }
                    self.finish(true)
                }
            }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(false)
            }
            start()
        }
    }

    func finish(_ ready: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
        continuation.resume(returning: ready)
    }
}

enum SystemIntegrationError: Error, LocalizedError {
    case rendererMissing
    case screenSaverMissing
    case screenSaverEngineMissing
    case screenSaverVerificationFailed
    case lockScreenPermissionRequired
    case lockScreenRequestFailed

    var errorDescription: String? {
        switch self {
        case .rendererMissing:
            "The launch-at-login component is missing from this build. Use the app from the DMG."
        case .screenSaverMissing:
            "The Screen Saver module is missing from this build. Use the app from the DMG."
        case .screenSaverEngineMissing:
            "The macOS Screen Saver engine couldn't be started."
        case .screenSaverVerificationFailed:
            "The Screen Saver display selection couldn't be confirmed."
        case .lockScreenPermissionRequired:
            "To lock natively, allow Wallpaper Studio in System Settings → Privacy & Security → Accessibility, then choose Lock again."
        case .lockScreenRequestFailed:
            "macOS rejected the lock command."
        }
    }
}
