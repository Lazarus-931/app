import AppKit
import Foundation
import SwiftUI

private struct ChatImageThumbnail: View {
    let attachment: ChatImageAttachment
    let isUserMessage: Bool
    var width: CGFloat = 120
    var height: CGFloat = 90

    var body: some View {
        Group {
            if let data = attachment.imageData,
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.title3)
                    Text(attachment.filename)
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(isUserMessage ? Color.white.opacity(0.82) : Color(nsColor: .secondaryLabelColor))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isUserMessage ? Color.white.opacity(0.3) : Color(nsColor: .separatorColor),
                    lineWidth: 0.5
                )
        )
        .help(attachment.filename)
    }
}

struct ChatComposer: View {
    @ObservedObject var viewModel: ChatViewModel
    let unavailableReason: String?
    let canCompose: Bool
    let canSend: Bool
    let onSend: () -> Void
    @State private var editorContentHeight: CGFloat = 0
    private let textInset = EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14)
    private let editorMinimumHeight: CGFloat = 64
    private let editorMaximumHeight: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.isCurrentSessionSending, let sendingStartedAt = viewModel.sendingStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(sendingStartedAt)
                    Text(workingStatus(elapsed: elapsed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            } else if let unavailableReason {
                Text(unavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !viewModel.currentSessionQueuedPrompts.isEmpty {
                ChatQueueTray(
                    prompts: viewModel.currentSessionQueuedPrompts,
                    onSteer: viewModel.steerQueuedRequest,
                    onPrioritize: viewModel.prioritizeQueuedRequest,
                    onRemove: viewModel.removeQueuedRequest
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ChatComposerTextEditor(
                        text: $viewModel.draft,
                        isEnabled: canCompose,
                        onSubmit: onSend,
                        onContentHeightChange: { height in
                            editorContentHeight = height
                        }
                    )

                    if viewModel.draft.isEmpty {
                        Text("Message")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(textInset)
                            .offset(x: 4)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: editorHeight)

                if !viewModel.pendingImageAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(viewModel.pendingImageAttachments) { attachment in
                                ChatPendingImageAttachmentView(attachment: attachment) {
                                    viewModel.removePendingImageAttachment(attachment.id)
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }

                HStack {
                    Menu {
                        Button {
                            viewModel.chooseImageAttachments()
                        } label: {
                            Label("Attach Image", systemImage: "photo.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .regular))
                            .frame(width: 30, height: 30)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(!canCompose)
                    .help("Add attachment")

                    Spacer(minLength: 12)

                    Button {
                        if showsStopButton {
                            viewModel.cancel()
                        } else {
                            onSend()
                        }
                    } label: {
                        Image(systemName: showsStopButton ? "stop.fill" : "arrow.up")
                            .font(.system(size: showsStopButton ? 10 : 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(actionButtonColor, in: Circle())
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(!showsStopButton && !canSend)
                    .help(showsStopButton ? "Stop response" : "Send (Return)")
                }
                .padding(.leading, 10)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
        }
        .padding(.vertical, 18)
    }

    private var actionButtonColor: Color {
        if showsStopButton || canSend {
            return .accentColor
        }
        return Color(nsColor: .tertiaryLabelColor)
    }

    private var showsStopButton: Bool {
        viewModel.isCurrentSessionSending && !canSend
    }

    private func workingStatus(elapsed: TimeInterval) -> String {
        "Working for \(MLXServerFormatting.elapsedDuration(elapsed))..."
    }

    private var editorHeight: CGFloat {
        min(max(editorContentHeight, editorMinimumHeight), editorMaximumHeight)
    }
}

private struct ChatQueueTray: View {
    let prompts: [ChatQueuedPrompt]
    let onSteer: (UUID) -> Void
    let onPrioritize: (UUID) -> Void
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: prompts.count > 2) {
            LazyVStack(spacing: 7) {
                ForEach(prompts) { prompt in
                    ChatQueuedPromptRow(
                        prompt: prompt,
                        onSteer: { onSteer(prompt.id) },
                        onPrioritize: { onPrioritize(prompt.id) },
                        onRemove: { onRemove(prompt.id) }
                    )
                }
            }
        }
        .frame(height: min(CGFloat(prompts.count) * 68, 180))
        .animation(.snappy(duration: 0.2), value: prompts)
    }
}

private struct ChatQueuedPromptRow: View {
    let prompt: ChatQueuedPrompt
    let onSteer: () -> Void
    let onPrioritize: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.indent")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayContent)
                    .font(.body)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if prompt.attachmentCount > 0 {
                    Label(attachmentLabel, systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onSteer) {
                Label("Steer", systemImage: "arrow.turn.down.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Stop the current response and run this message next")

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove from queue")

            Menu {
                Button(action: onPrioritize) {
                    Label("Move to Front", systemImage: "arrow.up.to.line")
                }
                .disabled(prompt.position == 1)

                Divider()

                Button(role: .destructive, action: onRemove) {
                    Label("Remove from Queue", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Queue options")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.035), radius: 5, y: 2)
    }

    private var displayContent: String {
        prompt.content.isEmpty ? attachmentLabel : prompt.content
    }

    private var attachmentLabel: String {
        prompt.attachmentCount == 1
            ? "1 image"
            : "\(prompt.attachmentCount) images"
    }
}

private struct ChatComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let onSubmit: () -> Void
    let onContentHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onContentHeightChange: onContentHeightChange
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ChatComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = context.coordinator.handleSubmit
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        let scrollView = ChatComposerNSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.onLayout = context.coordinator.reportContentHeight

        context.coordinator.textView = textView
        context.coordinator.reportContentHeight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onContentHeightChange = onContentHeightChange

        guard let textView = context.coordinator.textView else {
            return
        }

        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled

        guard textView.string != text else {
            context.coordinator.reportContentHeight()
            return
        }

        textView.string = text
        context.coordinator.reportContentHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        var onSubmit: () -> Void
        var onContentHeightChange: (CGFloat) -> Void
        weak var textView: NSTextView?
        private var lastReportedHeight: CGFloat?

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onContentHeightChange: @escaping (CGFloat) -> Void
        ) {
            _text = text
            self.onSubmit = onSubmit
            self.onContentHeightChange = onContentHeightChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else {
                return
            }

            text = textView.string
            reportContentHeight()
        }

        func handleSubmit() {
            onSubmit()
        }

        func reportContentHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  textContainer.containerSize.width > 0
            else {
                return
            }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let measuredHeight = ceil(usedRect.maxY + (textView.textContainerInset.height * 2))

            guard lastReportedHeight.map({ abs($0 - measuredHeight) >= 0.5 }) ?? true else {
                return
            }

            lastReportedHeight = measuredHeight
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastReportedHeight == measuredHeight else {
                    return
                }
                self.onContentHeightChange(measuredHeight)
            }
        }
    }
}

private final class ChatComposerNSScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private final class ChatComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch ComposerReturnBehavior.resolve(for: event) {
        case .submit:
            onSubmit?()
        case .insertNewline:
            insertText("\n", replacementRange: selectedRange())
        case .passthrough:
            super.keyDown(with: event)
        }
    }
}

private enum ComposerReturnBehavior {
    case submit
    case insertNewline
    case passthrough

    static func resolve(for event: NSEvent) -> ComposerReturnBehavior {
        guard isReturnKey(event) else {
            return .passthrough
        }

        let modifiers = relevantModifiers(for: event)
        if modifiers == [.command] {
            return .insertNewline
        }
        if modifiers.isEmpty {
            return .submit
        }
        return .passthrough
    }

    private static func isReturnKey(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }

    private static func relevantModifiers(for event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection([.command, .control, .option, .shift])
    }
}

private struct ChatPendingImageAttachmentView: View {
    let attachment: ChatImageAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ChatImageThumbnail(
                attachment: attachment,
                isUserMessage: false,
                width: 42,
                height: 32
            )

            Text(attachment.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help("Remove image")
        }
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}
