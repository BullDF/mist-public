import Foundation

struct DrifterCron: Equatable {
    private struct Field: Equatable {
        let values: Set<Int>
        let startsWithStar: Bool

        init(_ text: Substring, range: ClosedRange<Int>, names: [String] = []) throws {
            func value(_ word: Substring) throws -> Int {
                if let index = names.firstIndex(of: word.uppercased()) { return range.lowerBound + index }
                guard let number = Self.number(word), range.contains(number) else { throw DrifterScheduleError.invalidCron }
                return number
            }

            var values = Set<Int>()
            for part in text.split(separator: ",", omittingEmptySubsequences: false) {
                let stepped = part.split(separator: "/", omittingEmptySubsequences: false)
                guard let base = stepped.first, !base.isEmpty, stepped.count <= 2 else { throw DrifterScheduleError.invalidCron }
                let step: Int
                if stepped.count == 2 {
                    guard let number = Self.number(stepped[1]), number > 0 else { throw DrifterScheduleError.invalidCron }
                    step = number
                } else {
                    step = 1
                }
                let bounds: ClosedRange<Int>
                if base == "*" {
                    bounds = range
                } else {
                    let ends = base.split(separator: "-", omittingEmptySubsequences: false)
                    let first = try value(ends[0])
                    if ends.count == 2 {
                        let last = try value(ends[1])
                        guard first <= last else { throw DrifterScheduleError.invalidCron }
                        bounds = first...last
                    } else {
                        guard ends.count == 1, stepped.count == 1 else { throw DrifterScheduleError.invalidCron }
                        bounds = first...first
                    }
                }
                for number in bounds where (number - bounds.lowerBound).isMultiple(of: step) {
                    values.insert(number)
                }
            }
            self.values = values
            startsWithStar = text.first == "*"
        }

        private static func number(_ word: Substring) -> Int? {
            guard !word.isEmpty, word.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(word)
        }
    }

    private let minutes: [Int]
    private let hours: [Int]
    private let days: Field
    private let months: Set<Int>
    private let weekdays: Field

    init(_ expression: String) throws {
        let fields = expression.split(whereSeparator: \.isWhitespace)
        guard fields.count == 5 else { throw DrifterScheduleError.invalidCron }
        minutes = try Field(fields[0], range: 0...59).values.sorted()
        hours = try Field(fields[1], range: 0...23).values.sorted()
        days = try Field(fields[2], range: 1...31)
        months = try Field(fields[3], range: 1...12, names: [
            "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC",
        ]).values
        weekdays = try Field(fields[4], range: 0...7, names: ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"])
    }

    func next(after date: Date, calendar: Calendar) -> Date? {
        let firstDay = calendar.startOfDay(for: date)
        let current = calendar.dateComponents([.hour, .minute], from: date)
        let currentMinute = (current.hour ?? 0) * 60 + (current.minute ?? 0)
        var day = firstDay
        // The longest gap between valid Gregorian dates in a five-field cron is eight years
        // between leap days around a century boundary.
        for _ in 0..<(9 * 366) {
            let parts = calendar.dateComponents([.day, .month, .weekday], from: day)
            guard let month = parts.month, let dayOfMonth = parts.day, let weekday = parts.weekday,
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let dayMatches = days.values.contains(dayOfMonth)
            let weekdayMatches = weekdays.values.contains(weekday - 1) || (weekday == 1 && weekdays.values.contains(7))
            let matches = days.startsWithStar || weekdays.startsWithStar
                ? dayMatches && weekdayMatches : dayMatches || weekdayMatches
            let nextStart = calendar.startOfDay(for: nextDay)
            if months.contains(month), matches {
                for hour in hours {
                    for minute in minutes where day != firstDay || hour * 60 + minute > currentMinute {
                        // Look up the first instance from the start of the day even if now is
                        // between the two instances of a repeated local time.
                        if let match = calendar.nextDate(after: day.addingTimeInterval(-1),
                            matching: DateComponents(hour: hour, minute: minute, second: 0),
                            matchingPolicy: .strict, repeatedTimePolicy: .first),
                           match < nextStart, match > date {
                            return match
                        }
                    }
                }
            }
            day = nextStart
        }
        return nil
    }
}

enum DrifterScheduleError: LocalizedError {
    case timingCount, invalidCron, noOccurrence, invalidDate, pastDate, invalidDelay
    case unknownSchedule, forbiddenCancel

    var errorDescription: String? {
        switch self {
        case .timingCount: return "Exactly one of cron, at or delay_minutes is required."
        case .invalidCron: return "Invalid five-field cron (minute, hour, day of month, month, day of week)."
        case .noOccurrence: return "This cron has no future occurrence."
        case .invalidDate: return "at must be a valid ISO 8601 date-time."
        case .pastDate: return "at must be in the future."
        case .invalidDelay: return "delay_minutes must be an integer from 1 to 525600."
        case .unknownSchedule: return "No schedule has that ID. Call list_schedules for the current schedules."
        case .forbiddenCancel: return "Only the creating chat or Johnny can cancel a this_chat schedule."
        }
    }
}

struct DrifterSchedule: Codable, Equatable, Identifiable {
    enum Timing: Codable, Equatable {
        case cron(String), at(Date)

        static func resolve(cron: String?, at: String?, delayMinutes: Int?, now: Date, calendar: Calendar)
            throws -> (timing: Self, nextRun: Date) {
            guard [cron != nil, at != nil, delayMinutes != nil].filter({ $0 }).count == 1 else {
                throw DrifterScheduleError.timingCount
            }
            if let cron {
                let cron = cron.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let next = try DrifterCron(cron).next(after: now, calendar: calendar) else {
                    throw DrifterScheduleError.noOccurrence
                }
                return (.cron(cron), next)
            }
            if let delayMinutes {
                guard (1...525600).contains(delayMinutes) else { throw DrifterScheduleError.invalidDelay }
                let run = now.addingTimeInterval(TimeInterval(delayMinutes * 60))
                return (.at(run), run)
            }
            guard let at, let run = parseDate(at, calendar: calendar) else { throw DrifterScheduleError.invalidDate }
            guard run > now else { throw DrifterScheduleError.pastDate }
            return (.at(run), run)
        }

        private static func parseDate(_ text: String, calendar: Calendar) -> Date? {
            let pattern = #"^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2})(?::([0-9]{2})([.,][0-9]+)?)?([Zz]|[+-][0-9]{2}(?::?[0-9]{2})?)?$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.range.length == text.utf16.count else { return nil }
            func component(_ index: Int) -> String? {
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
            var calendar = calendar
            if let zone = component(8) {
                if zone.lowercased() == "z" {
                    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                } else {
                    let digits = zone.dropFirst().filter { $0 != ":" }
                    guard let hours = Int(digits.prefix(2)), hours < 24,
                          let minutes = digits.count == 2 ? 0 : Int(digits.suffix(2)), minutes < 60,
                          let offset = TimeZone(secondsFromGMT: (hours * 60 + minutes) * (zone.first == "-" ? -60 : 60))
                    else { return nil }
                    calendar.timeZone = offset
                }
            }
            let parts = DateComponents(year: component(1).flatMap(Int.init), month: component(2).flatMap(Int.init),
                                       day: component(3).flatMap(Int.init), hour: component(4).flatMap(Int.init),
                                       minute: component(5).flatMap(Int.init), second: component(6).flatMap(Int.init) ?? 0)
            guard let date = calendar.date(from: parts),
                  calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == parts
            else { return nil }
            let fraction = component(7).flatMap { Double("0." + $0.dropFirst()) } ?? 0
            return date.addingTimeInterval(fraction)
        }
    }

    enum Target: Codable, Equatable {
        case thisChat, newChat(DrifterConfig)

        var name: String {
            switch self {
            case .thisChat: return "this_chat"
            case .newChat: return "new_chat"
            }
        }
    }

    struct Run {
        let schedule: DrifterSchedule
        let nextRun: Date?
        let isLate: Bool

        func header(label: String, timeZone: TimeZone) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "EEE MMM dd HH:mm z"
            let due = formatter.string(from: schedule.nextRun)
            let late = isLate ? ", running late because Mist was closed or the Mac was asleep" : ""
            let header = "[Scheduled prompt \(label), due \(due)\(late)]"
            guard let nextRun else { return header + ". This was its only run." }
            return header + ". Next run: \(formatter.string(from: nextRun)). cancel_schedule \(schedule.id) stops it."
        }
    }

    let id: String
    let title: String
    let prompt: String
    let timing: Timing
    let target: Target
    let owner: UUID
    let createdAt: Date
    var nextRun: Date
    var lastRun: Date? = nil

    static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    func due(at now: Date, calendar: Calendar) throws -> Run? {
        guard nextRun <= now else { return nil }
        let following: Date?
        switch timing {
        case .at: following = nil
        case let .cron(expression):
            guard let next = try DrifterCron(expression).next(after: now, calendar: calendar) else {
                throw DrifterScheduleError.noOccurrence
            }
            following = next
        }
        return Run(schedule: self, nextRun: following, isLate: now.timeIntervalSince(nextRun) > 120)
    }

    func allowsCancellation(from caller: UUID) -> Bool {
        switch target {
        case .thisChat: return owner == caller
        case .newChat: return true
        }
    }
}

@MainActor
final class DrifterScheduleStore {
    static let didChange = Notification.Name("DrifterSchedulesDidChange")

    private let url: URL
    private let now: () -> Date
    private let calendar: () -> Calendar
    private var stored: Result<[DrifterSchedule], Error>

    init(url: URL, now: @escaping () -> Date = Date.init, calendar: @escaping () -> Calendar = { DrifterSchedule.localCalendar }) {
        self.url = url
        self.now = now
        self.calendar = calendar
        stored = Result {
            do { return try JSONDecoder().decode([DrifterSchedule].self, from: Data(contentsOf: url)) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        }
    }

    func list() throws -> [DrifterSchedule] {
        try stored.get().sorted { ($0.nextRun, $0.id) < ($1.nextRun, $1.id) }
    }

    func create(title: String, prompt: String, cron: String?, at: String?, delayMinutes: Int?,
                target: DrifterSchedule.Target, owner: UUID) throws -> DrifterSchedule {
        var schedules = try stored.get()
        let now = now()
        let (timing, nextRun) = try DrifterSchedule.Timing.resolve(
            cron: cron, at: at, delayMinutes: delayMinutes, now: now, calendar: calendar())
        var id: String
        repeat { id = String(UUID().uuidString.prefix(8)).lowercased() }
        while schedules.contains(where: { $0.id == id })
        let schedule = DrifterSchedule(id: id, title: title, prompt: prompt, timing: timing, target: target,
                                      owner: owner, createdAt: now, nextRun: nextRun)
        schedules.append(schedule)
        try save(schedules)
        return schedule
    }

    func cancel(_ id: String, from caller: UUID? = nil) throws {
        var schedules = try stored.get()
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { throw DrifterScheduleError.unknownSchedule }
        if let caller, !schedules[index].allowsCancellation(from: caller) { throw DrifterScheduleError.forbiddenCancel }
        schedules.remove(at: index)
        try save(schedules)
    }

    /// Commit each run before delivering it so a crash or relaunch cannot deliver it twice.
    func takeDue(_ id: String) throws -> DrifterSchedule.Run? {
        var schedules = try stored.get()
        let now = now()
        guard let index = schedules.firstIndex(where: { $0.id == id }),
              let run = try schedules[index].due(at: now, calendar: calendar()) else { return nil }
        if let following = run.nextRun {
            schedules[index].lastRun = now
            schedules[index].nextRun = following
        } else {
            schedules.remove(at: index)
        }
        try save(schedules)
        return run
    }

    private func save(_ schedules: [DrifterSchedule]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(schedules).write(to: url, options: .atomic)
        stored = .success(schedules)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
