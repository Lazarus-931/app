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
                try server.start()
                Thread.sleep(forTimeInterval: 3)
                guard server.isRunning else {
                    fputs("mlx-vlm-server exited before stop was requested\n", stderr)
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
}
