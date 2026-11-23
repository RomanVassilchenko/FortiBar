import Foundation
import os

/// Unified log, not stdout: the executable doubles as the `fortibar` CLI.
private let log = Logger(subsystem: "com.romanvassilchenko.FortiBar", category: "config")

class ConfigManager {
    static let shared = ConfigManager()
    
    /// Read from background queues too (connection setup, sudo checks): guarded by a lock
    private let lock = NSLock()
    private var storedConfig: AppConfig

    private(set) var config: AppConfig {
        get { lock.lock(); defer { lock.unlock() }; return storedConfig }
        set { lock.lock(); storedConfig = newValue; lock.unlock() }
    }
    
    static var configPath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("FortiBar")
        return appFolder.appendingPathComponent("config.json")
    }
    
    private init() {
        // Settings and logs written under the previous app name
        LegacyMigration.migrateFiles()
        storedConfig = ConfigManager.loadConfig(from: ConfigManager.configPath)
    }
    
    func reload() {
        config = ConfigManager.loadConfig(from: ConfigManager.configPath)
    }
    
    private static func loadConfig(from path: URL) -> AppConfig {
        let directory = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        guard FileManager.default.fileExists(atPath: path.path) else {
            log.info("Config file not found at \(path.path, privacy: .public), using defaults")
            return AppConfig.default
        }
        
        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            // No keyDecodingStrategy — we use explicit CodingKeys in Models
            let config = try decoder.decode(AppConfig.self, from: data)
            log.info("Config loaded from \(path.path, privacy: .public)")
            return config
        } catch {
            log.error("Error loading config: \(String(describing: error), privacy: .public)")
            // The next save replaces the file with defaults: keep the unreadable one for recovery
            let backup = path.appendingPathExtension("invalid")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: path, to: backup)
            return AppConfig.default
        }
    }
    
    func saveConfig(_ newConfig: AppConfig) {
        let path = ConfigManager.configPath
        let directory = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        do {
            let encoder = JSONEncoder()
            // No keyEncodingStrategy — we use explicit CodingKeys in Models
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(newConfig)
            // Atomic: a crash or a concurrent reader (app vs. CLI) never sees a half-written file
            try data.write(to: path, options: .atomic)
            self.config = newConfig
            log.info("Config saved to \(path.path, privacy: .public)")
        } catch {
            log.error("Error saving config: \(String(describing: error), privacy: .public)")
        }
    }
    
    func saveServers(_ servers: [VPNServer]) {
        var newConfig = config
        newConfig.servers = servers
        saveConfig(newConfig)
    }
    
    func saveOpenfortivpnPath(_ path: String) {
        var newConfig = config
        newConfig.openfortivpnPath = path
        saveConfig(newConfig)
    }
    
    func saveAllowMultipleConnections(_ allowed: Bool) {
        var newConfig = config
        newConfig.allowMultipleConnections = allowed
        saveConfig(newConfig)
    }
    
    func createDefaultConfig() {
        let path = ConfigManager.configPath
        let directory = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        guard !FileManager.default.fileExists(atPath: path.path) else { return }
        
        saveConfig(AppConfig.default)
    }
}
