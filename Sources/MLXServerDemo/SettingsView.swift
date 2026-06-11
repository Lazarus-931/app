import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: MLXServerDemoModel
    @StateObject private var modelLibrary = LocalModelLibrary()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(title: "Models") {
                    SettingsRow(label: "Search path") {
                        HStack(spacing: 8) {
                            TextField(
                                MLXServerSettings.defaultModelSearchPath,
                                text: $model.settings.modelSearchPath
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                            Button {
                                chooseModelSearchPath()
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.bordered)
                            .help("Choose folder")
                        }
                    }
                    Divider()
                    ModelPickerRow(
                        selectedModelID: $model.settings.selectedModelID,
                        library: modelLibrary,
                        onRefresh: {
                            modelLibrary.scan(path: model.settings.modelSearchPath)
                        }
                    )
                }

                SettingsSection(title: "Generation Defaults") {
                    IntSettingRow(
                        label: "Max tokens",
                        value: $model.settings.maxTokens,
                        range: 1...262_144,
                        step: 128
                    )
                    Divider()
                    DoubleSettingRow(
                        label: "Temperature",
                        value: $model.settings.temperature,
                        range: 0...2,
                        step: 0.05,
                        fractionDigits: 2
                    )
                    Divider()
                    IntSettingRow(
                        label: "Top-k",
                        value: $model.settings.topK,
                        range: 0...10_000,
                        step: 1
                    )
                    Divider()
                    DoubleSettingRow(
                        label: "Top-p",
                        value: $model.settings.topP,
                        range: 0...1,
                        step: 0.01,
                        fractionDigits: 2
                    )
                    Divider()
                    DoubleSettingRow(
                        label: "Min-p",
                        value: $model.settings.minP,
                        range: 0...1,
                        step: 0.01,
                        fractionDigits: 2
                    )
                    Divider()
                    RepetitionPenaltyRow(
                        enabled: $model.settings.repetitionPenaltyEnabled,
                        value: $model.settings.repetitionPenalty
                    )
                }

                HStack {
                    if model.settingsRequireRestart {
                        Label("Restart required", systemImage: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Reset Defaults") {
                        model.resetSettings()
                    }
                }
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: modelSearchScanPath) {
            modelLibrary.scan(path: model.settings.modelSearchPath)
        }
        .onDisappear {
            modelLibrary.cancel()
        }
    }

    private var modelSearchScanPath: String {
        model.settings.normalized().expandedModelSearchPath
    }

    private func chooseModelSearchPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: model.settings.expandedModelSearchPath, isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        model.settings.modelSearchPath = displayPath(for: url)
    }

    private func displayPath(for url: URL) -> String {
        let path = url.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if path == homePath {
            return "~"
        }
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }
}

private struct ModelPickerRow: View {
    @Binding var selectedModelID: String?
    @ObservedObject var library: LocalModelLibrary
    let onRefresh: () -> Void

    private var selectedModelIsMissing: Bool {
        guard let selectedModelID else {
            return false
        }
        return !library.models.contains { $0.repoID == selectedModelID }
    }

    private var selection: Binding<String> {
        Binding(
            get: { selectedModelID ?? "" },
            set: { value in
                selectedModelID = value.isEmpty ? nil : value
            }
        )
    }

    var body: some View {
        SettingsRow(label: "Model") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Picker("", selection: selection) {
                        Text("Do not preload").tag("")

                        if let selectedModelID, selectedModelIsMissing {
                            Text("\(selectedModelID) (missing)").tag(selectedModelID)
                        }

                        ForEach(library.models) { model in
                            Text(model.repoID).tag(model.repoID)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(library.models.isEmpty && selectedModelID == nil)

                    if library.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(library.isScanning)
                    .help("Refresh models")

                    Button {
                        selectedModelID = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedModelID == nil)
                    .help("Clear selected model")
                }

                if let statusText = statusText {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(selectedModelIsMissing || library.error != nil ? .orange : .secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var statusText: String? {
        if let error = library.error {
            return error
        }
        if selectedModelIsMissing {
            return "Selected model is not in this search path."
        }
        if library.isScanning {
            return "Scanning local Hugging Face cache..."
        }
        if library.models.isEmpty {
            return "No local models found."
        }
        return "\(library.models.count) local \(library.models.count == 1 ? "model" : "models") found."
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
            content
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct DoubleSettingRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let fractionDigits: Int

    var body: some View {
        SettingsRow(label: label) {
            Slider(value: $value, in: range, step: step)
                .frame(minWidth: 220)

            TextField(
                "",
                value: $value,
                format: .number.precision(.fractionLength(fractionDigits))
            )
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(.system(.body, design: .monospaced))
            .frame(width: 72)
        }
    }
}

private struct IntSettingRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        SettingsRow(label: label) {
            Spacer(minLength: 0)

            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                .frame(width: 96)

            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
}

private struct RepetitionPenaltyRow: View {
    @Binding var enabled: Bool
    @Binding var value: Double

    var body: some View {
        SettingsRow(label: "Repetition penalty") {
            Toggle("", isOn: $enabled)
                .labelsHidden()

            Slider(value: $value, in: 0...4, step: 0.05)
                .frame(minWidth: 220)
                .disabled(!enabled)

            TextField("", value: $value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                .frame(width: 72)
                .disabled(!enabled)
        }
    }
}

#Preview {
    SettingsView(model: .init())
}
