import Foundation

struct LocalModel: Identifiable, Equatable, Sendable {
    var id: String { repoID }

    let repoID: String
    let snapshotURL: URL?
    let modifiedAt: Date?
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
            return LocalModel(repoID: repoID, snapshotURL: snapshotURL, modifiedAt: modifiedAt)
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
        guard fileManager.fileExists(atPath: configURL.path),
              fileManager.fileExists(atPath: tokenizerConfigURL.path)
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
