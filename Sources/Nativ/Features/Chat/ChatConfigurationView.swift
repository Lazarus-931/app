import AppKit
import Foundation
import NativServerKit
import SwiftUI

struct ChatConfigurationView: View {
    @Binding var settings: NativSettings
    let settingsRequireRestart: Bool
    let onReset: () -> Void
    @State private var modelConfiguration: LocalModelConfigurationMetadata?
    @State private var isLoadingModelConfiguration = false
    @State private var modelConfigurationRevision = 0

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    modelContextSection
                    generationSection
                    kvCacheSection
                    thinkingSection
                    speculativeSection
                    advancedSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
        }
        .background(Color.nativPanel.opacity(0.45))
        .task(id: modelConfigurationLookupID) {
            await loadModelConfiguration(for: modelConfigurationLookupID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .localModelLibraryDidChange)) { _ in
            modelConfigurationRevision += 1
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Model Configuration", systemImage: "slider.horizontal.3")
                    .font(.title3.weight(.semibold))

                Spacer(minLength: 0)

                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset model configuration")
            }

            if settingsRequireRestart {
                Label("Server restart required", systemImage: "arrow.clockwise")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                Text("Request settings apply to the next message.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var modelContextSection: some View {
        ChatConfigurationSection(title: "Model Context") {
            ConfigurationIntegerField(
                title: "Max output",
                value: $settings.maxTokens,
                range: 1...262_144
            )

            ConfigurationIntegerField(
                title: "Context window",
                value: modelContextBinding,
                range: 0...1_048_576
            )
            .disabled(isLoadingModelConfiguration)

            VStack(alignment: .leading, spacing: 8) {
                Text("System prompt")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    if settings.systemPrompt.isEmpty {
                        Text(systemPromptPlaceholder)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .lineLimit(4)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $settings.systemPrompt)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                }
                .frame(minHeight: 88)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }

                Text(systemPromptHint)
                    .configurationHintStyle()
            }
        }
    }

    private var generationSection: some View {
        ChatConfigurationSection(title: "Generation") {
            ConfigurationDoubleField(title: "Temperature", value: $settings.temperature)
            ConfigurationIntegerField(title: "Top K", value: $settings.topK, range: 0...1000)
            ConfigurationDoubleField(title: "Top P", value: $settings.topP)
            ConfigurationDoubleField(title: "Min P", value: $settings.minP)
            Toggle("Repetition penalty", isOn: $settings.repetitionPenaltyEnabled)
            if settings.repetitionPenaltyEnabled {
                ConfigurationDoubleField(title: "Penalty", value: $settings.repetitionPenalty)
            }
        }
    }

    private var kvCacheSection: some View {
        ChatConfigurationSection(title: "KV Cache") {
            Toggle("KV cache quantization", isOn: $settings.kvQuantizationEnabled)
            if settings.kvQuantizationEnabled {
                ConfigurationDoubleField(title: "KV bits", value: $settings.kvBits)
                ConfigurationIntegerField(title: "Group size", value: $settings.kvGroupSize, range: 1...1024)
                ConfigurationIntegerField(title: "Quantized KV start", value: $settings.quantizedKVStart, range: 0...1_048_576)
                Toggle("TurboQuant", isOn: $settings.turboQuantEnabled)
            }
        }
    }

    private var thinkingSection: some View {
        ChatConfigurationSection(title: "Thinking") {
            Toggle("Enable thinking", isOn: $settings.thinkingEnabled)
            if settings.thinkingEnabled {
                Toggle("Thinking budget", isOn: $settings.thinkingBudgetEnabled)
                if settings.thinkingBudgetEnabled {
                    ConfigurationIntegerField(title: "Budget (tokens)", value: $settings.thinkingBudget, range: 0...1_048_576)
                }
                ConfigurationTextRow(title: "Start token", text: $settings.thinkingStartToken)
                ConfigurationTextRow(title: "End token", text: $settings.thinkingEndToken)
            }
        }
    }

    private var speculativeSection: some View {
        ChatConfigurationSection(title: "Speculative Decoding") {
            Toggle("Enable speculative decoding", isOn: $settings.speculativeDecodingEnabled)
            if settings.speculativeDecodingEnabled {
                ConfigurationTextRow(title: "Draft model", text: $settings.draftModelID)
                ConfigurationTextRow(title: "Draft kind", text: $settings.draftKind)
                ConfigurationIntegerField(title: "Draft block size", value: $settings.draftBlockSize, range: 0...4096)
            }
        }
    }

    private var advancedSection: some View {
        ChatConfigurationSection(title: "Advanced") {
            Toggle("Structured output", isOn: $settings.structuredOutputEnabled)
            if settings.structuredOutputEnabled {
                ConfigurationTextRow(title: "Schema name", text: $settings.structuredOutputName)
                TextField("Schema (JSON)", text: $settings.structuredOutputSchema, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Prefix caching", isOn: $settings.prefixCachingEnabled)
            if settings.prefixCachingEnabled {
                ConfigurationIntegerField(title: "Cache blocks", value: $settings.prefixCacheBlocks, range: 0...100_000)
                ConfigurationIntegerField(title: "Block size", value: $settings.prefixCacheBlockSize, range: 1...4096)
            }
        }
    }

    private var modelConfigurationLookupID: String {
        let normalizedSettings = settings.normalized()
        return [
            normalizedSettings.modelSearchPath,
            normalizedSettings.languageModelID ?? "",
            String(modelConfigurationRevision)
        ].joined(separator: "\u{0}")
    }

    private func loadModelConfiguration(for lookupID: String) async {
        modelConfiguration = nil
        guard let modelID = settings.normalized().languageModelID else {
            isLoadingModelConfiguration = false
            return
        }

        isLoadingModelConfiguration = true
        let metadata = await LocalModelDiscovery.configurationMetadata(
            repoID: modelID,
            path: settings.modelSearchPath
        )
        guard lookupID == modelConfigurationLookupID else {
            return
        }
        modelConfiguration = metadata
        isLoadingModelConfiguration = false
    }

    private var modelContextBinding: Binding<Int> {
        Binding(
            get: {
                settings.maxKVSize > 0
                    ? settings.maxKVSize
                    : (modelConfiguration?.contextSize ?? 0)
            },
            set: { value in
                if value == modelConfiguration?.contextSize {
                    settings.maxKVSize = 0
                } else {
                    settings.maxKVSize = value
                }
            }
        )
    }

    private var systemPromptPlaceholder: String {
        if isLoadingModelConfiguration {
            return "Reading chat template…"
        }
        return modelConfiguration?.defaultSystemPrompt ?? "Optional custom system prompt"
    }

    private var systemPromptHint: String {
        if isLoadingModelConfiguration {
            return "Looking for a default system prompt in the chat template."
        }
        if modelConfiguration?.defaultSystemPrompt != nil {
            return settings.systemPrompt.isEmpty
                ? "Template default shown above. Enter text to override it."
                : "Custom prompt overrides the model's chat-template default."
        }
        return "No default system prompt was found in the chat template."
    }
}

private struct ChatConfigurationSection<Content: View>: View {
    let title: String
    private let content: Content

    init(
        title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Text(title)
                .font(.headline)
        }
    }
}

private struct ConfigurationIntegerField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            TextField("", value: $value, format: .number)
                .font(.body)
                .multilineTextAlignment(.trailing)
                .frame(width: 104)
                .onChange(of: value) { _, newValue in
                    value = min(max(newValue, range.lowerBound), range.upperBound)
                }
        }
    }
}

private struct ConfigurationDoubleField: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            TextField("", value: $value, format: .number)
                .font(.body)
                .multilineTextAlignment(.trailing)
                .frame(width: 104)
        }
    }
}

private struct ConfigurationTextRow: View {
    let title: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            TextField("", text: $text)
                .font(.body)
                .multilineTextAlignment(.trailing)
                .frame(width: 140)
        }
    }
}

private extension View {
    func configurationHintStyle(isError: Bool = false) -> some View {
        font(.footnote)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
