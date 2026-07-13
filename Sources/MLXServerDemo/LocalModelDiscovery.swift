import Foundation

enum LocalModelCapability: String, CaseIterable, Hashable, Sendable {
    case vision
    case audio
}

struct LocalModel: Identifiable, Equatable, Sendable {
    var id: String { repoID }

    let repoID: String
    let snapshotURL: URL?
    let modifiedAt: Date?
    let sizeBytes: Int64?
    let contextSize: Int?
    let capabilities: Set<LocalModelCapability>
}

enum LocalModelDiscovery {
    static func scan(path: String) async throws -> [LocalModel] {
        let expandedPath = Self.expandedPath(path)
        return try await Task.detached(priority: .userInitiated) {
            try Self.scanSynchronously(path: expandedPath)
        }.value
    }

    static func expandedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePath = trimmed.isEmpty ? MLXServerSettings.defaultModelSearchPath : trimmed
        return (effectivePath as NSString).expandingTildeInPath
    }

    private static func scanSynchronously(path: String) throws -> [LocalModel] {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            throw LocalModelDiscoveryError.pathNotFound(path)
        }
        guard isDirectory.boolValue else {
            throw LocalModelDiscoveryError.notDirectory(path)
        }

        let repoURLs = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let models = repoURLs.compactMap { repoURL -> LocalModel? in
            guard repoURL.lastPathComponent.hasPrefix("models--"),
                  isDirectoryURL(repoURL, fileManager: fileManager),
                  let repoID = repoID(fromCacheDirectoryName: repoURL.lastPathComponent)
            else {
                return nil
            }

            guard let snapshotURL = preferredSnapshotURL(for: repoURL, fileManager: fileManager),
                  isLikelyMLXModelSnapshot(snapshotURL, fileManager: fileManager)
            else {
                return nil
            }

            let modifiedAt = (try? snapshotURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return LocalModel(
                repoID: repoID,
                snapshotURL: snapshotURL,
                modifiedAt: modifiedAt,
                sizeBytes: snapshotSize(at: snapshotURL, fileManager: fileManager),
                contextSize: contextSize(at: snapshotURL, fileManager: fileManager),
                capabilities: modelCapabilities(at: snapshotURL, fileManager: fileManager)
            )
        }

        return models.sorted { lhs, rhs in
            switch lhs.repoID.localizedCaseInsensitiveCompare(rhs.repoID) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                return lhs.repoID < rhs.repoID
            }
        }
    }

    private static func repoID(fromCacheDirectoryName name: String) -> String? {
        let prefix = "models--"
        guard name.hasPrefix(prefix) else {
            return nil
        }

        let encoded = String(name.dropFirst(prefix.count))
        let parts = encoded.components(separatedBy: "--").filter { !$0.isEmpty }
        guard parts.count >= 2 else {
            return nil
        }
        return parts.joined(separator: "/")
    }

    private static func preferredSnapshotURL(for repoURL: URL, fileManager: FileManager) -> URL? {
        if let mainRef = readRef(named: "main", repoURL: repoURL, fileManager: fileManager) {
            let snapshotURL = repoURL
                .appendingPathComponent("snapshots", isDirectory: true)
                .appendingPathComponent(mainRef, isDirectory: true)
            if isDirectoryURL(snapshotURL, fileManager: fileManager) {
                return snapshotURL
            }
        }

        let snapshotsURL = repoURL.appendingPathComponent("snapshots", isDirectory: true)
        guard let snapshotURLs = try? fileManager.contentsOfDirectory(
            at: snapshotsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return snapshotURLs
            .filter { isDirectoryURL($0, fileManager: fileManager) }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }
            .first
    }

    private static func readRef(named name: String, repoURL: URL, fileManager: FileManager) -> String? {
        let refURL = repoURL
            .appendingPathComponent("refs", isDirectory: true)
            .appendingPathComponent(name)
        guard fileManager.fileExists(atPath: refURL.path),
              let contents = try? String(contentsOf: refURL, encoding: .utf8)
        else {
            return nil
        }

        let ref = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return ref.isEmpty ? nil : ref
    }

    private static func isLikelyMLXModelSnapshot(_ snapshotURL: URL, fileManager: FileManager) -> Bool {
        let configURL = snapshotURL.appendingPathComponent("config.json")
        let tokenizerConfigURL = snapshotURL.appendingPathComponent("tokenizer_config.json")
        let modelIndexURL = snapshotURL.appendingPathComponent("model_index.json")
        guard fileManager.fileExists(atPath: configURL.path) || fileManager.fileExists(atPath: tokenizerConfigURL.path) || fileManager.fileExists(atPath: modelIndexURL.path)
        else {
            return false
        }

        let indexURL = snapshotURL.appendingPathComponent("model.safetensors.index.json")
        if fileManager.fileExists(atPath: indexURL.path) {
            return true
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: snapshotURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return contents.contains { $0.pathExtension == "safetensors" }
    }

    private static func snapshotSize(at snapshotURL: URL, fileManager: FileManager) -> Int64? {
        guard let enumerator = fileManager.enumerator(
            at: snapshotURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var visitedFiles = Set<String>()
        var totalBytes: Int64 = 0
        var foundFile = false

        for case let fileURL as URL in enumerator {
            let resolvedURL = fileURL.resolvingSymlinksInPath()
            guard visitedFiles.insert(resolvedURL.path).inserted,
                  let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize
            else {
                continue
            }
            totalBytes += Int64(fileSize)
            foundFile = true
        }

        return foundFile ? totalBytes : nil
    }

    private static func contextSize(at snapshotURL: URL, fileManager: FileManager) -> Int? {
        let candidates = ["config.json", "tokenizer_config.json"]
        for filename in candidates {
            let url = snapshotURL.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let contextSize = contextSize(in: json)
            else {
                continue
            }
            return contextSize
        }
        return nil
    }

    private static func modelCapabilities(
        at snapshotURL: URL,
        fileManager: FileManager
    ) -> Set<LocalModelCapability> {
        let configURL = snapshotURL.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }

        let keys = recursiveKeys(in: config)
        let descriptors = modelDescriptors(in: config)
        var capabilities = Set<LocalModelCapability>()

        let visionKeys: Set<String> = [
            "vision_config",
            "vision_tower",
            "vit_config",
            "img_processor",
            "image_token_id",
            "image_start_token_id"
        ]
        let visionDescriptors = [
            "vision", "llava", "pixtral", "minicpmv", "molmo", "phi3_v", "omni"
        ]
        if !keys.isDisjoint(with: visionKeys)
            || visionDescriptors.contains(where: descriptors.contains) {
            capabilities.insert(.vision)
        }

        let audioKeys: Set<String> = [
            "audio_config",
            "audio_tower",
            "audio_token_id",
            "speech_config",
            "max_audio_clip_s",
            "sample_rate",
            "code2wav_config",
            "speaker_encoder_config",
            "tts_model_type"
        ]
        let audioDescriptors = [
            "audio", "speech", "whisper", "asr", "tts", "transcribe", "omni"
        ]
        if !keys.isDisjoint(with: audioKeys)
            || audioDescriptors.contains(where: descriptors.contains) {
            capabilities.insert(.audio)
        }

        return capabilities
    }

    private static func recursiveKeys(in value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: Set(dictionary.keys)) { result, entry in
                result.formUnion(recursiveKeys(in: entry.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { result, entry in
                result.formUnion(recursiveKeys(in: entry))
            }
        }
        return []
    }

    private static func modelDescriptors(in config: [String: Any]) -> String {
        let modelType = config["model_type"] as? String ?? ""
        let architectures = config["architectures"] as? [String] ?? []
        return ([modelType] + architectures).joined(separator: " ").lowercased()
    }

    private static func contextSize(in config: [String: Any]) -> Int? {
        let nestedConfigurationKeys = ["text_config", "llm_config", "language_config"]
        let contextKeys = [
            "max_position_embeddings",
            "model_max_length",
            "max_sequence_length",
            "seq_length",
            "n_positions",
            "context_length"
        ]

        for nestedKey in nestedConfigurationKeys {
            if let nested = config[nestedKey] as? [String: Any],
               let value = contextValue(in: nested, keys: contextKeys) {
                return value
            }
        }
        return contextValue(in: config, keys: contextKeys)
    }

    private static func contextValue(in config: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            guard let number = config[key] as? NSNumber else {
                continue
            }
            let value = number.intValue
            if value > 0, value <= 10_000_000 {
                return value
            }
        }
        return nil
    }

    private static func isDirectoryURL(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

enum LocalModelDiscoveryError: LocalizedError, Equatable {
    case pathNotFound(String)
    case notDirectory(String)

    var errorDescription: String? {
        switch self {
        case .pathNotFound:
            return "Search path does not exist"
        case .notDirectory:
            return "Search path is not a folder"
        }
    }
}

@MainActor
final class LocalModelLibrary: ObservableObject {
    @Published private(set) var models: [LocalModel] = []
    @Published private(set) var isScanning = false
    @Published private(set) var error: String?

    private var scanTask: Task<Void, Never>?

    deinit {
        scanTask?.cancel()
    }

    func scan(path: String) {
        scanTask?.cancel()
        isScanning = true
        error = nil

        scanTask = Task { [weak self] in
            do {
                let models = try await LocalModelDiscovery.scan(path: path)
                guard !Task.isCancelled else {
                    return
                }
                self?.models = models
                self?.error = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.models = []
                self?.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }

            guard !Task.isCancelled else {
                return
            }
            self?.isScanning = false
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }
}
