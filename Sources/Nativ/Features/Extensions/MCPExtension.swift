import Foundation
import NativExtensionSDK
import NativServerKit
import SwiftUI

@MainActor
final class MCPExtension: NativHostExtension {
    static let extensionID = "com.nativ.mcp"
    static let serversPageID = "com.nativ.mcp.servers"

    let manifest: NativExtensionManifest
    let host = MCPHostManager()

    init() {
        manifest = MCPExtension.buildManifest()
    }

    func activate(context: NativExtensionHostContext) {}

    func deactivate() {
        host.shutdown()
    }

    func makePage(id: String, context: NativExtensionPageContext) -> AnyView? {
        guard id == Self.serversPageID else {
            return nil
        }
        return AnyView(MCPExtensionPage(host: host, model: context.model))
    }

    private static func buildManifest() -> NativExtensionManifest {
        NativExtensionManifest(
            id: extensionID,
            version: "1.0.0",
            minimumNativVersion: "0.1.0",
            displayName: "MCP",
            summary:
                "Connect local Model Context Protocol servers so tool-capable models can use their tools.",
            developer: "Nativ",
            systemImage: "wrench.and.screwdriver",
            included: true,
            runtime: .builtIn,
            contributions: .init(
                sidebar: [
                    .init(
                        id: serversPageID,
                        title: "MCP",
                        systemImage: "wrench.and.screwdriver",
                        order: 300
                    )
                ]
            ),
            permissions: [.processLaunch]
        )
    }
}

private struct MCPExtensionPage: View {
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel

    var body: some View {
        MCPServersPanel(
            host: host,
            servers: $model.settings.mcpServers,
            disabledToolNames: $model.settings.disabledToolNames
        )
        .onAppear {
            host.reload(servers: model.settings.mcpServers)
        }
        .onChange(of: model.settings.mcpServers) { _, servers in
            host.reload(servers: servers)
        }
    }
}
