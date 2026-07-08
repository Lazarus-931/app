import Foundation

public enum MLXServerError: Error, CustomStringConvertible {
    case missingDistribution(Bundle)
    case missingExecutable(URL)
    case alreadyRunning
    case notRunning
    case launchFailed(Int32, String)

    public var description: String {
        switch self {
        case .missingDistribution(let bundle):
            return "Missing mlx-vlm-server resource in \(bundle.bundlePath)"
        case .missingExecutable(let url):
            return "Missing mlx-vlm-server executable at \(url.path)"
        case .alreadyRunning:
            return "mlx-vlm-server is already running"
        case .notRunning:
            return "mlx-vlm-server is not running"
        case .launchFailed(let status, let output):
            return "mlx-vlm-server exited with status \(status):\n\(output)"
        }
    }
}

public enum MLXServer {
    public static func distributionURL() throws -> URL {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "mlx-vlm-server", withExtension: nil) else {
            throw MLXServerError.missingDistribution(bundle)
        }
        return url
    }

    public static func executableURL() throws -> URL {
        let url = try distributionURL().appendingPathComponent("bin/mlx-vlm-server")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw MLXServerError.missingExecutable(url)
        }
        return url
    }

    public static func makeProcess(
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> Process {
        let process = Process()
        process.executableURL = try executableURL()
        process.arguments = arguments
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment.merge(environment) { _, newValue in newValue }
        processEnvironment["PYTHONNOUSERSITE"] = "1"
        process.environment = processEnvironment
        return process
    }

    public static func run(arguments: [String], timeout: TimeInterval = 30) throws -> String {
        let process = try makeProcess(arguments: arguments)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw MLXServerError.launchFailed(process.terminationStatus, output)
        }
        return output
    }
}

public typealias MLXVLMServerError = MLXServerError
public typealias MLXVLMServer = MLXServer

public struct MLXServerMetrics: Decodable {
    public let latest: MLXServerLatestRequest?
    public let summary: MLXServerMetricsSummary
    public let server: MLXServerRuntimeSnapshot
    public let models: [MLXServerModelMetrics]

    enum CodingKeys: String, CodingKey {
        case latest
        case summary
        case server
        case models
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latest = try container.decodeIfPresent(MLXServerLatestRequest.self, forKey: .latest)
        summary = (try? container.decode(MLXServerMetricsSummary.self, forKey: .summary)) ?? MLXServerMetricsSummary()
        server = (try? container.decode(MLXServerRuntimeSnapshot.self, forKey: .server)) ?? MLXServerRuntimeSnapshot()
        models = (try? container.decode([MLXServerModelMetrics].self, forKey: .models)) ?? []
    }
}

public struct MLXServerMetricsSummary: Decodable {
    public let uptimeSeconds: Double
    public let requestsStarted: Int
    public let requestsCompleted: Int
    public let requestsFailed: Int
    public let streamingRequests: Int
    public let inFlight: Int
    public let promptTokensTotal: Int
    public let completionTokensTotal: Int
    public let generatedTokensTotal: Int
    public let averageRequestTimeSeconds: Double
    public let averageRequestTokensPerSecond: Double
    public let averageDecodeTokensPerSecond: Double
    public let lastRequestAt: Double?

    public var totalProcessedTokens: Int {
        promptTokensTotal + generatedTokensTotal
    }

    public var hasCompletedRequests: Bool {
        requestsCompleted > 0
    }

    enum CodingKeys: String, CodingKey {
        case uptimeSeconds = "uptime_s"
        case requestsStarted = "requests_started"
        case requestsCompleted = "requests_completed"
        case requestsFailed = "requests_failed"
        case streamingRequests = "streaming_requests"
        case inFlight = "in_flight"
        case promptTokensTotal = "prompt_tokens_total"
        case completionTokensTotal = "completion_tokens_total"
        case generatedTokensTotal = "generated_tokens_total"
        case averageRequestTimeSeconds = "avg_request_time_s"
        case averageRequestTokensPerSecond = "avg_request_tok_s"
        case averageDecodeTokensPerSecond = "avg_decode_tok_s"
        case lastRequestAt = "last_request_at"
    }

    public init() {
        uptimeSeconds = 0
        requestsStarted = 0
        requestsCompleted = 0
        requestsFailed = 0
        streamingRequests = 0
        inFlight = 0
        promptTokensTotal = 0
        completionTokensTotal = 0
        generatedTokensTotal = 0
        averageRequestTimeSeconds = 0
        averageRequestTokensPerSecond = 0
        averageDecodeTokensPerSecond = 0
        lastRequestAt = nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uptimeSeconds = container.decodeDoubleIfPresent(forKey: .uptimeSeconds)
        requestsStarted = container.decodeIntIfPresent(forKey: .requestsStarted)
        requestsCompleted = container.decodeIntIfPresent(forKey: .requestsCompleted)
        requestsFailed = container.decodeIntIfPresent(forKey: .requestsFailed)
        streamingRequests = container.decodeIntIfPresent(forKey: .streamingRequests)
        inFlight = container.decodeIntIfPresent(forKey: .inFlight)
        promptTokensTotal = container.decodeIntIfPresent(forKey: .promptTokensTotal)
        completionTokensTotal = container.decodeIntIfPresent(forKey: .completionTokensTotal)
        generatedTokensTotal = container.decodeIntIfPresent(forKey: .generatedTokensTotal)
        averageRequestTimeSeconds = container.decodeDoubleIfPresent(forKey: .averageRequestTimeSeconds)
        averageRequestTokensPerSecond = container.decodeDoubleIfPresent(forKey: .averageRequestTokensPerSecond)
        averageDecodeTokensPerSecond = container.decodeDoubleIfPresent(forKey: .averageDecodeTokensPerSecond)
        lastRequestAt = try container.decodeIfPresent(Double.self, forKey: .lastRequestAt)
    }
}

public struct MLXServerModelMetrics: Decodable, Identifiable {
    public let model: String
    public let requestsStarted: Int
    public let requestsCompleted: Int
    public let requestsFailed: Int
    public let streamingRequests: Int
    public let promptTokensTotal: Int
    public let completionTokensTotal: Int
    public let generatedTokensTotal: Int
    public let averageRequestTimeSeconds: Double
    public let averageRequestTokensPerSecond: Double
    public let averageDecodeTokensPerSecond: Double
    public let lastRequestAt: Double?

    public var id: String {
        model
    }

    public var totalProcessedTokens: Int {
        promptTokensTotal + generatedTokensTotal
    }

    enum CodingKeys: String, CodingKey {
        case model
        case requestsStarted = "requests_started"
        case requestsCompleted = "requests_completed"
        case requestsFailed = "requests_failed"
        case streamingRequests = "streaming_requests"
        case promptTokensTotal = "prompt_tokens_total"
        case completionTokensTotal = "completion_tokens_total"
        case generatedTokensTotal = "generated_tokens_total"
        case averageRequestTimeSeconds = "avg_request_time_s"
        case averageRequestTokensPerSecond = "avg_request_tok_s"
        case averageDecodeTokensPerSecond = "avg_decode_tok_s"
        case lastRequestAt = "last_request_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = (try? container.decode(String.self, forKey: .model)) ?? "Unknown"
        requestsStarted = container.decodeIntIfPresent(forKey: .requestsStarted)
        requestsCompleted = container.decodeIntIfPresent(forKey: .requestsCompleted)
        requestsFailed = container.decodeIntIfPresent(forKey: .requestsFailed)
        streamingRequests = container.decodeIntIfPresent(forKey: .streamingRequests)
        promptTokensTotal = container.decodeIntIfPresent(forKey: .promptTokensTotal)
        completionTokensTotal = container.decodeIntIfPresent(forKey: .completionTokensTotal)
        generatedTokensTotal = container.decodeIntIfPresent(forKey: .generatedTokensTotal)
        averageRequestTimeSeconds = container.decodeDoubleIfPresent(forKey: .averageRequestTimeSeconds)
        averageRequestTokensPerSecond = container.decodeDoubleIfPresent(forKey: .averageRequestTokensPerSecond)
        averageDecodeTokensPerSecond = container.decodeDoubleIfPresent(forKey: .averageDecodeTokensPerSecond)
        lastRequestAt = try container.decodeIfPresent(Double.self, forKey: .lastRequestAt)
    }
}

public struct MLXServerLatestRequest: Decodable {
    public let timestampUnix: Double?
    public let endpoint: String?
    public let model: String?
    public let stream: Bool
    public let backend: String?
    public let promptTokens: Int
    public let completionTokens: Int
    public let generatedTokens: Int
    public let reasoningTokens: Int
    public let totalTokens: Int
    public let promptEvalTimeSeconds: Double?
    public let prefillTokensPerSecond: Double?
    public let timeToFirstTokenSeconds: Double?
    public let decodeElapsedSeconds: Double?
    public let requestElapsedSeconds: Double?
    public let requestTokensPerSecond: Double?
    public let decodeTokensPerSecond: Double?
    public let peakMemoryGB: Double?
    public let finishReason: String?
    public let imageCount: Int
    public let audioCount: Int
    public let structuredOutput: Bool
    public let thinkingEnabled: Bool
    public let toolParser: String?
    public let toolCalls: Bool
    public let apcEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case timestampUnix = "timestamp_unix"
        case endpoint
        case model
        case stream
        case backend
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case generatedTokens = "generated_tokens"
        case reasoningTokens = "reasoning_tokens"
        case totalTokens = "total_tokens"
        case promptEvalTimeSeconds = "prompt_eval_time_s"
        case prefillTokensPerSecond = "prefill_tok_s"
        case timeToFirstTokenSeconds = "ttft_s"
        case decodeElapsedSeconds = "decode_elapsed_s"
        case requestElapsedSeconds = "request_elapsed_s"
        case requestTokensPerSecond = "request_tok_s"
        case decodeTokensPerSecond = "decode_tok_s"
        case peakMemoryGB = "peak_memory_gb"
        case finishReason = "finish_reason"
        case imageCount = "image_count"
        case audioCount = "audio_count"
        case structuredOutput = "structured_output"
        case thinkingEnabled = "thinking_enabled"
        case toolParser = "tool_parser"
        case toolCalls = "tool_calls"
        case apcEnabled = "apc_enabled"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestampUnix = try container.decodeIfPresent(Double.self, forKey: .timestampUnix)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        stream = container.decodeBoolIfPresent(forKey: .stream)
        backend = try container.decodeIfPresent(String.self, forKey: .backend)
        promptTokens = container.decodeIntIfPresent(forKey: .promptTokens)
        completionTokens = container.decodeIntIfPresent(forKey: .completionTokens)
        generatedTokens = container.decodeIntIfPresent(forKey: .generatedTokens)
        reasoningTokens = container.decodeIntIfPresent(forKey: .reasoningTokens)
        totalTokens = container.decodeIntIfPresent(forKey: .totalTokens)
        promptEvalTimeSeconds = try container.decodeIfPresent(Double.self, forKey: .promptEvalTimeSeconds)
        prefillTokensPerSecond = try container.decodeIfPresent(Double.self, forKey: .prefillTokensPerSecond)
        timeToFirstTokenSeconds = try container.decodeIfPresent(Double.self, forKey: .timeToFirstTokenSeconds)
        decodeElapsedSeconds = try container.decodeIfPresent(Double.self, forKey: .decodeElapsedSeconds)
        requestElapsedSeconds = try container.decodeIfPresent(Double.self, forKey: .requestElapsedSeconds)
        requestTokensPerSecond = try container.decodeIfPresent(Double.self, forKey: .requestTokensPerSecond)
        decodeTokensPerSecond = try container.decodeIfPresent(Double.self, forKey: .decodeTokensPerSecond)
        peakMemoryGB = try container.decodeIfPresent(Double.self, forKey: .peakMemoryGB)
        finishReason = try container.decodeIfPresent(String.self, forKey: .finishReason)
        imageCount = container.decodeIntIfPresent(forKey: .imageCount)
        audioCount = container.decodeIntIfPresent(forKey: .audioCount)
        structuredOutput = container.decodeBoolIfPresent(forKey: .structuredOutput)
        thinkingEnabled = container.decodeBoolIfPresent(forKey: .thinkingEnabled)
        toolParser = try container.decodeIfPresent(String.self, forKey: .toolParser)
        toolCalls = container.decodeBoolIfPresent(forKey: .toolCalls)
        apcEnabled = container.decodeBoolIfPresent(forKey: .apcEnabled)
    }
}

public struct MLXServerRuntimeSnapshot: Decodable {
    public let loadedModel: String?
    public let loadedAdapter: String?
    public let loadedContextSize: Int?
    public let configuredContextLimit: Int?
    public let effectiveContextLimit: Int?
    public let loadedToolParser: String?
    public let analyticsDatabasePath: String?
    public let continuousBatchingEnabled: Bool
    public let requestQueueDepth: Int
    public let apc: MLXServerAPCSnapshot

    public var displayLoadedModel: String {
        loadedModel ?? "None"
    }

    enum CodingKeys: String, CodingKey {
        case loadedModel = "loaded_model"
        case loadedAdapter = "loaded_adapter"
        case loadedContextSize = "loaded_context_size"
        case configuredContextLimit = "configured_context_limit"
        case effectiveContextLimit = "effective_context_limit"
        case loadedToolParser = "loaded_tool_parser"
        case analyticsDatabasePath = "analytics_db_path"
        case continuousBatchingEnabled = "continuous_batching_enabled"
        case requestQueueDepth = "request_queue_depth"
        case apc
    }

    public init() {
        loadedModel = nil
        loadedAdapter = nil
        loadedContextSize = nil
        configuredContextLimit = nil
        effectiveContextLimit = nil
        loadedToolParser = nil
        analyticsDatabasePath = nil
        continuousBatchingEnabled = false
        requestQueueDepth = 0
        apc = MLXServerAPCSnapshot()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        loadedModel = try container.decodeIfPresent(String.self, forKey: .loadedModel)
        loadedAdapter = try container.decodeIfPresent(String.self, forKey: .loadedAdapter)
        loadedContextSize = try container.decodeIfPresent(Int.self, forKey: .loadedContextSize)
        configuredContextLimit = try container.decodeIfPresent(Int.self, forKey: .configuredContextLimit)
        effectiveContextLimit = try container.decodeIfPresent(Int.self, forKey: .effectiveContextLimit)
        loadedToolParser = try container.decodeIfPresent(String.self, forKey: .loadedToolParser)
        analyticsDatabasePath = try container.decodeIfPresent(String.self, forKey: .analyticsDatabasePath)
        continuousBatchingEnabled = container.decodeBoolIfPresent(forKey: .continuousBatchingEnabled)
        requestQueueDepth = container.decodeIntIfPresent(forKey: .requestQueueDepth)
        apc = (try? container.decode(MLXServerAPCSnapshot.self, forKey: .apc)) ?? MLXServerAPCSnapshot()
    }
}

public struct MLXServerAPCSnapshot: Decodable {
    public let enabled: Bool
    public let matchedTokens: Int?
    public let servedTokens: Int?
    public let tokenHitRate: Double?
    public let diskHits: Int?
    public let diskEvictions: Int?
    public let diskBytes: Int?

    public init() {
        enabled = false
        matchedTokens = nil
        servedTokens = nil
        tokenHitRate = nil
        diskHits = nil
        diskEvictions = nil
        diskBytes = nil
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case matchedTokens = "matched_tokens"
        case servedTokens = "served_tokens"
        case tokenHitRate = "token_hit_rate"
        case diskHits = "disk_hits"
        case diskEvictions = "disk_evictions"
        case diskBytes = "disk_bytes"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = container.decodeBoolIfPresent(forKey: .enabled)
        matchedTokens = try container.decodeIfPresent(Int.self, forKey: .matchedTokens)
        servedTokens = try container.decodeIfPresent(Int.self, forKey: .servedTokens)
        tokenHitRate = try container.decodeIfPresent(Double.self, forKey: .tokenHitRate)
        diskHits = try container.decodeIfPresent(Int.self, forKey: .diskHits)
        diskEvictions = try container.decodeIfPresent(Int.self, forKey: .diskEvictions)
        diskBytes = try container.decodeIfPresent(Int.self, forKey: .diskBytes)
    }
}

public enum MLXServerMetricsError: Error, LocalizedError, CustomStringConvertible {
    case invalidResponse
    case httpStatus(Int)

    public var description: String {
        switch self {
        case .invalidResponse:
            return "Invalid metrics response"
        case .httpStatus(let statusCode):
            return "Metrics endpoint returned HTTP \(statusCode)"
        }
    }

    public var errorDescription: String? {
        description
    }
}

public final class MLXServerMetricsClient {
    private let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:8080")!,
        timeout: TimeInterval = 2
    ) {
        self.baseURL = baseURL
        self.timeout = timeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func fetchMetrics() async throws -> MLXServerMetrics {
        let paths = ["metrics", "v1/metrics"]
        var lastError: Error?

        for path in paths {
            do {
                return try await fetchMetrics(path: path)
            } catch MLXServerMetricsError.httpStatus(404) {
                lastError = MLXServerMetricsError.httpStatus(404)
                continue
            } catch {
                throw error
            }
        }

        throw lastError ?? MLXServerMetricsError.invalidResponse
    }

    private func fetchMetrics(path: String) async throws -> MLXServerMetrics {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MLXServerMetricsError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw MLXServerMetricsError.httpStatus(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(MLXServerMetrics.self, from: data)
    }
}

public final class MLXServerProcessController {
    public typealias OutputHandler = @Sendable (String) -> Void
    public typealias TerminationHandler = @Sendable (Int32) -> Void

    private let lock = NSLock()
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?

    public var onOutput: OutputHandler?
    public var onTermination: TerminationHandler?

    public init() {}

    public var isRunning: Bool {
        lock.withLock {
            process?.isRunning ?? false
        }
    }

    @discardableResult
    public func start(
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> Process {
        try lock.withLock {
            if process?.isRunning == true {
                throw MLXServerError.alreadyRunning
            }

            let process = try MLXServer.makeProcess(arguments: arguments, environment: environment)
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
            self.process = process

            observe(pipe: outputPipe)
            observe(pipe: errorPipe)

            process.terminationHandler = { [weak self] process in
                self?.handleTermination(status: process.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                self.process = nil
                self.outputPipe = nil
                self.errorPipe = nil
                throw error
            }

            return process
        }
    }

    public func stop(timeout: TimeInterval = 5) throws {
        let process = try lock.withLock {
            guard let process = self.process, process.isRunning else {
                throw MLXServerError.notRunning
            }
            return process
        }

        process.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            process.interrupt()
        }
    }

    private func observe(pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.onOutput?(String(decoding: data, as: UTF8.self))
        }
    }

    private func handleTermination(status: Int32) {
        let pipes = lock.withLock {
            let pipes = (self.outputPipe, self.errorPipe)
            self.process = nil
            self.outputPipe = nil
            self.errorPipe = nil
            return pipes
        }

        pipes.0?.fileHandleForReading.readabilityHandler = nil
        pipes.1?.fileHandleForReading.readabilityHandler = nil
        onTermination?(status)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension KeyedDecodingContainer {
    func decodeIntIfPresent(forKey key: Key) -> Int {
        (try? decodeIfPresent(Int.self, forKey: key)) ?? 0
    }

    func decodeDoubleIfPresent(forKey key: Key) -> Double {
        (try? decodeIfPresent(Double.self, forKey: key)) ?? 0
    }

    func decodeBoolIfPresent(forKey key: Key) -> Bool {
        (try? decodeIfPresent(Bool.self, forKey: key)) ?? false
    }
}

private final class BundleToken {}
