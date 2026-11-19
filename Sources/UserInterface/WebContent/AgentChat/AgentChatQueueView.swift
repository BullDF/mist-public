import AppKit
import SwiftUI

/// The agent's `hand_off` request above the composer: Johnny does the step himself in his own tab, then presses Done.
struct AgentChatHandOffView: View {
    let handOff: AgentHandOff
    var done: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "hand.raised").mistText(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(AgentChatStrings.handOffTitle).mistText(.secondary)
                Text(verbatim: handOff.message).mistText(.body).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let tab = handOff.tab {
                    Text(String(format: AgentChatStrings.handOffTab, tab)).mistText(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(AgentChatStrings.handOffDone, action: done)
                .buttonStyle(.mist(.primary, size: .regular))
                .accessibilityIdentifier("agentChat.handOffDone")
        }
        .padding(12)
        .mistCardBackground(.content)
        .accessibilityIdentifier("agentChat.handOff")
    }
}

struct AgentChatQueueView: View {
    @ObservedObject var conversation: AgentConversation
    var edit: (AgentQueuedMessage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if conversation.queuePaused {
                Text(AgentChatStrings.queuePaused)
                    .mistText(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
            }
            ForEach(conversation.queue) { message in
                HStack(spacing: 8) {
                    ForEach(Array(message.attachments.prefix(3).enumerated()), id: \.offset) { _, attachment in
                        if let image = thumbnail(for: attachment) {
                            Button { conversation.onOpenAttachment?(attachment) } label: {
                                Image(nsImage: image).resizable().scaledToFill()
                                    .frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 4))
                            }.buttonStyle(.plain)
                                .mistPointingHand()
                        }
                    }
                    queueText(message).mistText(.body)
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                        Button {
                            conversation.messageSent.send()
                            conversation.onSendQueuedNow?(message.id)
                        } label: {
                            Text(AgentChatStrings.queueSendNow)
                        }.buttonStyle(.mist(.secondary, size: .regular))
                        Button { edit(message) } label: { Image(systemName: "square.and.pencil") }
                            .buttonStyle(.mistIcon).customTooltip(AgentChatStrings.queueEdit).accessibilityLabel(AgentChatStrings.queueEdit)
                        Button { conversation.onRemoveQueued?(message.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.mistIcon).customTooltip(AgentChatStrings.queueDelete).accessibilityLabel(AgentChatStrings.queueDelete)
                    }
                    .disabled(message.delivering)
                }.padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .mistCardBackground(.content)
    }
    private func thumbnail(for attachment: AgentAttachment) -> NSImage? {
        switch attachment {
        case let .image(image): return NSImage(data: image.data)
        case let .file(file): return NSWorkspace.shared.icon(forFile: file.url.path)
        }
    }

    private func queueText(_ message: AgentQueuedMessage) -> Text {
        if let sender = message.sender {
            let firstLine = message.text.components(separatedBy: "\n").first { AgentCodeBlocks.fence($0) == nil } ?? ""
            return Text(verbatim: AgentChatStrings.peerMessage(sender.label, firstLine: firstLine))
        }
        // The one-line preview skips code fences, so a message opening with a block shows its code.
        return Text(verbatim: message.text.components(separatedBy: "\n").filter { AgentCodeBlocks.fence($0) == nil }.joined(separator: "\n"))
    }
}
