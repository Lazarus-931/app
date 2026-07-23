import Foundation

enum HuggingFaceCachePath {
    static let legacyDefault = "~/.cache/huggingface/hub"

    static let resolvedDefault: String = {
        if let path = configuredPath(in: ProcessInfo.processInfo.environment) {
            return path
        }
        if let path = configuredPath(in: loginShellValues) {
            return path
        }
        return legacyDefault
    }()

    static let resolvedToken: String? = {
        if let token = nonEmpty(ProcessInfo.processInfo.environment["HF_TOKEN"]) {
            return token
        }
        return nonEmpty(loginShellValues["HF_TOKEN"])
    }()

    private static let loginShellValues: [String: String] = loginShellEnvironment()

    private static func configuredPath(in environment: [String: String]) -> String? {
        if let hubCache = nonEmpty(environment["HF_HUB_CACHE"]) {
            return hubCache
        }
        if let home = nonEmpty(environment["HF_HOME"]) {
            return (home as NSString).appendingPathComponent("hub")
        }
        return nil
    }

    private static func loginShellEnvironment() -> [String: String] {
        let process = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = [
            "-lic",
            "printf 'HF_HUB_CACHE=%s\\nHF_HOME=%s\\nHF_TOKEN=%s\\n' \"$HF_HUB_CACHE\" \"$HF_HOME\" \"$HF_TOKEN\""
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return [:]
        }

        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return [:]
        }

        guard let data = try? output.fileHandleForReading.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else {
            return [:]
        }

        var environment: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<separator])
            if environment[key] == nil {
                environment[key] = String(line[line.index(after: separator)...])
            }
        }
        return environment
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
