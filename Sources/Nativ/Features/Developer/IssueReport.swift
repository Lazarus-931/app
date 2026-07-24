import AppKit
import Foundation
import NativServerKit

@MainActor
enum IssueReport {
    static let newIssueURL = "https://github.com/Lazarus-931/app/issues/new"
    private static let maximumBodyLength = 7000
    private static let crashReportMaxAge: TimeInterval = 7 * 24 * 60 * 60
    private static let lastSeenCrashKey = "Nativ.lastSeenCrashReport"

    struct CrashReport {
        let fileName: String
        let modifiedAt: Date
        let summary: String
        let raw: String

        var displayDate: String {
            crashDateFormatter.string(from: modifiedAt)
        }
    }

    static func open(model: NativModel, runtime: SystemRuntimeMonitor) {
        let crash = latestCrashReport()
        if let crash {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(crash.raw, forType: .string)
        }
        guard let url = url(model: model, runtime: runtime, crash: crash) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func unseenCrashReport() -> CrashReport? {
        guard let crash = latestCrashReport() else {
            return nil
        }
        return crash.fileName == UserDefaults.standard.string(forKey: lastSeenCrashKey) ? nil : crash
    }

    static func markCrashReportSeen(_ report: CrashReport) {
        UserDefaults.standard.set(report.fileName, forKey: lastSeenCrashKey)
    }

    static func url(model: NativModel, runtime: SystemRuntimeMonitor, crash: CrashReport? = nil) -> URL? {
        var components = URLComponents(string: newIssueURL)
        components?.queryItems = [
            URLQueryItem(name: "body", value: body(model: model, runtime: runtime, crash: crash))
        ]
        return components?.url
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
    }

    private static func body(model: NativModel, runtime: SystemRuntimeMonitor, crash: CrashReport?) -> String {
        let settings = model.settings.normalized()
        let ram = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: runtime.totalMemoryBytes),
            countStyle: .memory
        )
        let gpuModel = model.isRunning ? model.loadedModelDisplay : "none"
        let cpuModel = model.cpuIsRunning ? model.cpuMenuModelDisplay : "none"

        var sections: [String] = [
            """
            ### What happened

            _Describe the issue._

            ### Environment
            - App: Nativ v\(appVersion)
            - macOS: \(runtime.macOSVersion) (\(runtime.macOSBuild))
            - Chip: \(runtime.chipName), \(ram) RAM
            - Memory in use: \(memoryUsage(runtime))
            - mlx-vlm: \(runtime.mlxVLMVersion)

            ### Server state
            - Running: \(model.isRunning), CPU instance: \(model.cpuIsRunning)
            - GPU model: \(gpuModel)
            - CPU model: \(cpuModel)
            - Port: \(settings.serverPort)
            """
        ]

        if let crash {
            sections.append(
                "### Crash report\n"
                    + "- Report: \(crash.fileName)\n"
                    + "- When: \(crash.displayDate)\n\n"
                    + "```\n\(crash.summary)\n```\n\n"
                    + "_The full Apple crash report was copied to your clipboard — paste it below._"
            )
        }

        let launchArguments = redactHomeDirectory(settings.launchArguments.joined(separator: " "))
        if !launchArguments.isEmpty {
            sections.append("### Server configuration\n```\n\(launchArguments)\n```")
        }

        if let metrics = metricsSection(model: model) {
            sections.append(metrics)
        }

        let tail = logTail(model.logText, lines: 20)
        if !tail.isEmpty {
            sections.append("### Recent server output\n```\n\(tail)\n```")
        }

        return assemble(sections)
    }

    private static func assemble(_ sections: [String]) -> String {
        var body = ""
        for section in sections {
            let addition = body.isEmpty ? section : "\n\n" + section
            if body.count + addition.count > maximumBodyLength {
                break
            }
            body += addition
        }
        return body
    }

    private static func memoryUsage(_ runtime: SystemRuntimeMonitor) -> String {
        guard runtime.usedMemoryBytes > 0, runtime.totalMemoryBytes > 0 else {
            return "unavailable"
        }
        let gib = 1_073_741_824.0
        return String(
            format: "%.1f / %.0f GB (%d%%)",
            Double(runtime.usedMemoryBytes) / gib,
            Double(runtime.totalMemoryBytes) / gib,
            Int((runtime.memoryUsageFraction * 100).rounded())
        )
    }

    private static func metricsSection(model: NativModel) -> String? {
        var blocks: [String] = []
        if let metrics = model.metrics {
            blocks.append("**Session**\n" + statsLines(NativStats.sessionEntries(metrics)))
            if let latest = metrics.latest {
                blocks.append("**Latest request**\n" + statsLines(NativStats.latestRequestEntries(latest)))
            }
            blocks.append("**Runtime**\n" + statsLines(NativStats.runtimeEntries(metrics.server)))
        }
        if model.allTimeStats.hasValues {
            blocks.append("**All-time**\n" + statsLines(NativStats.allTimeEntries(model.allTimeStats)))
        }
        guard !blocks.isEmpty else {
            return nil
        }
        return "### Metrics\n" + blocks.joined(separator: "\n\n")
    }

    private static func statsLines(_ entries: [StatsEntry]) -> String {
        entries.map { "- \($0.label): \($0.value)" }.joined(separator: "\n")
    }

    private static func logTail(_ text: String, lines: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(lines)
            .joined(separator: "\n")
    }

    private static let crashDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func latestCrashReport() -> CrashReport? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let reports = entries.filter { url in
            url.lastPathComponent.hasPrefix("Nativ")
                && ["ips", "crash"].contains(url.pathExtension.lowercased())
        }
        guard let newest = reports.max(by: { modifiedAt($0) < modifiedAt($1) }) else {
            return nil
        }
        let modified = modifiedAt(newest)
        guard Date().timeIntervalSince(modified) <= crashReportMaxAge else {
            return nil
        }
        guard let contents = try? String(contentsOf: newest, encoding: .utf8) else {
            return nil
        }

        let raw = redactHomeDirectory(contents)
        let summary = crashSummary(fromIPS: contents) ?? String(raw.prefix(1500))
        return CrashReport(
            fileName: newest.lastPathComponent,
            modifiedAt: modified,
            summary: summary,
            raw: raw
        )
    }

    private static func modifiedAt(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    private static func crashSummary(fromIPS contents: String) -> String? {
        let parts = contents.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let bodyData = String(parts[1]).data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        else {
            return nil
        }

        var lines: [String] = []
        if let exception = payload["exception"] as? [String: Any] {
            let type = exception["type"] as? String ?? "unknown"
            if let signal = exception["signal"] as? String {
                lines.append("Exception: \(type) (\(signal))")
            } else {
                lines.append("Exception: \(type)")
            }
        }
        if let termination = payload["termination"] as? [String: Any] {
            if let indicator = termination["indicator"] as? String {
                lines.append("Reason: \(indicator)")
            } else if let namespace = termination["namespace"] as? String {
                let code = termination["code"] as? Int
                lines.append("Reason: \(namespace)\(code.map { " code \($0)" } ?? "")")
            }
        }

        let images = payload["usedImages"] as? [[String: Any]] ?? []
        if let threads = payload["threads"] as? [[String: Any]],
           let crashed = threads.first(where: { ($0["triggered"] as? Bool) == true }),
           let frames = crashed["frames"] as? [[String: Any]], !frames.isEmpty {
            lines.append("")
            lines.append("Crashed thread:")
            for (index, frame) in frames.prefix(20).enumerated() {
                let imageIndex = frame["imageIndex"] as? Int
                let imageName = imageIndex.flatMap { i -> String? in
                    guard i >= 0, i < images.count else { return nil }
                    return images[i]["name"] as? String
                } ?? "?"
                let detail: String
                if let symbol = frame["symbol"] as? String {
                    detail = "\(symbol) + \(frame["symbolLocation"] as? Int ?? 0)"
                } else {
                    detail = "0x… + \(frame["imageOffset"] as? Int ?? 0)"
                }
                lines.append("\(index)  \(imageName)  \(detail)")
            }
        }

        guard !lines.isEmpty else {
            return nil
        }
        return redactHomeDirectory(lines.joined(separator: "\n"))
    }

    private static func redactHomeDirectory(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard home.count > 1 else {
            return text
        }
        return text.replacingOccurrences(of: home, with: "~")
    }
}
