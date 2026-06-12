import AppKit
import Combine
import Foundation
import MLXServerKit
import UniformTypeIdentifiers

@MainActor
final class ImageGenerationViewModel: ObservableObject {
    @Published var prompt = ""
    @Published var modelID = ""
    @Published var count = 1
    @Published var width = 512
    @Published var height = 512
    @Published var steps = 4
    @Published var guidance = 1.0
    @Published var seedText = ""
    @Published private(set) var referenceImage: ImageGenerationReferenceImage?
    @Published private(set) var results: [GeneratedImage] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var statusText: String?
    @Published private(set) var errorText: String?

    private let client = MLXServerImageClient()
    private var activeTask: Task<Void, Never>?

    deinit {
        activeTask?.cancel()
    }

    func applyDefaultModel(_ selectedModelID: String?) {
        guard modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let selectedModelID,
              !selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        modelID = selectedModelID
    }

    func unavailableReason(isRunning: Bool) -> String? {
        if !isRunning {
            return "Server is stopped."
        }
        if normalizedModelID == nil {
            return "Enter an image model."
        }
        if normalizedPrompt == nil {
            return "Enter a prompt."
        }
        if parsedSeed == nil {
            return "Seed must be a whole number."
        }
        if isGenerating {
            return referenceImage == nil ? "Generation in progress." : "Edit in progress."
        }
        return nil
    }

    func run(using appModel: MLXServerDemoModel) {
        guard !isGenerating,
              appModel.isRunning,
              let requestModelID = normalizedModelID,
              let requestPrompt = normalizedPrompt,
              let requestSeed = parsedSeed
        else {
            return
        }

        let requestCount = min(max(count, 1), 10)
        let requestWidth = min(max(width, 64), 4096)
        let requestHeight = min(max(height, 64), 4096)
        let requestSteps = min(max(steps, 1), 1_000)
        let requestGuidance = min(max(guidance, 0), 100)
        let requestReference = referenceImage

        count = requestCount
        width = requestWidth
        height = requestHeight
        steps = requestSteps
        guidance = requestGuidance
        errorText = nil
        statusText = requestReference == nil ? "Generating image..." : "Editing image..."
        isGenerating = true

        activeTask?.cancel()
        activeTask = Task { @MainActor [weak self, weak appModel] in
            guard let self else {
                return
            }

            do {
                let response: MLXImageResponse
                if let requestReference {
                    response = try await client.edit(MLXImageEditRequest(
                        model: requestModelID,
                        prompt: requestPrompt,
                        image: [requestReference.url.path],
                        n: requestCount,
                        width: requestWidth,
                        height: requestHeight,
                        steps: requestSteps,
                        seed: requestSeed,
                        guidance: requestGuidance
                    ))
                } else {
                    response = try await client.generate(MLXImageGenerationRequest(
                        model: requestModelID,
                        prompt: requestPrompt,
                        n: requestCount,
                        width: requestWidth,
                        height: requestHeight,
                        steps: requestSteps,
                        seed: requestSeed,
                        guidance: requestGuidance
                    ))
                }

                let decodedResults = try makeGeneratedImages(from: response)
                results = decodedResults
                statusText = "\(decodedResults.count) \(decodedResults.count == 1 ? "image" : "images") ready."
                appModel?.refreshMetricsIfRunning(force: true)
            } catch is CancellationError {
                statusText = "Cancelled."
            } catch {
                errorText = error.localizedDescription
                statusText = nil
                appModel?.refreshMetricsIfRunning(force: true)
            }

            isGenerating = false
            activeTask = nil
        }
    }

    func cancel() {
        activeTask?.cancel()
    }

    func chooseReferenceImage() {
        guard !isGenerating else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        guard panel.runModal() == .OK,
              let url = panel.url
        else {
            return
        }

        do {
            referenceImage = try ImageGenerationReferenceImage(contentsOf: url)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    func removeReferenceImage() {
        guard !isGenerating else {
            return
        }

        referenceImage = nil
    }

    func clearResults() {
        guard !isGenerating else {
            return
        }

        results.removeAll()
        statusText = nil
        errorText = nil
    }

    func save(_ result: GeneratedImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "image-\(result.seed).png"

        guard panel.runModal() == .OK,
              let url = panel.url
        else {
            return
        }

        do {
            try result.imageData.write(to: url, options: .atomic)
            statusText = "Saved \(url.lastPathComponent)."
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private var normalizedModelID: String? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var normalizedPrompt: String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var parsedSeed: Int?? {
        let trimmed = seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .some(nil)
        }
        guard let seed = Int(trimmed) else {
            return nil
        }
        return .some(seed)
    }

    private func makeGeneratedImages(from response: MLXImageResponse) throws -> [GeneratedImage] {
        let generatedImages = response.data.compactMap { item -> GeneratedImage? in
            let imageData: Data?
            if let b64JSON = item.b64JSON {
                imageData = Data(base64Encoded: b64JSON)
            } else if let path = item.path {
                imageData = try? Data(contentsOf: URL(fileURLWithPath: path))
            } else {
                imageData = nil
            }

            guard let imageData,
                  NSImage(data: imageData) != nil
            else {
                return nil
            }

            return GeneratedImage(
                imageData: imageData,
                mimeType: item.mimeType,
                width: item.width,
                height: item.height,
                seed: item.seed,
                path: item.path,
                revisedPrompt: item.revisedPrompt
            )
        }

        guard !generatedImages.isEmpty else {
            throw MLXServerImageError.missingImageData
        }
        return generatedImages
    }
}

struct ImageGenerationReferenceImage: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let filename: String
    let imageData: Data

    init(id: UUID = UUID(), contentsOf url: URL) throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)

        self.id = id
        self.filename = url.lastPathComponent
        self.imageData = data
        self.url = try Self.writeReferenceCopy(
            originalURL: url,
            id: id,
            imageData: data
        )
    }

    var nsImage: NSImage? {
        NSImage(data: imageData)
    }

    private static func writeReferenceCopy(
        originalURL: URL,
        id: UUID,
        imageData: Data
    ) throws -> URL {
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = caches
            .appendingPathComponent("MLXServerDemo", isDirectory: true)
            .appendingPathComponent("ImageGeneration", isDirectory: true)
            .appendingPathComponent("References", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileExtension = originalURL.pathExtension.isEmpty ? "png" : originalURL.pathExtension
        let destination = directory.appendingPathComponent("\(id.uuidString).\(fileExtension)")
        try imageData.write(to: destination, options: .atomic)
        return destination
    }
}

struct GeneratedImage: Identifiable, Equatable, Sendable {
    let id = UUID()
    let imageData: Data
    let mimeType: String
    let width: Int
    let height: Int
    let seed: Int
    let path: String?
    let revisedPrompt: String?

    var nsImage: NSImage? {
        NSImage(data: imageData)
    }
}
