import Foundation

public enum MLXVLMServerError: Error, CustomStringConvertible {
    case missingDistribution(Bundle)
    case missingExecutable(URL)
    case launchFailed(Int32, String)

    public var description: String {
        switch self {
        case .missingDistribution(let bundle):
            return "Missing mlx-vlm-server resource in \(bundle.bundlePath)"
        case .missingExecutable(let url):
            return "Missing mlx-vlm-server executable at \(url.path)"
        case .launchFailed(let status, let output):
            return "mlx-vlm-server exited with status \(status):\n\(output)"
        }
    }
}

public enum MLXVLMServer {
    public static func distributionURL() throws -> URL {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "mlx-vlm-server", withExtension: nil) else {
            throw MLXVLMServerError.missingDistribution(bundle)
        }
        return url
    }

    public static func executableURL() throws -> URL {
        let url = try distributionURL().appendingPathComponent("bin/mlx-vlm-server")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw MLXVLMServerError.missingExecutable(url)
        }
        return url
    }

    public static func makeProcess(arguments: [String] = []) throws -> Process {
        let process = Process()
        process.executableURL = try executableURL()
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PYTHONNOUSERSITE": "1"
        ]) { _, newValue in newValue }
        return process
    }

    public static func run(arguments: [String], timeout: TimeInterval = 30) throws -> String {
        let process = try makeProcess(arguments: arguments)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw MLXVLMServerError.launchFailed(process.terminationStatus, output)
        }
        return output
    }
}

private final class BundleToken {}
