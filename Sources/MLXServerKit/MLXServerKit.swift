import Foundation

public enum MLXServerError: Error, CustomStringConvertible {
    case missingDistribution(Bundle)
    case missingExecutable(URL)
    case alreadyRunning
    case notRunning
    case launchFailed(Int32, String)

    public var description: String {
        switch self {
        case .missingDistribution(let bundle):
            return "Missing mlx-vlm-server resource in \(bundle.bundlePath)"
        case .missingExecutable(let url):
            return "Missing mlx-vlm-server executable at \(url.path)"
        case .alreadyRunning:
            return "mlx-vlm-server is already running"
        case .notRunning:
            return "mlx-vlm-server is not running"
        case .launchFailed(let status, let output):
            return "mlx-vlm-server exited with status \(status):\n\(output)"
        }
    }
}

public enum MLXServer {
    public static func distributionURL() throws -> URL {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "mlx-vlm-server", withExtension: nil) else {
            throw MLXServerError.missingDistribution(bundle)
        }
        return url
    }

    public static func executableURL() throws -> URL {
        let url = try distributionURL().appendingPathComponent("bin/mlx-vlm-server")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw MLXServerError.missingExecutable(url)
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
            throw MLXServerError.launchFailed(process.terminationStatus, output)
        }
        return output
    }
}

public typealias MLXVLMServerError = MLXServerError
public typealias MLXVLMServer = MLXServer

public final class MLXServerProcessController {
    public typealias OutputHandler = @Sendable (String) -> Void
    public typealias TerminationHandler = @Sendable (Int32) -> Void

    private let lock = NSLock()
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?

    public var onOutput: OutputHandler?
    public var onTermination: TerminationHandler?

    public init() {}

    public var isRunning: Bool {
        lock.withLock {
            process?.isRunning ?? false
        }
    }

    @discardableResult
    public func start(arguments: [String] = []) throws -> Process {
        try lock.withLock {
            if process?.isRunning == true {
                throw MLXServerError.alreadyRunning
            }

            let process = try MLXServer.makeProcess(arguments: arguments)
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
            self.process = process

            observe(pipe: outputPipe)
            observe(pipe: errorPipe)

            process.terminationHandler = { [weak self] process in
                self?.handleTermination(status: process.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                self.process = nil
                self.outputPipe = nil
                self.errorPipe = nil
                throw error
            }

            return process
        }
    }

    public func stop(timeout: TimeInterval = 5) throws {
        let process = try lock.withLock {
            guard let process = self.process, process.isRunning else {
                throw MLXServerError.notRunning
            }
            return process
        }

        process.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            process.interrupt()
        }
    }

    private func observe(pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.onOutput?(String(decoding: data, as: UTF8.self))
        }
    }

    private func handleTermination(status: Int32) {
        let pipes = lock.withLock {
            let pipes = (self.outputPipe, self.errorPipe)
            self.process = nil
            self.outputPipe = nil
            self.errorPipe = nil
            return pipes
        }

        pipes.0?.fileHandleForReading.readabilityHandler = nil
        pipes.1?.fileHandleForReading.readabilityHandler = nil
        onTermination?(status)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private final class BundleToken {}
