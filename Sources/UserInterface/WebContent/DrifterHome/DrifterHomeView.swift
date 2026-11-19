import AppKit
import SwiftUI

struct DrifterHomeView: View {
    @ObservedObject var model: DrifterHomeModel
    let composer: AgentChatComposer
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    MistPageHeader(glyph: .image(DrifterApp.logo), title: MistAppID.drifter.name, glyphSide: 72,
                                   action: .init(title: NSLocalizedString("browser.chatPanel.newChat", value: "New Chat", comment: "Start a new conversation: the Chat panel's and the Drifter home page's button, and the description of the /clear command in agent chats"),
                                                 symbol: "square.and.pencil", handler: { model.state?.openNewDrifterChat() }))
                    DrifterHomeComposerHost(composer: composer).padding(.top, 34)
                    ongoing.padding(.top, 28)
                    history.padding(.top, 28)
                }
                .frame(width: max(0, min(MistKit.readableWidth, geometry.size.width - 48)))
                .padding(.top, 40).padding(.bottom, 56)
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: model.focusSearch) { _, value in searchFocused = value }
        .onChange(of: searchFocused) { _, value in model.focusSearch = value }
    }

    private var ongoing: some View {
        VStack(spacing: 10) {
            MistSectionHeader(title: DrifterHomeStrings.ongoing)
            if model.ongoing.isEmpty {
                MistPlaceholder(message: DrifterHomeStrings.noOngoing).transition(.mistListRow)
            } else {
                ForEach(Array(model.ongoing.enumerated()), id: \.element.id) { index, chat in
                    VStack(spacing: 0) {
                        chatRow(chat)
                        if !chat.children.isEmpty {
                            LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 8) {
                                ForEach(Array(chat.children.enumerated()), id: \.element.id) { childIndex, child in
                                    Button { model.openChat(child.id) } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 6) {
                                                MistDot(color: child.status?.color ?? .textTertiary, isHollow: child.status == .background)
                                                Text(verbatim: child.title).mistText(.rowSubheadline).lineLimit(1).truncationMode(.tail)
                                            }
                                            if let line = child.lastLine {
                                                Text(verbatim: line).mistText(.secondary).lineLimit(2).truncationMode(.tail)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(MistCardButtonStyle())
                                    .transition(.mistListRow)
                                    .mistListPosition(childIndex)
                                }
                            }
                            .padding(.leading, 58).padding(.trailing, 12).padding(.top, 6).padding(.bottom, 10)
                        }
                    }
                    .padding(6).mistCardBackground(.content)
                    .transition(.mistListRow)
                    .mistListPosition(index)
                }
            }
        }
    }

    private var history: some View {
        let visible = model.visibleHistory
        return VStack(spacing: 12) {
            HStack {
                MistSectionHeader(title: DrifterHomeStrings.history)
                MistFieldWell(symbol: "magnifyingglass", focused: searchFocused) {
                    TextField(DrifterHomeStrings.search, text: $model.query).focused($searchFocused)
                }
                .frame(width: 220)
            }
            if visible.rows.isEmpty {
                MistPlaceholder(message: model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? DrifterHomeStrings.noHistory : DrifterHomeStrings.noMatches)
                .transition(.mistListRow)
            } else {
                VStack(spacing: 0) {
                    ForEach(visible.rows, id: \.id) { chat in
                        chatRow(.init(id: chat.id, title: chat.title, lastLine: chat.lastLine, status: nil,
                                      engine: chat.engine, time: chat.lastActivity, sortDate: chat.lastActivity))
                        .transition(.mistListRow)
                    }
                }
                .padding(6).mistCardBackground(.content)
                .transition(.mistListRow)
            }
            if visible.hasMore {
                Button(DrifterHomeStrings.showMore) { model.historyLimit += DrifterHomeList.historyPageSize }
                    .buttonStyle(.mist(.secondary, size: .regular))
            }
        }
    }

    private func chatRow(_ chat: DrifterHomeChat) -> some View {
        Button { model.openChat(chat.id) } label: {
            MistItemRow(tile: tile(chat.engine), title: chat.title, subtitle: chat.lastLine, subtitleTruncation: .tail) {
                VStack(alignment: .trailing, spacing: 3) {
                    if let status = chat.status {
                        HStack(spacing: 5) {
                            MistDot(color: status.color, isHollow: status == .background)
                            Text(verbatim: status.title).mistText(.secondary)
                        }
                    }
                    Text(verbatim: DrifterHomeList.timeLabel(chat.time, now: Date())).mistText(.detail)
                }
                .fixedSize()
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MistRowButtonStyle())
    }

    private func tile(_ engine: DrifterEngine) -> MistIconTile {
        let icon = AgentChatIcon.resolve(engine: engine)
        let image = NSImage(named: icon.rawValue) ?? NSImage()
        return MistIconTile(content: engine == .claude ? .logo(image) : .glyph(image), side: 32)
    }
}

private struct DrifterHomeComposerHost: NSViewRepresentable {
    let composer: AgentChatComposer
    func makeNSView(context: Context) -> AgentChatComposer { composer }
    func updateNSView(_ view: AgentChatComposer, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AgentChatComposer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? MistKit.readableWidth, height: nsView.intrinsicContentSize.height)
    }
}

private extension DrifterHomeStatus {
    var color: ThemedColor {
        switch self {
        case .working, .background: .themeColor
        case .needsYou: .mistAttention
        case .idle: .textTertiary
        case .failed: .mistError
        }
    }
    var title: String {
        switch self {
        case .working: NSLocalizedString("drifter.home.status.working", value: "Working", comment: "Drifter home - Status of an agent working on a turn")
        case .needsYou: NSLocalizedString("drifter.home.status.needsYou", value: "Needs you", comment: "Drifter home - Status of a chat waiting for user input")
        case .background: NSLocalizedString("drifter.home.status.background", value: "Running in background", comment: "Drifter home - Status of an idle chat whose background task or monitor still runs")
        case .idle: NSLocalizedString("drifter.home.status.idle", value: "Idle", comment: "Drifter home - Status of a chat with no active turn")
        case .failed: NSLocalizedString("drifter.home.status.failed", value: "Failed", comment: "Drifter home - Status of a chat whose turn failed")
        }
    }
}

private enum DrifterHomeStrings {
    static let ongoing = NSLocalizedString("drifter.home.ongoing", value: "Ongoing", comment: "Drifter home - Heading for open chats")
    static let history = NSLocalizedString("drifter.home.history", value: "History", comment: "Drifter home - Heading for earlier saved chats")
    static let search = NSLocalizedString("drifter.home.search", value: "Search chats", comment: "Drifter home - Placeholder for searching chat titles")
    static let showMore = NSLocalizedString("drifter.home.showMore", value: "Show More", comment: "Drifter home - Load another page of saved chats")
    static let noOngoing = NSLocalizedString("drifter.home.noOngoing", value: "No chats open", comment: "Drifter home - Empty open-chat list")
    static let noHistory = NSLocalizedString("drifter.home.noHistory", value: "No earlier chats", comment: "Drifter home - Empty saved-chat history")
    static let noMatches = NSLocalizedString("drifter.home.noMatches", value: "No chats match", comment: "Drifter home - No chat titles match the search")
}
