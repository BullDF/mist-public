import AppKit
import Combine

final class MistDrifterLaunchRow: NSView {
    let settings: DrifterSettings
    var onAttachFiles: (([URL]) -> Void)?
    var onInteraction: (() -> Void)?
    private let attachButton = MistButton(symbol: "plus", title: NSLocalizedString("browser.newTabPage.claudeCode.attachFiles", value: "Attach Files", comment: "Claude Code - Accessibility label for the file attachment button"),
                                          size: .regular, circle: true)
    private let confirmationButton = MistMenuButton()
    private let modelButton = MistMenuButton()
    private let effortButton = MistMenuButton()
    let backgroundLabel = NSTextField(labelWithString: "")
    let backgroundButton = MistMenuButton()
    private var backgroundTasks: [AgentBackgroundTask] = []
    private var schedules: [DrifterSchedule] = []
    private var onStopTask: ((String) -> Void)?
    private var onCancelSchedule: ((String) -> Void)?
    private var subscription: AnyCancellable?

    init(settings: DrifterSettings) {
        self.settings = settings
        super.init(frame: .zero)
        backgroundLabel.applyMistStyle(.secondary)
        backgroundLabel.lineBreakMode = .byTruncatingTail
        backgroundLabel.isHidden = true
        addSubview(backgroundLabel)
        backgroundButton.action = #selector(showBackgroundTasks)
        backgroundButton.isHidden = true
        for button in [backgroundButton, confirmationButton, modelButton, effortButton] {
            button.isBordered = false
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.lineBreakMode = .byTruncatingTail
            button.refusesFirstResponder = true
            button.target = self
            addSubview(button)
        }
        attachButton.refusesFirstResponder = true
        attachButton.onClick = { [weak self] in self?.chooseFiles() }
        addSubview(attachButton)
        confirmationButton.action = #selector(showConfirmation)
        modelButton.action = #selector(showModels)
        effortButton.action = #selector(showEfforts)
        modelButton.setAccessibilityLabel(NSLocalizedString("browser.newTabPage.claudeCode.model", value: "Model", comment: "Claude Code - Accessibility label for the model selector"))
        effortButton.setAccessibilityLabel(NSLocalizedString("browser.newTabPage.claudeCode.effort", value: "Effort", comment: "Claude Code - Accessibility label for the reasoning effort selector"))
        subscription = settings.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshModels() { Task { await settings.refreshModels() } }
    func setAttachmentsEnabled(_ enabled: Bool) { attachButton.isEnabled = enabled }
    func reload() {
        confirmationButton.title = settings.config.confirmation.title
        confirmationButton.setAccessibilityLabel(settings.config.confirmation.title)
        confirmationButton.setCustomTooltip(confirmationButton.accessibilityLabel())
        confirmationButton.symbolName = settings.config.confirmation == .ask ? "hand.raised" : "forward.end"
        modelButton.title = settings.modelTitle
        modelButton.symbolName = "cpu"
        effortButton.title = ClaudeCodeEffort(rawValue: settings.config.effort)?.title ?? settings.config.effort.capitalized
        effortButton.symbolName = "brain"
        // A folded chip shows only its symbol, so the tooltip names its value.
        modelButton.setCustomTooltip(modelButton.title)
        effortButton.setCustomTooltip(effortButton.title)
        modelButton.isEnabled = settings.isEnabled
        effortButton.isEnabled = settings.isEnabled
        needsLayout = true
    }
    func setBackgroundTasks(_ tasks: [AgentBackgroundTask], onStop: ((String) -> Void)? = nil) {
        backgroundTasks = tasks
        onStopTask = onStop
        refreshBackgroundChip()
    }

    func setSchedules(_ schedules: [DrifterSchedule], onCancel: @escaping (String) -> Void) {
        onCancelSchedule = onCancel
        guard self.schedules != schedules else { return }
        self.schedules = schedules
        refreshBackgroundChip()
    }

    private func refreshBackgroundChip() {
        var counts: [String] = []
        if !backgroundTasks.isEmpty { counts.append(AgentChatStrings.backgroundCount(backgroundTasks)) }
        if !schedules.isEmpty { counts.append(AgentChatStrings.scheduleCount(schedules.count)) }
        backgroundLabel.stringValue = counts.joined(separator: " · ")
        let lines = backgroundTasks.map(\.description) + schedules.map(scheduleMenuTitle)
        let tooltip = lines.isEmpty ? nil : lines.joined(separator: "\n")
        let hasMenu = !schedules.isEmpty || (!backgroundTasks.isEmpty && onStopTask != nil)
        backgroundLabel.setCustomTooltip(tooltip)
        backgroundLabel.isHidden = backgroundTasks.isEmpty || hasMenu
        backgroundButton.title = backgroundLabel.stringValue
        backgroundButton.setAccessibilityLabel(backgroundLabel.stringValue)
        backgroundButton.setCustomTooltip(tooltip)
        backgroundButton.isHidden = !hasMenu
        needsLayout = true
    }

    private func scheduleMenuTitle(_ schedule: DrifterSchedule) -> String {
        schedule.title + " · " + schedule.nextRun.formatted(date: .abbreviated, time: .shortened)
    }

    func backgroundMenu() -> NSMenu {
        let menu = NSMenu()
        for task in backgroundTasks {
            let entry = NSMenuItem(title: task.description, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            let stop = item(AgentChatStrings.stop, value: task.id, selected: false, action: #selector(stopBackgroundTask(_:)))
            stop.isEnabled = onStopTask != nil
            submenu.addItem(stop)
            entry.submenu = submenu
            menu.addItem(entry)
        }
        if !backgroundTasks.isEmpty && !schedules.isEmpty { menu.addItem(.separator()) }
        for schedule in schedules {
            let entry = NSMenuItem(title: scheduleMenuTitle(schedule), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.addItem(item(AgentChatStrings.cancelSchedule, value: schedule.id, selected: false, action: #selector(cancelSchedule(_:))))
            entry.submenu = submenu
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func showBackgroundTasks() { present(backgroundMenu(), from: backgroundButton) }
    @objc private func stopBackgroundTask(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, backgroundTasks.contains(where: { $0.id == id }) else { return }
        onStopTask?(id)
    }
    @objc private func cancelSchedule(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, schedules.contains(where: { $0.id == id }) else { return }
        onCancelSchedule?(id)
    }

    override func layout() {
        super.layout()
        attachButton.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        for button in [confirmationButton, modelButton, effortButton] { button.imagePosition = .imageLeading }
        // Keep room for the background menu's circle when the count doesn't fit.
        let backgroundReserve: CGFloat = backgroundButton.isHidden ? 0 : 28 + 12
        var confirmationWidth = confirmationButton.intrinsicContentSize.width
        var modelWidth = min(240, modelButton.intrinsicContentSize.width)
        var effortWidth = effortButton.intrinsicContentSize.width
        func fits() -> Bool { 40 + confirmationWidth + 12 + backgroundReserve + modelWidth + 12 + effortWidth <= bounds.width }
        if !fits() {
            confirmationButton.imagePosition = .imageOnly
            confirmationWidth = 28
        }
        // Model and effort fold into circles together, never cutting the model's name.
        if !fits() {
            modelButton.imagePosition = .imageOnly
            effortButton.imagePosition = .imageOnly
            modelWidth = 28
            effortWidth = 28
        }
        effortButton.frame = NSRect(x: bounds.width - effortWidth, y: 0, width: effortWidth, height: 28)
        modelButton.frame = NSRect(x: effortButton.frame.minX - 12 - modelWidth, y: 0, width: modelWidth, height: 28)
        confirmationButton.frame = NSRect(x: 40, y: 0, width: confirmationWidth, height: 28)
        let backgroundX = confirmationButton.frame.maxX + 12
        let backgroundRoom = modelButton.frame.minX - 12 - backgroundX
        let labelHeight = backgroundLabel.intrinsicContentSize.height
        backgroundLabel.frame = NSRect(x: backgroundX, y: ((28 - labelHeight) / 2).rounded(),
                                       width: max(0, min(backgroundLabel.intrinsicContentSize.width + 4, backgroundRoom)), height: labelHeight)
        // A capsule narrower than its count would draw as an oval, so it folds into a circle like the other chips.
        backgroundButton.imagePosition = .imageLeading
        backgroundButton.symbolName = nil
        var backgroundWidth = backgroundButton.intrinsicContentSize.width + 4
        if backgroundWidth > backgroundRoom {
            backgroundButton.imagePosition = .imageOnly
            backgroundButton.symbolName = backgroundTasks.isEmpty ? "clock" : "terminal"
            backgroundWidth = 28
        }
        backgroundButton.frame = NSRect(x: backgroundX, y: 0, width: backgroundWidth, height: 28)
    }
    private func present(_ menu: NSMenu, from button: NSButton) {
        onInteraction?()
        menu.popUp(positioning: menu.mistPositioningItem, at: .zero, in: button)
        onInteraction?()
    }
    private func item(_ title: String, value: String, selected: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.representedObject = value; item.target = self; item.state = selected ? .on : .off
        return item
    }
    func modelMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for engine in DrifterEngine.allCases where settings.lockedEngine == nil || settings.lockedEngine == engine {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let title = NSMenuItem(title: engine.pickerTitle, action: nil, keyEquivalent: "")
            title.isEnabled = false; menu.addItem(title)
            if let message = settings.modelMessages[engine] {
                let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
                item.isEnabled = false; menu.addItem(item)
            } else {
                for model in settings.models where model.engine == engine {
                    menu.addItem(item(model.title, value: model.id,
                        selected: model.engine == settings.config.engine && model.model == settings.config.model,
                        action: #selector(selectModel(_:))))
                }
            }
        }
        return menu
    }
    enum Picker { case model, effort }

    /// The pickers of the chat composer holding focus in `window`.
    static func focused(in window: NSWindow) -> MistDrifterLaunchRow? {
        var responder = window.firstResponder
        while let current = responder {
            if let row = (current as? AgentChatComposer)?.browserLaunchRow {
                return row.isHiddenOrHasHiddenAncestor ? nil : row
            }
            responder = current.nextResponder
        }
        return nil
    }

    /// Opens a list from the keyboard, as a click on its button does; the menu takes arrows, Return and Esc.
    func showPicker(_ picker: Picker) {
        let button = picker == .model ? modelButton : effortButton
        guard button.isEnabled else { return }
        picker == .model ? showModels() : showEfforts()
    }

    @objc private func showModels() { present(modelMenu(), from: modelButton) }
    @objc private func selectModel(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let model = settings.models.first(where: { $0.id == id }) else { return }
        settings.selectModel(model)
    }
    @objc private func showEfforts() {
        let menu = NSMenu()
        for effort in settings.efforts {
            menu.addItem(item(ClaudeCodeEffort(rawValue: effort)?.title ?? effort.capitalized, value: effort,
                selected: effort == settings.config.effort, action: #selector(selectEffort(_:))))
        }
        present(menu, from: effortButton)
    }
    @objc private func selectEffort(_ item: NSMenuItem) {
        if let effort = item.representedObject as? String { settings.selectEffort(effort) }
    }
    @objc private func showConfirmation() {
        let menu = NSMenu()
        for mode in DrifterConfirmation.allCases {
            menu.addItem(item(mode.title, value: mode.rawValue, selected: mode == settings.config.confirmation,
                              action: #selector(selectConfirmation(_:))))
        }
        present(menu, from: confirmationButton)
    }
    @objc private func selectConfirmation(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let mode = DrifterConfirmation(rawValue: raw) {
            settings.selectConfirmation(mode)
        }
    }
    @objc private func chooseFiles() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.onAttachFiles?(panel.urls) }
            self?.onInteraction?()
        }
    }
}
