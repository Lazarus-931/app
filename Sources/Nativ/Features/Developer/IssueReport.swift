import AppKit
import Foundation

@MainActor
enum IssueReport {
    static let newIssueURL = "https://github.com/Lazarus-931/app/issues/new"
    private static let maximumBodyLength = 6000
    private static let crashReportMaxAge: TimeInterval = 7 * 24 * 60 * 60

    struct CrashReport {
        let fileName: String
        let modifiedAt: Date
        let summary: String
        let raw: String
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

        if let crash {
            sections.append(
                """
                ### Crash report
                - Report: \(crash.fileName)
                - When: \(crashDateFormatter.string(from: crash.modifiedAt))

                ```
                \(crash.summary)
                ```

                _The full Apple crash report was copied to your clipboard — paste it below._
                """
            )
        }

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
