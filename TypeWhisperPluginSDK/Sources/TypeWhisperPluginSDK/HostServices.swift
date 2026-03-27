import Foundation
import os

// MARK: - Host Services

public protocol HostServices: Sendable {
    // Keychain
    func storeSecret(key: String, value: String) throws
    func loadSecret(key: String) -> String?

    // UserDefaults (plugin-scoped)
    func userDefault(forKey: String) -> Any?
    func setUserDefault(_ value: Any?, forKey: String)

    // Plugin data directory
    var pluginDataDirectory: URL { get }

    // App context
    var activeAppBundleId: String? { get }
    var activeAppName: String? { get }

    // Event bus
    var eventBus: EventBusProtocol { get }

    // Available profile names
    var availableProfileNames: [String] { get }

    // Notify host that plugin capabilities changed (e.g. model loaded/unloaded)
    func notifyCapabilitiesChanged()
}

// MARK: - HTTP Client (Ephemeral Sessions)

/// Drop-in replacement for `URLSession.shared.data(for:)` that creates a fresh ephemeral
/// session per call. This prevents stale HTTP/2 connections after sleep/wake or network changes
/// from hanging indefinitely.
public enum PluginHTTPClient {
    private static let logger = Logger(subsystem: "com.typewhisper.sdk", category: "HTTP")

    public static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let config = URLSessionConfiguration.ephemeral
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : 30
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout * 2, 90)
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "unknown"
        logger.info("\(method) \(url)")
        let start = ContinuousClock.now

        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = ContinuousClock.now - start
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.info("\(method) \(url) -> \(status) (\(elapsed))")
            return (data, response)
        } catch {
            let elapsed = ContinuousClock.now - start
            logger.error("\(method) \(url) failed after \(elapsed): \(error.localizedDescription)")
            throw error
        }
    }
}

// MARK: - WAV Encoder Utility

public struct PluginWavEncoder {
    public static func encode(_ samples: [Float], sampleRate: Int = 16000) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * Int(blockAlign))
        let fileSize = 36 + dataSize

        var data = Data(capacity: 44 + Int(dataSize))

        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Value = Int16(clamped * 32767)
            data.append(contentsOf: withUnsafeBytes(of: int16Value.littleEndian) { Array($0) })
        }

        return data
    }
}

// MARK: - Transcription Errors

public enum PluginTranscriptionError: LocalizedError, Sendable {
    case notConfigured
    case noModelSelected
    case invalidApiKey
    case rateLimited
    case fileTooLarge
    case apiError(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Cloud provider not configured. Please set an API key."
        case .noModelSelected:
            "No cloud model selected."
        case .invalidApiKey:
            "Invalid API key. Please check your API key and try again."
        case .rateLimited:
            "Rate limit exceeded. Please wait and try again."
        case .fileTooLarge:
            "Audio file too large for the API."
        case .apiError(let message):
            "API error: \(message)"
        case .networkError(let message):
            "Network error: \(message)"
        }
    }
}

// MARK: - Chat Errors

public enum PluginChatError: LocalizedError, Sendable {
    case notConfigured
    case noModelSelected
    case invalidApiKey
    case rateLimited
    case apiError(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "LLM provider not configured. Please set an API key."
        case .noModelSelected:
            "No LLM model selected."
        case .invalidApiKey:
            "Invalid API key. Please check your API key and try again."
        case .rateLimited:
            "Rate limit exceeded. Please wait and try again."
        case .apiError(let message):
            "API error: \(message)"
        case .networkError(let message):
            "Network error: \(message)"
        }
    }
}
