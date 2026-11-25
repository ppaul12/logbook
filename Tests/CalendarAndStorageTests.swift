import CoreGraphics
import Foundation
import Testing
@testable import LogbookCore

@Test func dayIdentitySurvivesTimeZoneChangesAndDST() throws {
    let instant = try #require(ISO8601DateFormatter().date(from: "2026-03-08T07:30:00Z"))
    let west = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let east = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let recorded = DayKey(instant, in: west)
    #expect(recorded.rawValue == "2026-03-07")
    #expect(DayKey(instant, in: east).rawValue == "2026-03-08")
    #expect(recorded.adding(days: 2).rawValue == "2026-03-09")
    #expect(DayKey(rawValue: "2026-02-29") == nil)
    let roundTrip = try JSONDecoder().decode(DayKey.self, from: JSONEncoder().encode(recorded))
    #expect(roundTrip == recorded)
}

@Test func aDisplayedDateCanBeEnteredWithoutShiftingTheSavedDay() throws {
    let day = try #require(DayKey(rawValue: "2026-02-09"))
    let date = try #require(LogCalendar.parseDateLabel(day.label))
    #expect(DayKey(date) == day)
    #expect(LogCalendar.parseDateLabel(day.label + "xyz") == nil)
}

@Test func balanceMonthsFollowRegionalShortDateOrderAndPadding() throws {
    let month = try #require(MonthKey(rawValue: "2026-02"))
    #expect(LogCalendar.monthLabel(month.date, locale: Locale(identifier: "ja_JP")) == "2026/02")
    #expect(LogCalendar.monthLabel(month.date, locale: Locale(identifier: "en_US")) == "2/2026")
    #expect(LogCalendar.monthLabel(month.date, locale: Locale(identifier: "en_GB")) == "02/2026")
    #expect(LogCalendar.monthLabel(month.date, locale: Locale(identifier: "de_DE")) == "02.2026")
}

@MainActor
@Test func savedCheckInReopensAndReplacesTheSameCalendarDay() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "Logbook.store")
    let day = try #require(DayKey(rawValue: "2026-11-19"))
    let scene = CheckInScene(name: "Reading")
    do {
        let store = try LogbookStore(url: url)
        try store.save([.scene(scene), .checkIn(CheckIn(sceneID: scene.id, day: day, value: 1))])
        try store.save([.checkIn(CheckIn(sceneID: scene.id, day: day, value: 1, note: "Edited"))])
        var preferences = store.preferences
        preferences.timeZoneID = "Pacific/Honolulu"
        try store.save(preferences: preferences)
    }
    let reopened = try LogbookStore(url: url)
    #expect(reopened.library.scenes == [scene])
    #expect(reopened.library.checkIns.count == 1)
    #expect(reopened.library.checkIn(for: scene.id, on: day)?.note == "Edited")
    #expect(reopened.library.firstCheckInDay(for: scene.id) == day)
    #expect(reopened.preferences.timeZoneID == "Pacific/Honolulu")
    try reopened.save(removing: [Record.checkIn(CheckIn(sceneID: scene.id, day: day, value: 1)).key])
    #expect(reopened.library.checkIn(for: scene.id, on: day) == nil)
    #expect(reopened.library.firstCheckInDay(for: scene.id) == nil)
    #expect(reopened.library.checkInDays(for: scene.id).isEmpty)
}

@Test func checkInStatisticsKeepYesterdaysStreakAndUseThirtyCalendarDays() throws {
    let today = try #require(DayKey(rawValue: "2026-01-01"))
    let offsets = [1, 2, 3, 7, 8, 9, 10, 11, 29, 30, -1, -2, -3, -4, -5, -6]
    var library = Library(offsets.map {
        .checkIn(CheckIn(sceneID: "reading", day: today.adding(days: -$0), value: 0))
    })
    library.set(.checkIn(CheckIn(sceneID: "walking", day: today, value: 1)))

    let waiting = CheckInStatistics(days: library.checkInDays(for: "reading"), through: today)
    #expect(waiting.currentStreak == 3)
    #expect(waiting.longestStreak == 5)
    #expect(waiting.last30Days == 9)

    let entry = Record.checkIn(CheckIn(sceneID: "reading", day: today, value: 0))
    library.set(entry)
    library.set(entry)
    let recorded = CheckInStatistics(days: library.checkInDays(for: "reading"), through: today)
    #expect(recorded.currentStreak == 4)
    #expect(recorded.longestStreak == 5)
    #expect(recorded.last30Days == 10)

    let interrupted = CheckInStatistics(days: [today.adding(days: -2)], through: today)
    #expect(interrupted.currentStreak == 0)
    #expect(interrupted.longestStreak == 1)
    #expect(interrupted.last30Days == 1)
}

@MainActor
@Test func quantityEntriesPersistIndependentlyAndSceneRemovalStaysScoped() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "Logbook.store")
    let day = try #require(DayKey(rawValue: "2026-11-19"))
    let scene = CheckInScene(id: "reading", name: "Reading", kind: .quantity, unit: "min", maximum: 30)
    let archived = CheckInScene(id: "walking", name: "Walking", archived: true)
    let legacy = CheckIn(sceneID: scene.id, day: day, value: 12, note: "Earlier")
    let newer = CheckIn(sceneID: scene.id, day: day, value: 25, note: "Later", entryID: UUID())
    let walking = CheckIn(sceneID: archived.id, day: day, value: 1)
    do {
        let store = try LogbookStore(url: url)
        try store.save([.scene(scene), .scene(archived), .checkIn(legacy), .checkIn(newer), .checkIn(walking)])
        #expect(store.library.visibleScenes(showArchived: store.preferences.showArchivedScenes) == [scene])
        var preferences = store.preferences
        preferences.showArchivedScenes = true
        try store.save(preferences: preferences)
    }

    let store = try LogbookStore(url: url)
    #expect(store.preferences.showArchivedScenes)
    #expect(store.library.visibleScenes(showArchived: store.preferences.showArchivedScenes) == [scene, archived])
    let summary = try #require(store.library.checkInDay(for: scene.id, on: day))
    #expect(summary.entries == [legacy, newer])
    #expect(summary.total == 37)
    #expect(store.library.checkInDays(for: scene.id) == [day])
    #expect(scene.intensity(15) == 0.62)
    #expect(scene.intensity(summary.total) == 1)

    var edited = newer
    edited.value = 6
    try store.save([.checkIn(edited)])
    #expect(store.library.checkInDay(for: scene.id, on: day)?.total == 18)
    try store.save(removing: [Record.checkIn(legacy).key])
    #expect(store.library.checkInDay(for: scene.id, on: day)?.entries == [edited])

    try store.resetScene(scene.id)
    #expect(store.library.scenes.contains(scene))
    #expect(store.library.checkInDays(for: scene.id).isEmpty)
    #expect(store.library.checkInDay(for: archived.id, on: day)?.entries == [walking])
    try store.save([.checkIn(newer)])
    try store.deleteScene(scene.id)
    #expect(store.library.scenes == [archived])
    #expect(store.library.checkIns == [walking])
    #expect(throws: LogbookError.self) { try store.save([.checkIn(newer)]) }
}

@Test func heatmapHistoryKeepsWeekIdentifiersWhenOlderDatesAreAdded() throws {
    let today = try #require(DayKey(rawValue: "2026-11-19"))
    let older = try #require(DayKey(rawValue: "1998-12-31"))
    let recent = HeatmapHistory(through: today, earliest: nil, weekStart: .monday)
    let extended = HeatmapHistory(through: today, earliest: older, weekStart: .monday)
    #expect(recent.weeks.count == 52)
    #expect(extended.weeks.upperBound == recent.weeks.upperBound)
    #expect(extended.weeks.lowerBound == extended.week(containing: older))
    #expect(extended.days(in: extended.weeks.lowerBound).compactMap { $0 }.first?.rawValue == "1998-12-28")
    #expect(extended.days(in: extended.weeks.lowerBound).contains(older))
    #expect(extended.days(in: extended.weeks.upperBound).contains(today))

    let firstDay = DayKey(DayKey.dateBounds.lowerBound)
    let earliest = HeatmapHistory(through: today, earliest: firstDay, weekStart: .wednesday)
    #expect(earliest.days(in: earliest.weeks.lowerBound).compactMap { $0 }.first == firstDay)
}

@Test func reusableHeatmapDateFormatterMatchesTheDatePicker() throws {
    let today = try #require(DayKey(rawValue: "2026-01-02"))
    let history = HeatmapHistory(through: today, earliest: nil, weekStart: .monday)
    let formatter = LogCalendar.dayFormatter()
    let days = history.days(in: history.weeks.upperBound).compactMap { $0 }
    #expect(days.map { formatter.string(from: $0.date) } == days.map(\.label))
}

@Test func heatmapGridCanDrawAndHitTestAWindowOfLongHistory() throws {
    let today = try #require(DayKey(rawValue: "2026-11-26"))
    let day = try #require(DayKey(rawValue: "0001-01-01"))
    let layout = HeatmapGridLayout.history(HeatmapHistory(through: today, earliest: day, weekStart: .monday))
    #expect(layout.columnCount > 100_000)
    #expect(layout.height == 151)
    let first = try #require(layout.position(of: day))
    #expect(first.column == 0)
    let rect = layout.rect(for: first)
    #expect(layout.position(at: CGPoint(x: rect.midX, y: rect.midY)) == first)
    #expect(layout.position(at: CGPoint(x: rect.maxX + 1, y: rect.midY)) == nil)
    #expect(layout.position(at: CGPoint(x: rect.midX, y: rect.minY - 1)) == nil)
    let recent = try #require(layout.position(of: today))
    let viewport = CGRect(x: layout.width - 780, y: 0, width: 780, height: layout.height)
    #expect(layout.visibleColumns(in: viewport).count <= 47)
    #expect(layout.visibleColumns(in: viewport).contains(recent.column))
    #expect(layout.days(in: recent.column)[recent.row] == today)
}

@Test func compactHeatmapUsesTheSameDatesAsItsFourWeekWindow() throws {
    let today = try #require(DayKey(rawValue: "2026-11-26"))
    let window = HeatmapWindow(endingOn: today, count: 4)
    let layout = HeatmapGridLayout.recent(window)
    #expect(layout.width == 315)
    #expect(layout.height == 9)
    for (column, week) in window.weeks.enumerated() {
        for (row, day) in week.enumerated() {
            let position = HeatmapGridLayout.Position(column: column, row: row)
            let rect = layout.rect(for: position)
            #expect(layout.position(at: CGPoint(x: rect.midX, y: rect.midY)) == position)
            #expect(layout.days(in: column)[row] == day)
        }
    }
    #expect(layout.position(at: CGPoint(x: 77, y: 4)) == nil)
}

@Test func sceneLinksPreserveSceneIdentifiersAndHeatmapsRespectWeekStart() throws {
    let id = "reading / 記録 & friends"
    let url = try #require(LogbookLinks.sceneURL(id))
    #expect(LogbookLinks.sceneID(from: url) == id)
    #expect(LogbookLinks.sceneID(from: URL(string: "https://scene?id=reading")!) == nil)

    let day = try #require(DayKey(rawValue: "2026-11-19"))
    let monday = HeatmapHistory(through: day, earliest: nil, weekStart: .monday)
    let sunday = HeatmapHistory(through: day, earliest: nil, weekStart: .sunday)
    let mondayWeek = monday.days(in: monday.weeks.upperBound)
    let sundayWeek = sunday.days(in: sunday.weeks.upperBound)
    #expect(mondayWeek[0]?.rawValue == "2026-11-16")
    #expect(sundayWeek[0]?.rawValue == "2026-11-15")
    #expect(mondayWeek.contains(day))
}

@Test func recentHeatmapShowsFourContinuousWeeksEndingToday() throws {
    let today = try #require(DayKey(rawValue: "2027-01-05"))
    let window = HeatmapWindow(endingOn: today, count: 4)
    let days = window.weeks.flatMap { $0 }

    #expect(window.weeks.map(\.count) == [7, 7, 7, 7])
    #expect(days.first?.rawValue == "2026-12-09")
    #expect(days.last == today)
    #expect(days.dropFirst().elementsEqual(days.dropLast().map { $0.adding(days: 1) }))
}
