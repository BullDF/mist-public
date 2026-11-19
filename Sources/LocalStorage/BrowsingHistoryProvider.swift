// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SQLite3

struct BrowsingHistoryEntry: Equatable, Sendable {
    let url: String
    let urls: [String]
    let title: String
    let visitCount: Int64
    let typedCount: Int64
    let lastVisit: Date
    let frecency: Double
}

@MainActor
final class BrowsingHistoryProvider {
    static let shared = BrowsingHistoryProvider()
    typealias Loader = @Sendable (URL) -> [BrowsingHistoryEntry]

    private let loader: Loader
    private let now: () -> Date
    private var cache: [String: (entries: [BrowsingHistoryEntry], loadedAt: Date)] = [:]
    private var loads: [String: Task<Void, Never>] = [:]

    init(loader: @escaping Loader = { BrowsingHistoryProvider.load(historyFileURL: $0) },
         now: @escaping () -> Date = Date.init) {
        self.loader = loader
        self.now = now
    }

    func entries(forProfileId profileId: String) -> [BrowsingHistoryEntry] {
        cache[profileId]?.entries ?? []
    }

    @discardableResult
    func refresh(profileId: String, completion: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        if loads[profileId] == nil,
           cache[profileId].map({ now().timeIntervalSince($0.loadedAt) < 15 }) != true {
            let fileURL = URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true)
                .appendingPathComponent(profileId, isDirectory: true)
                .appendingPathComponent("History")
            let loader = loader
            loads[profileId] = Task {
                let entries = await Task.detached(priority: .userInitiated) { loader(fileURL) }.value
                self.cache[profileId] = (entries, self.now())
                self.loads[profileId] = nil
            }
        }
        let load = loads[profileId]
        return Task {
            await load?.value
            completion()
        }
    }

    nonisolated static func rank(
        _ entries: [BrowsingHistoryEntry], query: String, excludingURLs: Set<String>, limit: Int
    ) -> [(entry: BrowsingHistoryEntry, match: SearchTabsMatch)] {
        guard !SearchTabsQueryMatcher.normalizedQuery(query).isEmpty else { return [] }
        return Array(entries.compactMap { entry -> (entry: BrowsingHistoryEntry, match: SearchTabsMatch)? in
            guard excludingURLs.isDisjoint(with: entry.urls),
                  let match = SearchTabsQueryMatcher.match(
                    query: query,
                    primaryTitle: entry.title,
                    primaryURL: entry.url,
                    secondaryTitle: nil,
                    secondaryURL: nil
                  ) else {
                return nil
            }
            return (entry, match)
        }.sorted {
            if $0.match.score != $1.match.score { return $0.match.score > $1.match.score }
            if $0.entry.frecency != $1.entry.frecency { return $0.entry.frecency > $1.entry.frecency }
            if $0.entry.lastVisit != $1.entry.lastVisit { return $0.entry.lastVisit > $1.entry.lastVisit }
            return $0.entry.url < $1.entry.url
        }.prefix(limit))
    }

    nonisolated static func load(historyFileURL: URL, now: Date = Date()) -> [BrowsingHistoryEntry] {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("BrowsingHistory-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent("History")
            try copyRegularFile(at: historyFileURL, to: copy)
            let journal = URL(fileURLWithPath: historyFileURL.path + "-journal")
            if fileManager.fileExists(atPath: journal.path) {
                try copyRegularFile(at: journal, to: directory.appendingPathComponent("History-journal"))
            }
            return try readCopy(at: copy, now: now)
        } catch {
            AppLogWarn("[BrowsingHistory] Could not load browsing history: \(error)")
            return []
        }
    }

    nonisolated static func chromiumDate(_ microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600)
    }

    private nonisolated static func copyRegularFile(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
        // A copied symlink could otherwise direct SQLite back into the live profile.
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LoadError.invalidFile
        }
    }

    nonisolated static func frecency(visitCount: Int64, typedCount: Int64, lastVisit: Date, now: Date) -> Double {
        let days = now.timeIntervalSince(lastVisit) / 86_400
        let weight: Double
        switch days {
        case ...4: weight = 1.0
        case ...14: weight = 0.7
        case ...31: weight = 0.5
        case ...90: weight = 0.3
        default: weight = 0.1
        }
        return (Double(max(visitCount, 1)) + 4 * Double(typedCount)) * weight
    }

    private nonisolated static func readCopy(at url: URL, now: Date) throws -> [BrowsingHistoryEntry] {
        var database: OpaquePointer?
        // Only the disposable copy is writable, so SQLite can recover its hot journal.
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(database) }
        guard result == SQLITE_OK else {
            throw LoadError.sqlite(errorMessage(database))
        }

        var statement: OpaquePointer?
        let query = "SELECT url, title, visit_count, typed_count, last_visit_time FROM urls WHERE hidden = 0"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            throw LoadError.sqlite(errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        var groups: [GroupKey: BrowsingHistoryEntry] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw LoadError.sqlite(errorMessage(database))
            }
            guard sqlite3_column_type(statement, 0) == SQLITE_TEXT,
                  [SQLITE_TEXT, SQLITE_NULL].contains(sqlite3_column_type(statement, 1)),
                  (2...4).allSatisfy({ sqlite3_column_type(statement, Int32($0)) == SQLITE_INTEGER }),
                  let urlText = sqlite3_column_text(statement, 0) else {
                throw LoadError.invalidRow
            }
            let rawURL = String(cString: urlText)
            guard let parsedURL = URL(string: rawURL),
                  let scheme = parsedURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                continue
            }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            var visitCount = sqlite3_column_int64(statement, 2)
            var typedCount = sqlite3_column_int64(statement, 3)
            let lastVisit = chromiumDate(sqlite3_column_int64(statement, 4))
            let key: GroupKey = title.isEmpty
                ? .url(rawURL)
                : .page(host: parsedURL.host?.lowercased() ?? "", title: title)
            let previous = groups[key]
            visitCount += previous?.visitCount ?? 0
            typedCount += previous?.typedCount ?? 0
            var representativeURL = rawURL
            var latestVisit = lastVisit
            if let previous,
               previous.lastVisit > lastVisit || (previous.lastVisit == lastVisit && previous.url < rawURL) {
                representativeURL = previous.url
                latestVisit = previous.lastVisit
            }
            groups[key] = BrowsingHistoryEntry(
                url: representativeURL,
                urls: (previous?.urls ?? []) + [rawURL],
                title: title,
                visitCount: visitCount,
                typedCount: typedCount,
                lastVisit: latestVisit,
                frecency: frecency(visitCount: visitCount, typedCount: typedCount, lastVisit: latestVisit, now: now)
            )
        }
        return Array(groups.values.sorted {
            if $0.frecency != $1.frecency { return $0.frecency > $1.frecency }
            if $0.lastVisit != $1.lastVisit { return $0.lastVisit > $1.lastVisit }
            return $0.url < $1.url
        }.prefix(5_000))
    }

    private nonisolated static func errorMessage(_ database: OpaquePointer?) -> String {
        sqlite3_errmsg(database).map { String(cString: $0) } ?? "Could not open history copy"
    }

    private enum LoadError: Error {
        case sqlite(String)
        case invalidFile
        case invalidRow
    }

    private enum GroupKey: Hashable {
        case page(host: String, title: String)
        case url(String)
    }
}
