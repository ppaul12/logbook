import Foundation

struct BalanceMonth {
    let accounts: [Account]
    let snapshots: [String: Balance]

    var missing: [Account] { accounts.filter { snapshots[$0.id] == nil } }
    var hasSnapshots: Bool { accounts.contains { snapshots[$0.id] != nil } }
    var subtotal: Decimal {
        accounts.reduce(0) { $0 + Decimal(snapshots[$1.id]?.minorUnits ?? 0) }
    }

    var total: Decimal? { accounts.isEmpty || !missing.isEmpty ? nil : subtotal }

    func change(from previous: Self?) -> Decimal? {
        guard hasSnapshots, let previous, previous.hasSnapshots else { return nil }
        return subtotal - previous.subtotal
    }

    func change(for accountID: String, from previous: Self?) -> Decimal? {
        guard let current = snapshots[accountID], let prior = previous?.snapshots[accountID] else { return nil }
        return Decimal(current.minorUnits) - Decimal(prior.minorUnits)
    }
}

struct BalanceReport {
    let accounts: [Account]
    private let snapshots: [MonthKey: [String: Balance]]

    init(library: Library, currency: LedgerCurrency, accountID: String? = nil) {
        accounts = library.accounts.filter { $0.currency == currency && (accountID == nil || $0.id == accountID) }
        let ids = Set(accounts.map(\.id))
        let balances = library.balances.filter { ids.contains($0.accountID) }
        snapshots = Dictionary(grouping: balances, by: \.month).mapValues {
            Dictionary(uniqueKeysWithValues: $0.map { ($0.accountID, $0) })
        }
    }

    var recordedMonths: [MonthKey] { snapshots.keys.sorted() }

    func recordedBalances(for accountID: String) -> [Balance] {
        recordedMonths.reversed().compactMap { snapshots[$0]?[accountID] }
    }

    func previousMonth(before selected: MonthKey) -> BalanceMonth? {
        guard selected.index > 12 else { return nil }
        return month(selected.adding(months: -1))
    }

    func history(through current: MonthKey) -> ClosedRange<MonthKey> {
        let openings = accounts.map(\.opened)
        let first = openings.min() ?? current
        let last = openings.max() ?? current
        let closings = accounts.compactMap(\.closed)
        let end = closings.count == accounts.count ? (closings.max() ?? current) : max(current, last)
        return first...max(end, snapshots.keys.max() ?? end)
    }

    func month(_ month: MonthKey) -> BalanceMonth {
        BalanceMonth(accounts: accounts.filter { $0.includes(month) }, snapshots: snapshots[month] ?? [:])
    }
}

struct CashFlowMonth {
    let entries: [Transaction]

    var income: Decimal { entries.reduce(0) { $0 + ($1.kind == .income ? Decimal($1.minorUnits) : 0) } }
    var expenses: Decimal { entries.reduce(0) { $0 + ($1.kind == .expense ? Decimal($1.minorUnits) : 0) } }
    var net: Decimal { income - expenses }
}

enum CashFlowMetric: CaseIterable {
    case netIncome, income, expense

    var transactionKind: TransactionKind? {
        switch self {
        case .netIncome: nil
        case .income: .income
        case .expense: .expense
        }
    }

    func amount(in month: CashFlowMonth) -> Decimal {
        switch self {
        case .netIncome: month.net
        case .income: month.income
        case .expense: -month.expenses
        }
    }

    func amount(in average: CashFlowMonthlyAverage) -> Decimal {
        switch self {
        case .netIncome: average.net
        case .income: average.income
        case .expense: -average.expenses
        }
    }

    func entries(in month: CashFlowMonth) -> [Transaction] {
        guard let transactionKind else { return month.entries }
        return month.entries.filter { $0.kind == transactionKind }
    }
}

enum CashFlowAveragePeriod: Int, CaseIterable, Codable, Sendable {
    case threeMonths = 3
    case sixMonths = 6
    case twelveMonths = 12
    case twentyFourMonths = 24
    case allHistory = 0
}

struct CashFlowMonthlyAverage {
    let months: ClosedRange<MonthKey>
    let income: Decimal
    let expenses: Decimal

    var net: Decimal { income - expenses }
}

struct CashFlowAverageProgress {
    private static let scale = 1.5

    let zero: Double
    let ratio: Decimal?
    let averageMarker: Double?

    init(metric: CashFlowMetric, amount: Decimal, average: Decimal?) {
        let signed = metric == .netIncome
        zero = signed ? 0.5 : 0
        guard let average, average != 0 else {
            ratio = nil
            averageMarker = nil
            return
        }
        ratio = (signed ? amount : abs(amount)) / abs(average)
        let direction = signed && average < 0 ? -1.0 : 1.0
        averageMarker = zero + direction * (1 - zero) / Self.scale
    }

    var fillEnd: Double {
        guard let ratio else { return zero }
        let offset = NSDecimalNumber(decimal: ratio).doubleValue / Self.scale
        return min(1, max(0, zero + offset * (1 - zero)))
    }
}

struct CashFlowReport {
    private let months: [MonthKey: [Transaction]]

    init(library: Library, currency: LedgerCurrency) {
        months = Dictionary(grouping: library.transactions.filter { $0.currency == currency }, by: \.postingMonth)
    }

    var earliest: MonthKey? { months.keys.min() }
    var latest: MonthKey? { months.keys.max() }
    var recordedMonths: [MonthKey] { months.keys.sorted() }

    func history(through current: MonthKey) -> ClosedRange<MonthKey> {
        min(current, earliest ?? current)...max(current, latest ?? current)
    }

    func month(_ month: MonthKey) -> CashFlowMonth { CashFlowMonth(entries: months[month] ?? []) }

    func average(before selected: MonthKey, current: MonthKey,
                 period: CashFlowAveragePeriod) -> CashFlowMonthlyAverage? {
        let last = min(selected, current).index - 1
        guard let earliest, earliest.index <= last else { return nil }
        let first = period == .allHistory ? earliest.index : max(earliest.index, last - period.rawValue + 1)
        let range = MonthKey(index: first)...MonthKey(index: last)
        var income: Decimal = 0
        var expenses: Decimal = 0
        for (month, entries) in months where range.contains(month) {
            let summary = CashFlowMonth(entries: entries)
            income += summary.income
            expenses += summary.expenses
        }
        let count = Decimal(last - first + 1)
        return CashFlowMonthlyAverage(months: range, income: income / count, expenses: expenses / count)
    }
}
