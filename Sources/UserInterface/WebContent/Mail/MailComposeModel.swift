import Foundation
import Combine
import MistMailCore

@MainActor
final class MailComposeModel: ObservableObject {
    enum InitialFocus: Equatable { case recipients, body }
    let source: any MailPageDataSource
    let initialFocus: InitialFocus
    @Published private(set) var draft: MailDraft
    @Published private(set) var edited = false
    @Published private(set) var isSending = false
    @Published private(set) var suggestions: [MailAddressSuggestion] = []
    var exportEditor: (() async throws -> MailComposeExport)?
    var commitFieldEdits: (() -> Void)?
    var onError: ((String) -> Void)?
    var onFinish: (() -> Void)?
    private let discardIfUntouched: Bool
    private(set) var automaticSignature: String?
    private var hasOnlyUntouchedSignature: Bool
    private var generation = 0, savedGeneration = 0
    private var debounce: Task<Void, Never>?
    private var saveTask: Task<Void, Error>?
    private var suggestionTask: Task<Void, Never>?
    private var temporaryFiles: [URL] = []
    private var finished = false
    private var actionInFlight = false

    init(draft: MailDraft, source: any MailPageDataSource, discardIfUntouched: Bool = true,
         initialFocus: InitialFocus = .recipients, automaticSignature: String? = nil) {
        self.draft = draft; self.source = source; self.discardIfUntouched = discardIfUntouched; self.initialFocus = initialFocus
        self.automaticSignature = automaticSignature
        hasOnlyUntouchedSignature = automaticSignature != nil &&
            draft.html == MailComposeFormatting.messageBody("", signature: automaticSignature).html
        self.draft.html = MailComposeFormatting.document(html: draft.html, plainText: draft.plainText)
        suggestionTask = Task { [weak self, source] in self?.suggestions = (try? await source.addressSuggestions()) ?? [] }
    }
    deinit {
        debounce?.cancel(); suggestionTask?.cancel()
        for file in temporaryFiles { try? FileManager.default.removeItem(at: file) }
    }
    var hasUnsavedChanges: Bool { !finished && (generation != savedGeneration || saveTask != nil) }
    var hasContent: Bool {
        if draft.isEmpty { return false }
        return !hasOnlyUntouchedSignature || !draft.to.isEmpty || !draft.cc.isEmpty || !draft.bcc.isEmpty
            || !draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty
    }
    func signatureSwapped(to html: String?) {
        if discardIfUntouched, draft.replyContext == nil { automaticSignature = html }
    }
    func update(_ change: (inout MailDraft) -> Void) {
        guard !isSending, !finished else { return }
        let previous = draft; change(&draft)
        if draft != previous { changed() }
    }
    func editorChanged() { guard !finished else { return }; changed() }
    private func changed() {
        edited = true; generation += 1
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self else { return }
            do { try await saveNow() } catch { report(error) }
        }
    }
    func saveNow() async throws {
        guard !finished else { return }
        debounce?.cancel(); debounce = nil
        if let saveTask {
            try await saveTask.value
            if generation != savedGeneration { try await saveNow() }
            return
        }
        let task = Task {
            defer { self.saveTask = nil }
            try await self.saveLoop()
        }
        saveTask = task
        try await task.value
    }
    private func saveLoop() async throws {
        repeat {
            let revision = generation
            try await refreshEditor()
            guard generation == revision else { continue }
            var snapshot = draft
            let referenced = MailComposeFormatting.referencedCIDs(snapshot.html ?? "")
            snapshot.attachments.removeAll { $0.contentID.map { !referenced.contains(MailBodyPreparation.normalizedCID($0)) } ?? false }
            let saved = try await source.saveDraft(snapshot)
            if generation == revision { draft = saved }
            else {
                // Keep edits made during the await, but follow files moved into engine storage.
                var current = draft
                let moved = Dictionary(uniqueKeysWithValues: saved.attachments.map { ($0.id, $0.file) })
                for index in current.attachments.indices { if let file = moved[current.attachments[index].id] { current.attachments[index].file = file } }
                draft = current
            }
            savedGeneration = revision
        } while generation != savedGeneration
    }
    func send() async throws {
        guard !isSending, !finished, !actionInFlight else { return }
        isSending = true; defer { isSending = false }
        debounce?.cancel(); debounce = nil
        if let saveTask { try await saveTask.value }
        try await saveNow()
        let recipients = draft.to + draft.cc + draft.bcc
        guard !recipients.isEmpty else { throw ComposeError.noRecipients }
        guard recipients.allSatisfy(MailComposeFormatting.isValid) else { throw ComposeError.invalidRecipient }
        try await source.send(draft.id); finish()
    }
    func discard() async throws {
        guard !isSending, !finished, !actionInFlight else { return }
        actionInFlight = true; defer { actionInFlight = false }
        try await removeDraft()
    }
    private func removeDraft() async throws {
        debounce?.cancel(); debounce = nil
        if let saveTask { _ = try? await saveTask.value }
        try await source.discardDraft(draft.id); finish()
    }
    func close() async throws {
        guard !isSending, !finished, !actionInFlight else { return }
        if !edited, discardIfUntouched { try await discard(); return }
        actionInFlight = true; defer { actionInFlight = false }
        try await saveNow()
        // An empty draft is deleted rather than kept, whether it started empty or was emptied.
        if !hasContent { try await removeDraft(); return }
        let source = source, id = draft.id, onError = onError
        finish()
        Task { do { try await source.flushDraft(id) } catch { onError?(MailPresentation.errorMessage(error)) } }
    }
    private func finish() { finished = true; debounce?.cancel(); debounce = nil; onFinish?() }
    func refreshEditor() async throws {
        if let exportEditor {
            let value = try await exportEditor()
            draft.html = value.html; draft.plainText = value.plainText
            hasOnlyUntouchedSignature = value.hasOnlyUntouchedSignature
        }
    }
    func addFiles(_ urls: [URL]) {
        update { draft in
            draft.attachments += urls.filter(\.isFileURL).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.map { .init(filename: $0.lastPathComponent, file: $0) }
        }
    }
    func addInlineImage(_ data: Data) throws -> String {
        let id = UUID().uuidString.lowercased(), file = FileManager.default.temporaryDirectory.appendingPathComponent("mist-compose-\(id).png")
        try data.write(to: file, options: .atomic); temporaryFiles.append(file)
        let cid = id + "@mist"
        update { $0.attachments.append(.init(filename: "image.png", file: file, contentID: cid)) }
        return cid
    }
    func removeAttachment(_ id: UUID) { update { $0.attachments.removeAll { $0.id == id } } }
    func report(_ error: Error) {
        if let error = error as? ComposeError { onError?(error == .noRecipients ? MailStrings.noRecipients : MailStrings.invalidRecipient) }
        else if error is MailError { onError?(MailPresentation.errorMessage(error)) }
        else { onError?(MailStrings.storageFailure) }
    }
    enum ComposeError: Error, Equatable { case noRecipients, invalidRecipient }
}
