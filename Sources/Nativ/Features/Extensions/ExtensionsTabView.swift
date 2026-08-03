import NativExtensionSDK
import SwiftUI

struct ExtensionsTabView: View {
    @ObservedObject var manager: NativExtensionManager
    @ObservedObject var model: NativModel
    @State private var openedRecord: NativExtensionRecord?
    @State private var didLaunch = false

    var body: some View {
        NavigationStack {
            ExtensionsView(
                manager: manager,
                titleLeadingInset: 0,
                onOpen: { openedRecord = $0 }
            )
            .navigationDestination(item: $openedRecord) { record in
                extensionPage(for: record)
                    .navigationTitle(record.manifest.displayName)
            }
        }
        .task {
            guard !didLaunch else {
                return
            }
            didLaunch = true
            manager.launch(
                context: NativExtensionHostContext(
                    transcriptionConfiguration: { nil },
                    openSpeechModels: {},
                    showMainWindow: {}
                )
            )
        }
    }

    @ViewBuilder
    private func extensionPage(for record: NativExtensionRecord) -> some View {
        if let pageID = record.manifest.contributions.sidebar.first?.id,
           let page = manager.makePage(
               id: pageID,
               context: NativExtensionPageContext(
                   model: model,
                   titleLeadingInset: 0,
                   openSpeechModels: {}
               )
           ) {
            page
        } else {
            ContentUnavailableView(
                "Extension Unavailable",
                systemImage: "puzzlepiece.extension",
                description: Text("Enable this extension to open it.")
            )
        }
    }
}
