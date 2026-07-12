import AppKit
import SwiftUI

struct LogsView: View {
    @ObservedObject var model: MLXServerDemoModel

    var body: some View {
        LogTextView(text: model.logText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct LogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.string = text

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        DispatchQueue.main.async { [weak textView] in
            textView?.scrollToEndOfDocument(nil)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        guard textView.string != text else {
            return
        }

        let shouldFollowOutput = isNearBottom(scrollView)
        textView.string = text
        if shouldFollowOutput {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func isNearBottom(_ scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else {
            return true
        }
        let distance = documentView.bounds.maxY - scrollView.contentView.bounds.maxY
        return distance <= 24
    }
}
