import Foundation
import Testing
@testable import LogbookCore

@MainActor
@Test func repeatedCSVImportsSkipExactDuplicates() throws {
    let store = try LogbookStore(inMemory: true)
    let scene = CheckInScene(id: "reading", name: "Reading")
    try store.save([.scene(scene)])
    let csv = "scene_id,date,value,note\r\nreading,2026-11-19,1,\"Finished, and said \"\"great\"\".\r\nPage 5\"\r\n"
    let first = ImportPreview(csv: csv, kind: .checkins, library: store.library)
    #expect(first.count(.new) == 1)
    try store.save(first.changes(choices: [:]))
    let second = ImportPreview(csv: csv, kind: .checkins, library: store.library)
    #expect(second.count(.duplicate) == 1)
    #expect(try second.changes(choices: [:]).isEmpty)
    #expect(store.library.checkIns.count == 1)
    #expect(store.library.checkIns.first?.note == "Finished, and said \"great\".\r\nPage 5")
}

@Test func previewClassifiesDuplicatesConflictsAndInvalidRows() throws {
    let old = Transaction(id: "t", day: try #require(DayKey(rawValue: "2026-12-31")), minorUnits: 10,
                          currency: .jpy, paymentMethod: "Cash")
    let csv = """
        transaction_id,date,kind,amount,currency,payment_method,note
        t,2026-12-31,expense,20,JPY,credit_card,Dinner
        t,2026-12-31,expense,20,JPY,credit_card,Dinner
        t,2026-12-31,expense,10,JPY,cash,
        wrong,2026-02-30,income,2.5,JPY,cash,
        """
    let preview = ImportPreview(csv: csv, kind: .transactions, library: Library([.transaction(old)]))
    #expect(preview.count(.conflict) == 1)
    #expect(preview.count(.duplicate) == 2)
    #expect(preview.count(.invalid) == 1)
    #expect(try preview.changes(choices: [:]).isEmpty)
    let conflict = try #require(preview.conflicts.first)
    let chosen = try #require(conflict.incoming.first)
    let result = try preview.changes(choices: [conflict.id: chosen.id])
    guard case .transaction(let updated) = try #require(result.first) else {
        Issue.record("Expected an updated transaction")
        return
    }
    #expect(updated.postingMonth.rawValue == "2027-01")
    #expect(updated.paymentMethod == "Credit card")
    #expect(updated.minorUnits == 20)
}

@Test func transactionCSVRequiresNotesForNewAndChangedRows() throws {
    let day = try #require(DayKey(rawValue: "2026-11-19"))
    let blank = Transaction(id: "legacy", day: day, kind: .income, minorUnits: 100, currency: .jpy)
    let income = Transaction(id: "income", day: day, kind: .income, minorUnits: 100, currency: .jpy, note: "Salary")
    let library = Library([.transaction(blank), .transaction(income)])
    let csv = CSVKind.transactions.template + """
        blank,2026-11-19,income,100,JPY,,,,
        whitespace,2026-11-19,expense,100,JPY,Cash,"   ",false,
        income,2026-11-19,income,100,JPY,,,,
        legacy,2026-11-19,income,100,JPY,,,,
        valid,2026-11-19,expense,100,JPY,Cash,Lunch,false,
        """
    let preview = ImportPreview(csv: csv, kind: .transactions, library: library)
    #expect(preview.items.map(\.status) == [.invalid, .invalid, .invalid, .duplicate, .new])
    let changes = try preview.changes(choices: [:])
    #expect(changes.count == 1)
}

@MainActor
@Test func backupRestoresAllRecordsPreferencesAndSceneOrder() throws {
    let day = try #require(DayKey(rawValue: "2026-11-19"))
    let currency = try #require(LedgerCurrency(rawValue: "KWD"))
    let scene = CheckInScene(name: "Reading", position: 12, archived: true)
    let account = Account(name: "Savings", currency: currency, opened: day.month, color: "#8459CB")
    let records: [Record] = [
        .scene(scene), .checkIn(CheckIn(sceneID: scene.id, day: day, value: 1)),
        .account(account), .balance(Balance(accountID: account.id, month: day.month, minorUnits: 15001)),
        .transaction(Transaction(day: day, minorUnits: 1234, currency: currency,
                                 paymentMethod: "Corporate card, Tokyo", settlesNextMonth: true, category: "Conference, travel")),
        .transaction(Transaction(day: day, kind: .income, minorUnits: 8000, currency: currency))
    ]
    let preferences = Preferences(defaultCurrency: currency, timeZoneID: "Asia/Tokyo", weekStart: .sunday,
                                  cashFlowAveragePeriod: .sixMonths, greetingName: "Alex")
    let backup = try LogbookBackup(library: Library(records), preferences: preferences)
    let restored = try LogbookBackup.read(JSONEncoder().encode(backup))
    let preview = ImportPreview(backup: restored, library: Library())
    #expect(preview.count(.new) == records.count)
    #expect(preview.count(.invalid) == 0)
    #expect(preview.preferences == preferences)
    let store = try LogbookStore(inMemory: true)
    try store.save(preview.changes(choices: [:]), preferences: preview.preferences, restoringBackup: preview.isBackup)
    #expect(store.library.records == Library(records).records)
    #expect(store.preferences == preferences)
    let reimport = ImportPreview(backup: restored, library: store.library)
    #expect(reimport.count(.duplicate) == records.count)
    #expect(try reimport.changes(choices: [:]).isEmpty)
}

@Test func versionFourTransactionsRestoreUncategorizedAndReimportKeepsAssignedCategory() throws {
    let csv = """
        transaction_id,date,kind,amount,currency,payment_method,note,settles_next_month
        t,2026-12-31,expense,20,JPY,Card,,true
        """
    var backup = try LogbookBackup(library: Library(), preferences: Preferences())
    backup.version = 4
    backup.files[CSVKind.transactions.filename] = csv
    let restored = try LogbookBackup.read(JSONEncoder().encode(backup))
    let preview = ImportPreview(backup: restored, library: Library())
    let entries = try Library(preview.changes(choices: [:])).transactions
    var expense = try #require(entries.first)
    #expect(expense.category.isEmpty)
    #expect(expense.postingMonth.rawValue == "2027-01")
    expense.category = "Groceries"
    let library = Library([.transaction(expense)])
    let reimport = ImportPreview(csv: csv, kind: .transactions, library: library)
    #expect(reimport.count(.duplicate) == 1)
}

@Test func versionFiveBackupResolvesCategoryNamesIntoTransactionText() throws {
    var backup = try LogbookBackup(library: Library(), preferences: Preferences())
    backup.version = 5
    backup.files["expense_categories.csv"] = "category_id,name\ndining,\"Food, drinks\"\n"
    backup.files[CSVKind.transactions.filename] = """
        transaction_id,date,kind,amount,currency,payment_method,note,settles_next_month,category_id
        first,2026-12-31,expense,20,JPY,Card,,true,dining
        second,2026-12-31,expense,50,JPY,Cash,,false,
        """
    let restored = try LogbookBackup.read(JSONEncoder().encode(backup))
    let preview = ImportPreview(backup: restored, library: Library())
    let entries = try Library(preview.changes(choices: [:])).transactions
    #expect(preview.count(.invalid) == 0)
    #expect(entries.count == 2)
    #expect(entries.first { $0.id == "first" }?.category == "Food, drinks")
    #expect(entries.first { $0.id == "second" }?.category == "")
}

@Test func accountColorsSupportLegacyRowsAndRejectInvalidHex() throws {
    let legacy = """
        account_id,name,currency,opened_month,closed_month
        bank,Checking,JPY,2026-01,
        """
    let saved = try JSONDecoder().decode(Account.self, from: Data("""
        {"id":"bank","name":"Checking","currency":"JPY","opened":"2026-01"}
        """.utf8))
    #expect(saved.color == nil)
    var themed = saved
    themed.color = "#8459CB"
    let library = Library([.account(themed)])
    let old = ImportPreview(csv: legacy, kind: .accounts, library: library)
    #expect(old.count(.duplicate) == 1)

    let csv = """
        account_id,name,currency,opened_month,closed_month,color
        cash,Cash,JPY,2026-01,,#0f427f
        broken,Broken,JPY,2026-01,,red
        """
    let preview = ImportPreview(csv: csv, kind: .accounts, library: library)
    #expect(preview.count(.new) == 1)
    #expect(preview.count(.invalid) == 1)
    let imported = try Library(preview.changes(choices: [:]))
    #expect(imported.accounts.first?.color == "#0F427F")
    let defaults = Account.themeColors(for: [saved, Account(id: "cash", currency: .jpy, opened: saved.opened)])
    #expect(defaults["bank"] != defaults["cash"])
}

@Test func olderSceneDataAndBackupsRestoreWithAHeatmapMaximum() throws {
    let decoder = JSONDecoder()
    let saved = try decoder.decode(CheckInScene.self, from: Data("""
        {"id":"reading","name":"Reading","kind":"quantity","unit":"min","color":"#237F69",
         "thresholds":[10,25,45],"position":0,"archived":false}
        """.utf8))
    #expect(saved.maximum == 45)

    var backup = try LogbookBackup(library: Library(), preferences: Preferences())
    backup.version = 1
    backup.files["scenes.csv"] = "scene_id,name,kind,unit,color,thresholds\nreading,Reading,quantity,min,#237F69,10|25|45\n"
    backup.files["checkins.csv"] = "scene_id,date,value,note\nreading,2026-11-19,5,Earlier\n"
    let oldBackup = try LogbookBackup.read(JSONEncoder().encode(backup))
    let preview = ImportPreview(backup: oldBackup, library: Library())
    let migrated = try Library(preview.changes(choices: [:]))
    #expect(preview.count(.invalid) == 0)
    #expect(migrated.scenes == [saved])
    #expect(migrated.checkIns.first?.entryID == nil)

    let oldPreferences = try decoder.decode(Preferences.self, from: Data("""
        {"defaultCurrency":"JPY","timeZoneID":"Asia/Tokyo","weekStart":2}
        """.utf8))
    #expect(!oldPreferences.showArchivedScenes)
}

@Test func newBackupsRoundTripMultipleQuantityEntriesOnTheSameDay() throws {
    let day = try #require(DayKey(rawValue: "2026-11-19"))
    let scene = CheckInScene(id: "reading", name: "Reading", kind: .quantity, unit: "min", maximum: 45)
    let old = CheckIn(sceneID: scene.id, day: day, value: 5, note: "Legacy")
    let first = CheckIn(sceneID: scene.id, day: day, value: 10, note: "Session", entryID: UUID())
    let second = CheckIn(sceneID: scene.id, day: day, value: 10, note: "Session", entryID: UUID())
    let library = Library([.scene(scene), .checkIn(old), .checkIn(first), .checkIn(second)])
    let backup = try LogbookBackup(library: library, preferences: Preferences(showArchivedScenes: true))
    let restored = try LogbookBackup.read(JSONEncoder().encode(backup))
    let preview = ImportPreview(backup: restored, library: Library())
    let roundTrip = try Library(preview.changes(choices: [:]))
    #expect(preview.count(.new) == 4)
    #expect(preview.count(.invalid) == 0)
    #expect(preview.preferences?.showArchivedScenes == true)
    #expect(roundTrip.records == library.records)
    #expect(roundTrip.checkInDay(for: scene.id, on: day)?.total == 25)
    #expect(ImportPreview(backup: restored, library: roundTrip).count(.duplicate) == 4)
}
