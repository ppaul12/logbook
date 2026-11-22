import Foundation

enum LogCalendar {
    static let utc = TimeZone(secondsFromGMT: 0)!

    static func gregorian(in zone: TimeZone = utc) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    // Day and month keys use UTC for display so their saved dates never shift.
    static var displayCalendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = utc
        return calendar
    }

    // A balance period remains a Gregorian month, displayed in the system's regional format.
    static var displayMonthCalendar: Calendar {
        var calendar = gregorian()
        calendar.locale = .autoupdatingCurrent
        return calendar
    }

    static func label(_ date: Date, template: String, calendar: Calendar = displayCalendar) -> String {
        let formatter = displayFormatter(calendar: calendar)
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private static func dayFormatter() -> DateFormatter {
        let formatter = displayFormatter()
        formatter.dateStyle = .short
        formatter.isLenient = false
        return formatter
    }

    static func dateLabel(_ date: Date) -> String { dayFormatter().string(from: date) }

    static func monthLabel(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        var calendar = displayMonthCalendar
        calendar.locale = locale
        let formatter = displayFormatter(calendar: calendar, locale: locale)
        formatter.dateStyle = .short
        let pattern = formatter.dateFormat ?? ""

        // Keep the system's order, separators and month padding when its short date is numeric.
        // Use a full year so a bookkeeping period is unambiguous.
        if let fields = pattern.wholeMatch(of: #/(y+|M+|L+|d+)([^A-Za-z']+)(y+|M+|L+|d+)([^A-Za-z']+)(y+|M+|L+|d+)/#) {
            let tokens = [fields.1, fields.3, fields.5]
            let kept = tokens.indices.filter { tokens[$0].first != "d" }
            if kept.count == 2, tokens.contains(where: { $0.first == "y" }) {
                let separator = kept[0] == 0 ? fields.2 : fields.4
                let parts = kept.map { tokens[$0].first == "y" ? "y" : String(tokens[$0]) }
                formatter.dateFormat = parts.joined(separator: String(separator))
                return formatter.string(from: date)
            }
        }
        formatter.setLocalizedDateFormatFromTemplate("yM")
        return formatter.string(from: date)
    }

    static func parseDateLabel(_ text: String) -> Date? {
        dayFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func displayFormatter(calendar: Calendar = displayCalendar, locale: Locale = .autoupdatingCurrent) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = utc
        return formatter
    }

    static func parse(_ key: String, lengths: [Int]) -> [Int]? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.utf8.count) == lengths,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        return parts.compactMap { Int($0) }
    }
}

struct DayKey: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    static let dateBounds = Self(rawValue: "0001-01-01")!.date...Self(rawValue: "9999-12-31")!.date

    let rawValue: String

    init?(rawValue: String) {
        guard let parts = LogCalendar.parse(rawValue, lengths: [4, 2, 2]),
              parts[0] > 0,
              let date = LogCalendar.gregorian().date(from: DateComponents(
                year: parts[0], month: parts[1], day: parts[2], hour: 12
              )),
              Self(date).rawValue == rawValue else { return nil }
        self.rawValue = rawValue
    }

    init(_ instant: Date, in zone: TimeZone = LogCalendar.utc) {
        let parts = LogCalendar.gregorian(in: zone).dateComponents([.year, .month, .day], from: instant)
        rawValue = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    var date: Date {
        let parts = rawValue.split(separator: "-").compactMap { Int($0) }
        return LogCalendar.gregorian().date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: 12
        ))!
    }

    var month: MonthKey { MonthKey(rawValue: String(rawValue.prefix(7)))! }
    var label: String { LogCalendar.dateLabel(date) }

    func adding(days: Int) -> Self {
        Self(LogCalendar.gregorian().date(byAdding: .day, value: days, to: date)!)
    }

    func startOfWeek(_ start: WeekStart) -> Self {
        let weekday = LogCalendar.gregorian().component(.weekday, from: date)
        return adding(days: -((weekday - start.rawValue + 7) % 7))
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct MonthKey: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard let parts = LogCalendar.parse(rawValue, lengths: [4, 2]),
              parts[0] > 0, (1...12).contains(parts[1]) else { return nil }
        self.rawValue = rawValue
    }

    init(_ date: Date, in zone: TimeZone = LogCalendar.utc) {
        self = DayKey(date, in: zone).month
    }

    var date: Date { DayKey(rawValue: rawValue + "-01")!.date }
    var label: String { LogCalendar.monthLabel(date) }

    var index: Int {
        let parts = rawValue.split(separator: "-").compactMap { Int($0) }
        return parts[0] * 12 + parts[1] - 1
    }

    init(index: Int) {
        rawValue = String(format: "%04d-%02d", index / 12, index % 12 + 1)
    }

    func adding(months: Int) -> Self { Self(index: index + months) }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum WeekStart: Int, Codable, CaseIterable, Sendable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    var label: String {
        LogCalendar.displayCalendar.standaloneWeekdaySymbols[rawValue - 1]
    }
}
