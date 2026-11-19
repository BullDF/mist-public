import AppKit
import SwiftUI

@MainActor
final class MistPasswordSavePrompt: NSObject, NSPopoverDelegate {
    enum Action { case save, never }
    private var popover: NSPopover?

    func show(login: MistLogin, updating: Bool, anchor: NSView, rect: NSRect? = nil, action: @escaping (Action) -> Void) {
        close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let content = NSHostingController(rootView: MistPasswordSaveView(
            login: login, updating: updating, choose: { [weak self] choice in
                self?.close()
                if let choice { action(choice) }
            }))
        popover.contentViewController = content
        // Size before showing: a popover placed at its default size keeps its origin when SwiftUI shrinks it.
        popover.contentSize = content.view.fittingSize
        self.popover = popover
        popover.show(relativeTo: rect ?? anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func close() { popover?.close(); popover = nil }
    func popoverDidClose(_ notification: Notification) { popover = nil }
}

private struct MistPasswordSaveView: View {
    let login: MistLogin
    let updating: Bool
    let choose: (MistPasswordSavePrompt.Action?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(updating ? MistPasswordStrings.updateTitle : MistPasswordStrings.saveTitle).font(.headline)
            Text(verbatim: login.host).foregroundStyle(.secondary)
            Text(verbatim: login.username).lineLimit(2)
            HStack {
                if !updating { Button(MistPasswordStrings.neverSite) { choose(.never) } }
                Spacer()
                Button(MistPasswordStrings.notNow) { choose(nil) }
                Button(updating ? MistPasswordStrings.update : MistPasswordStrings.save) { choose(.save) }
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 400)
    }
}
