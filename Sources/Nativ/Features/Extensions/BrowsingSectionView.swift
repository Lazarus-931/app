import AppKit
import SwiftUI

struct BrowsingSectionView: View {
    @ObservedObject var model: NativModel

    var body: some View {
        HubSectionScaffold(
            title: "Browsing",
            subtitle: "Connect a provider once. Nativ gives models the same small, reliable web tools."
        ) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 22) {
                capabilitySummary
                providerGroup(
                    title: "Search",
                    detail: "Find sources with one compact web_search tool.",
                    providers: BrowsingProvider.allCases.filter(\.supportsSearch)
                )
                providerGroup(
                    title: "Read pages",
                    detail: "Turn a public page into clean text with web_read.",
                    providers: BrowsingProvider.allCases.filter(\.supportsRead)
                )
                providerGroup(
                    title: "Browser automation",
                    detail: "For sign-in and interactive sites. These are deliberately separate from research tools.",
                    providers: BrowsingProvider.allCases.filter(\.supportsBrowserTasks)
                )
            }
        }
    }

    private var capabilitySummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Models see only the capabilities you enable", systemImage: "wand.and.stars")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                capabilityPill("web_search", enabled: model.settings.browsing.searchProvider != nil)
                capabilityPill("web_read", enabled: model.settings.browsing.readProvider != nil)
                capabilityPill("browser_task", enabled: false)
            }
            Text("Search results are capped at five and page text is capped before it reaches your model. Browser tasks need explicit approval and are coming after the local runner is complete.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func capabilityPill(_ label: String, enabled: Bool) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(enabled ? Color.accentColor : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((enabled ? Color.accentColor : Color.primary).opacity(enabled ? 0.12 : 0.06), in: Capsule())
    }

    @ViewBuilder
    private func providerGroup(title: String, detail: String, providers: [BrowsingProvider]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(providers) { provider in
                BrowsingProviderCard(provider: provider, model: model)
            }
        }
    }
}

private struct BrowsingProviderCard: View {
    let provider: BrowsingProvider
    @ObservedObject var model: NativModel
    @State private var keyEntry = ""
    @State private var saved = false
    @State private var errorText: String?

    private var configured: Bool { BrowsingCredentials.isConfigured(provider) }
    private var selectedForSearch: Bool { model.settings.browsing.searchProvider == provider }
    private var selectedForRead: Bool { model.settings.browsing.readProvider == provider }
    private var selectedForBrowser: Bool { model.settings.browsing.browserProvider == provider }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                NativTintedIconTile(symbol: symbol, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(provider.displayName)
                            .font(.system(size: 13, weight: .semibold))
                        statusBadge
                    }
                    Text(provider.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Docs") { NSWorkspace.shared.open(provider.documentationURL) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }

            if provider.requiresAPIKey {
                HStack(spacing: 8) {
                    SecureField(configured ? "Saved API key" : "API key", text: $keyEntry)
                        .textFieldStyle(.roundedBorder)
                    Button(saved ? "Saved" : "Save key") { saveKey() }
                        .disabled(keyEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if configured {
                        Button("Remove", role: .destructive) { removeKey() }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                    }
                }
                .controlSize(.small)
                Text("Stored only in this Mac’s Keychain.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Text("Uses an isolated local Chromium profile. It will never use an existing signed-in browser profile.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if provider.supportsSearch || provider.supportsRead || provider.supportsBrowserTasks {
                HStack(spacing: 8) {
                    if provider.supportsSearch { selectButton("Use for search", isSelected: selectedForSearch) { $0.searchProvider = provider } }
                    if provider.supportsRead { selectButton("Use for reading", isSelected: selectedForRead) { $0.readProvider = provider } }
                    if provider.supportsBrowserTasks {
                        selectButton("Use for browser tasks", isSelected: selectedForBrowser) { $0.browserProvider = provider }
                            .disabled(true)
                    }
                }
            }
            if provider.supportsBrowserTasks {
                Text("Browser tasks are not enabled in this build yet; this provider is listed now so the configuration surface stays in one place.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if let errorText {
                Text(errorText)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var statusBadge: some View {
        Text(configured ? "CONNECTED" : "NOT CONNECTED")
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(configured ? Color.green : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background((configured ? Color.green : Color.primary).opacity(configured ? 0.12 : 0.06), in: Capsule())
    }

    private var symbol: String {
        switch provider {
        case .brave: "magnifyingglass"
        case .exa: "sparkle.magnifyingglass"
        case .firecrawl: "flame"
        case .browserbase: "globe.americas"
        case .browserUse: "cursorarrow.click"
        case .chromium: "rectangle.3.group"
        }
    }

    private func selectButton(
        _ title: String,
        isSelected: Bool,
        update: @escaping (inout BrowsingConfiguration) -> Void
    ) -> some View {
        Button(isSelected ? "Using \(provider.displayName)" : title) {
            guard configured else {
                errorText = "Save an API key before selecting \(provider.displayName)."
                return
            }
            var browsing = model.settings.browsing
            update(&browsing)
            model.settings.browsing = browsing.normalized()
            errorText = nil
        }
        .buttonStyle(isSelected ? .borderedProminent : .bordered)
        .controlSize(.small)
    }

    private func saveKey() {
        do {
            try BrowsingCredentials.save(keyEntry, for: provider)
            keyEntry = ""
            saved = true
            errorText = nil
        } catch {
            errorText = "Nativ could not save this key to the Keychain."
        }
    }

    private func removeKey() {
        do {
            try BrowsingCredentials.save(nil, for: provider)
            var browsing = model.settings.browsing
            if browsing.searchProvider == provider { browsing.searchProvider = nil }
            if browsing.readProvider == provider { browsing.readProvider = nil }
            if browsing.browserProvider == provider { browsing.browserProvider = nil }
            model.settings.browsing = browsing.normalized()
            saved = false
            errorText = nil
        } catch {
            errorText = "Nativ could not remove this Keychain key."
        }
    }
}
