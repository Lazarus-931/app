import AppKit
import MLXServerKit

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--smoke-test") {
            do {
                let output = try MLXServer.run(arguments: ["--help"])
                print(output)
                exit(EXIT_SUCCESS)
            } catch {
                fputs("\(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        if CommandLine.arguments.contains("--lifecycle-smoke-test") {
            let server = MLXServerProcessController()
            server.onOutput = { text in
                print(text, terminator: "")
            }
            server.onTermination = { status in
                print("\nmlx-vlm-server stopped with status \(status)")
            }

            do {
                let smokePort = ProcessInfo.processInfo.environment["MLX_SERVER_SMOKE_PORT"] ?? "18080"
                try server.start(arguments: ["--host", "127.0.0.1", "--port", smokePort])
                Thread.sleep(forTimeInterval: 3)
                guard server.isRunning else {
                    fputs("mlx-vlm-server exited before stop was requested\n", stderr)
                    exit(EXIT_FAILURE)
                }
                guard checkMetricsEndpoint(port: smokePort) else {
                    fputs("mlx-vlm-server did not expose /metrics on port \(smokePort)\n", stderr)
                    try? server.stop()
                    exit(EXIT_FAILURE)
                }
                try server.stop()
                Thread.sleep(forTimeInterval: 1)
                guard !server.isRunning else {
                    fputs("mlx-vlm-server was still running after stop\n", stderr)
                    exit(EXIT_FAILURE)
                }
                exit(EXIT_SUCCESS)
            } catch {
                fputs("\(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)
        application.run()
    }

    private static func checkMetricsEndpoint(port: String) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/metrics") else {
            return false
        }

        let semaphore = DispatchSemaphore(value: 0)
        var didSucceed = false
        let task = URLSession.shared.dataTask(with: url) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse {
                didSucceed = (200..<300).contains(httpResponse.statusCode)
            }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            task.cancel()
        }
        return didSucceed
    }
}
