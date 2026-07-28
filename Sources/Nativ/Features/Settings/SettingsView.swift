import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: NativModel
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
                .padding(.top, 26)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)
                .background(Color.nativWindow)

            Form {
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
            }
            .formStyle(.grouped)
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
}
