import Foundation
import Testing
@testable import LogbookCore

@Test(arguments: [
    ("2026-11-22T04:59:00+09:00", "Good evening", "Wishing you a quiet, restful evening."),
    ("2026-11-22T05:00:00+09:00", "Good morning", "Here’s to a good day ahead."),
    ("2026-11-22T11:59:00+09:00", "Good morning", "Here’s to a good day ahead."),
    ("2026-11-22T12:00:00+09:00", "Good afternoon", "Hope there’s a bright spot in your afternoon."),
    ("2026-11-22T17:59:00+09:00", "Good afternoon", "Hope there’s a bright spot in your afternoon."),
    ("2026-11-22T18:00:00+09:00", "Good evening", "Wishing you a quiet, restful evening.")
])
func welcomeGreetingChangesAtLocalTimeBoundaries(sample: (String, String, String)) throws {
    let (timestamp, salutation, message) = sample
    let instant = try #require(ISO8601DateFormatter().date(from: timestamp))
    let zone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let greeting = WelcomeGreeting(date: instant, displayName: "  Alex Chen\n", calendar: LogCalendar.gregorian(in: zone))

    #expect(greeting.title == "\(salutation), Alex Chen!")
    #expect(greeting.message == message)
}

@Test(arguments: ["", " \n\t"])
func welcomeGreetingKeepsTheLocalMessageWithoutAName(displayName: String) throws {
    let instant = try #require(ISO8601DateFormatter().date(from: "2026-11-22T03:00:00Z"))
    let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let inTokyo = WelcomeGreeting(date: instant, displayName: displayName, calendar: LogCalendar.gregorian(in: tokyo))
    let inUTC = WelcomeGreeting(date: instant, displayName: displayName, calendar: LogCalendar.gregorian())

    #expect(inTokyo.title == "Hello there!")
    #expect(inTokyo.message == "Hope there’s a bright spot in your afternoon.")
    #expect(inUTC.title == "Hello there!")
    #expect(inUTC.message == "Wishing you a quiet, restful evening.")
}

@Test func earlierPreferencesStartWithNoGreetingName() throws {
    let data = Data(#"{"defaultCurrency":"JPY","timeZoneID":"Asia/Tokyo","weekStart":2}"#.utf8)
    let preferences = try JSONDecoder().decode(Preferences.self, from: data)

    #expect(preferences.greetingName.isEmpty)
}

@MainActor
@Test func greetingNameCanBeSavedAndClearedAcrossLaunches() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "Logbook.store")

    do {
        let store = try LogbookStore(url: url)
        var preferences = store.preferences
        #expect(preferences.greetingName.isEmpty)
        preferences.greetingName = "小澎"
        try store.save(preferences: preferences)
    }
    do {
        let store = try LogbookStore(url: url)
        var preferences = store.preferences
        #expect(preferences.greetingName == "小澎")
        preferences.greetingName = ""
        try store.save(preferences: preferences)
    }
    let store = try LogbookStore(url: url)
    #expect(store.preferences.greetingName.isEmpty)
}
