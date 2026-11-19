// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation
import SwiftData

extension LocalStore {

    /// Nil units leave existing values and their edit timestamps unchanged.
    struct URLRuleDraft {
        struct ContentUnit: Equatable {
            var host: String
            var pathPrefix: String?
            var askBeforeRouting: Bool

            init(host: String, pathPrefix: String? = nil, askBeforeRouting: Bool = false) {
                let normalized = LocalStore.normalizedRule(host: host, pathPrefix: pathPrefix)
                self.host = normalized.host
                self.pathPrefix = normalized.pathPrefix
                self.askBeforeRouting = askBeforeRouting
            }
        }

        var id: String = UUID().uuidString
        var content: ContentUnit?
        var spaceId: String?
        var sortOrder: Int?
        var createdDate: Date?

    }

    @MainActor
    func getAllURLRules() -> [SpaceRoutingRule] {
        readableURLRules() ?? []
    }

    /// Same rows as `getAllURLRules()`, but nil when the store cannot be read (no main context or a thrown
    /// fetch), so a routing-table consumer can keep its previous snapshot instead of blanking routing.
    /// `urlRulesPublisher()` reads through this API and inherits the soft-delete filter.
    @MainActor
    func readableURLRules() -> [SpaceRoutingRule]? {
        guard let context = mainContext else {
            AppLogError("[LocalStore] URL rule read skipped: no main context")
            return nil
        }
        do {
            let descriptor = FetchDescriptor<SpaceURLRule>(
                predicate: #Predicate { $0.deletedDate == nil },
                sortBy: [SortDescriptor(\.spaceId), SortDescriptor(\.sortOrder)]
            )
            return try context.fetch(descriptor).map { model in
                SpaceRoutingRule(id: model.id, spaceId: model.spaceId, host: model.host,
                                 pathPrefix: model.pathPrefix,
                                 askBeforeRouting: model.askBeforeRouting,
                                 sortOrder: model.sortOrder, createdDate: model.createdDate,
                                 syncId: model.syncId, deletedDate: model.deletedDate)
            }
        } catch {
            AppLogError("[LocalStore] URL rule read failed: \(error)")
            return nil
        }
    }

    @MainActor
    func getURLRules(forSpaceId spaceId: String) -> [SpaceRoutingRule] {
        guard let context = mainContext else { return [] }
        do {
            let descriptor = FetchDescriptor<SpaceURLRule>(
                predicate: #Predicate { $0.spaceId == spaceId && $0.deletedDate == nil },
                sortBy: [SortDescriptor(\.sortOrder)]
            )
            return try context.fetch(descriptor).map { model in
                SpaceRoutingRule(id: model.id, spaceId: model.spaceId, host: model.host,
                                 pathPrefix: model.pathPrefix,
                                 askBeforeRouting: model.askBeforeRouting,
                                 sortOrder: model.sortOrder, createdDate: model.createdDate,
                                 syncId: model.syncId, deletedDate: model.deletedDate)
            }
        } catch {
            AppLogError("[LocalStore] getURLRules(forSpaceId:) failed: \(error)")
            return []
        }
    }


    func applyURLRuleEditsThrowing(upserts: [URLRuleDraft], deletedIds: Set<String>) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.applyURLRuleEditsBody(upserts: upserts, deletedIds: deletedIds, in: context)
        }
    }

    /// Apply local edits and normalize each affected bucket in one transaction.
    private func applyURLRuleEditsBody(upserts: [URLRuleDraft],
                                       deletedIds: Set<String>,
                                       in context: ModelContext) throws {
        let now = Date()
        var rows = try context.fetch(FetchDescriptor<SpaceURLRule>())
        var byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var touchedBuckets: Set<String> = []
        // Explicit placements take precedence over existing sibling order.
        var placements: [String: Int] = [:]
        var insertedIds: Set<String> = []
        for draft in upserts {
            let located = byId[draft.id]
            let mintsFreshId = located?.deletedDate != nil
            if let row = located, !mintsFreshId {
                let rowId = row.id
                if let unit = draft.content {
                    let normalized = LocalStore.normalizedRule(host: unit.host, pathPrefix: unit.pathPrefix)
                    var contentChanged = false
                    if row.host != normalized.host {
                        row.host = normalized.host
                        contentChanged = true
                    }
                    if row.pathPrefix != normalized.pathPrefix {
                        row.pathPrefix = normalized.pathPrefix
                        contentChanged = true
                    }
                    if row.askBeforeRouting != unit.askBeforeRouting {
                        row.askBeforeRouting = unit.askBeforeRouting
                        contentChanged = true
                    }
                    if contentChanged {
                        row.contentUpdatedDate = now
                    }
                }

                if let spaceId = draft.spaceId {
                    if spaceId != row.spaceId {
                        touchedBuckets.insert(row.spaceId)
                        row.spaceId = spaceId
                        row.targetUpdatedDate = now
                    }
                    touchedBuckets.insert(spaceId)
                } else {
                    touchedBuckets.insert(row.spaceId)
                }
                if let sortOrder = draft.sortOrder {
                    placements[rowId] = sortOrder
                }
            } else {
                guard let unit = draft.content, let spaceId = draft.spaceId else {
                    throw LocalStoreWriteError.noCandidateSurvived
                }
                let normalized = LocalStore.normalizedRule(host: unit.host, pathPrefix: unit.pathPrefix)
                let id = mintsFreshId ? UUID().uuidString.lowercased() : draft.id
                // Ruling 5: do not mint a content stamp for new rows; baseline-free projection uses
                // contentUpdatedDate ?? createdDate, and createdDate is current. sortOrder is a placeholder
                // normalized in step 8.
                let row = SpaceURLRule(
                    id: id,
                    spaceId: spaceId,
                    host: normalized.host,
                    pathPrefix: normalized.pathPrefix,
                    askBeforeRouting: unit.askBeforeRouting,
                    sortOrder: Int.max,
                    createdDate: draft.createdDate ?? Date()
                )
                context.insert(row)
                rows.append(row)
                byId[id] = row
                insertedIds.insert(id)
                if let sortOrder = draft.sortOrder {
                    placements[id] = sortOrder
                }
                touchedBuckets.insert(spaceId)
            }
        }

        for id in deletedIds {
            guard let row = byId[id] else { continue }
            touchedBuckets.insert(row.spaceId)
            rows.removeAll { $0 === row }
            context.delete(row)
        }

        for bucket in touchedBuckets {
            let live = rows.filter { $0.spaceId == bucket && $0.deletedDate == nil }
            var sequence = live
                .filter { placements[$0.id] == nil }
                .sorted { lhs, rhs in
                    let l = insertedIds.contains(lhs.id) ? Int.max : lhs.sortOrder
                    let r = insertedIds.contains(rhs.id) ? Int.max : rhs.sortOrder
                    if l != r { return l < r }
                    return lhs.id < rhs.id
                }
            let placed = live
                .filter { placements[$0.id] != nil }
                .sorted { lhs, rhs in
                    let l = placements[lhs.id] ?? Int.max
                    let r = placements[rhs.id] ?? Int.max
                    if l != r { return l < r }
                    return lhs.id < rhs.id
                }
            for row in placed {
                let requested = placements[row.id] ?? sequence.count
                sequence.insert(row, at: min(max(requested, 0), sequence.count))
            }
            for (index, row) in sequence.enumerated() where row.sortOrder != index {
                row.sortOrder = index
            }
        }

    }

    @MainActor
    func urlRulesPublisher() -> AnyPublisher<[SpaceRoutingRule], Never> {
        guard mainContext != nil else {
            AppLogError("[LocalStore] urlRulesPublisher: no main context")
            return Empty<[SpaceRoutingRule], Never>().eraseToAnyPublisher()
        }

        // A failed read emits nothing, so subscribers keep their last good snapshot (a nil initial value is
        // dropped by the compactMap below).
        let fetch = { self.readableURLRules() }
        let subject = CurrentValueSubject<[SpaceRoutingRule]?, Never>(fetch())

        let cancellable = NotificationCenter.default
            .publisher(for: .NSManagedObjectContextDidSave)
            .filter {
                Self.notificationContainsChanges(
                    $0,
                    matching: { $0.entity.name == SpaceURLRule.entityName }
                )
            }
            .receive(on: DispatchQueue.main)
            .sink { _ in
                if let rules = fetch() { subject.send(rules) }
            }

        return subject
            .compactMap { $0 }
            .removeDuplicates()
            .handleEvents(receiveCancel: { cancellable.cancel() })
            .prefix(untilOutputFrom: NotificationCenter.default.publisher(
                for: Self.willCloseNotification, object: self))
            .eraseToAnyPublisher()
    }



    /// Idempotent normalization shared by drafts and local routing.
    static func normalizedRule(host: String, pathPrefix: String?)
        -> (host: String, pathPrefix: String?) {
        (host: normalizedHost(host), pathPrefix: normalizedPathPrefix(pathPrefix))
    }

    static func normalizedHost(_ raw: String) -> String {
        var s = Substring(raw).drop(while: { $0.isWhitespace || $0.isNewline })
        while let last = s.last, last.isWhitespace || last.isNewline || last == "." {
            s = s.dropLast()
        }
        return String(s).lowercased()
    }

    /// Compare canonical percent-encoded paths. A slash matches only the root; nil matches any path.
    /// Decode and encode before stripping trailing slashes so escaped slashes normalize consistently.
    static func normalizedPathPrefix(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "/" { return "/" }                                          // 0
        guard !trimmed.isEmpty else { return nil }                                // 1
        var s = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed                  // 2
        s = s.removingPercentEncoding ?? s                                        // 3
        s = s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s  // 4
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }                  // 5
        return s                                                                  // 6
    }
}

extension LocalStore.URLRuleDraft {
    /// Flat convenience initializer supplying content and spaceId for Task 11's four construction sites and
    /// the agent router (SpaceURLRulesEditor.swift:143-149; AgentSpaceRouter+Management.swift:247-252,
    /// 308-311, 350-353). Nil spaceId supports older callers whose SpaceManager.setAllRules/setRules supplies
    /// the target. Field-dirty callers (M5 / 8b-4) use memberwise initialization directly.
    init(id: String = UUID().uuidString,
         host: String,
         pathPrefix: String? = nil,
         askBeforeRouting: Bool = false,
         spaceId: String? = nil,
         sortOrder: Int? = nil,
         createdDate: Date? = nil) {
        self.init(id: id,
                  content: ContentUnit(host: host,
                                       pathPrefix: pathPrefix,
                                       askBeforeRouting: askBeforeRouting),
                  spaceId: spaceId,
                  sortOrder: sortOrder,
                  createdDate: createdDate)
    }
}
