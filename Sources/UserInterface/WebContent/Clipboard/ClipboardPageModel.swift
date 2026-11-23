import AppKit
import Combine

@MainActor final class ClipboardPageModel: ObservableObject {
    enum State { case notSetUp, sharingOff, box }
    let source: MistClipboardSyncSource
    private let pasteboard: NSPasteboard
    @Published private var syncSetUp = false
    @Published var draft: MistClipboardDraft? {
        didSet {
            draftText = draft?.type == .text ? draft.map { String(decoding: $0.data, as: UTF8.self) } : nil
            draftImage = draft?.type == .image ? draft.flatMap { NSImage(data: $0.data) } : nil
        }
    }
    /// A staged text or image, decoded once rather than on every render.
    private(set) var draftText: String?
    private(set) var draftImage: NSImage?
    @Published var error: String?
    @Published var staging = false
    @Published var thumbnail: NSImage?
    @Published var focused = false
    @Published var hovering = false
    /// Where the shared file was last downloaded; its button shows it in Finder while it's there.
    @Published private var downloaded: (id: String, url: URL)?
    weak var inputView: NSView?
    weak var draftTextView: NSScrollView?
    private let downloadsFolder: URL
    private var stageID = UUID()
    private var subscriptions = Set<AnyCancellable>()

    var state: State { !syncSetUp ? .notSetUp : source.sharing ? .box : .sharingOff }

    init(source: MistClipboardSyncSource? = nil, syncSetUp: AnyPublisher<Bool, Never>? = nil,
         pasteboard: NSPasteboard = .general, downloadsFolder: URL? = nil) {
        let source = source ?? .shared
        self.source = source
        self.pasteboard = pasteboard
        self.downloadsFolder = downloadsFolder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        (syncSetUp ?? MistSyncEngine.shared.$credentials.map { $0 != nil }.removeDuplicates().eraseToAnyPublisher())
            .sink { [weak self] in self?.syncSetUp = $0 }.store(in: &subscriptions)
        source.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        source.$current.dropFirst().sink { [weak self] _ in
            // Published emits before current changes; refresh the thumbnail on the next turn.
            DispatchQueue.main.async { [weak self] in self?.refreshThumbnail() }
        }.store(in: &subscriptions)
    }

    func paste() { stage(pasteboard) }
    func stage(_ pasteboard: NSPasteboard) {
        begin { MistClipboardPasteboard.stage(pasteboard, directory: self.source.directory, completion: $0) }
    }
    func stage(file url: URL) { begin { $0(Result { try MistClipboardPasteboard.fileDraft(url) }) } }
    var canChooseFile: Bool { state == .box }
    /// Choosing stages the file like a drop, replacing a staged item; Cancel changes nothing.
    func chooseFile() {
        guard canChooseFile, let window = inputView?.window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.stage(file: url) }
        }
    }
    private func begin(_ read: (@escaping (Result<MistClipboardDraft, Error>) -> Void) -> Void) {
        let id = UUID()
        stageID = id
        staging = true
        read { [weak self] result in
            guard let self, id == self.stageID else { return }
            switch result {
            case .success(let value): self.draft = value; self.error = nil
            case .failure(let error): self.error = error.localizedDescription
            }
            self.staging = false
        }
    }
    func send() { perform { if let draft { try source.send(draft); self.draft = nil } } }
    func copy(_ item: MistClipboardItem) { perform { try MistClipboardPasteboard.copy(item, source: source, to: pasteboard) } }
    /// Saves a file to Downloads under its name and bounces the Dock's Downloads stack, as browsers do.
    func download(_ item: MistClipboardItem) {
        perform {
            let url = try source.download(item, to: downloadsFolder)
            downloaded = (item.id, url)
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
        }
    }
    func downloadedFile(for item: MistClipboardItem) -> URL? {
        guard let downloaded, downloaded.id == item.id, FileManager.default.fileExists(atPath: downloaded.url.path) else { return nil }
        return downloaded.url
    }
    func showInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func clear() { perform { try source.clear() } }
    /// Unstages on this Mac only, dropping a stage still in flight; unlike `clear()` it never reaches the relay.
    func clearDraft() { stageID = UUID(); staging = false; draft = nil; error = nil }
    func drag(_ item: MistClipboardItem) -> NSItemProvider {
        do { return try MistClipboardPasteboard.drag(item, source: source) }
        catch { self.error = error.localizedDescription; return NSItemProvider() }
    }
    func appear() { perform { try source.flushPendingChanges() }; refreshThumbnail() }
    func disappear() { stageID = UUID(); staging = false }

    private func refreshThumbnail() {
        thumbnail = nil
        if let item = source.current, item.type == .image, !item.receiving,
           let data = try? source.data(for: item) { thumbnail = NSImage(data: data) }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
}
