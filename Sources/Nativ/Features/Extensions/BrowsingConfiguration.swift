import Foundation

enum BrowsingProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case brave
    case exa
    case firecrawl
    case browserbase
    case browserUse
    case chromium

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .brave: "Brave Search"
        case .exa: "Exa"
        case .firecrawl: "Firecrawl"
        case .browserbase: "Browserbase"
        case .browserUse: "Browser Use"
        case .chromium: "Chromium"
        }
    }

    var summary: String {
        switch self {
        case .brave: "Fast web search with a dedicated index."
        case .exa: "Semantic search with research-ready results."
        case .firecrawl: "Search and clean pages into agent-ready text."
        case .browserbase: "Search and fetch through browser infrastructure."
        case .browserUse: "Hosted browser agents for complex, interactive work."
        case .chromium: "A local, isolated browser for visible browsing."
        }
    }

    var documentationURL: URL {
        switch self {
        case .brave: URL(string: "https://api.search.brave.com/app/documentation/web-search/get-started")!
        case .exa: URL(string: "https://exa.ai/docs/reference/search")!
        case .firecrawl: URL(string: "https://docs.firecrawl.dev/api-reference/endpoint/search")!
        case .browserbase: URL(string: "https://docs.browserbase.com/platform/search/overview")!
        case .browserUse: URL(string: "https://docs.browser-use.com/cloud/quickstart")!
        case .chromium: URL(string: "https://www.chromium.org/getting-involved/download-chromium/")!
        }
    }

    var supportsSearch: Bool {
        switch self {
        case .brave, .exa, .firecrawl, .browserbase: true
        case .browserUse, .chromium: false
        }
    }

    var supportsRead: Bool {
        switch self {
        case .firecrawl, .browserbase: true
        case .brave, .exa, .browserUse, .chromium: false
        }
    }

    var supportsBrowserTasks: Bool {
        switch self {
        case .browserUse, .chromium: true
        case .brave, .exa, .firecrawl, .browserbase: false
        }
    }

    var requiresAPIKey: Bool { self != .chromium }

    var keychain: ServerAPIKeychain {
        ServerAPIKeychain(
            service: "dev.local.Nativ.browsing.\(rawValue)",
            account: "api-key"
        )
    }
}

struct BrowsingConfiguration: Codable, Equatable, Sendable {
    var searchProvider: BrowsingProvider?
    var readProvider: BrowsingProvider?
    var browserProvider: BrowsingProvider?

    init(
        searchProvider: BrowsingProvider? = nil,
        readProvider: BrowsingProvider? = nil,
        browserProvider: BrowsingProvider? = nil
    ) {
        self.searchProvider = searchProvider?.supportsSearch == true ? searchProvider : nil
        self.readProvider = readProvider?.supportsRead == true ? readProvider : nil
        self.browserProvider = browserProvider?.supportsBrowserTasks == true ? browserProvider : nil
    }

    func normalized() -> Self {
        Self(
            searchProvider: searchProvider,
            readProvider: readProvider,
            browserProvider: browserProvider
        )
    }
}

enum BrowsingCredentials {
    static func load(for provider: BrowsingProvider) -> String? {
        guard provider.requiresAPIKey else { return nil }
        return try? provider.keychain.load()
    }

    static func save(_ key: String?, for provider: BrowsingProvider) throws {
        guard provider.requiresAPIKey else { return }
        try provider.keychain.save(key)
    }

    static func isConfigured(_ provider: BrowsingProvider) -> Bool {
        if provider == .chromium {
            return FileManager.default.fileExists(atPath: "/Applications/Chromium.app")
                || FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app")
        }
        return load(for: provider) != nil
    }
}
