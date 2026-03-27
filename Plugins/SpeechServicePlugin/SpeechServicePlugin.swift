import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(SpeechServicePlugin)
final class SpeechServicePlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.speechservice"
    static let pluginName = "Speech Service"

    fileprivate var host: HostServices?
    fileprivate var baseURL: String = "http://127.0.0.1:8300"
    fileprivate var isHealthy = false
    fileprivate var sttModelName: String?

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        if let saved = host.userDefault(forKey: "baseURL") as? String, !saved.isEmpty {
            baseURL = saved
        }
        Task { await checkHealth() }
    }

    func deactivate() {
        host = nil
        isHealthy = false
        sttModelName = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "speechservice" }
    var providerDisplayName: String { "Speech Service" }

    var isConfigured: Bool { isHealthy }

    var transcriptionModels: [PluginModelInfo] {
        guard isHealthy else { return [] }
        let name = sttModelName ?? "Remote STT"
        return [PluginModelInfo(id: "default", displayName: name)]
    }

    var selectedModelId: String? { isHealthy ? "default" : nil }
    func selectModel(_ modelId: String) {}

    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { false }
    var supportedLanguages: [String] { [] }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard isHealthy else {
            throw PluginTranscriptionError.notConfigured
        }

        let url = URL(string: "\(baseURL)/stt")!
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(audio.wavData)
        body.append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw PluginTranscriptionError.apiError(message)
        }

        struct STTResponse: Decodable {
            let text: String
            let duration_ms: Int?
        }

        let sttResponse = try JSONDecoder().decode(STTResponse.self, from: data)
        return PluginTranscriptionResult(text: sttResponse.text)
    }

    // MARK: - Health Check

    @discardableResult
    fileprivate func checkHealth() async -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else {
            isHealthy = false
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                isHealthy = false
                return false
            }

            struct HealthResponse: Decodable {
                let status: String
                let models: Models?
                struct Models: Decodable {
                    let stt: String?
                }
            }

            let health = try JSONDecoder().decode(HealthResponse.self, from: data)
            sttModelName = health.models?.stt
            isHealthy = health.status == "ok"
            host?.notifyCapabilitiesChanged()
            return isHealthy
        } catch {
            isHealthy = false
            return false
        }
    }

    fileprivate func updateBaseURL(_ newURL: String) {
        baseURL = newURL
        host?.setUserDefault(newURL, forKey: "baseURL")
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(SpeechServiceSettingsView(plugin: self))
    }
}

// MARK: - Data Extension

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

// MARK: - Settings View

private struct SpeechServiceSettingsView: View {
    let plugin: SpeechServicePlugin
    @State private var urlText: String = ""
    @State private var isChecking = false
    @State private var isHealthy = false
    @State private var modelName: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Speech Service")
                .font(.headline)

            Text("Connect to a local Speech Service HTTP API for transcription.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Server URL")
                    .font(.subheadline.weight(.medium))

                HStack {
                    TextField("http://127.0.0.1:8300", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveAndCheck() }

                    Button("Check") { saveAndCheck() }
                        .buttonStyle(.bordered)
                        .disabled(isChecking)
                }

                if isChecking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if isHealthy {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Connected")
                            .font(.caption)
                            .foregroundStyle(.green)
                        if let modelName {
                            Text("— \(modelName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let errorMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("API Endpoints")
                    .font(.subheadline.weight(.medium))
                Group {
                    Text("POST /stt — Transcribe audio (multipart file upload)")
                    Text("GET /health — Check server status")
                    Text("GET /voices — List TTS voices")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear {
            urlText = plugin.baseURL
            isHealthy = plugin.isHealthy
            modelName = plugin.sttModelName
        }
    }

    private func saveAndCheck() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        urlText = trimmed
        plugin.updateBaseURL(trimmed)
        isChecking = true
        errorMessage = nil
        Task {
            let ok = await plugin.checkHealth()
            isChecking = false
            isHealthy = ok
            modelName = plugin.sttModelName
            if !ok {
                errorMessage = "Cannot reach \(trimmed)/health"
            }
        }
    }
}
