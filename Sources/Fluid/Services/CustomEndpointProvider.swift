import Foundation

/// Transcription provider that sends audio to a self-hosted OpenAI-compatible
/// endpoint (`POST {baseURL}/audio/transcriptions`, multipart, Bearer auth) —
/// e.g. Chronicle's `/api/v1` surface, or any server implementing the OpenAI
/// audio transcription API.
///
/// Batch-only: `SpeechModel.customEndpoint.supportsStreaming` is false, so no
/// per-chunk preview requests are made; the full recording is transcribed once
/// when dictation stops.
final class CustomEndpointProvider: TranscriptionProvider {
    private static let sampleRate = 16_000

    var name: String { "Custom Endpoint" }

    var isAvailable: Bool { true }

    var isReady: Bool { Self.endpointURL() != nil }

    var shouldClearCacheAfterCancellation: Bool { false }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        guard Self.endpointURL() != nil else {
            throw Self.configurationError()
        }
    }

    func modelsExistOnDisk() -> Bool {
        Self.endpointURL() != nil
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard let url = Self.endpointURL() else {
            throw Self.configurationError()
        }

        let settings = SettingsStore.shared
        let apiKey = settings.customEndpointAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = settings.customEndpointModelName.trimmingCharacters(in: .whitespacesAndNewlines)

        let boundary = "fluidvoice-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        if !modelName.isEmpty {
            body.append(Self.formField(name: "model", value: modelName, boundary: boundary))
        }
        body.append(Self.formField(name: "response_format", value: "json", boundary: boundary))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(Self.wavData(from: samples))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let start = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "CustomEndpointProvider",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected response from transcription server."]
            )
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "CustomEndpointProvider",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Transcription server returned HTTP \(http.statusCode). \(detail.prefix(300))"]
            )
        }

        struct TranscriptionResponse: Decodable { let text: String }
        let text: String
        if let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) {
            text = decoded.text
        } else {
            // Servers configured for response_format=text reply with a plain string body.
            text = String(data: data, encoding: .utf8) ?? ""
        }

        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        DebugLogger.shared.info(
            "CustomEndpointProvider: transcribed \(samples.count) samples in \(elapsedMs)ms -> \(text.count) chars",
            source: "CustomEndpointProvider"
        )
        return ASRTranscriptionResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Helpers

    /// Resolve the configured base URL to the full transcriptions endpoint.
    /// Returns nil when no valid base URL is configured.
    static func endpointURL() -> URL? {
        var base = SettingsStore.shared.customEndpointBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") {
            base = String(base.dropLast())
        }
        guard let url = URL(string: base + "/audio/transcriptions"),
              url.scheme != nil,
              url.host != nil
        else {
            return nil
        }
        return url
    }

    private static func configurationError() -> NSError {
        NSError(
            domain: "CustomEndpointProvider",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: "Set the server base URL for the Custom Endpoint model in Voice Engine settings (e.g. https://myserver/api/v1).",
            ]
        )
    }

    private static func formField(name: String, value: String, boundary: String) -> Data {
        Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
    }

    /// Encode 16kHz mono float samples as a 16-bit PCM WAV blob.
    static func wavData(from samples: [Float]) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var value = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }

        let dataSize = UInt32(pcm.count)
        var header = Data()
        func appendUInt32(_ value: UInt32) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { header.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { header.append(contentsOf: $0) }
        }

        header.append(Data("RIFF".utf8))
        appendUInt32(36 + dataSize)
        header.append(Data("WAVE".utf8))
        header.append(Data("fmt ".utf8))
        appendUInt32(16) // PCM fmt chunk size
        appendUInt16(1) // PCM format
        appendUInt16(1) // mono
        appendUInt32(UInt32(self.sampleRate))
        appendUInt32(UInt32(self.sampleRate * 2)) // byte rate
        appendUInt16(2) // block align
        appendUInt16(16) // bits per sample
        header.append(Data("data".utf8))
        appendUInt32(dataSize)

        return header + pcm
    }
}
