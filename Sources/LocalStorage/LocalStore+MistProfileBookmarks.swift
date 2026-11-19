import Combine
import CoreData
import Foundation
import SwiftData

extension LocalStore {
    /// Pages suggested by the address bar, across every Space in a profile.
    @MainActor
    func mistSuggestionSourcesPublisher(profileId: String) -> AnyPublisher<[TabDataModel], Never> {
        guard mainContext != nil else {
            return Empty().eraseToAnyPublisher()
        }

        let subject = CurrentValueSubject<[TabDataModel]?, Never>(nil)
        let fetch: () -> [TabDataModel]? = { [weak self] in
            guard let self, let context = self.mainContext else { return nil }
            do {
                let bookmarkRaw = TabDataType.bookmark.rawValue
                let pinnedRaw = TabDataType.pinnedTab.rawValue
                let descriptor = FetchDescriptor<TabDataModel>(
                    predicate: #Predicate { $0.type == bookmarkRaw || $0.type == pinnedRaw },
                    sortBy: [SortDescriptor(\.createdDate), SortDescriptor(\.guid)]
                )
                let scope = try self.pinnedTabScope(in: context)
                return try context.fetch(descriptor).filter { row in
                    if row.dataType == .bookmark {
                        return row.profile?.profileId == profileId
                    }
                    // Scope migrations retain old collections as backups. Only
                    // the active collection is visible, including app-wide pins.
                    guard !row.isPinnedTabDormant else { return false }
                    switch scope {
                    case .space:
                        return (row.profileId == profileId || row.profile?.profileId == profileId)
                            && row.spaceId != nil
                    case .profile:
                        return (row.profileId == profileId || row.profile?.profileId == profileId)
                            && row.spaceId == nil
                    case .app:
                        return row.profileId == nil && row.spaceId == nil
                    }
                }
            } catch {
                AppLogError("[MistBookmarkMirror] Failed to fetch suggestion sources: \(error)")
                return nil
            }
        }

        if let rows = fetch() { subject.send(rows) }
        let changes = NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)
            .filter { Self.notificationContainsChanges($0, matching: {
                // A scope change can select a retained collection without
                // changing its rows, so settings saves also require a refetch.
                if $0.entity.name == BrowserDataSettingsModel.entityName { return true }
                guard $0.entity.name == TabDataModel.entityName,
                      let type = Self.tabType(from: $0) else { return false }
                return type == TabDataType.bookmark.rawValue || type == TabDataType.pinnedTab.rawValue
            }) }
            .receive(on: DispatchQueue.main)
            .sink { _ in
                if let rows = fetch() { subject.send(rows) }
            }

        return subject
            .compactMap { $0 }
            .handleEvents(receiveCancel: { changes.cancel() })
            .eraseToAnyPublisher()
    }
}
