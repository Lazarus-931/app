import Foundation
import MLXServerKit

struct HuggingFaceModel: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let downloads: Int
    let likes: Int
    let pipelineTag: String?
    let libraryName: String?
    let tags: [String]
    let isPrivate: Bool
    let isGated: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case downloads
        case likes
        case pipelineTag = "pipeline_tag"
        case libraryName = "library_name"
        case tags
        case isPrivate = "private"
        case gated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        downloads = try container.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        likes = try container.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        pipelineTag = try container.decodeIfPresent(String.self, forKey: .pipelineTag)
        libraryName = try container.decodeIfPresent(String.self, forKey: .libraryName)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false

        if let value = try? container.decode(Bool.self, forKey: .gated) {
            isGated = value
        } else if let value = try? container.decode(String.self, forKey: .gated) {
            isGated = !value.isEmpty && value != "false"
        } else {
            isGated = false
        }
    }

    var provider: LocalModelProvider? {
        LocalModelProviderResolver.resolve(repoID: id, modelType: nil, architectures: [])
    }

    var capabilities: Set<LocalModelCapability> {
        let descriptors = ([pipelineTag, libraryName].compactMap { $0 } + tags)
            .joined(separator: " ")
            .lowercased()
        var result = Set<LocalModelCapability>()
        if descriptors.contains("image-text")
            || descriptors.contains("vision")
            || descriptors.contains("vlm")
            || descriptors.contains("llava") {
            result.insert(.vision)
        }
        if descriptors.contains("audio")
            || descriptors.contains("speech")
            || descriptors.contains("whisper")
            || descriptors.contains("asr")
            || descriptors.contains("tts") {
            result.insert(.audio)
        }
        if descriptors.contains("tool") || descriptors.contains("function-call") {
            result.insert(.tools)
        }
        return result
    }
}

enum HuggingFaceHubError: LocalizedError {
    case invalidResponse
    case requestFailed(Int, String)
    case pythonUnavailable
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Hugging Face returned an invalid response."
        case .requestFailed(let status, let message):
            message.isEmpty ? "Hugging Face request failed (HTTP \(status))." : message
        case .pythonUnavailable:
            "The bundled model downloader is unavailable."
        case .downloadFailed(let message):
            message.isEmpty ? "The model download failed." : message
        }
    }
}

private struct HuggingFaceHubClient: Sendable {
    func search(query: String) async throws -> [HuggingFaceModel] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models"

        var queryItems = [
            URLQueryItem(name: "filter", value: "mlx"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "full", value: "true")
        ]
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: trimmedQuery))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw HuggingFaceHubError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("MLXPlatform/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HuggingFaceHubError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(HubErrorPayload.self, from: data))?.error ?? ""
            throw HuggingFaceHubError.requestFailed(httpResponse.statusCode, message)
        }
        return try JSONDecoder().decode([HuggingFaceModel].self, from: data)
    }
}

private struct HubErrorPayload: Decodable {
    let error: String
}

@MainActor
final class HuggingFaceModelLibrary: ObservableObject {
    @Published private(set) var models: [HuggingFaceModel] = []
    @Published private(set) var isSearching = false
    @Published private(set) var error: String?

    private let client = HuggingFaceHubClient()
    private var searchTask: Task<Void, Never>?

    deinit {
        searchTask?.cancel()
    }

    func search(query: String) {
        searchTask?.cancel()
        isSearching = true
        error = nil

        searchTask = Task { [weak self, client] in
            do {
                let models = try await client.search(query: query)
                try Task.checkCancellation()
                self?.models = models
                self?.error = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.models = []
                self?.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            self?.isSearching = false
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }
}

@MainActor
final class HuggingFaceDownloadManager: ObservableObject {
    @Published private(set) var downloadingModelID: String?
    @Published private(set) var errorByModelID: [String: String] = [:]

    private var downloadTask: Task<Void, Never>?

    deinit {
        downloadTask?.cancel()
    }

    func download(repoID: String, cachePath: String, onCompletion: @escaping () -> Void) {
        guard downloadingModelID == nil else { return }
        downloadingModelID = repoID
        errorByModelID[repoID] = nil

        let expandedCachePath = LocalModelDiscovery.expandedPath(cachePath)
        downloadTask = Task { [weak self] in
            do {
                try await HuggingFaceSnapshotDownloader.download(
                    repoID: repoID,
                    cachePath: expandedCachePath
                )
                guard !Task.isCancelled else { return }
                self?.downloadingModelID = nil
                onCompletion()
            } catch is CancellationError {
                self?.downloadingModelID = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorByModelID[repoID] =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self?.downloadingModelID = nil
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadingModelID = nil
    }
}

private enum HuggingFaceSnapshotDownloader {
    static func download(repoID: String, cachePath: String) async throws {
        let operation = try HuggingFaceDownloadOperation(repoID: repoID, cachePath: cachePath)
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try operation.run()
            }.value
        } onCancel: {
            operation.cancel()
        }
    }
}

private final class HuggingFaceDownloadOperation: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var wasCancelled = false

    init(repoID: String, cachePath: String) throws {
        let distributionURL = try MLXServer.distributionURL()
        let pythonURL = distributionURL.appendingPathComponent("python/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            throw HuggingFaceHubError.pythonUnavailable
        }

        let script = """
        import sys
        from huggingface_hub import snapshot_download
        snapshot_download(repo_id=sys.argv[1], cache_dir=sys.argv[2])
        """

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = ["-c", script, repoID, cachePath]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONHOME"] = distributionURL.appendingPathComponent("python").path
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HF_HUB_CACHE"] = cachePath
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        process.environment = environment
        self.process = process
    }

    func run() throws {
        lock.lock()
        let cancelledBeforeLaunch = wasCancelled
        lock.unlock()
        if cancelledBeforeLaunch {
            throw CancellationError()
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let outputGroup = DispatchGroup()
        let outputLock = NSLock()
        var output = Data()
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            output = data
            outputLock.unlock()
            outputGroup.leave()
        }

        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForWriting.close()
            outputGroup.wait()
            throw error
        }
        process.waitUntilExit()
        outputGroup.wait()

        lock.lock()
        let cancelled = wasCancelled
        lock.unlock()
        if cancelled {
            throw CancellationError()
        }
        guard process.terminationStatus == 0 else {
            outputLock.lock()
            let message = String(decoding: output, as: UTF8.self)
            outputLock.unlock()
            let usefulMessage = message
                .split(separator: "\n")
                .suffix(4)
                .joined(separator: "\n")
            throw HuggingFaceHubError.downloadFailed(usefulMessage)
        }
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let shouldTerminate = process.isRunning
        lock.unlock()
        if shouldTerminate {
            process.terminate()
        }
    }
}
