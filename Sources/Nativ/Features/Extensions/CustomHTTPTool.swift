import Foundation
import NativServerKit

struct CustomHTTPTool: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var slug: String
    var summary: String
    var endpoint: String
    var parametersJSON: String

    static let defaultParametersJSON = #"""
    {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "query": {
          "type": "string",
          "description": "The value to send to the service."
        }
      },
      "required": ["query"]
    }
    """#

    var toolName: String {
        "custom__\(slug)"
    }

    var displaySummary: String {
        summary.isEmpty ? "Sends model-provided JSON to \(endpoint)" : summary
    }

    func definition() throws -> MLXChatToolDefinition {
        let parameters = try MLXJSONValue(jsonData: Data(parametersJSON.utf8))
        guard case .object = parameters else {
            throw CustomHTTPToolError.invalidParameters
        }
        return MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: toolName,
            description: displaySummary,
            parameters: parameters
        ))
    }

    static func make(
        name: String,
        summary: String,
        endpoint: String,
        parametersJSON: String
    ) throws -> Self {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slug = normalizedSlug(trimmedName) else {
            throw CustomHTTPToolError.invalidName
        }
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw CustomHTTPToolError.invalidEndpoint
        }
        let tool = Self(
            id: UUID(),
            name: trimmedName,
            slug: slug,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: url.absoluteString,
            parametersJSON: parametersJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        _ = try tool.definition()
        return tool
    }

    private static func normalizedSlug(_ name: String) -> String? {
        let lowered = name.lowercased()
        let characters = lowered.unicodeScalars.map { character -> Character in
            CharacterSet.alphanumerics.contains(character) ? Character(String(character)) : "_"
        }
        let slug = String(characters).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !slug.isEmpty,
              slug.count <= 48,
              slug.unicodeScalars.first.map(CharacterSet.letters.contains) == true else {
            return nil
        }
        return slug
    }
}

enum CustomHTTPToolError: LocalizedError {
    case invalidName
    case invalidEndpoint
    case invalidParameters
    case invalidResponse
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Use a short tool name that starts with a letter."
        case .invalidEndpoint:
            return "Enter a complete http or https URL."
        case .invalidParameters:
            return "Parameters must be a JSON object schema."
        case .invalidResponse:
            return "The service returned an unreadable response."
        case let .httpStatus(status, body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "The service returned HTTP \(status)." : "The service returned HTTP \(status): \(detail)"
        }
    }
}

enum CustomHTTPToolExecutor {
    static func execute(_ tool: CustomHTTPTool, argumentsJSON: String?) async throws -> String {
        guard let endpoint = URL(string: tool.endpoint) else {
            throw CustomHTTPToolError.invalidEndpoint
        }
        let body = Data((argumentsJSON ?? "{}").utf8)
        _ = try JSONSerialization.jsonObject(with: body)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data.prefix(128_000), as: UTF8.self)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CustomHTTPToolError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw CustomHTTPToolError.httpStatus(httpResponse.statusCode, text)
        }
        return text.isEmpty ? "{}" : text
    }
}
