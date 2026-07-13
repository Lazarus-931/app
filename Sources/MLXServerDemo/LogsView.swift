import AppKit
import Darwin
import MLXServerKit
import SwiftUI

struct LogsView: View {
    @ObservedObject var model: MLXServerDemoModel
    @StateObject private var runtime = LogsRuntimeMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeader
            runtimeGrid
            logPanel
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 22)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { runtime.start() }
        .onDisappear { runtime.stop() }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Logs")
                    .font(.title2.weight(.semibold))
                Text("Live server output and runtime environment.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(model.isRunning ? "Live" : "Offline", systemImage: "circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(model.isRunning ? .green : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.secondary.opacity(0.10)))
        }
    }

    private var runtimeGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 165), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            RuntimeInfoCard(
                title: "Apple chip",
                value: runtime.chipName,
                detail: "Apple silicon",
                systemImage: "cpu",
                tint: .blue
            )

            RuntimeInfoCard(
                title: "Memory",
                value: byteCount(runtime.totalMemoryBytes),
                detail: "Unified memory",
                systemImage: "memorychip",
                tint: .purple
            )

            RuntimeInfoCard(
                title: "Live usage",
                value: byteCount(runtime.usedMemoryBytes),
                detail: "\(memoryUsagePercent)% of memory in use",
                systemImage: "gauge.with.dots.needle.67percent",
                tint: memoryUsageTint,
                progress: runtime.memoryUsageFraction
            )

            RuntimeInfoCard(
                title: "macOS",
                value: runtime.macOSVersion,
                detail: runtime.macOSBuild,
                systemImage: "macbook",
                tint: .teal
            )

            RuntimeInfoCard(
                title: "mlx-vlm",
                value: runtime.mlxVLMVersion,
                detail: "Bundled runtime",
                systemImage: "shippingbox",
                tint: .orange
            )
        }
    }

    private var logPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Server output")
                        .font(.callout.weight(.semibold))
                    Text(model.logText.isEmpty ? "No output yet" : "Following new output")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    copyLogs()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(model.logText.isEmpty)

                Button {
                    model.clearLogs()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(model.logText.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ZStack {
                LogTextView(text: model.logText)

                if model.logText.isEmpty {
                    ContentUnavailableView(
                        "No server output",
                        systemImage: "terminal",
                        description: Text("Server logs will appear here as they arrive.")
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private var memoryUsagePercent: Int {
        Int((runtime.memoryUsageFraction * 100).rounded())
    }

    private var memoryUsageTint: Color {
        switch runtime.memoryUsageFraction {
        case 0.85...: .red
        case 0.70...: .orange
        default: .green
        }
    }

    private func byteCount(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    private func copyLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.logText, forType: .string)
    }
}

private struct RuntimeInfoCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color
    var progress: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(tint)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

@MainActor
private final class LogsRuntimeMonitor: ObservableObject {
    @Published private(set) var usedMemoryBytes: UInt64 = 0

    let chipName = SystemRuntimeInfo.chipName
    let totalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    let macOSVersion = SystemRuntimeInfo.macOSVersion
    let macOSBuild = SystemRuntimeInfo.macOSBuild
    let mlxVLMVersion = SystemRuntimeInfo.mlxVLMVersion

    private var timer: Timer?

    var memoryUsageFraction: Double {
        guard totalMemoryBytes > 0 else { return 0 }
        return min(max(Double(usedMemoryBytes) / Double(totalMemoryBytes), 0), 1)
    }

    func start() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        usedMemoryBytes = SystemRuntimeInfo.usedMemoryBytes
    }
}

private enum SystemRuntimeInfo {
    static let chipName: String = {
        sysctlString("machdep.cpu.brand_string")
            ?? sysctlString("hw.model")
            ?? "Apple silicon"
    }()

    static let macOSVersion: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var components = ["\(version.majorVersion)", "\(version.minorVersion)"]
        if version.patchVersion > 0 {
            components.append("\(version.patchVersion)")
        }
        return "macOS " + components.joined(separator: ".")
    }()

    static let macOSBuild: String = {
        let fullVersion = ProcessInfo.processInfo.operatingSystemVersionString
        guard let openParenthesis = fullVersion.firstIndex(of: "("),
              let closeParenthesis = fullVersion[openParenthesis...].firstIndex(of: ")")
        else {
            return "System version"
        }
        return String(fullVersion[fullVersion.index(after: openParenthesis)..<closeParenthesis])
    }()

    static let mlxVLMVersion: String = {
        guard let distributionURL = try? MLXServer.distributionURL() else {
            return "Unavailable"
        }
        let libraryURL = distributionURL.appendingPathComponent("python/lib", isDirectory: true)
        guard let pythonDirectories = try? FileManager.default.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "Unavailable"
        }

        for pythonDirectory in pythonDirectories where pythonDirectory.lastPathComponent.hasPrefix("python") {
            let sitePackagesURL = pythonDirectory.appendingPathComponent("site-packages", isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: sitePackagesURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            if let metadataDirectory = entries.first(where: {
                $0.lastPathComponent.hasPrefix("mlx_vlm-")
                    && $0.lastPathComponent.hasSuffix(".dist-info")
            }) {
                let name = metadataDirectory.lastPathComponent
                return String(name.dropFirst("mlx_vlm-".count).dropLast(".dist-info".count))
            }
        }
        return "Unavailable"
    }()

    static var usedMemoryBytes: UInt64 {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let usedPages = UInt64(statistics.active_count)
            + UInt64(statistics.wire_count)
            + UInt64(statistics.compressor_page_count)
        let usedBytes = usedPages * UInt64(vm_kernel_page_size)
        return min(usedBytes, ProcessInfo.processInfo.physicalMemory)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: value)
    }
}

private struct LogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.string = text

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        DispatchQueue.main.async { [weak textView] in
            textView?.scrollToEndOfDocument(nil)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        guard textView.string != text else {
            return
        }

        let shouldFollowOutput = isNearBottom(scrollView)
        textView.string = text
        if shouldFollowOutput {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func isNearBottom(_ scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else {
            return true
        }
        let distance = documentView.bounds.maxY - scrollView.contentView.bounds.maxY
        return distance <= 24
    }
}

#Preview {
    LogsView(model: .init())
        .frame(width: 950, height: 650)
}
