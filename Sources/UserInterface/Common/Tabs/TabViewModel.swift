// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine
import AppKit

enum TabCornerBadgeStatus: Int, CaseIterable {
    case agent

    static func resolve(isAgentActive: Bool) -> TabCornerBadgeStatus? {
        isAgentActive ? .agent : nil
    }

    static func highestPriority(_ statuses: [TabCornerBadgeStatus?]) -> TabCornerBadgeStatus? {
        statuses.compactMap { $0 }.max { $0.rawValue < $1.rawValue }
    }
}

@MainActor
final class TabStatusModel: ObservableObject {
    @Published private(set) var isDiscarded = false
    @Published private(set) var isUnloaded = false
    @Published private(set) var isAgentActive = false

    var cornerBadgeStatus: TabCornerBadgeStatus? {
        TabCornerBadgeStatus.resolve(isAgentActive: isAgentActive)
    }

    private var configuredTabGuid: Int?
    private var configurationGeneration: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()

    func configure(with tab: Tab) {
        cancelSubscriptions()

        let expectedGuid = tab.guid
        let expectedGeneration = configurationGeneration
        configuredTabGuid = expectedGuid
        isDiscarded = tab.isDiscarded
        isUnloaded = tab.isUnloaded
        isAgentActive = AgentAnimationManager.shared.isActive(for: expectedGuid)

        tab.$isDiscarded
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isDiscarded in
                guard let self,
                      self.isCurrentConfiguration(
                        expectedGuid: expectedGuid,
                        expectedGeneration: expectedGeneration
                      ) else { return }
                self.isDiscarded = isDiscarded
            }
            .store(in: &cancellables)

        tab.$isUnloaded
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isUnloaded in
                guard let self,
                      self.isCurrentConfiguration(
                        expectedGuid: expectedGuid,
                        expectedGeneration: expectedGeneration
                      ) else { return }
                self.isUnloaded = isUnloaded
            }
            .store(in: &cancellables)

        AgentAnimationManager.shared.stateChanged
            .filter { $0 == expectedGuid }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self,
                      self.isCurrentConfiguration(
                        expectedGuid: expectedGuid,
                        expectedGeneration: expectedGeneration
                      ) else { return }
                self.isAgentActive = AgentAnimationManager.shared.isActive(for: expectedGuid)
            }
            .store(in: &cancellables)
    }

    func cancelSubscriptions() {
        configurationGeneration &+= 1
        cancellables.removeAll()
    }

    func prepareForReuse() {
        cancelSubscriptions()
        configuredTabGuid = nil
        isDiscarded = false
        isUnloaded = false
        isAgentActive = false
    }

    private func isCurrentConfiguration(expectedGuid: Int, expectedGeneration: UInt64) -> Bool {
        configuredTabGuid == expectedGuid && configurationGeneration == expectedGeneration
    }
}

@Observable
@MainActor
final class TabViewModel {
    var agentSidebarStatus: AgentSidebarStatus = .none
    var isEndedAgentChat = false
    var title: String = ""
    var isRenaming = false
    var url: String?
    var appIcon: MistAppIcon?
    var faviconUrl: String?
    var liveFaviconImage: NSImage?
    var profileFaviconImage: NSImage?
    private(set) var liveFaviconRevision: Int = 0
    /// The last non-nil URL used for favicon loading. Prevents globe flash
    /// when viewModel is briefly reconfigured with a nil-url tab during layout.
    private(set) var faviconLoadURL: String?
    var isActive: Bool = false
    /// True when this tab is part of the temporary multi-selection (the active
    /// tab is implicitly included but never carries this flag).
    var isMultiSelected: Bool = false
    var isHovered: Bool = false
    var isHoverSuppressed: Bool = false
    var showsTabPreview: Bool = false
    /// A live Peek is attached to this tab — drives the trailing peek
    /// indicator on the sidebar row.
    var showsPeek: Bool = false
    var isPressed: Bool = false
    /// Progress-gated visual loading used by sidebar title effects.
    /// Raw Chromium loading can lag or pulse after progress reaches completion.
    var isLoading: Bool = false
    var loadingProgress: Double = 1.0
    var isCurrentlyAudible: Bool = false
    var isMuted: Bool = false
    var isCapturingMedia: Bool = false
    var isHorizontalCompactMode: Bool = false
    /// Set by the horizontal tab strip while it hides this favicon under the
    /// cell's centered recording icon, or with the whole cell laid out at
    /// zero size: the badge then stays out of the tree, as its pulse would
    /// keep rendering inside the hidden host.
    var hidesRecordingBadge: Bool = false
    /// Color of the tab group this tab belongs to, if any. Drives the
    /// vertical group-affiliation bar on the leading edge of the cell.
    /// Tracks live: changes when the tab joins / leaves a group, when the
    /// group is closed, or when the group's color is recolored.
    var groupColor: GroupColor?
    /// Membership flag derived directly from `tab.groupToken`. Distinct
    /// from `groupColor != nil`: a tab can be a group member momentarily
    /// before its color resolves (kJoined arrives on the data side
    /// before `state.groups` re-emits onto the main runloop), so this
    /// flag is the authoritative signal for layout decisions like
    /// indentation that should not flicker on color settling.
    var isInGroup: Bool = false
    let status = TabStatusModel()

    var onToggleMute: (() -> Void)?
    var onToolTipUpdated: (() -> Void)?
    
    private(set) var faviconRevision: Int = 0
    
    private var cancellables = Set<AnyCancellable>()
    private var rawIsLoading: Bool = false
    private var profileFaviconLoadHandle: ProfileScopedFaviconLoadHandle?

    var isShimmering: Bool {
        isLoading
    }
    
    var displayTitle: String {
        if !title.isEmpty { return title }
        if let url, !url.isEmpty { return url }
        return ""
    }

    func reloadFavicon() {
        faviconRevision += 1
    }

    func cancelSubscriptions() {
        configurationGeneration &+= 1
        cancellables.removeAll()
        status.cancelSubscriptions()
        profileFaviconLoadHandle?.cancel()
        profileFaviconLoadHandle = nil
    }

    func prepareForReuse() {
        cancelSubscriptions()
        configuredTabGuid = nil
        title = ""
        url = nil
        faviconUrl = nil
        appIcon = nil
        faviconLoadURL = nil
        liveFaviconImage = nil
        profileFaviconImage = nil
        liveFaviconRevision = 0
        isActive = false
        isMultiSelected = false
        isHovered = false
        isHoverSuppressed = false
        showsTabPreview = false
        showsPeek = false
        isPressed = false
        rawIsLoading = false
        isLoading = false
        loadingProgress = 1.0
        isCurrentlyAudible = false
        isMuted = false
        isCapturingMedia = false
        agentSidebarStatus = .none
        isEndedAgentChat = false
        groupColor = nil
        status.prepareForReuse()
        faviconRevision &+= 1
        onToggleMute = nil
        onToolTipUpdated = nil
    }

    func setHovered(_ hovered: Bool) {
        isHovered = hovered && !isHoverSuppressed
    }

    func setHoverSuppressed(_ suppressed: Bool) {
        isHoverSuppressed = suppressed
        if suppressed {
            isHovered = false
        }
    }

    private var configuredTabGuid: Int?
    private var configurationGeneration: UInt64 = 0

    private func isCurrentConfiguration(expectedGuid: Int, expectedGeneration: UInt64) -> Bool {
        configuredTabGuid == expectedGuid && configurationGeneration == expectedGeneration
    }

    func configure(with tab: Tab, in browserState: BrowserState? = nil) {
        cancellables.removeAll()
        configurationGeneration &+= 1

        let expectedGuid = tab.guid
        let expectedGeneration = configurationGeneration
        configuredTabGuid = expectedGuid
        status.configure(with: tab)
        bindAgentSidebarStatus(to: tab, expectedGeneration: expectedGeneration)

        self.title = tab.title
        self.isRenaming = tab.isRenaming
        tab.$isRenaming.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] isRenaming in
                guard let self, self.isCurrentConfiguration(expectedGuid: expectedGuid, expectedGeneration: expectedGeneration) else { return }
                self.isRenaming = isRenaming
            }
            .store(in: &cancellables)
        self.url = tab.url
        self.appIcon = tab.appAddress.flatMap { MistApps.app($0.app)?.icon($0.instance) }
        AgentChatStore.shared.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self, weak tab] in
                guard let self, let address = tab?.appAddress, address.app == .drifter else { return }
                let icon = MistApps.app(address.app)?.icon(address.instance)
                if self.appIcon != icon { self.appIcon = icon }
            }.store(in: &cancellables)
        self.faviconLoadURL = Self.faviconPageURLString(for: tab)
        self.faviconUrl = tab.faviconUrl
        updateLiveFavicon(data: tab.liveFaviconData, revision: tab.liveFaviconRevision)
        updateProfileFaviconImage(data: tab.cachedFaviconData, clearsOnNil: true)
        refreshProfileFaviconIfNeeded(for: tab, expectedGuid: tab.guid)
        AppLogDebug(
            "[FaviconFlow] tabViewModel.configure " +
            "model=\(ObjectIdentifier(self)) tabId=\(expectedGuid) " +
            "url=\(tab.url ?? "nil") faviconLoadURL=\(faviconLoadURL ?? "nil") " +
            "tabLiveBytes=\(tab.liveFaviconData?.count ?? 0) " +
            "tabCachedBytes=\(tab.cachedFaviconData?.count ?? 0) " +
            "liveImage=\(liveFaviconImage != nil) profileImage=\(profileFaviconImage != nil)"
        )
        self.isActive = tab.isActive
        self.rawIsLoading = tab.isLoading
        self.loadingProgress = Double(tab.loadingProgress)
        updateVisualLoading()
        self.isCurrentlyAudible = tab.isCurrentlyAudible
        self.isMuted = tab.isMuted
        self.isCapturingMedia = tab.isCapturingAudio || tab.isCapturingVideo || tab.isSharingScreen
        self.isHovered = false
        self.isHoverSuppressed = false
        
        tab.$title
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newTitle in
                guard let self, self.isCurrentConfiguration(expectedGuid: expectedGuid, expectedGeneration: expectedGeneration) else { return }
                self.title = newTitle
                self.onToolTipUpdated?()
            }
            .store(in: &cancellables)
            
        tab.$url
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newUrl in
                guard let self, self.isCurrentConfiguration(expectedGuid: expectedGuid, expectedGeneration: expectedGeneration) else { return }
                self.url = newUrl
                self.appIcon = tab.appAddress.flatMap { MistApps.app($0.app)?.icon($0.instance) }
                // Intentionally keep faviconLoadURL when newUrl is nil/empty.
                // During navigation the URL briefly becomes nil before the new
                // page URL arrives; clearing faviconLoadURL here would cause a
                // globe-icon flash. configure() already resets it unconditionally.
                if let newUrl, !newUrl.isEmpty {
                    let oldFaviconLoadURL = self.faviconLoadURL
                    self.faviconLoadURL = newUrl
                    if let oldFaviconLoadURL,
                       Self.faviconHostChanged(from: oldFaviconLoadURL, to: newUrl) {
                        self.clearVisibleFaviconForURLChange(from: oldFaviconLoadURL, to: newUrl)
                    }
                }
                self.refreshProfileFaviconIfNeeded(for: tab, expectedGuid: expectedGuid)
            }
            .store(in: &cancellables)
            
        tab.$faviconUrl
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rawFaviconUrl in
                guard let self, self.isCurrentConfiguration(expectedGuid: expectedGuid, expectedGeneration: expectedGeneration) else { return }
                let newFaviconUrl = (rawFaviconUrl?.isEmpty == false) ? rawFaviconUrl : nil
                let oldFaviconUrl = (self.faviconUrl?.isEmpty == false) ? self.faviconUrl : nil
                self.faviconUrl = rawFaviconUrl
                
                if let newFaviconUrl,
                    oldFaviconUrl?.isEmpty == false,
                    newFaviconUrl != oldFaviconUrl,
                   let pageURL = self.faviconLoadURL.flatMap(URL.init(string:)) {
                    Task { [weak self] in
                        await FaviconDataProvider.clearCache(for: pageURL)
                        guard let self,
                              self.isCurrentConfiguration(expectedGuid: expectedGuid, expectedGeneration: expectedGeneration) else {
                            return
                        }
                        self.reloadFavicon()
                    }
                } else if oldFaviconUrl == nil {
                    self.reloadFavicon()
                }
                self.refreshProfileFaviconIfNeeded(for: tab, expectedGuid: expectedGuid)
            }
            .store(in: &cancellables)

        tab.$liveFaviconData
            .combineLatest(tab.$liveFaviconRevision)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data, revision in
                guard let self, self.isCurrentConfiguration(expectedGuid: expectedGuid, expectedGeneration: expectedGeneration) else { return }
                self.updateLiveFavicon(data: data, revision: revision)
                self.refreshProfileFaviconIfNeeded(for: tab, expectedGuid: expectedGuid)
            }
            .store(in: &cancellables)

        tab.$cachedFaviconData
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                guard let self, self.configuredTabGuid == expectedGuid else { return }
                self.updateProfileFaviconImage(data: data, clearsOnNil: false)
            }
            .store(in: &cancellables)
            
        tab.$isActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, self.isCurrentConfiguration(expectedGuid: expectedGuid, expectedGeneration: expectedGeneration) else { return }
                self.isActive = $0
            }
            .store(in: &cancellables)
            
        tab.$isLoading
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newVal in
                guard let self else { return }
                guard self.isCurrentConfiguration(expectedGuid: expectedGuid, expectedGeneration: expectedGeneration) else {
                    return
                }
                self.rawIsLoading = newVal
                self.updateVisualLoading()
            }
            .store(in: &cancellables)
            
        tab.$loadingProgress
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newVal in
                guard let self else { return }
                guard self.isCurrentConfiguration(expectedGuid: expectedGuid, expectedGeneration: expectedGeneration) else {
                    return
                }
                self.loadingProgress = Double(newVal)
                self.updateVisualLoading()
            }
            .store(in: &cancellables)

        tab.$isCurrentlyAudible
            .combineLatest(tab.audioMutePublisher)
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isCurrentlyAudible, isMuted in
                guard let self, self.isCurrentConfiguration(expectedGuid: expectedGuid, expectedGeneration: expectedGeneration) else { return }
                self.isCurrentlyAudible = isCurrentlyAudible
                self.isMuted = isMuted
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(tab.$isCapturingAudio, tab.$isCapturingVideo, tab.$isSharingScreen)
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isCapturingAudio, isCapturingVideo, isSharingScreen in
                guard let self, self.isCurrentConfiguration(expectedGuid: expectedGuid, expectedGeneration: expectedGeneration) else { return }
                self.isCapturingMedia = isCapturingAudio || isCapturingVideo || isSharingScreen
            }
            .store(in: &cancellables)

        // Group affiliation color. Updates on (a) tab joining/leaving a group,
        // (b) the dict gaining/losing the entry, (c) the current group's color
        // change. switchToLatest re-binds the inner color publisher whenever
        // membership changes so we don't leak subscriptions to old groups.
        if let token = tab.groupToken,
           let info = browserState?.groups[token] {
            self.groupColor = info.color
        } else {
            self.groupColor = nil
        }
        self.isInGroup = (tab.groupToken != nil)
        // Track group membership independently of color resolution. Updates
        // synchronously on tab.groupToken transitions so callers like
        // `SideTabView`'s indent rely on a flicker-free signal.
        tab.$groupToken
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] inGroup in
                guard let self, self.isCurrentConfiguration(expectedGuid: expectedGuid, expectedGeneration: expectedGeneration) else { return }
                self.isInGroup = inGroup
            }
            .store(in: &cancellables)
        if let browserState {
            tab.$groupToken
                .combineLatest(browserState.$groups)
                .map { token, groups -> AnyPublisher<GroupColor?, Never> in
                    guard let token, let info = groups[token] else {
                        return Just(nil).eraseToAnyPublisher()
                    }
                    return info.$color
                        .map { Optional($0) }
                        .eraseToAnyPublisher()
                }
                .switchToLatest()
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] color in
                    guard let self, self.isCurrentConfiguration(expectedGuid: expectedGuid, expectedGeneration: expectedGeneration) else { return }
                    self.groupColor = color
                }
                .store(in: &cancellables)
        }

        if let browserState {
            self.isMultiSelected = browserState.multiSelection.contains(expectedGuid)
            browserState.$multiSelection
                .receive(on: DispatchQueue.main)
                .sink { [weak self] selection in
                    guard let self, self.isCurrentConfiguration(expectedGuid: expectedGuid, expectedGeneration: expectedGeneration) else { return }
                    self.isMultiSelected = selection.contains(expectedGuid)
                }
                .store(in: &cancellables)
        } else {
            self.isMultiSelected = false
        }
    }

    private func bindAgentSidebarStatus(to tab: Tab, expectedGeneration: UInt64) {
        Self.agentSidebarStatusPublisher(for: tab)
            .sink { [weak self] marker, ended in
                guard let self, self.isCurrentConfiguration(expectedGuid: tab.guid, expectedGeneration: expectedGeneration) else { return }
                self.agentSidebarStatus = marker
                self.isEndedAgentChat = ended
            }
            .store(in: &cancellables)
    }

    static func agentSidebarStatusPublisher(for tab: Tab, store: AgentChatStore? = nil) -> AnyPublisher<(AgentSidebarStatus, Bool), Never> {
        let store = store ?? AgentChatStore.shared
        return tab.$url.combineLatest(store.objectWillChange.prepend(()))
            .receive(on: DispatchQueue.main)
            .map { url, _ -> AnyPublisher<(AgentSidebarStatus, Bool), Never> in
                guard let id = store.route.conversationId(for: url) else {
                    return Just((.none, false)).eraseToAnyPublisher()
                }
                guard let conversation = store.conversation(for: id) else {
                    return Just((.none, !store.canRestore(id))).eraseToAnyPublisher()
                }
                return conversation.$status.combineLatest(store.$unseenCompletions,
                                                          conversation.$backgroundTasks.map { !$0.isEmpty }.removeDuplicates(),
                                                          conversation.$handOff.map { $0 != nil }.removeDuplicates())
                    .map { status, unseen, background, waiting in
                        (AgentSidebarStatus.marker(for: status, isUnseenCompletion: unseen.contains(id), hasBackgroundTasks: background,
                                                   waitsForUser: waiting),
                         status == .ended)
                    }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            // A running chat republishes its status with every streamed update.
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    private func updateLiveFavicon(data: Data?, revision: Int) {
        liveFaviconRevision = revision

        guard let data, let image = NSImage(data: data) else {
            liveFaviconImage = nil
            AppLogDebug(
                "[FaviconFlow] tabViewModel.liveFavicon " +
                "tabId=\(configuredTabGuid.map(String.init) ?? "nil") " +
                "bytes=\(data?.count ?? 0) revision=\(revision) image=false"
            )
            return
        }

        liveFaviconImage = image
        AppLogDebug(
            "[FaviconFlow] tabViewModel.liveFavicon " +
            "tabId=\(configuredTabGuid.map(String.init) ?? "nil") " +
            "bytes=\(data.count) revision=\(revision) image=true"
        )
    }

    private func updateVisualLoading() {
        isLoading = rawIsLoading && loadingProgress < 0.99
    }

    private static func faviconPageURLString(for tab: Tab) -> String? {
        let pageURLString = tab.isOpenned ? (tab.url ?? tab.pinnedUrl) : (tab.pinnedUrl ?? tab.url)
        return (pageURLString?.isEmpty == false) ? pageURLString : nil
    }

    private func updateProfileFaviconImage(data: Data?, clearsOnNil: Bool) {
        guard let data, let image = NSImage(data: data) else {
            if clearsOnNil {
                profileFaviconImage = nil
            }
            return
        }

        profileFaviconImage = image
    }

    private func clearVisibleFaviconForURLChange(from oldURLString: String, to newURLString: String) {
        let oldLiveImage = liveFaviconImage != nil
        let oldProfileImage = profileFaviconImage != nil
        liveFaviconImage = nil
        liveFaviconRevision = 0
        profileFaviconLoadHandle?.cancel()
        profileFaviconLoadHandle = nil
        profileFaviconImage = nil
        reloadFavicon()
        AppLogDebug(
            "[FaviconFlow] tabViewModel.clearFaviconForURLChange " +
            "tabId=\(configuredTabGuid.map(String.init) ?? "nil") " +
            "oldURL=\(oldURLString) newURL=\(newURLString) " +
            "oldLiveImage=\(oldLiveImage) oldProfileImage=\(oldProfileImage)"
        )
    }

    private static func faviconHostChanged(from oldURLString: String, to newURLString: String) -> Bool {
        guard let oldHost = normalizedFaviconHost(oldURLString),
              let newHost = normalizedFaviconHost(newURLString) else {
            return oldURLString != newURLString
        }
        return oldHost != newHost
    }

    private static func normalizedFaviconHost(_ urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func refreshProfileFaviconIfNeeded(for tab: Tab, expectedGuid: Int) {
        guard configuredTabGuid == expectedGuid else { return }

        guard tab.liveFaviconData == nil else {
            profileFaviconLoadHandle?.cancel()
            profileFaviconLoadHandle = nil
            return
        }

        profileFaviconLoadHandle?.cancel()
        profileFaviconLoadHandle = nil

        guard tab.cachedFaviconData != nil || tab.profileId?.isEmpty == false else {
            profileFaviconImage = nil
            return
        }

        let request = ProfileScopedFaviconRequest(
            profileId: tab.profileId,
            pageURLString: Self.faviconPageURLString(for: tab),
            snapshotData: tab.cachedFaviconData
        )

        profileFaviconLoadHandle = ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { [weak self, weak tab] result in
            guard let self,
                  self.configuredTabGuid == expectedGuid,
                  self.faviconLoadURL == request.pageURLString else {
                return
            }
            self.profileFaviconImage = result.image
            if result.source == .chromium, let data = result.data {
                tab?.updateProfileScopedFaviconData(
                    data,
                    sourceURLString: request.pageURLString
                )
            }
        }
    }
}
