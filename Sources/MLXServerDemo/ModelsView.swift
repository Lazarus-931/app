import AppKit
import SwiftUI

private enum ModelsPageSection: String, CaseIterable, Identifiable {
    case installed = "Installed"
    case discover = "Discover"

    var id: String { rawValue }
}

private enum HubAccessFilter: String, CaseIterable, Identifiable {
    case all = "All access"
    case open = "Open models"
    case gated = "Gated models"

    var id: String { rawValue }
}

struct ModelsView: View {
    @ObservedObject var model: MLXServerDemoModel
    @StateObject private var localLibrary = LocalModelLibrary()
    @StateObject private var hubLibrary = HuggingFaceModelLibrary()
    @StateObject private var downloadManager = HuggingFaceDownloadManager()
    @State private var section: ModelsPageSection = .installed
    @State private var localQuery = ""
    @State private var hubQuery = ""
    @State private var hubSort: HuggingFaceModelSort = .downloads
    @State private var hubCapabilityFilters = Set<LocalModelCapability>()
    @State private var hubAccessFilter: HubAccessFilter = .all
    @State private var showsConfiguration = false

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            Divider()

            switch section {
            case .installed:
                installedPage
            case .discover:
                discoverPage
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: modelScanPath) {
            localLibrary.scan(path: model.settings.modelSearchPath)
        }
        .task(id: hubSearchTaskID) {
            guard section == .discover else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            hubLibrary.search(query: hubQuery, sort: hubSort)
        }
        .onDisappear {
            localLibrary.cancel()
            hubLibrary.cancel()
            downloadManager.cancelDownload()
        }
    }

    private var pageHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                pageTitle
                Spacer(minLength: 12)
                sectionPicker
            }

            VStack(alignment: .leading, spacing: 12) {
                pageTitle
                HStack {
                    Spacer()
                    sectionPicker
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var installedPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ModelsSearchField(prompt: "Filter installed models", text: $localQuery)

                Button {
                    localLibrary.scan(path: model.settings.modelSearchPath)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(localLibrary.isScanning)

                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        showsConfiguration.toggle()
                    }
                } label: {
                    Label("Configure", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let error = localLibrary.error {
                        ModelsNotice(
                            title: "Couldn’t read the model cache",
                            message: error,
                            systemImage: "exclamationmark.triangle.fill",
                            color: .orange
                        )
                    }

                    if localLibrary.isScanning && localLibrary.models.isEmpty {
                        ModelsLoadingState(title: "Scanning your Hugging Face cache…")
                    } else if filteredLocalModels.isEmpty {
                        ModelsEmptyState(
                            systemImage: localQuery.isEmpty ? "shippingbox" : "magnifyingglass",
                            title: localQuery.isEmpty ? "No MLX models installed" : "No models match your filter",
                            message: localQuery.isEmpty
                                ? "Discover an MLX model on Hugging Face and download it to this cache."
                                : "Try a different model name or provider.",
                            actionTitle: localQuery.isEmpty ? "Discover models" : nil,
                            action: { section = .discover }
                        )
                    } else {
                        HStack {
                            Text("\(filteredLocalModels.count) \(filteredLocalModels.count == 1 ? "model" : "models")")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if localLibrary.isScanning {
                                ProgressView().controlSize(.small)
                            }
                        }

                        ForEach(filteredLocalModels) { localModel in
                            InstalledModelRow(
                                localModel: localModel,
                                selectedLanguageModelID: model.settings.normalized().languageModelID,
                                isModelSwitchInProgress: model.modelSwitchInProgress,
                                onLoadModel: { model.switchLanguageModel(to: localModel.repoID) },
                                onUseForImageGeneration: {
                                    model.settings.imageGenerationModelID = localModel.repoID
                                },
                                onUseForTextToSpeech: {
                                    model.settings.textToSpeechModelID = localModel.repoID
                                },
                                onUseForSpeechToText: {
                                    model.settings.speechToTextModelID = localModel.repoID
                                }
                            )
                        }
                    }

                    if showsConfiguration {
                        ModelConfigurationCard(model: model, onChooseCache: chooseModelCache)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
    }

    private var discoverPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    ModelsSearchField(prompt: "Search MLX models on Hugging Face", text: $hubQuery)

                    if hubLibrary.isSearching {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 28)
                    }
                }

                discoverFilterBar
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let error = hubLibrary.error {
                        ModelsNotice(
                            title: "Hugging Face is unavailable",
                            message: error,
                            systemImage: "wifi.exclamationmark",
                            color: .orange
                        )
                    } else if hubLibrary.isSearching && hubLibrary.models.isEmpty {
                        ModelsLoadingState(title: hubQuery.isEmpty ? "Finding popular MLX models…" : "Searching Hugging Face…")
                    } else if hubLibrary.models.isEmpty {
                        ModelsEmptyState(
                            systemImage: "magnifyingglass",
                            title: "No MLX models found",
                            message: "Try a model family, provider, or repository name.",
                            actionTitle: nil,
                            action: {}
                        )
                    } else {
                        discoverResultsHeader

                        if filteredHubModels.isEmpty {
                            ModelsEmptyState(
                                systemImage: "line.3.horizontal.decrease.circle",
                                title: "No models match these filters",
                                message: "Try another capability or access filter, or continue to the next page.",
                                actionTitle: nil,
                                action: {}
                            )
                        } else {
                            ForEach(filteredHubModels) { hubModel in
                                HubModelRow(
                                    model: hubModel,
                                    isInstalled: installedModelIDs.contains(hubModel.id),
                                    isDownloading: downloadManager.downloadingModelID == hubModel.id,
                                    anotherDownloadIsActive: downloadManager.downloadingModelID != nil,
                                    downloadError: downloadManager.errorByModelID[hubModel.id],
                                    onDownload: {
                                        downloadManager.download(
                                            repoID: hubModel.id,
                                            cachePath: model.settings.modelSearchPath
                                        ) {
                                            localLibrary.scan(path: model.settings.modelSearchPath)
                                            NotificationCenter.default.post(
                                                name: .localModelLibraryDidChange,
                                                object: nil
                                            )
                                        }
                                    }
                                )
                            }
                        }

                        HStack(spacing: 12) {
                            Spacer()

                            Button {
                                hubLibrary.goToPreviousPage()
                            } label: {
                                Label("Previous", systemImage: "chevron.left")
                            }
                            .disabled(!hubLibrary.canGoToPreviousPage)

                            Text("Page \(hubLibrary.pageNumber) of up to 5")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 122)

                            Button {
                                hubLibrary.goToNextPage()
                            } label: {
                                Label("Next", systemImage: "chevron.right")
                                    .labelStyle(.titleAndIcon)
                            }
                            .disabled(!hubLibrary.canGoToNextPage)

                            Spacer()
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
    }

    private var filteredLocalModels: [LocalModel] {
        let query = localQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return localLibrary.models }
        return localLibrary.models.filter {
            $0.repoID.localizedCaseInsensitiveContains(query)
                || $0.provider?.displayName.localizedCaseInsensitiveContains(query) == true
        }
    }

    private var installedModelIDs: Set<String> {
        Set(localLibrary.models.map(\.repoID))
    }

    private var pageTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Models")
                .font(.title2.weight(.semibold))
            Text("Manage local MLX models or find new ones on Hugging Face.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var sectionPicker: some View {
        Picker("Section", selection: $section) {
            ForEach(ModelsPageSection.allCases) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 230)
    }

    private var discoverFilterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                hubSortPicker
                hubCapabilityPicker
                hubAccessPicker
                Spacer(minLength: 8)
                shownModelCount
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    hubSortPicker
                    Spacer(minLength: 8)
                    shownModelCount
                }
                HStack(spacing: 12) {
                    hubCapabilityPicker
                    hubAccessPicker
                    Spacer(minLength: 0)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                hubSortPicker
                hubCapabilityPicker
                hubAccessPicker
                shownModelCount
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hubSortPicker: some View {
        Picker("Sort by", selection: $hubSort) {
            ForEach(HuggingFaceModelSort.allCases) { sort in
                Label(sort.displayName, systemImage: sort.systemImage)
                    .tag(sort)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var hubCapabilityPicker: some View {
        HStack(spacing: 8) {
            Text("Capability")

            Menu {
                Button {
                    hubCapabilityFilters.removeAll()
                } label: {
                    if hubCapabilityFilters.isEmpty {
                        Label("All capabilities", systemImage: "checkmark")
                    } else {
                        Text("All capabilities")
                    }
                }

                Divider()

                ForEach(LocalModelCapability.allCases, id: \.self) { capability in
                    Toggle(
                        capability.displayName,
                        isOn: capabilitySelectionBinding(for: capability)
                    )
                }
            } label: {
                Text(capabilityFilterTitle)
                    .frame(minWidth: 130, alignment: .leading)
            }
            .menuStyle(.button)
        }
        .fixedSize()
    }

    private var capabilityFilterTitle: String {
        switch hubCapabilityFilters.count {
        case 0:
            "All capabilities"
        case 1:
            hubCapabilityFilters.first?.displayName ?? "All capabilities"
        default:
            "\(hubCapabilityFilters.count) selected"
        }
    }

    private func capabilitySelectionBinding(
        for capability: LocalModelCapability
    ) -> Binding<Bool> {
        Binding(
            get: { hubCapabilityFilters.contains(capability) },
            set: { isSelected in
                if isSelected {
                    hubCapabilityFilters.insert(capability)
                } else {
                    hubCapabilityFilters.remove(capability)
                }
            }
        )
    }

    private var hubAccessPicker: some View {
        Picker("Access", selection: $hubAccessFilter) {
            ForEach(HubAccessFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var shownModelCount: some View {
        Text("\(filteredHubModels.count) shown")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var discoverResultsHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                discoverResultsTitle
                Spacer(minLength: 8)
                discoverSortStatus
                openHubLink
            }

            VStack(alignment: .leading, spacing: 6) {
                discoverResultsTitle
                HStack(spacing: 12) {
                    discoverSortStatus
                    Spacer(minLength: 8)
                    openHubLink
                }
            }
        }
    }

    private var discoverResultsTitle: some View {
        Text(hubQuery.isEmpty ? "MLX models on Hugging Face" : "Search results")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var discoverSortStatus: some View {
        Label("Sorted by \(hubSort.displayName.lowercased())", systemImage: hubSort.systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var openHubLink: some View {
        Link(destination: hubModelsURL) {
            Label("Open Hub", systemImage: "arrow.up.right")
                .font(.caption)
        }
        .fixedSize()
    }

    private var filteredHubModels: [HuggingFaceModel] {
        hubLibrary.models.filter { hubModel in
            let matchesCapability = hubCapabilityFilters.allSatisfy {
                hubModel.capabilities.contains($0)
            }
            let matchesAccess: Bool
            switch hubAccessFilter {
            case .all:
                matchesAccess = true
            case .open:
                matchesAccess = !hubModel.isGated && !hubModel.isPrivate
            case .gated:
                matchesAccess = hubModel.isGated
            }
            return matchesCapability && matchesAccess
        }
    }

    private var modelScanPath: String {
        model.settings.normalized().expandedModelSearchPath
    }

    private var hubSearchTaskID: String {
        "\(section.rawValue):\(hubQuery):\(hubSort.rawValue)"
    }

    private var hubModelsURL: URL {
        var components = URLComponents(string: "https://huggingface.co/models")!
        components.queryItems = [
            URLQueryItem(name: "library", value: "mlx"),
            URLQueryItem(name: "sort", value: "downloads")
        ]
        return components.url!
    }

    private func chooseModelCache() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(
            fileURLWithPath: model.settings.expandedModelSearchPath,
            isDirectory: true
        )

        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.modelSearchPath = displayPath(for: url)
    }

    private func displayPath(for url: URL) -> String {
        let path = url.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }
}

private struct ModelsSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

private struct InstalledModelRow: View {
    let localModel: LocalModel
    let selectedLanguageModelID: String?
    let isModelSwitchInProgress: Bool
    let onLoadModel: () -> Void
    let onUseForImageGeneration: () -> Void
    let onUseForTextToSpeech: () -> Void
    let onUseForSpeechToText: () -> Void

    private var isSelected: Bool {
        selectedLanguageModelID == localModel.repoID
    }

    private var isLoading: Bool {
        isSelected && isModelSwitchInProgress
    }

    var body: some View {
        HStack(spacing: 14) {
            ModelProviderBadge(provider: localModel.provider)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(modelName(localModel.repoID))
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if isLoading {
                        ModelPill(
                            title: "Loading model",
                            systemImage: "arrow.triangle.2.circlepath",
                            color: .orange
                        )
                    } else if isSelected {
                        ModelPill(title: "Chat model", systemImage: "checkmark", color: .accentColor)
                    }
                }

                Text(localModel.repoID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    if let contextSize = localModel.contextSize {
                        ModelPill(
                            title: "\(compactContextSize(contextSize)) context",
                            systemImage: "text.line.first.and.arrowtriangle.forward"
                        )
                    }
                    if let sizeBytes = localModel.sizeBytes {
                        ModelPill(
                            title: ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file),
                            systemImage: "internaldrive"
                        )
                    }
                }

                HStack(spacing: 6) {
                    ForEach(LocalModelCapability.allCases, id: \.self) { capability in
                        if localModel.capabilities.contains(capability) {
                            CapabilityPill(capability: capability)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            Button(action: onLoadModel) {
                HStack(spacing: 7) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isLoading ? "Loading Model…" : isSelected ? "Loaded" : "Load Model")
                }
            }
                .buttonStyle(.borderedProminent)
                .disabled(isSelected)
                .fixedSize()

            Menu {
                Button("Load Model", action: onLoadModel)
                    .disabled(isSelected)
                Button("Use for Image Generation", action: onUseForImageGeneration)
                Button("Use for Text to Speech", action: onUseForTextToSpeech)
                Button("Use for Speech to Text", action: onUseForSpeechToText)
                if let snapshotURL = localModel.snapshotURL {
                    Divider()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([snapshotURL])
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(14)
        .modelRowBackground(isHighlighted: isSelected)
    }
}

private struct HubModelRow: View {
    let model: HuggingFaceModel
    let isInstalled: Bool
    let isDownloading: Bool
    let anotherDownloadIsActive: Bool
    let downloadError: String?
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ModelProviderBadge(provider: model.provider)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(modelName(model.id))
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        if model.isGated {
                            ModelPill(title: "Gated", systemImage: "lock")
                        }
                    }

                    Text(model.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        ModelPill(title: compactCount(model.downloads), systemImage: "arrow.down.circle")
                        ModelPill(title: compactCount(model.likes), systemImage: "heart")
                    }

                    if !model.capabilities.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(LocalModelCapability.allCases, id: \.self) { capability in
                                if model.capabilities.contains(capability) {
                                    CapabilityPill(capability: capability)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 12)

                if isInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
                        .fixedSize()
                } else if isDownloading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Downloading…")
                    }
                    .font(.callout.weight(.medium))
                    .fixedSize()
                } else {
                    Button("Download", action: onDownload)
                        .buttonStyle(.borderedProminent)
                        .disabled(anotherDownloadIsActive || model.isPrivate)
                        .help(model.isGated ? "Gated models require Hugging Face authentication." : "Download to the configured cache")
                        .fixedSize()
                }
            }

            if let downloadError {
                Label(downloadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .modelRowBackground(isHighlighted: false)
    }
}

private struct ModelProviderBadge: View {
    let provider: LocalModelProvider?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.10))

            if let provider, let image = LocalModelProviderIcon.image(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 25, height: 25)
                    .accessibilityLabel(provider.displayName)
            } else if let provider {
                Text(provider.monogram)
                    .font(.system(size: provider.monogram.count > 2 ? 9 : 12, weight: .bold))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 46, height: 46)
        .help(provider?.displayName ?? "Unknown provider")
    }
}

private struct ModelPill: View {
    let title: String
    let systemImage: String
    var color: Color = .secondary

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.10)))
            .fixedSize()
    }
}

private struct CapabilityPill: View {
    let capability: LocalModelCapability

    var body: some View {
        ModelPill(title: capability.displayName, systemImage: capability.systemImage)
    }
}

private struct ModelsNotice: View {
    let title: String
    let message: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.08)))
    }
}

private struct ModelsLoadingState: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

private struct ModelsEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

private struct ModelConfigurationCard: View {
    @ObservedObject var model: MLXServerDemoModel
    let onChooseCache: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model configuration").font(.headline)
                    Text("Cache location and generation defaults")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.settingsRequireRestart {
                    ModelPill(title: "Restart required", systemImage: "arrow.clockwise", color: .orange)
                }
            }

            ConfigurationRow(label: "Hugging Face cache") {
                TextField(MLXServerSettings.defaultModelSearchPath, text: $model.settings.modelSearchPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                Button(action: onChooseCache) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .help("Choose cache folder")
            }

            Divider()

            ConfigurationRow(label: "Maximum tokens") {
                Spacer()
                TextField("", value: $model.settings.maxTokens, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 92)
                Stepper("", value: $model.settings.maxTokens, in: 1...262_144, step: 128)
                    .labelsHidden()
            }

            ConfigurationRow(label: "Temperature") {
                Slider(value: $model.settings.temperature, in: 0...2, step: 0.05)
                TextField("", value: $model.settings.temperature, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 68)
            }

            ConfigurationRow(label: "Sampling") {
                Text("Top-k")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", value: $model.settings.topK, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 66)
                Text("Top-p")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", value: $model.settings.topP, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 66)
                Text("Min-p")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", value: $model.settings.minP, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 66)
            }

            ConfigurationRow(label: "Repetition penalty") {
                Toggle("", isOn: $model.settings.repetitionPenaltyEnabled).labelsHidden()
                Slider(value: $model.settings.repetitionPenalty, in: 0...4, step: 0.05)
                    .disabled(!model.settings.repetitionPenaltyEnabled)
                TextField(
                    "",
                    value: $model.settings.repetitionPenalty,
                    format: .number.precision(.fractionLength(2))
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 68)
                .disabled(!model.settings.repetitionPenaltyEnabled)
            }

            HStack {
                Spacer()
                Button("Reset Defaults") { model.resetSettings() }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .padding(.top, 4)
    }
}

private struct ConfigurationRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            content
        }
    }
}

private struct ModelRowBackground: ViewModifier {
    let isHighlighted: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        isHighlighted
                            ? Color.accentColor.opacity(0.08)
                            : Color(nsColor: .controlBackgroundColor)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isHighlighted ? Color.accentColor.opacity(0.45) : Color(nsColor: .separatorColor),
                        lineWidth: isHighlighted ? 1 : 0.5
                    )
            )
    }
}

private extension View {
    func modelRowBackground(isHighlighted: Bool) -> some View {
        modifier(ModelRowBackground(isHighlighted: isHighlighted))
    }
}

private extension LocalModelCapability {
    var systemImage: String {
        switch self {
        case .vision: "eye"
        case .audio: "waveform"
        case .tools: "hammer"
        }
    }
}

private func modelName(_ repoID: String) -> String {
    repoID.split(separator: "/").last.map(String.init) ?? repoID
}

private func compactContextSize(_ value: Int) -> String {
    let million = 1024 * 1024
    if value >= million, value.isMultiple(of: million) { return "\(value / million)M" }
    if value >= 1024, value.isMultiple(of: 1024) { return "\(value / 1024)K" }
    return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
}

private func compactCount(_ value: Int) -> String {
    if value >= 1_000_000 {
        return String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
    }
    if value >= 1_000 {
        return String(format: "%.1fK", Double(value) / 1_000).replacingOccurrences(of: ".0K", with: "K")
    }
    return "\(value)"
}

#Preview {
    ModelsView(model: .init())
        .frame(width: 850, height: 680)
}
