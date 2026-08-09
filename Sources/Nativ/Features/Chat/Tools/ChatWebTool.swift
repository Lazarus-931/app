import Foundation
import NativServerKit

enum ChatWebToolRegistry {
    static let searchToolName = "web_search"
    static let readToolName = "web_read"
    static let browserTaskToolName = "browser_task"

    static func definitions(configuration: BrowsingConfiguration) -> [MLXChatToolDefinition] {
        var definitions: [MLXChatToolDefinition] = []
        if configuration.searchProvider != nil {
            definitions.append(definition(
                name: searchToolName,
                description: "Search the web for reliable, current sources. Returns up to five concise results with URLs.",
                properties: ["query": .object([
                    "type": .string("string"),
                    "description": .string("A focused web search query.")
                ])]
            ))
        }
        if configuration.readProvider != nil {
            definitions.append(definition(
                name: readToolName,
                description: "Read a public web page and return its main text as concise markdown.",
                properties: ["url": .object([
                    "type": .string("string"),
                    "description": .string("The full http or https URL to read.")
                ])]
            ))
        }
        if configuration.browserProvider == .browserUse {
            definitions.append(definition(
                name: browserTaskToolName,
                description: "Complete an interactive browser task. Ask for user confirmation before acting on a website.",
                properties: ["task": .object([
                    "type": .string("string"),
                    "description": .string("A specific browser task with the intended website and outcome.")
                ])]
            ))
        }
        return definitions
    }

    private static func definition(
        name: String,
        description: String,
        properties: [String: MLXJSONValue]
    ) -> MLXChatToolDefinition {
        MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: name,
            description: description,
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object(properties),
                "required": .array(properties.keys.sorted().map(MLXJSONValue.string))
            ])
        ))
    }
}

enum ChatWebToolError: LocalizedError {
    case unavailable(String)
    case invalidArguments
    case invalidURL
    case invalidTask
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail): detail
        case .invalidArguments: "The tool call needs a non-empty query or URL."
        case .invalidURL: "Only public http or https URLs can be read."
        case .invalidTask: "The browser task needs a specific instruction."
        case .requestFailed(let status, let detail): "The browsing provider returned HTTP \(status): \(detail)"
        }
    }
}

private struct ChatWebArguments: Decodable {
    let query: String?
    let url: String?
    let task: String?
}

private struct ChatWebResult: Encodable {
    struct Item: Encodable {
        let title: String
        let url: String
        let snippet: String?
    }

    let ok: Bool
    let provider: String
    let results: [Item]?
    let content: String?
    let error: String?
}

struct ChatWebToolExecutor {
    func execute(call: MLXChatToolCall, configuration: BrowsingConfiguration) async throws -> String {
        guard let name = call.function?.name,
              let argumentsData = call.function?.arguments?.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(ChatWebArguments.self, from: argumentsData)
        else {
            throw ChatWebToolError.invalidArguments
        }

        let result: ChatWebResult
        switch name {
        case ChatWebToolRegistry.searchToolName:
            guard let query = normalized(arguments.query), let provider = configuration.searchProvider else {
                throw ChatWebToolError.unavailable("Choose a web search provider in Extensions → Browsing first.")
            }
            result = try await search(query: query, provider: provider)
        case ChatWebToolRegistry.readToolName:
            guard let rawURL = arguments.url, let url = validatedURL(rawURL) else {
                throw ChatWebToolError.invalidURL
            }
            guard let provider = configuration.readProvider else {
                throw ChatWebToolError.unavailable("Choose a page reader in Extensions → Browsing first.")
            }
            result = try await read(url: url, provider: provider)
        case ChatWebToolRegistry.browserTaskToolName:
            guard let task = normalized(arguments.task), let provider = configuration.browserProvider else {
                throw ChatWebToolError.invalidTask
            }
            result = try await browserTask(task: task, provider: provider)
        default:
            throw ChatImageToolError.unsupportedTool(name)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(result), as: UTF8.self)
    }

    func failurePayload(operation: String, error: Error, configuration: BrowsingConfiguration) -> String {
        let provider: String
        if operation == ChatWebToolRegistry.searchToolName {
            provider = configuration.searchProvider?.displayName ?? "None"
        } else if operation == ChatWebToolRegistry.readToolName {
            provider = configuration.readProvider?.displayName ?? "None"
        } else {
            provider = configuration.browserProvider?.displayName ?? "None"
        }
        let payload = ChatWebResult(ok: false, provider: provider, results: nil, content: nil, error: error.localizedDescription)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(decoding: encoder.encode(payload), as: UTF8.self))
            ?? #"{"ok":false,"error":"Web request failed."}"#
    }

    private func search(query: String, provider: BrowsingProvider) async throws -> ChatWebResult {
        let key = try credential(for: provider)
        switch provider {
        case .brave:
            var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
            components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: "5")]
            var request = URLRequest(url: components.url!)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
            let object = try await object(for: request)
            let rows = nestedArray(object, path: ["web", "results"])
            return ChatWebResult(ok: true, provider: provider.displayName, results: rows.map(resultItem), content: nil, error: nil)
        case .exa:
            let object = try await post(
                "https://api.exa.ai/search",
                key: key,
                header: "x-api-key",
                body: ["query": query, "type": "auto", "numResults": 5, "contents": ["highlights": ["maxCharacters": 600]]]
            )
            let rows = object["results"] as? [[String: Any]] ?? []
            return ChatWebResult(ok: true, provider: provider.displayName, results: rows.map(resultItem), content: nil, error: nil)
        case .firecrawl:
            let object = try await post(
                "https://api.firecrawl.dev/v2/search",
                key: key,
                header: "Authorization",
                bearer: true,
                body: ["query": query, "limit": 5, "sources": ["web"]]
            )
            let data = object["data"] as? [String: Any] ?? object
            let rows = data["web"] as? [[String: Any]] ?? data["results"] as? [[String: Any]] ?? []
            return ChatWebResult(ok: true, provider: provider.displayName, results: rows.map(resultItem), content: nil, error: nil)
        case .browserbase:
            let object = try await post(
                "https://api.browserbase.com/v1/search",
                key: key,
                header: "x-bb-api-key",
                body: ["query": query, "numResults": 5]
            )
            let rows = object["results"] as? [[String: Any]] ?? []
            return ChatWebResult(ok: true, provider: provider.displayName, results: rows.map(resultItem), content: nil, error: nil)
        case .browserUse, .chromium:
            throw ChatWebToolError.unavailable("\(provider.displayName) is for browser tasks, not web search.")
        }
    }

    private func read(url: URL, provider: BrowsingProvider) async throws -> ChatWebResult {
        let key = try credential(for: provider)
        switch provider {
        case .firecrawl:
            let object = try await post(
                "https://api.firecrawl.dev/v2/scrape",
                key: key,
                header: "Authorization",
                bearer: true,
                body: ["url": url.absoluteString, "formats": ["markdown"], "onlyMainContent": true]
            )
            let data = object["data"] as? [String: Any] ?? object
            return ChatWebResult(ok: true, provider: provider.displayName, results: nil, content: pageContent(string(data["markdown"] ?? data["content"])), error: nil)
        case .browserbase:
            let object = try await post(
                "https://api.browserbase.com/v1/fetch",
                key: key,
                header: "x-bb-api-key",
                body: ["url": url.absoluteString, "format": "markdown", "allowRedirects": true]
            )
            return ChatWebResult(ok: true, provider: provider.displayName, results: nil, content: pageContent(string(object["content"])), error: nil)
        default:
            throw ChatWebToolError.unavailable("\(provider.displayName) cannot read pages. Choose Firecrawl or Browserbase in Extensions → Browsing.")
        }
    }

    private func browserTask(task: String, provider: BrowsingProvider) async throws -> ChatWebResult {
        guard provider == .browserUse else {
            throw ChatWebToolError.unavailable("\(provider.displayName) needs Nativ’s local browser runner before it can complete browser tasks.")
        }
        let key = try credential(for: provider)
        let run = try await post(
            "https://api.browser-use.com/api/v4/runs",
            key: key,
            header: "X-Browser-Use-API-Key",
            body: ["task": task, "maxCostUsd": 1.0]
        )
        guard let runID = string(run["id"]), !runID.isEmpty else {
            throw ChatWebToolError.unavailable("Browser Use did not return a run identifier.")
        }

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try Task.checkCancellation()
            let status = try await get(
                "https://api.browser-use.com/api/v4/runs/\(runID)/status",
                key: key,
                header: "X-Browser-Use-API-Key"
            )
            let state = string(status["status"])?.lowercased() ?? ""
            if ["completed", "failed", "cancelled"].contains(state) {
                let completed = try await get(
                    "https://api.browser-use.com/api/v4/runs/\(runID)",
                    key: key,
                    header: "X-Browser-Use-API-Key"
                )
                if state == "completed" {
                    return ChatWebResult(
                        ok: true,
                        provider: provider.displayName,
                        results: nil,
                        content: pageContent(string(completed["result"]) ?? string(completed["output"]) ?? string(completed["summary"])),
                        error: nil
                    )
                }
                throw ChatWebToolError.unavailable(string(completed["error"]) ?? "Browser Use \(state) the task.")
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw ChatWebToolError.unavailable("Browser Use is still working. Try a more focused task.")
    }

    private func credential(for provider: BrowsingProvider) throws -> String {
        guard let key = BrowsingCredentials.load(for: provider) else {
            throw ChatWebToolError.unavailable("Add a \(provider.displayName) API key in Extensions → Browsing.")
        }
        return key
    }

    private func post(
        _ endpoint: String,
        key: String,
        header: String,
        bearer: Bool = false,
        body: [String: Any]
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(bearer ? "Bearer \(key)" : key, forHTTPHeaderField: header)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await object(for: request)
    }

    private func get(_ endpoint: String, key: String, header: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.setValue(key, forHTTPHeaderField: header)
        return try await object(for: request)
    }

    private func object(for request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let body = String(decoding: data.prefix(1_000), as: UTF8.self)
        guard let http = response as? HTTPURLResponse else {
            throw ChatWebToolError.unavailable("The browsing provider did not return an HTTP response.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw ChatWebToolError.requestFailed(http.statusCode, body)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatWebToolError.unavailable("The browsing provider returned an unreadable response.")
        }
        return object
    }

    private func resultItem(_ value: [String: Any]) -> ChatWebResult.Item {
        let highlights = (value["highlights"] as? [String])?.joined(separator: " ")
        return .init(
            title: compact(string(value["title"])
                ?? string((value["metadata"] as? [String: Any])?["title"])
                ?? "Untitled result", maximum: 160) ?? "Untitled result",
            url: string(value["url"]) ?? string(value["sourceURL"]) ?? "",
            snippet: compact(string(value["description"]) ?? string(value["snippet"]) ?? highlights ?? string(value["markdown"]), maximum: 500)
        )
    }

    private func nestedArray(_ object: [String: Any], path: [String]) -> [[String: Any]] {
        var current: Any = object
        for key in path { current = (current as? [String: Any])?[key] as Any }
        return current as? [[String: Any]] ?? []
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(500))
    }

    private func validatedURL(_ raw: String) -> URL? {
        guard let raw = normalized(raw),
              let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(),
              !host.isEmpty,
              !host.hasSuffix(".local"),
              host != "localhost",
              host != "127.0.0.1",
              host != "::1",
              !host.hasPrefix("10."),
              !host.hasPrefix("127."),
              !host.hasPrefix("192.168."),
              !host.hasPrefix("172.16."),
              !host.hasPrefix("172.17."),
              !host.hasPrefix("172.18."),
              !host.hasPrefix("172.19."),
              !host.hasPrefix("172.2"),
              !host.hasPrefix("172.30."),
              !host.hasPrefix("172.31.")
        else { return nil }
        return url
    }

    private func string(_ value: Any?) -> String? { value as? String }

    private func compact(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        return String(value.prefix(maximum))
    }

    private func pageContent(_ value: String?) -> String? {
        compact(value, maximum: 4_000)
    }
}
