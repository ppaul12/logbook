import Foundation
import Testing
@testable import LogbookCore

@Test func olderPreferencesDefaultToTwelveMonthsForCashFlowAverages() throws {
    let old = Data("""
        {"defaultCurrency":"JPY","timeZoneID":"Asia/Tokyo","weekStart":2}
        """.utf8)
    let preferences = try JSONDecoder().decode(Preferences.self, from: old)
    let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
    #expect(encoded["cashFlowAveragePeriod"] as? Int == 12)
}

@MainActor
@Test func savingTransactionsRejectsBlankNotes() throws {
    let store = try LogbookStore(inMemory: true)
    let day = try #require(DayKey(rawValue: "2026-11-19"))
    let blank = Transaction(day: day, minorUnits: 100, currency: .jpy, note: " \n\t")
    #expect(throws: LogbookError.self) { try store.save([.transaction(blank)]) }
    #expect(store.library.transactions.isEmpty)

    var expense = blank
    expense.note = "Lunch\nwith a friend"
    try store.save([.transaction(expense)])
    var edited = expense
    edited.note = ""
    #expect(throws: LogbookError.self) { try store.save([.transaction(edited)]) }
    #expect(store.library.transactions.first?.note == "Lunch\nwith a friend")
}

@Test func onlyExpensesMarkedForNextMonthRollIntoJanuary() throws {
    let day = try #require(DayKey(rawValue: "2026-12-31"))
    var expense = Transaction(day: day, kind: .expense, minorUnits: 1200, currency: .jpy,
                              paymentMethod: "Store card", settlesNextMonth: true)
    #expect(expense.postingMonth.rawValue == "2027-01")
    expense.paymentMethod = "Credit card"
    expense.settlesNextMonth = false
    #expect(expense.postingMonth == day.month)
    expense.settlesNextMonth = true
    expense.kind = .income
    #expect(expense.postingMonth == day.month)
    expense.kind = .expense
    expense.day = day.adding(days: 1)
    #expect(expense.postingMonth.rawValue == "2027-02")
}

@Test func storedTransactionsRetainLegacyPostingMonths() throws {
    let decoder = JSONDecoder()
    let expense = try decoder.decode(Transaction.self, from: Data("""
        {"id":"expense","day":"2026-12-31","kind":"expense","minorUnits":100,"currency":"JPY",
         "paymentMethod":"credit_card","note":""}
        """.utf8))
    let income = try decoder.decode(Transaction.self, from: Data("""
        {"id":"income","day":"2026-12-31","kind":"income","minorUnits":100,"currency":"JPY",
         "paymentMethod":"bank_transfer","note":""}
        """.utf8))
    #expect(expense.paymentMethod == "Credit card")
    #expect(expense.category.isEmpty)
    #expect(expense.settlesNextMonth)
    #expect(expense.postingMonth.rawValue == "2027-01")
    #expect(income.paymentMethod.isEmpty)
    #expect(!income.settlesNextMonth)
    #expect(income.postingMonth == income.day.month)

    var edited = expense
    edited.paymentMethod = "credit_card"
    edited.settlesNextMonth = false
    #expect(try decoder.decode(Transaction.self, from: JSONEncoder().encode(edited)) == edited)
}

@MainActor
@Test func legacyExpenseCategoriesBecomeIndependentTextWhenTheStoreReopens() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "Logbook.store")
    let day = try #require(DayKey(rawValue: "2026-11-19"))
    let category = ExpenseCategory(id: "dining", name: "Eating out")
    let first = Transaction(day: day, minorUnits: 100, currency: .jpy, note: "Lunch", categoryID: category.id)
    let second = Transaction(day: day.adding(days: 2), minorUnits: 20, currency: .cny,
                             note: "Dinner", categoryID: category.id)
    let uncategorized = Transaction(day: day, minorUnits: 40, currency: .jpy, note: "Snacks")

    do {
        let store = try LogbookStore(url: url)
        try store.save([.transaction(first), .transaction(second), .expenseCategory(category), .transaction(uncategorized)])
    }
    do {
        let store = try LogbookStore(url: url)
        var edited = try #require(store.library.transactions.first { $0.id == first.id })
        #expect(edited.category == "Eating out")
        #expect(edited.categoryID == nil)
        edited.category = "Lunch"
        try store.save([.transaction(edited)])
    }
    let store = try LogbookStore(url: url)
    let categories = Dictionary(uniqueKeysWithValues: store.library.transactions.map { ($0.id, $0.category) })
    #expect(categories == [first.id: "Lunch", second.id: "Eating out", uncategorized.id: ""])
}

@Test func currencyIsolationAndMinorUnits() throws {
    let day = try #require(DayKey(rawValue: "2026-11-19"))
    #expect(LedgerCurrency.jpy.parse("12.50") == nil)
    #expect(LedgerCurrency.cny.parse("12.50") == 1250)
    #expect(LedgerCurrency.cny.parse("12.501") == nil)
    #expect(LedgerCurrency.cny.parse("-92233720368547758.08") == Int64.min)
    let yen = Transaction(day: day, kind: .income, minorUnits: 12, currency: .jpy)
    let yuan = Transaction(day: day, minorUnits: 1250, currency: .cny)
    let yenAccount = Account(name: "JPY", currency: .jpy, opened: day.month)
    let yuanAccount = Account(name: "CNY", currency: .cny, opened: day.month)
    let library = Library([
        .transaction(yen), .transaction(yuan), .account(yenAccount), .account(yuanAccount),
        .balance(Balance(accountID: yenAccount.id, month: day.month, minorUnits: 50)),
        .balance(Balance(accountID: yuanAccount.id, month: day.month, minorUnits: 123))
    ])
    #expect(CashFlowReport(library: library, currency: .jpy).month(day.month).net == 12)
    #expect(CashFlowReport(library: library, currency: .cny).month(day.month).net == -1250)
    #expect(BalanceReport(library: library, currency: .jpy).month(day.month).total == 50)
    #expect(BalanceReport(library: library, currency: .cny).month(day.month).total == 123)
}

@Test func cashFlowMetricsKeepExpenseBarsNegativeAndFilterMonthlyTransactions() throws {
    let day = try #require(DayKey(rawValue: "2026-11-19"))
    let income = Transaction(day: day, kind: .income, minorUnits: 80, currency: .jpy)
    let expense = Transaction(day: day, minorUnits: 120, currency: .jpy)
    let month = CashFlowMonth(entries: [income, expense])

    #expect(CashFlowMetric.netIncome.amount(in: month) == -40)
    #expect(CashFlowMetric.income.amount(in: month) == 80)
    #expect(CashFlowMetric.expense.amount(in: month) == -120)
    #expect(CashFlowMetric.netIncome.entries(in: month) == [income, expense])
    #expect(CashFlowMetric.income.entries(in: month) == [income])
    #expect(CashFlowMetric.expense.entries(in: month) == [expense])
}

@Test func cashFlowMonthSelectionCoversCurrentMonthAndPostingHistoryForItsCurrency() throws {
    let day = try #require(DayKey(rawValue: "2026-11-19"))
    let prior = try #require(DayKey(rawValue: "2026-07-02"))
    let unrelated = try #require(DayKey(rawValue: "2025-01-01"))
    let library = Library([
        .transaction(Transaction(day: prior, minorUnits: 120, currency: .jpy)),
        .transaction(Transaction(day: day, minorUnits: 100, currency: .jpy, settlesNextMonth: true)),
        .transaction(Transaction(day: unrelated, minorUnits: 20, currency: .cny))
    ])
    let report = CashFlowReport(library: library, currency: .jpy)
    #expect(report.history(through: day.month) == prior.month...day.month.adding(months: 1))
    #expect(CashFlowReport(library: Library(), currency: .jpy).history(through: day.month) == day.month...day.month)
}

@Test func cashFlowAveragesUseCompleteMonthsBeforeSelectionAndCountGapsAsZero() throws {
    let january = try #require(DayKey(rawValue: "2025-01-01"))
    let june = try #require(DayKey(rawValue: "2026-06-01"))
    let august = try #require(DayKey(rawValue: "2026-08-01"))
    let september = try #require(DayKey(rawValue: "2026-09-30"))
    let october = try #require(DayKey(rawValue: "2026-10-01"))
    let november = try #require(DayKey(rawValue: "2026-11-19"))
    let december = november.month.adding(months: 1)
    let library = Library([
        .transaction(Transaction(day: january, kind: .income, minorUnits: 1950, currency: .jpy)),
        .transaction(Transaction(day: june, kind: .income, minorUnits: 100, currency: .jpy)),
        .transaction(Transaction(day: august, kind: .income, minorUnits: 90, currency: .jpy)),
        .transaction(Transaction(day: september, minorUnits: 30, currency: .jpy, settlesNextMonth: true)),
        .transaction(Transaction(day: october, kind: .income, minorUnits: 60, currency: .jpy)),
        .transaction(Transaction(day: november, kind: .income, minorUnits: 5000, currency: .jpy)),
        .transaction(Transaction(day: november, minorUnits: 7000, currency: .jpy, settlesNextMonth: true)),
        .transaction(Transaction(day: september, kind: .income, minorUnits: 400, currency: .cny))
    ])
    let report = CashFlowReport(library: library, currency: .jpy)
    let average = try #require(report.average(before: november.month, current: november.month, period: .threeMonths))
    #expect(average.months == august.month...october.month)
    #expect(average.income == 50)
    #expect(average.expenses == 10)
    #expect(average.net == 40)

    let historical = try #require(report.average(before: september.month, current: november.month, period: .threeMonths))
    #expect(historical.months == june.month...august.month)
    #expect(historical.expenses == 0)

    let future = try #require(report.average(before: december, current: november.month, period: .threeMonths))
    #expect(future.months == average.months)
    #expect(future.income == 50)
    #expect(future.expenses == 10)

    let all = try #require(report.average(before: november.month, current: november.month, period: .allHistory))
    #expect(all.months == january.month...october.month)
    #expect(all.income == 100)

    let yuan = CashFlowReport(library: library, currency: .cny)
    let short = try #require(yuan.average(before: november.month, current: november.month, period: .twelveMonths))
    #expect(short.months == september.month...october.month)
    #expect(short.income == 200)
    #expect(short.expenses == 0)
    #expect(yuan.average(before: september.month, current: november.month, period: .allHistory) == nil)
}

@Test func cashFlowAverageNetPreservesNegativeBalances() throws {
    let month = try #require(MonthKey(rawValue: "2026-10"))
    let average = CashFlowMonthlyAverage(months: month...month, income: 10_000, expenses: 30_000)
    #expect(CashFlowMetric.netIncome.amount(in: average) == -20_000)
    #expect(CashFlowMetric.income.amount(in: average) == 10_000)
    #expect(CashFlowMetric.expense.amount(in: average) == -30_000)
}

@Test func netIncomeProgressDistinguishesProfitAndLossAcrossTheZeroLine() {
    let loss = CashFlowAverageProgress(metric: .netIncome, amount: -1_000, average: 2_000)
    #expect(loss.ratio == -0.5)
    #expect(loss.zero == 0.5)
    #expect(loss.fillEnd < loss.zero)
    #expect((loss.averageMarker ?? 0) > loss.zero)

    let profit = CashFlowAverageProgress(metric: .netIncome, amount: 1_000, average: -2_000)
    #expect(profit.ratio == 0.5)
    #expect(profit.fillEnd > profit.zero)
    #expect((profit.averageMarker ?? 1) < profit.zero)
}

@Test func cashFlowProgressCapsTheFillAndPreservesTheOrdinaryExpenseScale() {
    let loss = CashFlowAverageProgress(metric: .netIncome, amount: -6_000, average: -2_000)
    #expect(loss.ratio == -3)
    #expect(loss.fillEnd == 0)

    let breakEven = CashFlowAverageProgress(metric: .netIncome, amount: 0, average: -2_000)
    #expect(breakEven.ratio == 0)
    #expect(breakEven.fillEnd == breakEven.zero)

    let noBaseline = CashFlowAverageProgress(metric: .netIncome, amount: 1_000, average: 0)
    #expect(noBaseline.ratio == nil)
    #expect(noBaseline.averageMarker == nil)
    #expect(noBaseline.fillEnd == noBaseline.zero)

    let expense = CashFlowAverageProgress(metric: .expense, amount: -1_000, average: -2_000)
    #expect(expense.ratio == 0.5)
    #expect(expense.zero == 0)
    #expect(expense.fillEnd == 1.0 / 3.0)
    #expect(expense.averageMarker == 2.0 / 3.0)
}

@Test func missingSnapshotCreatesAGapAndZeroIsValid() throws {
    let november = try #require(MonthKey(rawValue: "2026-11"))
    let december = november.adding(months: 1)
    let a = Account(name: "Checking", currency: .jpy, opened: november)
    let b = Account(name: "Savings", currency: .jpy, opened: november, closed: november)
    let zero = Balance(accountID: a.id, month: november, minorUnits: 0)
    var library = Library([.account(a), .account(b), .balance(zero)])
    var report = BalanceReport(library: library, currency: .jpy)
    #expect(report.month(november).total == nil)
    #expect(report.month(november).subtotal == 0)
    #expect(report.month(november).missing.map(\.id) == [b.id])
    #expect(BalanceReport(library: library, currency: .jpy, accountID: a.id).month(november).total == 0)
    library.set(.balance(Balance(accountID: b.id, month: november, minorUnits: 410)))
    report = BalanceReport(library: library, currency: .jpy)
    #expect(report.month(november).total == 410)
    #expect(report.month(december).missing.map(\.id) == [a.id])
}

@Test func additionalCurrenciesKeepTheirPrecisionAndEncodeAsCodes() throws {
    let usd = try #require(LedgerCurrency(rawValue: "USD"))
    let krw = try #require(LedgerCurrency(rawValue: "KRW"))
    let kwd = try #require(LedgerCurrency(rawValue: "KWD"))
    #expect(LedgerCurrency.available.contains(kwd))
    #expect(LedgerCurrency(rawValue: "ZZZ") == nil)
    #expect(usd.parse("12.50") == 1250)
    #expect(krw.parse("12.5") == nil)
    #expect(kwd.parse("12.345") == 12345)
    #expect(kwd.parse("12.3456") == nil)
    #expect(kwd.plain(12345) == "12.345")
    #expect(String(decoding: try JSONEncoder().encode(kwd), as: UTF8.self) == "\"KWD\"")
    #expect(try JSONDecoder().decode(LedgerCurrency.self, from: Data("\"JPY\"".utf8)) == .jpy)
}

@Test func balanceHistoryIncludesOldSnapshotsAndMonthsAvailableForBackfill() throws {
    let opening = try #require(MonthKey(rawValue: "2022-01"))
    let closing = try #require(MonthKey(rawValue: "2024-01"))
    let current = try #require(MonthKey(rawValue: "2026-11"))
    let old = Account(name: "Closed", currency: .jpy, opened: opening, closed: closing)
    let active = Account(name: "Open", currency: .jpy, opened: closing)
    let library = Library([
        .account(old), .account(active), .balance(Balance(accountID: old.id, month: opening, minorUnits: 0))
    ])
    let all = BalanceReport(library: library, currency: .jpy)
    #expect(all.history(through: current) == opening...current)
    #expect(all.recordedMonths == [opening])
    let closed = BalanceReport(library: library, currency: .jpy, accountID: old.id)
    #expect(closed.history(through: current) == opening...closing)
}

@Test func monthlyChangeUsesRecordedSubtotalsAndHistoryKeepsEverySnapshot() throws {
    let january = try #require(MonthKey(rawValue: "2026-01"))
    let february = january.adding(months: 1)
    let march = january.adding(months: 2)
    let april = january.adding(months: 3)
    let checking = Account(name: "Checking", currency: .jpy, opened: january)
    let savings = Account(name: "Savings", currency: .jpy, opened: january)
    let first = Balance(accountID: checking.id, month: january, minorUnits: 40)
    let second = Balance(accountID: checking.id, month: february, minorUnits: 0)
    let fourth = Balance(accountID: checking.id, month: april, minorUnits: -10)
    let library = Library([
        .account(checking), .account(savings), .balance(first), .balance(second), .balance(fourth),
        .balance(Balance(accountID: savings.id, month: january, minorUnits: 10))
    ])
    let report = BalanceReport(library: library, currency: .jpy)
    #expect(report.month(february).hasSnapshots)
    #expect(report.month(february).total == nil)
    #expect(report.month(february).change(from: report.previousMonth(before: february)) == -50)
    #expect(report.month(february).change(for: checking.id, from: report.month(january)) == -40)
    #expect(report.month(february).change(for: savings.id, from: report.month(january)) == nil)
    #expect(!report.month(march).hasSnapshots)
    #expect(report.month(april).change(from: report.previousMonth(before: april)) == nil)
    #expect(report.month(april).change(for: checking.id, from: report.month(march)) == nil)
    #expect(report.recordedBalances(for: checking.id) == [fourth, second, first])
}

@MainActor
@Test func accountResetAndDeletionPersistAndStayScoped() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "Logbook.store")
    let month = try #require(MonthKey(rawValue: "2026-11"))
    let account = Account(name: "Checking", currency: .jpy, opened: month)
    let other = Account(name: "Savings", currency: .jpy, opened: month)
    let first = Balance(accountID: account.id, month: month, minorUnits: 10)
    let second = Balance(accountID: account.id, month: month.adding(months: 1), minorUnits: 20)
    let otherBalance = Balance(accountID: other.id, month: month, minorUnits: 30)

    do {
        let store = try LogbookStore(url: url)
        try store.save([.account(account), .account(other), .balance(first), .balance(second), .balance(otherBalance)])
        try store.resetAccount(account.id)
        #expect(store.library.accounts == [account, other])
        #expect(store.library.balances == [otherBalance])
    }
    do {
        let store = try LogbookStore(url: url)
        #expect(store.library.accounts == [account, other])
        #expect(store.library.balances == [otherBalance])
        try store.save([.balance(first), .balance(second)])
        #expect(throws: LogbookError.self) { try store.save(removing: [Record.account(account).key]) }
        try store.deleteAccount(account.id)
        #expect(throws: LogbookError.self) { try store.save([.balance(first)]) }
    }
    let store = try LogbookStore(url: url)
    #expect(store.library.accounts == [other])
    #expect(store.library.balances == [otherBalance])
}
