import AppKit
import Foundation
import MLXServerKit
import SwiftUI

struct ChatConfigurationView: View {
    @Binding var settings: MLXServerSettings
    let settingsRequireRestart: Bool
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    modelContextSection
                    kvQuantizationSection
                    thinkingSection
                    samplingSection
                    speculativeDecodingSection
                    structuredOutputSection
                    prefixCachingSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
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
                value: $settings.maxKVSize,
                range: 0...1_048_576
            )

            Text("0 uses the model's native context window.")
                .configurationHintStyle()

            VStack(alignment: .leading, spacing: 8) {
                Text("System prompt")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextEditor(text: $settings.systemPrompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 88)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    }
            }
        }
    }

    private var kvQuantizationSection: some View {
        ChatConfigurationSection(title: "KV Quantization") {
            Toggle("Quantize KV cache", isOn: $settings.kvQuantizationEnabled)
                .configurationToggleStyle()

            if settings.kvQuantizationEnabled {
                Toggle("TurboQuant", isOn: turboQuantBinding)
                    .configurationToggleStyle()

                ConfigurationDoubleField(
                    title: "KV bits",
                    value: $settings.kvBits,
                    range: 2...16
                )

                if !settings.turboQuantEnabled {
                    ConfigurationIntegerField(
                        title: "Group size",
                        value: $settings.kvGroupSize,
                        range: 1...1024
                    )
                }

                ConfigurationIntegerField(
                    title: "Quantize after",
                    value: $settings.quantizedKVStart,
                    range: 0...1_048_576
                )

                Text("Changes to the KV cache require a server restart.")
                    .configurationHintStyle()
            }
        }
    }

    private var thinkingSection: some View {
        ChatConfigurationSection(title: "Thinking") {
            Toggle("Enable Thinking", isOn: $settings.thinkingEnabled)
                .configurationToggleStyle()

            if settings.thinkingEnabled {
                ConfigurationIntegerField(
                    title: "Budget",
                    value: $settings.thinkingBudget,
                    range: 1...262_144
                )
                ConfigurationTextField(title: "Start token", text: $settings.thinkingStartToken)
                ConfigurationTextField(title: "EOS token", text: $settings.thinkingEndToken)
            }
        }
    }

    private var samplingSection: some View {
        ChatConfigurationSection(title: "Sampling") {
            ConfigurationDoubleField(
                title: "Temperature",
                value: $settings.temperature,
                range: 0...2
            )
            ConfigurationIntegerField(
                title: "Top K",
                value: $settings.topK,
                range: 0...10_000
            )
            ConfigurationDoubleField(
                title: "Top P",
                value: $settings.topP,
                range: 0...1
            )
            ConfigurationDoubleField(
                title: "Min P",
                value: $settings.minP,
                range: 0...1
            )

            Toggle("Repetition penalty", isOn: $settings.repetitionPenaltyEnabled)
                .configurationToggleStyle()

            if settings.repetitionPenaltyEnabled {
                ConfigurationDoubleField(
                    title: "Penalty",
                    value: $settings.repetitionPenalty,
                    range: 0...4
                )
            }
        }
    }

    private var speculativeDecodingSection: some View {
        ChatConfigurationSection(title: "Speculative Decoding") {
            Toggle("Enable drafter", isOn: speculativeDecodingBinding)
                .configurationToggleStyle()

            if settings.speculativeDecodingEnabled {
                ConfigurationTextField(title: "Draft model", text: $settings.draftModelID)

                HStack(spacing: 8) {
                    Text("Family")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Picker("", selection: $settings.draftKind) {
                        Text("Auto").tag("auto")
                        Text("DFlash").tag("dflash")
                        Text("EAGLE3").tag("eagle3")
                        Text("MTP").tag("mtp")
                    }
                    .labelsHidden()
                    .frame(width: 112)
                }
                .font(.body)

                ConfigurationIntegerField(
                    title: "Block size",
                    value: $settings.draftBlockSize,
                    range: 0...1024
                )

                Text(settings.draftModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Enter a drafter model to activate speculative decoding."
                    : "The drafter is loaded after the next server restart.")
                    .configurationHintStyle(
                        isError: settings.draftModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
    }

    private var structuredOutputSection: some View {
        ChatConfigurationSection(title: "Structured Output") {
            Toggle("Enforce JSON schema", isOn: structuredOutputBinding)
                .configurationToggleStyle()

            if settings.structuredOutputEnabled {
                ConfigurationTextField(title: "Schema name", text: $settings.structuredOutputName)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("JSON schema")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        Button("Reset") {
                            settings.structuredOutputSchema = MLXServerSettings.defaultStructuredOutputSchema
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                    }

                    TextEditor(text: $settings.structuredOutputSchema)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 128)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(
                                    settings.structuredOutputValidationError == nil
                                        ? Color(nsColor: .separatorColor)
                                        : Color.red.opacity(0.7),
                                    lineWidth: 0.5
                                )
                        }
                }

                if let error = settings.structuredOutputValidationError {
                    Text(error)
                        .configurationHintStyle(isError: true)
                }
            }
        }
    }

    private var prefixCachingSection: some View {
        ChatConfigurationSection(title: "Prefix Caching") {
            Toggle("Enable automatic caching", isOn: $settings.prefixCachingEnabled)
                .configurationToggleStyle()

            if settings.prefixCachingEnabled {
                ConfigurationIntegerField(
                    title: "Cache blocks",
                    value: $settings.prefixCacheBlocks,
                    range: 1...1_048_576
                )
                ConfigurationIntegerField(
                    title: "Tokens per block",
                    value: $settings.prefixCacheBlockSize,
                    range: 1...4096
                )
                Text("Shared prompt prefixes are reused after a server restart.")
                    .configurationHintStyle()
            }
        }
    }

    private var turboQuantBinding: Binding<Bool> {
        Binding(
            get: { settings.turboQuantEnabled },
            set: { enabled in
                settings.turboQuantEnabled = enabled
                if enabled, settings.kvBits == 8 {
                    settings.kvBits = 3.5
                } else if !enabled, settings.kvBits == 3.5 {
                    settings.kvBits = 8
                }
            }
        )
    }

    private var speculativeDecodingBinding: Binding<Bool> {
        Binding(
            get: { settings.speculativeDecodingEnabled },
            set: { enabled in
                settings.speculativeDecodingEnabled = enabled
                if enabled {
                    settings.structuredOutputEnabled = false
                }
            }
        )
    }

    private var structuredOutputBinding: Binding<Bool> {
        Binding(
            get: { settings.structuredOutputEnabled },
            set: { enabled in
                settings.structuredOutputEnabled = enabled
                if enabled {
                    settings.speculativeDecodingEnabled = false
                }
            }
        )
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
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            TextField(
                "",
                value: $value,
                format: .number.precision(.fractionLength(0...3))
            )
            .font(.body)
            .multilineTextAlignment(.trailing)
            .frame(width: 104)
            .onChange(of: value) { _, newValue in
                value = min(max(newValue, range.lowerBound), range.upperBound)
            }
        }
    }
}

private struct ConfigurationTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(title, text: $text)
                .font(.body)
        }
    }
}

private extension View {
    func configurationToggleStyle() -> some View {
        toggleStyle(.switch)
            .controlSize(.regular)
            .font(.body)
    }

    func configurationHintStyle(isError: Bool = false) -> some View {
        font(.footnote)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

