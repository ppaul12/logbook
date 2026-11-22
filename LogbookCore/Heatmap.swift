import Foundation

struct HeatmapWindow {
    let weeks: [[DayKey]]

    init(endingOn day: DayKey, count: Int) {
        let start = day.adding(days: 1 - 7 * count)
        weeks = (0..<count).map { week in
            (0..<7).map { start.adding(days: week * 7 + $0) }
        }
    }
}

struct HeatmapHistory {
    let weeks: ClosedRange<Int>
    private let referenceWeek: Date

    init(through today: DayKey, earliest: DayKey?, weekStart: WeekStart) {
        let referenceWeek = DayKey(Date(timeIntervalSinceReferenceDate: 0)).startOfWeek(weekStart).date
        self.referenceWeek = referenceWeek

        let last = Self.week(containing: today, from: referenceWeek)
        let earliest = earliest.map { Self.week(containing: $0, from: referenceWeek) }
        weeks = min(last - 51, earliest ?? last)...last
    }

    func week(containing day: DayKey) -> Int {
        Self.week(containing: day, from: referenceWeek)
    }

    func days(in week: Int) -> [DayKey?] {
        let calendar = LogCalendar.gregorian()
        return (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: week * 7 + offset, to: referenceWeek)!
            return DayKey.dateBounds.contains(date) ? DayKey(date) : nil
        }
    }

    private static func week(containing day: DayKey, from referenceWeek: Date) -> Int {
        let days = LogCalendar.gregorian().dateComponents([.day], from: referenceWeek, to: day.date).day!
        return Int(floor(Double(days) / 7))
    }
}

struct CheckInStatistics {
    let currentStreak: Int
    let longestStreak: Int
    let last30Days: Int

    init(days: Set<DayKey>, through today: DayKey) {
        let calendar = LogCalendar.gregorian()
        let cutoff = calendar.date(byAdding: .day, value: -29, to: today.date)!
        let firstRecentDay = DayKey(max(cutoff, DayKey.dateBounds.lowerBound))
        var previousDay: DayKey?
        var streak = 0
        var longest = 0
        var recent = 0

        for day in days.lazy.filter({ $0 <= today }).sorted() {
            streak = previousDay?.adding(days: 1) == day ? streak + 1 : 1
            longest = max(longest, streak)
            if day >= firstRecentDay { recent += 1 }
            previousDay = day
        }

        currentStreak = previousDay == today || previousDay?.adding(days: 1) == today ? streak : 0
        longestStreak = longest
        last30Days = recent
    }
}
