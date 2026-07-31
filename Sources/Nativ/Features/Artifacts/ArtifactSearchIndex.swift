import Foundation
import NativServerKit

@MainActor
final class ArtifactSearchIndex: ObservableObject {
    @Published private(set) var indexedCount = 0
    @Published private(set) var isIndexing = false

    // Each artifact keeps its component vectors separately (image content and
    // metadata text). Matching takes the best component so a strong image match
    // is never diluted by weak metadata.
    private var vectors: [UUID: [[Float]]] = [:]
    private let storageURL: URL

    private static let matchThreshold: Float = 0.35

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        storageURL = support
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Artifact Vectors.json")
        vectors = Self.load(storageURL)
        indexedCount = vectors.count
    }

    var hasIndex: Bool {
        !vectors.isEmpty
    }

    func index(
        artifacts: [Artifact],
        model: String,
        client: NativEmbeddingsClient,
        dataURL: @escaping (Artifact) async -> String?
    ) async {
        guard !isIndexing else {
            return
        }
        isIndexing = true
        defer { isIndexing = false }

        let liveIDs = Set(artifacts.map(\.id))
        vectors = vectors.filter { liveIDs.contains($0.key) }

        for artifact in artifacts where vectors[artifact.id] == nil {
            if Task.isCancelled {
                break
            }
            if let components = await Self.embed(artifact: artifact, model: model, client: client, dataURL: dataURL) {
                vectors[artifact.id] = components
                indexedCount = vectors.count
            }
        }
        Self.save(vectors, to: storageURL)
    }

    func search(query: String, model: String, client: NativEmbeddingsClient, limit: Int = 400) async -> [UUID]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !vectors.isEmpty else {
            return nil
        }
        // This VLM aligns poorly with bare keywords; a caption-style prompt
        // pulls the query into the same space as the image embeddings.
        guard let queryVector = try? await client.embed(text: "a photo of \(trimmed)", model: model) else {
            return nil
        }
        let normalizedQuery = Self.normalized(queryVector)
        let ranked = vectors
            .map { (id: $0.key, score: Self.bestScore(normalizedQuery, $0.value)) }
            .filter { $0.score > Self.matchThreshold }
            .sorted { $0.score > $1.score }
            .prefix(limit)
        return ranked.map(\.id)
    }

    func clear() {
        vectors = [:]
        indexedCount = 0
        try? FileManager.default.removeItem(at: storageURL)
    }

    // MARK: - Embedding

    private static func embed(
        artifact: Artifact,
        model: String,
        client: NativEmbeddingsClient,
        dataURL: (Artifact) async -> String?
    ) async -> [[Float]]? {
        let metadata = [artifact.filename, artifact.sessionTitle, artifact.prompt ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        var components: [[Float]] = []
        if artifact.kind == .image, let url = await dataURL(artifact),
           let imageVector = try? await client.embed(dataURL: url, model: model) {
            components.append(normalized(imageVector))
        }
        if !metadata.isEmpty, let textVector = try? await client.embed(text: metadata, model: model) {
            components.append(normalized(textVector))
        }
        return components.isEmpty ? nil : components
    }

    private static func bestScore(_ query: [Float], _ components: [[Float]]) -> Float {
        components.map { dot(query, $0) }.max() ?? -1
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else {
            return vector
        }
        return vector.map { $0 / magnitude }
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else {
            return 0
        }
        var total: Float = 0
        for index in 0..<a.count {
            total += a[index] * b[index]
        }
        return total
    }

    // MARK: - Persistence

    private static func load(_ url: URL) -> [UUID: [[Float]]] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: [[Float]]].self, from: data)
        else {
            return [:]
        }
        var result: [UUID: [[Float]]] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key) {
                result[id] = value
            }
        }
        return result
    }

    private static func save(_ vectors: [UUID: [[Float]]], to url: URL) {
        var raw: [String: [[Float]]] = [:]
        for (id, value) in vectors {
            raw[id.uuidString] = value
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(raw) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}
