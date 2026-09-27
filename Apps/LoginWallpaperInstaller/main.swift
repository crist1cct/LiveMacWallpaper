import Darwin
import Foundation

private enum Paths {
    static let overlaySupport = URL(fileURLWithPath: "/Library/Application Support/Wallpaper Studio/Login Wallpaper", isDirectory: true)
    static let overlayAgent = URL(fileURLWithPath: "/Library/LaunchAgents/com.wallpaperstudio.login-wallpaper.plist")
    static let overlayLabel = "com.wallpaperstudio.login-wallpaper"
    static let aerialSupport = URL(fileURLWithPath: "/Library/Application Support/Wallpaper Studio/Aerial", isDirectory: true)
    static let aerialState = aerialSupport.appendingPathComponent("State.plist")
    static let aerialDaemon = URL(fileURLWithPath: "/Library/LaunchDaemons/com.wallpaperstudio.aerial-maintainer.plist")
    static let aerialHelper = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.wallpaperstudio.aerial-maintainer")
    static let aerialLabel = "com.wallpaperstudio.aerial-maintainer"
    static let aerialRoot = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true).standardizedFileURL

    static let posterSupport = URL(fileURLWithPath: "/Library/Application Support/Wallpaper Studio/Lock Poster", isDirectory: true)
    static let poster = posterSupport.appendingPathComponent("Selected.png")
    static let posterBackup = posterSupport.appendingPathComponent("Original.png")
    static let posterState = posterSupport.appendingPathComponent("State.plist")
    static let posterDaemon = URL(fileURLWithPath: "/Library/LaunchDaemons/com.wallpaperstudio.lock-poster.plist")
    static let posterHelper = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.wallpaperstudio.lock-poster-maintainer")
    static let posterLabel = "com.wallpaperstudio.lock-poster"
}

private struct PosterState: Codable {
    let targetPath: String
    let backupExisted: Bool
    let userID: UInt32
}

private enum HelperError: Error, LocalizedError {
    case administratorRequired, invalidArguments, invalidUserID, invalidPoster, userNotFound

    var errorDescription: String? {
        switch self {
        case .administratorRequired: "Administrator privileges are required."
        case .invalidArguments: "The Lock Screen command is incomplete."
        case .invalidUserID: "The user session couldn't be identified."
        case .invalidPoster: "The Lock Screen image isn't valid."
        case .userNotFound: "The macOS account identifier couldn't be read."
        }
    }
}

private nonisolated(unsafe) let fileManager = FileManager.default

@discardableResult
private func run(_ executable: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run(); process.waitUntilExit(); return process.terminationStatus
    } catch { return -1 }
}

private func capture(_ executable: String, _ arguments: [String]) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run(); process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    } catch { return "" }
}

private func isSafeFile(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
    return values.isRegularFile == true && values.isSymbolicLink != true
}

private func replaceFile(_ source: URL, _ destination: URL) throws {
    guard isSafeFile(source) else { throw HelperError.invalidPoster }
    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    try fileManager.copyItem(at: source, to: temporary)
    if fileManager.fileExists(atPath: destination.path) {
        _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
    } else {
        try fileManager.moveItem(at: temporary, to: destination)
    }
}

private func parseUserID(_ value: String) throws -> uid_t {
    guard let parsed = UInt32(value), parsed > 0 else { throw HelperError.invalidUserID }
    return parsed
}

private func generatedUID(for userID: uid_t) throws -> String {
    guard let record = getpwuid(userID), let namePointer = record.pointee.pw_name else {
        throw HelperError.userNotFound
    }
    let name = String(cString: namePointer)
    let output = capture("/usr/bin/dscl", [".", "-read", "/Users/\(name)", "GeneratedUID"])
    guard let value = output.split(whereSeparator: \.isWhitespace).last,
          UUID(uuidString: String(value)) != nil
    else { throw HelperError.userNotFound }
    return String(value).uppercased()
}

private func restoreLegacyAerial() {
    guard let data = try? Data(contentsOf: Paths.aerialState),
          let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let dictionary = value as? [String: Any],
          let targetPath = dictionary["targetPath"] as? String ?? dictionary["target"] as? String,
          let backupPath = dictionary["backupPath"] as? String ?? dictionary["backup"] as? String
    else { return }
    let target = URL(fileURLWithPath: targetPath).standardizedFileURL
    let backup = URL(fileURLWithPath: backupPath).standardizedFileURL
    guard target.path.hasPrefix(Paths.aerialRoot.path + "/"), isSafeFile(backup) else { return }
    try? replaceFile(backup, target)
    _ = run("/usr/sbin/chown", ["root:wheel", target.path])
}

private func removeObsoleteIntegrations(userID: uid_t) {
    _ = run("/bin/launchctl", ["bootout", "gui/\(userID)/\(Paths.overlayLabel)"])
    _ = run("/usr/bin/killall", ["LoginWallpaperRenderer"])
    try? fileManager.removeItem(at: Paths.overlayAgent)
    try? fileManager.removeItem(at: Paths.overlaySupport)
    _ = run("/bin/launchctl", ["bootout", "system/\(Paths.aerialLabel)"])
    restoreLegacyAerial()
    try? fileManager.removeItem(at: Paths.aerialDaemon)
    try? fileManager.removeItem(at: Paths.aerialHelper)
    try? fileManager.removeItem(at: Paths.aerialSupport)
}

private func loadPosterState() -> PosterState? {
    guard let data = try? Data(contentsOf: Paths.posterState) else { return nil }
    return try? PropertyListDecoder().decode(PosterState.self, from: data)
}

private func maintainPoster() throws {
    guard let state = loadPosterState(), isSafeFile(Paths.poster) else { return }
    let target = URL(fileURLWithPath: state.targetPath).standardizedFileURL
    if !fileManager.contentsEqual(atPath: Paths.poster.path, andPath: target.path) {
        try replaceFile(Paths.poster, target)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        _ = run("/usr/sbin/chown", ["\(state.userID):staff", target.path])
    }
}

private func installMaintainer() throws {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    try replaceFile(executable, Paths.posterHelper)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.posterHelper.path)
    _ = run("/usr/sbin/chown", ["root:wheel", Paths.posterHelper.path])
    let plist: [String: Any] = [
        "Label": Paths.posterLabel,
        "ProgramArguments": [Paths.posterHelper.path, "maintain-poster"],
        "RunAtLoad": true,
        "StartInterval": 5,
        "ProcessType": "Background"
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: Paths.posterDaemon, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: Paths.posterDaemon.path)
    _ = run("/bin/launchctl", ["bootout", "system/\(Paths.posterLabel)"])
    _ = run("/bin/launchctl", ["bootstrap", "system", Paths.posterDaemon.path])
    _ = run("/bin/launchctl", ["kickstart", "-k", "system/\(Paths.posterLabel)"])
}

private func installPoster(source: URL, userID: uid_t) throws {
    guard isSafeFile(source) else { throw HelperError.invalidPoster }
    removeObsoleteIntegrations(userID: userID)
    let accountID = try generatedUID(for: userID)
    let target = URL(fileURLWithPath: "/Library/Caches/Desktop Pictures", isDirectory: true)
        .appendingPathComponent(accountID, isDirectory: true)
        .appendingPathComponent("lockscreen.png")
    try fileManager.createDirectory(at: Paths.posterSupport, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let backupExisted = fileManager.fileExists(atPath: target.path)
    if backupExisted && !fileManager.fileExists(atPath: Paths.posterBackup.path) {
        try replaceFile(target, Paths.posterBackup)
    }
    let convertedPoster = Paths.posterSupport.appendingPathComponent(".Selected.\(UUID().uuidString).png")
    guard run("/usr/bin/sips", ["-s", "format", "png", source.path, "--out", convertedPoster.path]) == 0,
          isSafeFile(convertedPoster)
    else { throw HelperError.invalidPoster }
    try replaceFile(convertedPoster, Paths.poster)
    try? fileManager.removeItem(at: convertedPoster)
    let state = PosterState(targetPath: target.path, backupExisted: backupExisted, userID: userID)
    let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
    try encoder.encode(state).write(to: Paths.posterState, options: .atomic)
    try maintainPoster()
    try installMaintainer()
}

private func restorePoster() {
    _ = run("/bin/launchctl", ["bootout", "system/\(Paths.posterLabel)"])
    if let state = loadPosterState() {
        let target = URL(fileURLWithPath: state.targetPath)
        if state.backupExisted, isSafeFile(Paths.posterBackup) {
            try? replaceFile(Paths.posterBackup, target)
        } else {
            try? fileManager.removeItem(at: target)
        }
    }
    try? fileManager.removeItem(at: Paths.posterDaemon)
    try? fileManager.removeItem(at: Paths.posterHelper)
    try? fileManager.removeItem(at: Paths.posterSupport)
}

do {
    guard geteuid() == 0 else { throw HelperError.administratorRequired }
    guard CommandLine.arguments.count >= 2 else { throw HelperError.invalidArguments }
    switch CommandLine.arguments[1] {
    case "install-poster":
        guard CommandLine.arguments.count == 4 else { throw HelperError.invalidArguments }
        try installPoster(source: URL(fileURLWithPath: CommandLine.arguments[2]), userID: try parseUserID(CommandLine.arguments[3]))
    case "maintain-poster":
        try maintainPoster()
    case "uninstall":
        guard CommandLine.arguments.count == 3 else { throw HelperError.invalidArguments }
        let userID = try parseUserID(CommandLine.arguments[2])
        removeObsoleteIntegrations(userID: userID)
        restorePoster()
    default:
        throw HelperError.invalidArguments
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
