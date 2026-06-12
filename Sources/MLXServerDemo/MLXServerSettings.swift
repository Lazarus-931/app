import Foundation

struct MLXServerSettings: Codable, Equatable {
    static let defaultModelSearchPath = "~/.cache/huggingface/hub"

    var modelSearchPath: String
    var languageModelID: String?
    var imageGenerationModelID: String?
    var textToSpeechModelID: String?
    var speechToTextModelID: String?
    var maxTokens: Int
    var temperature: Double
    var topK: Int
    var topP: Double
    var minP: Double
    var repetitionPenaltyEnabled: Bool
    var repetitionPenalty: Double

    init(
        modelSearchPath: String = Self.defaultModelSearchPath,
        languageModelID: String? = nil,
        imageGenerationModelID: String? = nil,
        textToSpeechModelID: String? = nil,
        speechToTextModelID: String? = nil,
        maxTokens: Int = 2048,
        temperature: Double = 0,
        topK: Int = 0,
        topP: Double = 1,
        minP: Double = 0,
        repetitionPenaltyEnabled: Bool = false,
        repetitionPenalty: Double = 1.1
    ) {
        self.modelSearchPath = modelSearchPath
        self.languageModelID = languageModelID
        self.imageGenerationModelID = imageGenerationModelID
        self.textToSpeechModelID = textToSpeechModelID
        self.speechToTextModelID = speechToTextModelID
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.repetitionPenaltyEnabled = repetitionPenaltyEnabled
        self.repetitionPenalty = repetitionPenalty
    }

    enum CodingKeys: String, CodingKey {
        case modelSearchPath
        case languageModelID
        case imageGenerationModelID
        case textToSpeechModelID
        case speechToTextModelID
        case selectedModelID
        case maxTokens
        case temperature
        case topK
        case topP
        case minP
        case repetitionPenaltyEnabled
        case repetitionPenalty
    }

    init(from decoder: Decoder) throws {
        let defaults = Self()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacySelectedModelID = try container.decodeIfPresent(String.self, forKey: .selectedModelID)
        modelSearchPath = try container.decodeIfPresent(String.self, forKey: .modelSearchPath) ?? defaults.modelSearchPath
        languageModelID = try container.decodeIfPresent(String.self, forKey: .languageModelID) ?? legacySelectedModelID ?? defaults.languageModelID
        imageGenerationModelID = try container.decodeIfPresent(String.self, forKey: .imageGenerationModelID) ?? defaults.imageGenerationModelID
        textToSpeechModelID = try container.decodeIfPresent(String.self, forKey: .textToSpeechModelID) ?? defaults.textToSpeechModelID
        speechToTextModelID = try container.decodeIfPresent(String.self, forKey: .speechToTextModelID) ?? defaults.speechToTextModelID
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? defaults.maxTokens
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? defaults.temperature
        topK = try container.decodeIfPresent(Int.self, forKey: .topK) ?? defaults.topK
        topP = try container.decodeIfPresent(Double.self, forKey: .topP) ?? defaults.topP
        minP = try container.decodeIfPresent(Double.self, forKey: .minP) ?? defaults.minP
        repetitionPenaltyEnabled = try container.decodeIfPresent(Bool.self, forKey: .repetitionPenaltyEnabled) ?? defaults.repetitionPenaltyEnabled
        repetitionPenalty = try container.decodeIfPresent(Double.self, forKey: .repetitionPenalty) ?? defaults.repetitionPenalty
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelSearchPath, forKey: .modelSearchPath)
        try container.encodeIfPresent(languageModelID, forKey: .languageModelID)
        try container.encodeIfPresent(imageGenerationModelID, forKey: .imageGenerationModelID)
        try container.encodeIfPresent(textToSpeechModelID, forKey: .textToSpeechModelID)
        try container.encodeIfPresent(speechToTextModelID, forKey: .speechToTextModelID)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(topK, forKey: .topK)
        try container.encode(topP, forKey: .topP)
        try container.encode(minP, forKey: .minP)
        try container.encode(repetitionPenaltyEnabled, forKey: .repetitionPenaltyEnabled)
        try container.encode(repetitionPenalty, forKey: .repetitionPenalty)
    }

    static func load() -> Self {
        guard let data = try? Data(contentsOf: storageURL) else {
            return Self()
        }
        return (try? PropertyListDecoder().decode(Self.self, from: data)) ?? Self()
    }

    func save() {
        do {
            let url = Self.storageURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListEncoder().encode(normalized())
            try data.write(to: url, options: .atomic)
        } catch {
            // Settings should not prevent the server from running.
        }
    }

    func normalized() -> Self {
        var settings = self
        let trimmedPath = settings.modelSearchPath.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.modelSearchPath = trimmedPath.isEmpty ? Self.defaultModelSearchPath : trimmedPath
        settings.languageModelID = Self.normalizedModelID(settings.languageModelID)
        settings.imageGenerationModelID = Self.normalizedModelID(settings.imageGenerationModelID)
        settings.textToSpeechModelID = Self.normalizedModelID(settings.textToSpeechModelID)
        settings.speechToTextModelID = Self.normalizedModelID(settings.speechToTextModelID)
        settings.maxTokens = min(max(settings.maxTokens, 1), 262_144)
        settings.temperature = min(max(settings.temperature, 0), 2)
        settings.topK = min(max(settings.topK, 0), 10_000)
        settings.topP = min(max(settings.topP, 0), 1)
        settings.minP = min(max(settings.minP, 0), 1)
        settings.repetitionPenalty = min(max(settings.repetitionPenalty, 0), 4)
        return settings
    }

    func hasSameLaunchConfiguration(as other: Self) -> Bool {
        let lhs = normalized()
        let rhs = other.normalized()
        return lhs.modelSearchPath == rhs.modelSearchPath
            && lhs.languageModelID == rhs.languageModelID
            && lhs.maxTokens == rhs.maxTokens
    }

    var launchEnvironment: [String: String] {
        let settings = normalized()
        return [
            "HF_HUB_CACHE": settings.expandedModelSearchPath
        ]
    }

    var launchArguments: [String] {
        let settings = normalized()
        var arguments = [
            "--max-tokens", "\(settings.maxTokens)"
        ]

        if let languageModelID = settings.languageModelID {
            arguments.append(contentsOf: ["--model", languageModelID])
        }

        return arguments
    }

    var expandedModelSearchPath: String {
        NSString(string: modelSearchPath).expandingTildeInPath
    }

    private static func normalizedModelID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static var storageURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let baseURL = applicationSupport ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("MLXServerDemo", isDirectory: true)
            .appendingPathComponent("Settings.plist")
    }
}
