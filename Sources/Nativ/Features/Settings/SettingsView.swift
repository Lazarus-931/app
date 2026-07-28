import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: NativModel
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage("sidebarPinned") private var pinNavigationPanel = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @StateObject private var voiceLibrary = LocalModelLibrary()

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .system
    }

    private var textToSpeechModels: [LocalModel] {
        voiceLibrary.models.filter {
            $0.capabilities.contains(.textToSpeech) || $0.capabilities.contains(.audio)
        }
    }

    private var speechToTextModels: [LocalModel] {
        voiceLibrary.models.filter {
            $0.capabilities.contains(.speechToText) || $0.capabilities.contains(.audio)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
                .padding(.top, 26)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)
                .background(Color.nativWindow)

            settingsForm
        }
        .onAppear {
            voiceLibrary.scan(path: model.settings.modelSearchPath)
        }
        .onChange(of: appearanceRaw) { _, newValue in
            (AppAppearance(rawValue: newValue) ?? .system).apply()
        }
        .onChange(of: launchAtLogin) { _, enabled in
            updateLaunchAtLogin(enabled)
        }
    }

    private var pageHeader: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 5)

            VStack(spacing: 4) {
                Text("Nativ")
                    .font(.title.weight(.semibold))
                Text(appVersionLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Local AI, native to your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
    }

    private var settingsForm: some View {
        Form {
            if model.settingsRequireRestart {
                Section {
                    Label(
                        "The server is running with different settings. Restart it to apply changes.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("General") {
                LabeledContent {
                    CheckForUpdatesCommand(updater: SoftwareUpdater.shared.updater)
                        .buttonStyle(.bordered)
                } label: {
                    settingLabel("arrow.triangle.2.circlepath", "Software Updates", "Check for a newer version of Nativ.")
                }
                LabeledContent {
                    Picker("", selection: $appearanceRaw) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                } label: {
                    settingLabel(appearance.systemImage, "Appearance", appearanceDescription)
                }
                LabeledContent {
                    Toggle("", isOn: $pinNavigationPanel).labelsHidden()
                } label: {
                    settingLabel("sidebar.left", "Pin navigation panel", "Keep the sidebar docked open.")
                }
                LabeledContent {
                    Toggle("", isOn: $launchAtLogin).labelsHidden()
                } label: {
                    settingLabel("person.crop.circle.badge.checkmark", "Start at Login", "Open Nativ automatically when you log in.")
                }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Voice") {
                LabeledContent {
                    modelMenu($model.settings.textToSpeechModelID, models: textToSpeechModels)
                } label: {
                    settingLabel("speaker.wave.2", "Text-to-speech model", "Voice used to read replies aloud.")
                }
                LabeledContent {
                    devicePicker($model.settings.textToSpeechDevice)
                } label: {
                    settingLabel("cpu", "Text-to-speech device", "GPU is fastest; CPU keeps the GPU free for the model.")
                }
                LabeledContent {
                    modelMenu($model.settings.speechToTextModelID, models: speechToTextModels)
                } label: {
                    settingLabel("waveform", "Speech-to-text model", "Optional — Apple's on-device voice input is used otherwise.")
                }
                LabeledContent {
                    devicePicker($model.settings.speechToTextDevice)
                } label: {
                    settingLabel("cpu", "Speech-to-text device", "Where transcription runs when a model is selected.")
                }
            }

            Section("Models") {
                TextField("Model search path", text: $model.settings.modelSearchPath)
                TextField("Language model", text: optionalString($model.settings.languageModelID))
                TextField("Image generation model", text: optionalString($model.settings.imageGenerationModelID))
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
        }
        .formStyle(.grouped)
    }

    private func settingLabel(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func devicePicker(_ selection: Binding<ChatInferenceDevice>) -> some View {
        Picker("", selection: selection) {
            Text("GPU").tag(ChatInferenceDevice.gpu)
            Text("CPU").tag(ChatInferenceDevice.cpu)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func modelMenu(_ selection: Binding<String?>, models: [LocalModel]) -> some View {
        Menu {
            Button("None") { selection.wrappedValue = nil }
            if !models.isEmpty {
                Divider()
                ForEach(models, id: \.repoID) { localModel in
                    Button(localModel.repoID) { selection.wrappedValue = localModel.repoID }
                }
            }
        } label: {
            Text(selection.wrappedValue ?? "None")
                .foregroundStyle(.secondary)
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

    private var appearanceDescription: String {
        switch appearance {
        case .system: "Match your Mac's appearance."
        case .light: "Use Nativ's light appearance."
        case .dark: "Use Nativ's dark appearance."
        }
    }

    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String
        if let build, !build.isEmpty {
            return "Version \(version) (\(build))"
        }
        return "Version \(version)"
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
