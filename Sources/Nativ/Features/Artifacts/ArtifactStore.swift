import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ArtifactStore: ObservableObject {
    @Published private(set) var artifacts: [Artifact] = []
    @Published private(set) var isRefreshing = false

    private let baseDirectory: URL

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        baseDirectory = support
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Artifacts", isDirectory: true)

        artifacts = Self.loadManifest(baseDirectory: baseDirectory)
        refresh()
    }

    func fileURL(for artifact: Artifact) -> URL {
        baseDirectory.appendingPathComponent(artifact.relativePath)
    }

    func refresh() {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        let base = baseDirectory
        let known = artifacts
        Task.detached(priority: .utility) {
            let rebuilt = Self.rebuild(baseDirectory: base, known: known)
            await MainActor.run {
                self.artifacts = rebuilt
                self.isRefreshing = false
            }
        }
    }

    func delete(_ artifact: Artifact) {
        try? FileManager.default.removeItem(at: fileURL(for: artifact))
        artifacts.removeAll { $0.id == artifact.id }
        Self.writeManifest(artifacts, baseDirectory: baseDirectory)
    }

    func revealInFinder(_ artifact: Artifact) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(for: artifact)])
    }

    func open(_ artifact: Artifact) {
        NSWorkspace.shared.open(fileURL(for: artifact))
    }

    func export(_ artifact: Artifact) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = artifact.filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: fileURL(for: artifact), to: destination)
    }

    func copyToPasteboard(_ artifact: Artifact) {
        let url = fileURL(for: artifact)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var items: [NSPasteboardWriting] = [url as NSURL]
        if artifact.kind == .image, let image = NSImage(contentsOf: url) {
            items.append(image)
        }
        pasteboard.writeObjects(items)
    }

    func chatAttachment(for artifact: Artifact) -> ChatImageAttachment? {
        try? ChatImageAttachment(contentsOf: fileURL(for: artifact))
    }

    // MARK: - Scanning

    private nonisolated static func rebuild(baseDirectory: URL, known: [Artifact]) -> [Artifact] {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        var byID = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var live: Set<UUID> = []
        var result: [Artifact] = []

        for session in ChatSessionStore().loadSessions() {
            var lastUserPrompt = ""
            for message in session.messages {
                if message.role == .user, !message.content.isEmpty {
                    lastUserPrompt = message.content
                }

                for attachment in message.imageAttachments {
                    if let artifact = materialize(
                        attachment,
                        source: .uploaded,
                        prompt: message.content.isEmpty ? nil : message.content,
                        session: session,
                        message: message,
                        baseDirectory: baseDirectory,
                        existing: byID[attachment.id]
                    ) {
                        live.insert(artifact.id)
                        result.append(artifact)
                        byID[artifact.id] = artifact
                    }
                }

                for attachment in message.generatedImages {
                    if let artifact = materialize(
                        attachment,
                        source: .generated,
                        prompt: lastUserPrompt.isEmpty ? nil : lastUserPrompt,
                        session: session,
                        message: message,
                        baseDirectory: baseDirectory,
                        existing: byID[attachment.id]
                    ) {
                        live.insert(artifact.id)
                        result.append(artifact)
                        byID[artifact.id] = artifact
                    }
                }
            }
        }

        for (id, artifact) in byID where !live.contains(id) {
            try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(artifact.relativePath))
        }

        let sorted = result.sorted(by: recencySort)
        writeManifest(sorted, baseDirectory: baseDirectory)
        return sorted
    }

    private nonisolated static func materialize(
        _ attachment: ChatImageAttachment,
        source: ArtifactSource,
        prompt: String?,
        session: ChatSession,
        message: ChatTranscriptMessage,
        baseDirectory: URL,
        existing: Artifact?
    ) -> Artifact? {
        let kind = ArtifactKind.resolve(mimeType: attachment.mimeType, filename: attachment.filename)
        let relativePath = "\(kind.rawValue)/\(attachment.id.uuidString).\(fileExtension(for: attachment))"
        let destination = baseDirectory.appendingPathComponent(relativePath)
        let fileManager = FileManager.default

        if let existing, fileManager.fileExists(atPath: destination.path) {
            return existing
        }

        guard let data = Data(base64Encoded: attachment.base64Data) else {
            return nil
        }

        try? fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard (try? data.write(to: destination, options: .atomic)) != nil else {
            return nil
        }

        return Artifact(
            id: attachment.id,
            kind: kind,
            source: source,
            sessionID: session.id,
            messageID: message.id,
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            relativePath: relativePath,
            byteSize: data.count,
            createdAt: message.createdAt,
            prompt: prompt
        )
    }

    private nonisolated static func fileExtension(for attachment: ChatImageAttachment) -> String {
        if let ext = UTType(mimeType: attachment.mimeType)?.preferredFilenameExtension {
            return ext
        }
        let ext = (attachment.filename as NSString).pathExtension
        return ext.isEmpty ? "dat" : ext
    }

    private nonisolated static func recencySort(_ lhs: Artifact, _ rhs: Artifact) -> Bool {
        lhs.createdAt > rhs.createdAt
    }

    // MARK: - Manifest

    private nonisolated static func manifestURL(baseDirectory: URL) -> URL {
        baseDirectory.appendingPathComponent("manifest.json")
    }

    private nonisolated static func loadManifest(baseDirectory: URL) -> [Artifact] {
        guard let data = try? Data(contentsOf: manifestURL(baseDirectory: baseDirectory)) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Artifact].self, from: data)) ?? []
    }

    private nonisolated static func writeManifest(_ artifacts: [Artifact], baseDirectory: URL) {
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(artifacts) else {
            return
        }
        try? data.write(to: manifestURL(baseDirectory: baseDirectory), options: .atomic)
    }
}
