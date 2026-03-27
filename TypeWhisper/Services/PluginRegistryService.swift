import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "PluginRegistry")

// MARK: - Plugin Category

enum PluginCategory: String, CaseIterable {
    case transcription
    case llm
    case postProcessor = "post-processor"
    case action
    case memory
    case utility

    var displayName: String {
        switch self {
        case .transcription: String(localized: "Transcription Engines")
        case .llm: String(localized: "LLM Providers")
        case .postProcessor: String(localized: "Post-Processors")
        case .action: String(localized: "Actions")
        case .memory: String(localized: "Memory")
        case .utility: String(localized: "Utilities")
        }
    }

    var iconSystemName: String {
        switch self {
        case .transcription: "waveform"
        case .llm: "brain"
        case .postProcessor: "arrow.triangle.2.circlepath"
        case .action: "bolt.fill"
        case .memory: "brain.head.profile"
        case .utility: "wrench"
        }
    }

    var sortOrder: Int {
        switch self {
        case .transcription: 0
        case .llm: 1
        case .postProcessor: 2
        case .action: 3
        case .memory: 4
        case .utility: 5
        }
    }
}

// MARK: - Registry Models

struct RegistryPlugin: Codable, Identifiable {
    let id: String
    let name: String
    let version: String
    let minHostVersion: String
    let minOSVersion: String?
    let author: String
    let description: String
    let category: String
    let size: Int64
    let downloadURL: String
    let iconSystemName: String?
    let requiresAPIKey: Bool?
    let descriptions: [String: String]?

    var localizedDescription: String {
        if let descriptions,
           let lang = Locale.current.language.languageCode?.identifier,
           let localized = descriptions[lang] {
            return localized
        }
        return description
    }

    var isCompatibleWithCurrentOS: Bool {
        guard let minOS = minOSVersion else { return true }
        let parts = minOS.split(separator: ".").compactMap { Int($0) }
        let required = OperatingSystemVersion(
            majorVersion: parts.count > 0 ? parts[0] : 0,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0
        )
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(required)
    }
}

struct PluginRegistryResponse: Codable {
    let schemaVersion: Int
    let plugins: [RegistryPlugin]
}

enum PluginInstallInfo {
    case notInstalled
    case installed(version: String)
    case updateAvailable(installed: String, available: String)
    case bundled
}

// MARK: - Plugin Registry Service

@MainActor
final class PluginRegistryService: ObservableObject {
    nonisolated(unsafe) static var shared: PluginRegistryService!

    @Published var registry: [RegistryPlugin] = []
    @Published var fetchState: FetchState = .idle
    @Published var installStates: [String: InstallState] = [:]
    @Published var availableUpdatesCount: Int = 0

    private var lastFetchDate: Date?
    private let registryURL = URL(string: "https://typewhisper.github.io/typewhisper-mac/plugins.json")!
    private let cacheDuration: TimeInterval = 300 // 5 minutes
    private static let lastUpdateCheckKey = "pluginRegistryLastUpdateCheck"

    enum FetchState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    enum InstallState: Equatable {
        case downloading(Double)
        case extracting
        case error(String)
    }

    // MARK: - Version Comparison

    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }
        let count = max(partsA.count, partsB.count)
        for i in 0..<count {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va < vb { return .orderedAscending }
            if va > vb { return .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - Fetch Registry

    func fetchRegistry() async {
        fetchState = .loaded
    }

    // MARK: - Background Update Check

    /// Check for plugin updates on app launch (at most once per 24h).
    func checkForUpdatesInBackground() {
        let lastCheck = UserDefaults.standard.double(forKey: Self.lastUpdateCheckKey)
        let hoursSinceLastCheck = (Date().timeIntervalSince1970 - lastCheck) / 3600
        guard hoursSinceLastCheck >= 24 || lastCheck == 0 else { return }

        Task {
            lastFetchDate = nil
            await fetchRegistry()
            updateAvailableUpdatesCount()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastUpdateCheckKey)
        }
    }

    func updateAvailableUpdatesCount() {
        let count = PluginManager.shared.loadedPlugins.count(where: { plugin in
            if case .updateAvailable = installInfo(for: plugin.manifest.id) { return true }
            return false
        })
        availableUpdatesCount = count
    }

    // MARK: - Install Info

    func installInfo(for pluginId: String) -> PluginInstallInfo {
        guard let loaded = PluginManager.shared.loadedPlugins.first(where: { $0.manifest.id == pluginId }) else {
            return .notInstalled
        }

        if loaded.isBundled {
            return .bundled
        }

        guard let registryPlugin = registry.first(where: { $0.id == pluginId }) else {
            return .installed(version: loaded.manifest.version)
        }

        if Self.compareVersions(registryPlugin.version, loaded.manifest.version) == .orderedDescending {
            return .updateAvailable(installed: loaded.manifest.version, available: registryPlugin.version)
        }

        return .installed(version: loaded.manifest.version)
    }

    // MARK: - Download & Install

    func downloadAndInstall(_ plugin: RegistryPlugin) async {
        installStates[plugin.id] = .error("Remote plugin installation is disabled")
    }

    // MARK: - Uninstall

    func uninstallPlugin(_ pluginId: String, deleteData: Bool = false) {
        guard let bundleURL = PluginManager.shared.bundleURL(for: pluginId) else { return }

        PluginManager.shared.unloadPlugin(pluginId)

        try? FileManager.default.removeItem(at: bundleURL)

        if deleteData {
            let dataDir = AppConstants.appSupportDirectory
                .appendingPathComponent("PluginData", isDirectory: true)
                .appendingPathComponent(pluginId, isDirectory: true)
            try? FileManager.default.removeItem(at: dataDir)
        }

        UserDefaults.standard.removeObject(forKey: "plugin.\(pluginId).enabled")
        logger.info("Uninstalled plugin: \(pluginId)")
    }

    // MARK: - Install from File

    func installFromFile(_ url: URL) async throws {
        let fm = FileManager.default
        let pluginsDir = PluginManager.shared.pluginsDirectory

        if url.pathExtension == "bundle" {
            let destURL = pluginsDir.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: url, to: destURL)
            PluginManager.shared.loadPlugin(at: destURL)
        } else if url.pathExtension == "zip" {
            let tempDir = fm.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempDir) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-xk", url.path, tempDir.path]
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw NSError(domain: "PluginRegistry", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to extract ZIP"])
            }

            let extracted = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            guard let bundleURL = extracted.first(where: { $0.pathExtension == "bundle" }) else {
                throw NSError(domain: "PluginRegistry", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "No .bundle found in ZIP"])
            }

            let destURL = pluginsDir.appendingPathComponent(bundleURL.lastPathComponent)
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.moveItem(at: bundleURL, to: destURL)
            PluginManager.shared.loadPlugin(at: destURL)
        }
    }

    // MARK: - Formatted Size

    static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

