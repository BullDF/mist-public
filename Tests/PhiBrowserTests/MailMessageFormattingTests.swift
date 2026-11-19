import AppKit
import MistMailCore
import XCTest
@testable import Phi

final class MailMessageFormattingTests: XCTestCase {
    func testSentAndDraftsUseRecipientsAndNamelessSendersUseAddresses() {
        let message = MailMessageSummary(id: UUID(), accountID: UUID(), mailboxID: UUID(), sender: [.init("sender@example.com")], recipients: [.init("ada@example.com", name: "Ada")], subject: "Notes", snippet: "", date: Date(), flags: [], hasAttachments: false, uid: 1)
        XCTAssertEqual(MailPresentation.correspondent(message, role: .inbox), "sender@example.com")
        XCTAssertEqual(MailPresentation.correspondent(message, role: .sent), String(format: MailStrings.to, "Ada"))
        XCTAssertEqual(MailPresentation.correspondent(message, role: .drafts), String(format: MailStrings.to, "Ada"))
    }
    func testSubjectIsTrimmedAndBlankShowsNoSubject() {
        XCTAssertEqual(MailPresentation.subject(" Vous avez résilié votre forfait\n"), "Vous avez résilié votre forfait")
        XCTAssertEqual(MailPresentation.subject("  "), MailStrings.noSubject)
    }
    func testDateBucketsUseCalendarDaysAndLocale() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "fr_FR")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 15)))
        let today = now.addingTimeInterval(-3600), yesterday = now.addingTimeInterval(-86400), weekday = now.addingTimeInterval(-3 * 86400), older = now.addingTimeInterval(-8 * 86400)
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.locale = locale; formatter.timeZone = calendar.timeZone; formatter.timeStyle = .short
        XCTAssertEqual(MailPresentation.date(today, now: now, calendar: calendar, locale: locale), formatter.string(from: today))
        XCTAssertEqual(MailPresentation.date(yesterday, now: now, calendar: calendar, locale: locale), MailStrings.yesterday)
        formatter.timeStyle = .none; formatter.setLocalizedDateFormatFromTemplate("EEE")
        XCTAssertEqual(MailPresentation.date(weekday, now: now, calendar: calendar, locale: locale), formatter.string(from: weekday))
        formatter.dateStyle = .short
        XCTAssertEqual(MailPresentation.date(older, now: now, calendar: calendar, locale: locale), formatter.string(from: older))
    }
    @MainActor func testMenuItemCopyKeepsItsAction() throws {
        // Opening any menu copies its items (ShortcutMenuPresentation); a copy must not trap.
        var runs = 0
        let item = MailMenuItem("Move") { runs += 1 }
        let copy = try XCTUnwrap(item.copy() as? NSMenuItem)
        XCTAssertEqual(copy.title, "Move")
        NSApp.sendAction(try XCTUnwrap(copy.action), to: copy.target, from: copy)
        XCTAssertEqual(runs, 1)
    }
}

@MainActor
final class MailMessageCellTests: XCTestCase {
    func testTextColumnsAlignForReadAndUnreadMessages() {
        func cell(flags: Set<String>) -> MailMessageCell {
            let message = MailMessageSummary(id: UUID(), accountID: UUID(), mailboxID: UUID(), sender: [.init("sender@example.com")], subject: "Notes", snippet: "A snippet", date: Date(), flags: flags, hasAttachments: false, uid: 1)
            let cell = MailMessageCell(frame: NSRect(x: 0, y: 0, width: 360, height: MailMessageCell.rowHeight))
            cell.update(message, role: nil, accountName: nil)
            cell.layoutSubtreeIfNeeded()
            return cell
        }
        let read = cell(flags: [MailFlags.seen]), unread = cell(flags: [])
        XCTAssertTrue(read.unread.isHidden)
        XCTAssertFalse(unread.unread.isHidden)
        XCTAssertEqual(unread.unread.accessibilityLabel(), MailStrings.markUnread)
        func x(_ view: NSView, in cell: MailMessageCell) -> CGFloat { view.convert(view.bounds, to: cell).minX }
        for cell in [read, unread] {
            let senderX = x(cell.sender, in: cell)
            XCTAssertEqual(senderX, x(cell.subject, in: cell), accuracy: 0.5)
            XCTAssertEqual(senderX, x(cell.snippet, in: cell), accuracy: 0.5)
            XCTAssertLessThanOrEqual(cell.unread.convert(cell.unread.bounds, to: cell).maxX, senderX)
        }
        XCTAssertEqual(x(read.sender, in: read), x(unread.sender, in: unread), accuracy: 0.5)
    }

    func testRowTextIsNotSelectable() {
        let cell = MailMessageCell(frame: NSRect(x: 0, y: 0, width: 360, height: MailMessageCell.rowHeight))
        func fields(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? fields(in: $0) }
        }
        let labels = fields(in: cell)
        XCTAssertFalse(labels.isEmpty)
        for label in labels { XCTAssertFalse(label.isSelectable, label.stringValue) }
    }

    func testTwoLineSnippetFitsInsideTheRowPadding() {
        let message = MailMessageSummary(id: UUID(), accountID: UUID(), mailboxID: UUID(), sender: [.init("sender@example.com")], subject: "Notes", snippet: "First line\nSecond line", date: Date(), flags: [], hasAttachments: false, uid: 1)
        let cell = MailMessageCell(frame: NSRect(x: 0, y: 0, width: 360, height: MailMessageCell.rowHeight))
        cell.update(message, role: nil, accountName: nil)
        cell.layoutSubtreeIfNeeded()
        let snippet = cell.snippet.convert(cell.snippet.bounds, to: cell)
        let sender = cell.sender.convert(cell.sender.bounds, to: cell)
        let expected = cell.snippet.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: cell.snippet.bounds.width, height: 1000)).height
        XCTAssertGreaterThanOrEqual(snippet.height, expected)
        XCTAssertGreaterThanOrEqual(min(sender.minY, snippet.minY), 14)
        XCTAssertLessThanOrEqual(max(sender.maxY, snippet.maxY), cell.bounds.height - 14)
    }
}
