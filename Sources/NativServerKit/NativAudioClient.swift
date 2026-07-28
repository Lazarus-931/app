import Foundation

public enum NativAudioError: Error, LocalizedError, CustomStringConvertible {
    case invalidResponse
    case httpStatus(Int, String)
    case emptyAudio

    public var description: String {
        switch self {
        case .invalidResponse:
            return "Invalid audio response"
        case .httpStatus(let statusCode, let body):
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBody.isEmpty {
                return "Audio endpoint returned HTTP \(statusCode)"
            }
            return "Audio endpoint returned HTTP \(statusCode): \(trimmedBody)"
        case .emptyAudio:
            return "Audio response did not include any audio data"
        }
    }

    public var errorDescription: String? {
        description
    }

    var statusCode: Int? {
        if case .httpStatus(let statusCode, _) = self {
            return statusCode
        }
        return nil
    }
}

public struct MLXSpeechRequest: Encodable, Equatable, Sendable {
    public var model: String
    public var input: String
    public var voice: String?
    public var speed: Double?
    public var responseFormat: String

    public init(
        model: String,
        input: String,
        voice: String? = nil,
        speed: Double? = nil,
        responseFormat: String = "mp3"
    ) {
        self.model = model
        self.input = input
        self.voice = voice
        self.speed = speed
        self.responseFormat = responseFormat
    }

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case voice
        case speed
        case responseFormat = "response_format"
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

public final class NativAudioClient {
    private let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval
    private let apiKey: String?
    private let encoder = JSONEncoder()

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:8080")!,
        timeout: TimeInterval = 300,
        apiKey: String? = nil
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.apiKey = apiKey

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Synthesize speech for the request's text and return the raw audio bytes
    /// (mp3 by default). Tries `/v1/audio/speech` then the unversioned fallback.
    public func speech(_ request: MLXSpeechRequest) async throws -> Data {
        var fallbackError: NativAudioError?
        for path in ["v1/audio/speech", "audio/speech"] {
            do {
                return try await speech(request, path: path)
            } catch let error as NativAudioError where error.statusCode == 404 || error.statusCode == 405 {
                fallbackError = error
                continue
            }
        }
        throw fallbackError ?? NativAudioError.invalidResponse
    }

    public func transcribe(_ audio: Data, fileName: String, model: String) async throws -> String {
        var fallbackError: NativAudioError?
        for path in ["v1/audio/transcriptions", "audio/transcriptions"] {
            do {
                return try await transcribe(audio, fileName: fileName, model: model, path: path)
            } catch let error as NativAudioError where error.statusCode == 404 || error.statusCode == 405 {
                fallbackError = error
                continue
            }
        }
        throw fallbackError ?? NativAudioError.invalidResponse
    }

    private func transcribe(_ audio: Data, fileName: String, model: String, path: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        appendField("model", model)
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = body

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NativAudioError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NativAudioError.httpStatus(httpResponse.statusCode, String(decoding: data, as: UTF8.self))
        }
        if let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) {
            return decoded.text
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func speech(_ request: MLXSpeechRequest, path: String) async throws -> Data {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("audio/*", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NativAudioError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NativAudioError.httpStatus(httpResponse.statusCode, String(decoding: data, as: UTF8.self))
        }
        guard !data.isEmpty else {
            throw NativAudioError.emptyAudio
        }
        return data
    }
}
