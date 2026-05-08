import AppKit
import MLXServerKit

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--smoke-test") {
            do {
                let output = try MLXVLMServer.run(arguments: ["--help"])
                print(output)
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
