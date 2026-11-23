// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Darwin

/// Serializes a Space's bookmark tree — optionally preceded by a Favorites
/// folder carrying the window's visible pinned tabs — into the Netscape
/// bookmark file format (`NETSCAPE-Bookmark-file-1`) understood by Chrome,
/// Firefox, Safari, and Edge. Shared by the Bookmarks menu and Drifter.
enum BookmarkHTMLExporter {
    struct Counts {
        let bookmarks: Int
        let pinnedTabs: Int
    }

    enum ExportError: LocalizedError {
        case emptySpace
        case destinationExists

        var errorDescription: String? {
            switch self {
            case .emptySpace: return "That Space has no bookmarks or pinned tabs to export."
            case .destinationExists: return "A file already exists at that path. Set overwrite to true to replace it."
            }
        }
    }

    @MainActor
    static func export(from state: BrowserState, to url: URL, overwrite: Bool,
                       createParentDirectories: Bool = false,
                       completion: @escaping (Result<Counts, Error>) -> Void) throws {
        let bookmarks = state.bookmarkManager.rootFolder.children
        let pinnedTabs = state.pinnedTabs
        guard hasExportableContent(bookmarks: bookmarks, pinnedTabs: pinnedTabs) else { throw ExportError.emptySpace }
        let counts = Counts(bookmarks: leafCount(bookmarks), pinnedTabs: pinnedTabs.filter { pinnedURL(for: $0) != nil }.count)
        let html = htmlDocument(for: bookmarks, pinnedTabs: pinnedTabs,
            favoritesFolderTitle: NSLocalizedString("app.bookmarkExport.exportedFolderName", value: "Favorites",
                comment: "Bookmark export - name of the exported folder carrying the window's pinned tabs"))
        AppController.inFlightBookmarkExportWrites += 1
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try write(Data(html.utf8), to: url, overwrite: overwrite, createParentDirectories: createParentDirectories)
                return counts
            }
            DispatchQueue.main.async {
                AppController.inFlightBookmarkExportWrites -= 1
                if AppController.bookmarkExportTerminationPending {
                    AppController.shared.resumeTerminationAfterConfirmedExports()
                }
                completion(result)
            }
        }
    }

    private static func write(_ data: Data, to url: URL, overwrite: Bool, createParentDirectories: Bool) throws {
        let files = FileManager.default
        let parent = url.deletingLastPathComponent()
        if createParentDirectories {
            try files.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if overwrite {
            try data.write(to: url, options: .atomic)
            return
        }
        if files.fileExists(atPath: url.path) { throw ExportError.destinationExists }
        // Publish the completed file atomically, failing even if a competing writer just created the destination.
        let staging = parent.appendingPathComponent(".mist-bookmarks-\(UUID().uuidString).tmp")
        defer { try? files.removeItem(at: staging) }
        try data.write(to: staging, options: .atomic)
        guard renamex_np(staging.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw ExportError.destinationExists }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    private static func leafCount(_ bookmarks: [Bookmark]) -> Int {
        bookmarks.reduce(0) { $0 + ($1.isFolder ? leafCount($1.children) : 1) }
    }

    static func htmlDocument(for bookmarks: [Bookmark],
                             pinnedTabs: [Tab],
                             favoritesFolderTitle: String) -> String {
        var lines: [String] = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<!-- This is an automatically generated file.",
            "     It will be read and overwritten.",
            "     DO NOT EDIT! -->",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Bookmarks</TITLE>",
            "<H1>Bookmarks</H1>",
            "<DL><p>",
        ]
        appendFavoritesFolder(for: pinnedTabs, title: favoritesFolderTitle, into: &lines)
        for bookmark in bookmarks {
            appendNode(bookmark, depth: 1, into: &lines)
        }
        lines.append("</DL><p>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The export-enablement predicate, defined per spec as: bookmark tree
    /// non-empty OR visible pinned collection non-empty. The single
    /// definition shared by menu validation, the action entry point, and
    /// the save-panel confirmation re-read, so the three can never drift.
    /// Pinned records count even when none has a usable URL — that
    /// degenerate export is a valid, item-less document.
    static func hasExportableContent(bookmarks: [Bookmark], pinnedTabs: [Tab]) -> Bool {
        !bookmarks.isEmpty || !pinnedTabs.isEmpty
    }

    /// Renders the visible pinned collection as one Favorites folder, first
    /// in the top-level list — mirroring the sidebar, where pinned tabs sit
    /// above bookmarks. Entries carry the saved state a pin re-opens to,
    /// never live navigation state; pinned tabs with no usable URL are
    /// skipped, and the folder is omitted when no entry survives.
    private static func appendFavoritesFolder(for pinnedTabs: [Tab],
                                              title: String,
                                              into lines: inout [String]) {
        let entries = pinnedTabs.compactMap(favoritesEntry(for:))
        guard !entries.isEmpty else { return }
        lines.append("    <DT><H3>\(escaped(title))</H3>")
        lines.append("    <DL><p>")
        lines.append(contentsOf: entries)
        lines.append("    </DL><p>")
    }

    /// One `<DT><A>` line for a pinned tab, or nil when both the saved and
    /// live URL are empty. A split pinned pair arrives as two records and so
    /// exports as two adjacent plain entries; the bookmark-provenance
    /// secondary fields on pinned records are never emitted (they would
    /// duplicate the partner's entry).
    private static func favoritesEntry(for tab: Tab) -> String? {
        guard let url = pinnedURL(for: tab) else { return nil }
        let title = tab.storedTitle ?? tab.title
        let favicon = isFaviconPresumedDrifted(for: tab) ? nil : tab.cachedFaviconData
        let attributes = " HREF=\"\(escaped(url))\""
            + addDateAttribute(for: tab.pinnedCreatedDate)
            + iconAttribute(for: favicon)
        return "        <DT><A\(attributes)>\(escaped(title))</A>"
    }

    private static func pinnedURL(for tab: Tab) -> String? {
        if let url = tab.pinnedUrl, !url.isEmpty { return url }
        guard let url = tab.url, !url.isEmpty else { return nil }
        return url
    }

    /// An open pinned tab's cached favicon follows live navigation (it is
    /// cleared and rewritten when the page host changes), so a live URL on a
    /// different host than the saved URL means the cached bytes belong to the
    /// live site, not the pin — such an entry carries no ICON and importers
    /// fetch their own. Closed and unloaded records normally carry
    /// `url == pinnedUrl` and keep their ICON; a record detached with a
    /// stale live `url` trips this only when its favicon truly drifted.
    /// Host normalization mirrors the favicon
    /// pipeline's (lowercased, `www.` stripped, full-string comparison when
    /// a host is unparseable) so the presumption matches how drift happens.
    private static func isFaviconPresumedDrifted(for tab: Tab) -> Bool {
        guard let savedURL = normalizedNonEmptyURLString(tab.pinnedUrl),
              let liveURL = normalizedNonEmptyURLString(tab.url) else { return false }
        guard let savedHost = normalizedFaviconHost(savedURL),
              let liveHost = normalizedFaviconHost(liveURL) else {
            return savedURL != liveURL
        }
        return savedHost != liveHost
    }

    private static func normalizedNonEmptyURLString(_ urlString: String?) -> String? {
        guard let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalizedFaviconHost(_ urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func appendNode(_ bookmark: Bookmark, depth: Int, into lines: inout [String]) {
        let indent = String(repeating: "    ", count: depth)
        if bookmark.isFolder {
            lines.append("\(indent)<DT><H3\(folderDateAttributes(for: bookmark))>\(escaped(bookmark.title))</H3>")
            lines.append("\(indent)<DL><p>")
            for child in bookmark.children {
                appendNode(child, depth: depth + 1, into: &lines)
            }
            lines.append("\(indent)</DL><p>")
            return
        }
        let attributes = " HREF=\"\(escaped(bookmark.url ?? ""))\""
            + addDateAttribute(for: bookmark.createdDate)
            + iconAttribute(for: bookmark.cachedFaviconData)
        lines.append("\(indent)<DT><A\(attributes)>\(escaped(bookmark.title))</A>")
        // A split bookmark carries a second URL the generic format cannot
        // express on one entry — flatten it into an adjacent plain entry.
        // Its title falls back to the primary title (suppressed-duplicate
        // convention at creation), then to the URL itself.
        if let secondaryURL = bookmark.secondaryUrl, !secondaryURL.isEmpty {
            let fallback = bookmark.title.isEmpty ? secondaryURL : bookmark.title
            let secondaryTitle = (bookmark.secondaryTitle?.isEmpty == false)
                ? bookmark.secondaryTitle! : fallback
            let secondaryAttributes = " HREF=\"\(escaped(secondaryURL))\"" + addDateAttribute(for: bookmark.createdDate)
            lines.append("\(indent)<DT><A\(secondaryAttributes)>\(escaped(secondaryTitle))</A>")
        }
    }

    private static func addDateAttribute(for created: Date?) -> String {
        guard let created else { return "" }
        return " ADD_DATE=\"\(Int(created.timeIntervalSince1970))\""
    }

    private static func iconAttribute(for favicon: Data?) -> String {
        guard let favicon else { return "" }
        return " ICON=\"data:image/png;base64,\(favicon.base64EncodedString())\""
    }

    /// URL entries carry ADD_DATE only: LAST_MODIFIED means "last edit" in
    /// the format, while `updatedDate` is also bumped by bookmark opens
    /// (LocalStore.updateLastSeen). Chrome's exporter omits it on entries
    /// too. Folder rows are only touched by real edits, so folders keep it.
    private static func folderDateAttributes(for bookmark: Bookmark) -> String {
        var attributes = addDateAttribute(for: bookmark.createdDate)
        if let updated = bookmark.updatedDate {
            attributes += " LAST_MODIFIED=\"\(Int(updated.timeIntervalSince1970))\""
        }
        return attributes
    }

    /// Default export filename: `Phi-Bookmarks-<SpaceName>-<yyyy-MM-dd>.html`,
    /// spaces-free throughout. Whitespace and the filesystem-hostile `/` and
    /// `:` in the Space name become hyphens; runs collapse to one.
    static func defaultFilename(spaceName: String, date: Date) -> String {
        var collapsed = ""
        for character in spaceName {
            let mapped: Character =
                (character == "/" || character == ":" || character.isWhitespace) ? "-" : character
            if mapped == "-", collapsed.hasSuffix("-") { continue }
            collapsed.append(mapped)
        }
        let name = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let segment = name.isEmpty ? "Space" : name

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Mist-Bookmarks-\(segment)-\(formatter.string(from: date)).html"
    }

    /// Escapes text for use in HTML body text and double-quoted attributes.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
