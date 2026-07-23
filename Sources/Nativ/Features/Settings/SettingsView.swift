import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: NativModel
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage("sidebarPinned") private var pinNavigationPanel = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            if model.settingsRequireRestart {
                Section {
                    Label(
                        "The server is running with different settings. Restart it to apply changes.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("Models") {
                TextField("Model search path", text: $model.settings.modelSearchPath)
                TextField("Language model", text: optionalString($model.settings.languageModelID))
                TextField("Image generation model", text: optionalString($model.settings.imageGenerationModelID))
                TextField("Text-to-speech model", text: optionalString($model.settings.textToSpeechModelID))
                TextField("Speech-to-text model", text: optionalString($model.settings.speechToTextModelID))
            }

            Section("Hugging Face") {
                SecureField("Access token", text: optionalString($model.settings.huggingFaceToken))
                Text(huggingFaceTokenStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Generation") {
                TextField("System prompt", text: $model.settings.systemPrompt, axis: .vertical)
                    .lineLimit(2...6)
                numberField("Max tokens", value: $model.settings.maxTokens)
                doubleField("Temperature", value: $model.settings.temperature)
                numberField("Top K", value: $model.settings.topK)
                doubleField("Top P", value: $model.settings.topP)
                doubleField("Min P", value: $model.settings.minP)
                Toggle("Repetition penalty", isOn: $model.settings.repetitionPenaltyEnabled)
                if model.settings.repetitionPenaltyEnabled {
                    doubleField("Penalty", value: $model.settings.repetitionPenalty)
                }
            }

            Section("KV Cache") {
                numberField("Max KV size (0 = unlimited)", value: $model.settings.maxKVSize)
                Toggle("KV cache quantization", isOn: $model.settings.kvQuantizationEnabled)
                if model.settings.kvQuantizationEnabled {
                    doubleField("KV bits", value: $model.settings.kvBits)
                    numberField("Group size", value: $model.settings.kvGroupSize)
                    numberField("Quantized KV start", value: $model.settings.quantizedKVStart)
                    Toggle("TurboQuant", isOn: $model.settings.turboQuantEnabled)
                }
            }

            Section("Thinking") {
                Toggle("Enable thinking", isOn: $model.settings.thinkingEnabled)
                if model.settings.thinkingEnabled {
                    Toggle("Thinking budget", isOn: $model.settings.thinkingBudgetEnabled)
                    if model.settings.thinkingBudgetEnabled {
                        numberField("Budget (tokens)", value: $model.settings.thinkingBudget)
                    }
                    TextField("Start token", text: $model.settings.thinkingStartToken)
                    TextField("End token", text: $model.settings.thinkingEndToken)
                }
            }

            Section("Speculative Decoding") {
                Toggle("Enable speculative decoding", isOn: $model.settings.speculativeDecodingEnabled)
                if model.settings.speculativeDecodingEnabled {
                    TextField("Draft model", text: $model.settings.draftModelID)
                    TextField("Draft kind", text: $model.settings.draftKind)
                    numberField("Draft block size (0 = auto)", value: $model.settings.draftBlockSize)
                }
            }

            Section("Advanced") {
                Toggle("Structured output", isOn: $model.settings.structuredOutputEnabled)
                if model.settings.structuredOutputEnabled {
                    TextField("Schema name", text: $model.settings.structuredOutputName)
                    TextField("Schema (JSON)", text: $model.settings.structuredOutputSchema, axis: .vertical)
                        .lineLimit(3...10)
                        .font(.system(.body, design: .monospaced))
                }
                Toggle("Prefix caching", isOn: $model.settings.prefixCachingEnabled)
                if model.settings.prefixCachingEnabled {
                    numberField("Cache blocks", value: $model.settings.prefixCacheBlocks)
                    numberField("Block size", value: $model.settings.prefixCacheBlockSize)
                }
            }

            Section("App") {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                Toggle("Pin navigation panel", isOn: $pinNavigationPanel)
                Toggle("Launch at login", isOn: $launchAtLogin)
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onChange(of: appearanceRaw) { _, newValue in
            (AppAppearance(rawValue: newValue) ?? .system).apply()
        }
        .onChange(of: launchAtLogin) { _, enabled in
            updateLaunchAtLogin(enabled)
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        guard enabled != (SMAppService.mainApp.status == .enabled) else {
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = error.localizedDescription
        }
    }

    private var huggingFaceTokenStatus: String {
        if model.settings.huggingFaceToken?.isEmpty == false {
            return "Using this custom token for gated model downloads."
        }
        if model.environmentHuggingFaceToken != nil {
            return "Using HF_TOKEN from your environment. Enter a token to override it."
        }
        return "Set a token to download gated models. Manage tokens at huggingface.co/settings/tokens."
    }

    private func optionalString(_ source: Binding<String?>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    private func numberField(_ title: String, value: Binding<Int>) -> some View {
        TextField(title, value: value, format: .number)
    }

    private func doubleField(_ title: String, value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number)
    }
}
