import Foundation

public actor RuntimeConfigurationStore {
    private let directories: AppDirectories

    public init(directories: AppDirectories) {
        self.directories = directories
    }

    public func load() throws -> RuntimeConfiguration? {
        guard FileManager.default.fileExists(atPath: directories.activeConfiguration.path) else {
            return nil
        }

        let data = try Data(contentsOf: directories.activeConfiguration)
        let configuration = try AtomicJSON.decoder.decode(RuntimeConfiguration.self, from: data)
        guard (1...RuntimeConfiguration.currentSchemaVersion).contains(configuration.schemaVersion) else {
            throw RuntimeConfigurationError.unsupportedSchema(configuration.schemaVersion)
        }
        guard configuration.schemaVersion != RuntimeConfiguration.currentSchemaVersion else {
            return configuration
        }
        let migrated = RuntimeConfiguration(activeProfile: configuration.activeProfile)
        try AtomicJSON.write(migrated, to: directories.activeConfiguration)
        return migrated
    }

    public func save(profile: WallpaperProfile, availableMediaIDs: Set<UUID>) throws {
        try ProfileValidator().validate(profile, availableMediaIDs: availableMediaIDs)
        try directories.prepare()
        try AtomicJSON.write(RuntimeConfiguration(activeProfile: profile), to: directories.activeConfiguration)
    }
}

public enum RuntimeConfigurationError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(schema):
            "Unsupported runtime configuration schema: \(schema)."
        }
    }
}
