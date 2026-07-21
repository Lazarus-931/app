import AppKit
import Foundation

@MainActor
enum IssueReport {
    static let newIssueURL = "https://github.com/Lazarus-931/app/issues/new"
    private static let maximumBodyLength = 6000

    static func open(model: NativModel, runtime: SystemRuntimeMonitor) {
        guard let url = url(model: model, runtime: runtime) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func url(model: NativModel, runtime: SystemRuntimeMonitor) -> URL? {
        var components = URLComponents(string: newIssueURL)
        components?.queryItems = [
            URLQueryItem(name: "body", value: body(model: model, runtime: runtime))
        ]
        return components?.url
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
    }

    private static func body(model: NativModel, runtime: SystemRuntimeMonitor) -> String {
        let settings = model.settings.normalized()
        let ram = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: runtime.totalMemoryBytes),
            countStyle: .memory
        )
        let gpuModel = model.isRunning ? model.loadedModelDisplay : "none"
        let cpuModel = model.cpuIsRunning ? model.cpuMenuModelDisplay : "none"

        var sections = [
            """
            ### What happened

            _Describe the issue._

            ### Environment
            - App: Nativ v\(appVersion)
            - macOS: \(runtime.macOSVersion) (\(runtime.macOSBuild))
            - Chip: \(runtime.chipName), \(ram) RAM
            - mlx-vlm: \(runtime.mlxVLMVersion)

            ### Server state
            - Running: \(model.isRunning), CPU instance: \(model.cpuIsRunning)
            - GPU model: \(gpuModel)
            - CPU model: \(cpuModel)
            - Port: \(settings.serverPort)
            """
        ]

        let tail = logTail(model.logText, lines: 25)
        if !tail.isEmpty {
            sections.append("### Recent server output\n```\n\(tail)\n```")
        }

        let body = sections.joined(separator: "\n\n")
        return String(body.suffix(maximumBodyLength))
    }

    private static func logTail(_ text: String, lines: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(lines)
            .joined(separator: "\n")
    }
}
