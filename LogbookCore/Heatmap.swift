import CoreGraphics
import Foundation

struct HeatmapWindow: Equatable {
    let weeks: [[DayKey]]

    init(endingOn day: DayKey, count: Int) {
        let start = day.adding(days: 1 - 7 * count)
        weeks = (0..<count).map { week in
            (0..<7).map { start.adding(days: week * 7 + $0) }
        }
    }
}

struct HeatmapHistory: Equatable {
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

enum HeatmapGridLayout: Equatable {
    case history(HeatmapHistory)
    case recent(HeatmapWindow)

    struct Position: Hashable {
        let column: Int
        let row: Int
    }

    var showsMonths: Bool {
        if case .history = self { return true }
        return false
    }

    var columnCount: Int {
        switch self {
        case .history(let history): history.weeks.count
        case .recent(let window): window.weeks.count
        }
    }

    var cellSize: CGFloat { showsMonths ? 14 : 9 }
    var cellGap: CGFloat { showsMonths ? 3 : 2 }
    var firstCellY: CGFloat { showsMonths ? 20 + cellGap : 0 }
    var height: CGFloat { showsMonths ? firstCellY + 7 * cellSize + 6 * cellGap + 12 : cellSize }

    private var leadingInset: CGFloat { showsMonths ? 1 : 0 }
    private var columnWidth: CGFloat { showsMonths ? cellSize : 7 * cellSize + 6 * cellGap }
    private var columnStride: CGFloat { columnWidth + (showsMonths ? cellGap : 5) }

    var width: CGFloat {
        guard columnCount > 0 else { return 0 }
        return columnStart(columnCount - 1) + columnWidth + (showsMonths ? cellSize : 0)
    }

    func columnStart(_ column: Int) -> CGFloat {
        leadingInset + CGFloat(column) * columnStride
    }

    func days(in column: Int) -> [DayKey?] {
        switch self {
        case .history(let history): history.days(in: history.weeks.lowerBound + column)
        case .recent(let window): window.weeks[column].map(Optional.some)
        }
    }

    func position(of day: DayKey) -> Position? {
        switch self {
        case .history(let history):
            let week = history.week(containing: day)
            guard history.weeks.contains(week), let row = history.days(in: week).firstIndex(of: day) else { return nil }
            return Position(column: week - history.weeks.lowerBound, row: row)
        case .recent(let window):
            for (column, week) in window.weeks.enumerated() {
                if let row = week.firstIndex(of: day) { return Position(column: column, row: row) }
            }
            return nil
        }
    }

    func rect(for position: Position) -> CGRect {
        let start = columnStart(position.column)
        let offset = CGFloat(position.row) * (cellSize + cellGap)
        return CGRect(x: showsMonths ? start : start + offset, y: showsMonths ? firstCellY + offset : 0,
                      width: cellSize, height: cellSize)
    }

    func position(at point: CGPoint) -> Position? {
        guard point.x >= leadingInset, point.x < width, point.y >= firstCellY, point.y < height else { return nil }
        let column = Int((point.x - leadingInset) / columnStride)
        guard column < columnCount else { return nil }
        let rowOffset = showsMonths ? point.y - firstCellY : point.x - columnStart(column)
        let row = Int(rowOffset / (cellSize + cellGap))
        let position = Position(column: column, row: row)
        return row < 7 && rect(for: position).contains(point) ? position : nil
    }

    func visibleColumns(in rect: CGRect) -> Range<Int> {
        guard rect.width > 0, rect.maxX > leadingInset, rect.minX < width else { return 0..<0 }
        let start = max(0, Int(floor((max(leadingInset, rect.minX) - leadingInset) / columnStride)))
        let end = min(columnCount, Int(ceil((min(width, rect.maxX) - leadingInset) / columnStride)))
        return min(start, end)..<end
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
