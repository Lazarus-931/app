import Foundation

public enum MLXServerChatError: Error, LocalizedError, CustomStringConvertible {
    case invalidResponse
    case httpStatus(Int, String)
    case missingAssistantContent
    case malformedStreamEvent(String)

    public var description: String {
        switch self {
        case .invalidResponse:
            return "Invalid chat response"
        case .httpStatus(let statusCode, let body):
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBody.isEmpty {
                return "Chat endpoint returned HTTP \(statusCode)"
            }
            return "Chat endpoint returned HTTP \(statusCode): \(trimmedBody)"
        case .missingAssistantContent:
            return "Chat response did not include assistant content"
        case .malformedStreamEvent(let event):
            return "Malformed chat stream event: \(event)"
        }
    }

    public var errorDescription: String? {
        description
    }
}

public struct MLXChatMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: MLXChatMessageContent?

    public init(role: String, content: String?) {
        self.role = role
        self.content = content.map(MLXChatMessageContent.text)
    }

    public init(role: String, content: MLXChatMessageContent?) {
        self.role = role
        self.content = content
    }

    public var textContent: String? {
        content?.textValue
    }
}

public enum MLXChatMessageContent: Codable, Equatable, Sendable {
    case text(String)
    case parts([MLXChatContentPart])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }

        self = .parts(try container.decode([MLXChatContentPart].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }

    public var textValue: String? {
        switch self {
        case .text(let text):
            return text
        case .parts(let parts):
            let text = parts.compactMap(\.text).joined(separator: " ")
            return text.isEmpty ? nil : text
        }
    }
}

public struct MLXChatContentPart: Codable, Equatable, Sendable {
    public var type: String
    public var text: String?
    public var imageURL: MLXChatImageURL?

    public init(text: String) {
        self.type = "text"
        self.text = text
        self.imageURL = nil
    }

    public init(imageURL: String) {
        self.type = "image_url"
        self.text = nil
        self.imageURL = MLXChatImageURL(url: imageURL)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }
}

public struct MLXChatImageURL: Codable, Equatable, Sendable {
    public var url: String

    public init(url: String) {
        self.url = url
    }
}

public struct MLXChatUsage: Decodable, Equatable, Sendable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

public struct MLXChatCompletion: Equatable, Sendable {
    public let model: String?
    public let content: String
    public let finishReason: String?
    public let usage: MLXChatUsage?
}

public struct MLXChatStreamOptions: Encodable, Equatable, Sendable {
    public var includeUsage: Bool

    public init(includeUsage: Bool) {
        self.includeUsage = includeUsage
    }

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

public struct MLXChatCompletionRequest: Encodable, Equatable, Sendable {
    public var model: String
    public var messages: [MLXChatMessage]
    public var maxTokens: Int
    public var temperature: Double
    public var topK: Int
    public var topP: Double
    public var minP: Double
    public var repetitionPenalty: Double?
    public var stream: Bool
    public var streamOptions: MLXChatStreamOptions?

    public init(
        model: String,
        messages: [MLXChatMessage],
        maxTokens: Int,
        temperature: Double,
        topK: Int,
        topP: Double,
        minP: Double,
        repetitionPenalty: Double? = nil,
        stream: Bool = false,
        streamOptions: MLXChatStreamOptions? = nil
    ) {
        self.model = model
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.stream = stream
        self.streamOptions = streamOptions
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case temperature
        case topK = "top_k"
        case topP = "top_p"
        case minP = "min_p"
        case repetitionPenalty = "repetition_penalty"
        case stream
        case streamOptions = "stream_options"
    }
}

public final class MLXServerChatClient {
    private let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:8080")!,
        timeout: TimeInterval = 600
    ) {
        self.baseURL = baseURL
        self.timeout = timeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func completeChat(_ request: MLXChatCompletionRequest) async throws -> MLXChatCompletion {
        var payload = request
        payload.stream = false
        payload.streamOptions = nil

        let urlRequest = try makeURLRequest(payload: payload, accepts: "application/json")
        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MLXServerChatError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw MLXServerChatError.httpStatus(httpResponse.statusCode, String(decoding: data, as: UTF8.self))
        }

        let decoded = try decoder.decode(ChatCompletionResponse.self, from: data)
        guard let choice = decoded.choices.first,
              let content = choice.message.textContent,
              !content.isEmpty
        else {
            throw MLXServerChatError.missingAssistantContent
        }

        return MLXChatCompletion(
            model: decoded.model,
            content: content,
            finishReason: choice.finishReason,
            usage: decoded.usage
        )
    }

    public func streamChat(
        _ request: MLXChatCompletionRequest,
        onDelta: @escaping (String) async -> Void
    ) async throws -> MLXChatCompletion {
        var payload = request
        payload.stream = true
        payload.streamOptions = MLXChatStreamOptions(includeUsage: true)

        let urlRequest = try makeURLRequest(payload: payload, accepts: "text/event-stream")
        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MLXServerChatError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw MLXServerChatError.httpStatus(httpResponse.statusCode, await readErrorBody(from: bytes))
        }

        var content = ""
        var finishReason: String?
        var usage: MLXChatUsage?
        var responseModel: String?

        for try await line in bytes.lines {
            try Task.checkCancellation()

            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.hasPrefix("data:") else {
                continue
            }

            let dataString = trimmedLine
                .dropFirst("data:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if dataString == "[DONE]" {
                break
            }
            guard let data = dataString.data(using: .utf8) else {
                throw MLXServerChatError.malformedStreamEvent(dataString)
            }

            let chunk = try decoder.decode(ChatStreamChunk.self, from: data)
            responseModel = chunk.model ?? responseModel
            usage = chunk.usage ?? usage

            if let choice = chunk.choices.first {
                finishReason = choice.finishReason ?? finishReason
                if let delta = choice.delta.textContent, !delta.isEmpty {
                    content += delta
                    await onDelta(delta)
                }
            }
        }

        guard !content.isEmpty else {
            throw MLXServerChatError.missingAssistantContent
        }

        return MLXChatCompletion(
            model: responseModel,
            content: content,
            finishReason: finishReason,
            usage: usage
        )
    }

    private func makeURLRequest(payload: MLXChatCompletionRequest, accepts: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accepts, forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(payload)
        return request
    }

    private func readErrorBody(from bytes: URLSession.AsyncBytes) async -> String {
        var body = ""

        do {
            for try await line in bytes.lines {
                if !body.isEmpty {
                    body.append("\n")
                }
                body.append(line)

                if body.count > 4096 {
                    body = String(body.prefix(4096))
                    break
                }
            }
        } catch {
            return body
        }

        return body
    }
}

private struct ChatCompletionResponse: Decodable {
    let model: String?
    let choices: [Choice]
    let usage: MLXChatUsage?

    struct Choice: Decodable {
        let finishReason: String?
        let message: MLXChatMessage

        enum CodingKeys: String, CodingKey {
            case finishReason = "finish_reason"
            case message
        }
    }
}

private struct ChatStreamChunk: Decodable {
    let model: String?
    let choices: [Choice]
    let usage: MLXChatUsage?

    struct Choice: Decodable {
        let finishReason: String?
        let delta: MLXChatMessage

        enum CodingKeys: String, CodingKey {
            case finishReason = "finish_reason"
            case delta
        }
    }
}
