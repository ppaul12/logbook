import Foundation

struct LedgerCurrency: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    static let jpy = LedgerCurrency(rawValue: "JPY")!
    static let cny = LedgerCurrency(rawValue: "CNY")!

    static let available = Set(Locale.Currency.isoCurrencies.map(\.identifier))
        .sorted().compactMap(Self.init(rawValue:))

    let rawValue: String
    var id: Self { self }
    var label: String {
        guard let name = Locale.current.localizedString(forCurrencyCode: rawValue) else { return rawValue }
        return "\(rawValue) · \(name)"
    }

    let fractionDigits: Int
    private var scale: Decimal { pow(Decimal(10), fractionDigits) }

    init?(rawValue: String) {
        guard rawValue.utf8.count == 3, rawValue.utf8.allSatisfy({ (65...90).contains($0) }),
              Locale.Currency(rawValue).isISOCurrency else { return nil }
        self.rawValue = rawValue
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = rawValue
        fractionDigits = formatter.maximumFractionDigits
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }

    func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }

    func parse(_ input: String) -> Int64? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let negative = trimmed.hasPrefix("-")
        let unsigned = negative ? trimmed.dropFirst() : trimmed[...]
        let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        guard let whole = parts.first, !whole.isEmpty, parts.count <= 2,
              parts.joined().utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard parts.count == 1 || (!fraction.isEmpty && fraction.count <= fractionDigits) else { return nil }
        let padded = fraction.padding(toLength: fractionDigits, withPad: "0", startingAt: 0)
        return Int64((negative ? "-" : "") + whole + padded)
    }

    func amount(_ minor: Decimal) -> Decimal { minor / scale }

    func plain(_ minor: Int64) -> String { NSDecimalNumber(decimal: amount(Decimal(minor))).stringValue }

    func format(_ minor: Decimal, showPlus: Bool = false) -> String {
        "\(rawValue) \(formattedNumber(minor, showPlus: showPlus))"
    }

    func formattedNumber(_ minor: Decimal, showPlus: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        if showPlus && minor > 0 { formatter.positivePrefix = formatter.plusSign }
        return formatter.string(from: NSDecimalNumber(decimal: amount(minor))) ?? ""
    }
}

struct Preferences: Codable, Equatable, Sendable {
    var defaultCurrency: LedgerCurrency = .jpy
    var timeZoneID = TimeZone.current.identifier
    var weekStart: WeekStart = .monday
    var showArchivedScenes = false
    var cashFlowAveragePeriod = CashFlowAveragePeriod.twelveMonths
    var greetingName = ""
    var strengthPlanOrder: [UUID] = []
    var strengthCheckInSceneID: String?

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? LogCalendar.utc }
    var today: DayKey { DayKey(.now, in: timeZone) }
}

extension Preferences {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        defaultCurrency = try values.decode(LedgerCurrency.self, forKey: .defaultCurrency)
        timeZoneID = try values.decode(String.self, forKey: .timeZoneID)
        weekStart = try values.decode(WeekStart.self, forKey: .weekStart)
        showArchivedScenes = try values.decodeIfPresent(Bool.self, forKey: .showArchivedScenes) ?? false
        cashFlowAveragePeriod = try values.decodeIfPresent(CashFlowAveragePeriod.self, forKey: .cashFlowAveragePeriod)
            ?? .twelveMonths
        greetingName = try values.decodeIfPresent(String.self, forKey: .greetingName) ?? ""
        strengthPlanOrder = try values.decodeIfPresent([UUID].self, forKey: .strengthPlanOrder) ?? []
        strengthCheckInSceneID = try values.decodeIfPresent(String.self, forKey: .strengthCheckInSceneID)
    }
}

enum SceneKind: String, Codable, CaseIterable, Sendable {
    case completion, quantity
    var label: String { rawValue.capitalized }
}

enum LogbookColor {
    static func isValidHex(_ hex: String) -> Bool {
        hex.utf8.count == 7 && hex.hasPrefix("#")
            && hex.dropFirst().utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
}

struct CheckInScene: Codable, Equatable, Identifiable, Sendable {
    static let defaultColor = "#237F69"

    var id = UUID().uuidString
    var name = ""
    var kind: SceneKind = .completion
    var unit = ""
    var color = Self.defaultColor
    var maximum: Double?
    var position = 0
    var archived = false

    func intensity(_ value: Double) -> Double {
        guard kind == .quantity, let maximum, maximum > 0 else { return 1 }
        return 0.24 + 0.76 * min(1, value / maximum)
    }

    func accepts(_ entry: CheckIn) -> Bool {
        guard entry.value.isFinite, entry.value >= 0 else { return false }
        return kind == .quantity || (entry.entryID == nil && entry.value == 1)
    }

    static func parseMaximum(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value > 0 else { return nil }
        return value
    }

    static func parseLegacyMaximum(_ text: String) -> Double? {
        let parts = text.split(separator: "|", omittingEmptySubsequences: false)
        let values = parts.compactMap { parseMaximum(String($0)) }
        guard values.count == parts.count,
              zip(values, values.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        return values.last
    }
}

extension CheckInScene {
    private enum LegacyKeys: String, CodingKey { case thresholds }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(SceneKind.self, forKey: .kind)
        unit = try values.decode(String.self, forKey: .unit)
        color = try values.decode(String.self, forKey: .color)
        position = try values.decode(Int.self, forKey: .position)
        archived = try values.decode(Bool.self, forKey: .archived)
        maximum = try values.decodeIfPresent(Double.self, forKey: .maximum)
        if kind == .quantity, maximum == nil {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            maximum = try legacy.decodeIfPresent([Double].self, forKey: .thresholds)?.max()
        }
    }
}

struct CheckIn: Codable, Equatable, Identifiable, Sendable {
    var sceneID: String
    var day: DayKey
    var value: Double
    var note = ""
    var entryID: UUID?

    var id: String {
        let dayID = "\(sceneID)/\(day.rawValue)"
        return entryID.map { "\(dayID)/\($0.uuidString)" } ?? dayID
    }

    static func parseQuantity(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value >= 0 else { return nil }
        return value
    }
}

struct CheckInDay {
    let entries: [CheckIn]

    var total: Double { entries.reduce(0) { $0 + $1.value } }
}

struct Account: Codable, Equatable, Identifiable, Sendable {
    static let palette = ["#007AFF", "#008F95", "#EA7A17", "#9555C8", "#CC477B",
                          "#5354BE", "#299A6B", "#A06E37", "#0088C2", "#DB4437"]

    var id = UUID().uuidString
    var name = ""
    var currency: LedgerCurrency
    var opened: MonthKey
    var closed: MonthKey?
    var color: String?

    static func themeColors(for accounts: [Account]) -> [String: String] {
        var themes: [String: String] = [:]
        let explicit = Set(accounts.compactMap(\.color))
        let available = palette.filter { !explicit.contains($0) }
        var autoIndex = 0
        for account in accounts {
            if let color = account.color {
                themes[account.id] = color
            } else {
                themes[account.id] = autoIndex < available.count ? available[autoIndex] : palette[autoIndex % palette.count]
                autoIndex += 1
            }
        }
        return themes
    }

    func includes(_ month: MonthKey) -> Bool {
        opened <= month && (closed.map { month <= $0 } ?? true)
    }
}

struct Balance: Codable, Equatable, Identifiable, Sendable {
    var accountID: String
    var month: MonthKey
    var minorUnits: Int64
    var id: String { "\(accountID)/\(month.rawValue)" }
}

enum TransactionKind: String, Codable, CaseIterable, Sendable {
    case income, expense
    var label: String { rawValue.capitalized }
}

enum LegacyPaymentMethod: String {
    case cash, debitCard = "debit_card", creditCard = "credit_card", bankTransfer = "bank_transfer"

    var label: String {
        switch self {
        case .cash: "Cash"
        case .debitCard: "Debit card"
        case .creditCard: "Credit card"
        case .bankTransfer: "Bank transfer"
        }
    }
}

// Retained to decode stores created when expenses linked to shared categories.
struct ExpenseCategory: Codable, Equatable, Sendable {
    var id: String
    var name: String
}

struct Transaction: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var day: DayKey
    var kind: TransactionKind = .expense
    var minorUnits: Int64 = 0
    var currency: LedgerCurrency
    var paymentMethod = ""
    var settlesNextMonth = false
    var note = ""
    var category = ""
    var categoryID: String? // Legacy reference resolved when opening the store.

    var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    func validateNote() throws {
        guard !trimmedNote.isEmpty else {
            throw LogbookError.message("Enter a note for the transaction.")
        }
    }

    var postingMonth: MonthKey {
        kind == .expense && settlesNextMonth ? day.month.adding(months: 1) : day.month
    }
}

extension Transaction {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        day = try values.decode(DayKey.self, forKey: .day)
        kind = try values.decode(TransactionKind.self, forKey: .kind)
        minorUnits = try values.decode(Int64.self, forKey: .minorUnits)
        currency = try values.decode(LedgerCurrency.self, forKey: .currency)
        note = try values.decode(String.self, forKey: .note)
        if kind == .expense {
            category = try values.decodeIfPresent(String.self, forKey: .category) ?? ""
            categoryID = try values.decodeIfPresent(String.self, forKey: .categoryID)
            let method = try values.decode(String.self, forKey: .paymentMethod)
            if let settlesNextMonth = try values.decodeIfPresent(Bool.self, forKey: .settlesNextMonth) {
                self.settlesNextMonth = settlesNextMonth
                paymentMethod = method
            } else if let legacy = LegacyPaymentMethod(rawValue: method) {
                paymentMethod = legacy.label
                settlesNextMonth = legacy == .creditCard
            } else {
                paymentMethod = method
            }
        }
    }
}

enum Record: Codable, Equatable, Sendable {
    case scene(CheckInScene), checkIn(CheckIn), account(Account), balance(Balance)
    case expenseCategory(ExpenseCategory), transaction(Transaction)
    case strengthPlan(StrengthPlan), strengthSession(StrengthSession)

    var key: String {
        switch self {
        case .scene(let row): "scene/\(row.id)"
        case .checkIn(let row): "checkin/\(row.id)"
        case .account(let row): "account/\(row.id)"
        case .balance(let row): "balance/\(row.id)"
        case .expenseCategory(let row): "expenseCategory/\(row.id)"
        case .transaction(let row): "transaction/\(row.id)"
        case .strengthPlan(let row): "strengthPlan/\(row.id)"
        case .strengthSession(let row): "strengthSession/\(row.id)"
        }
    }
}

struct Revision: Codable, Equatable, Sendable {
    var counter: Int64
    var writer: String
}

struct VersionedRecord: Codable, Equatable, Sendable {
    var key: String
    var revision: Revision
    var value: Record?
}

struct Library: Sendable {
    private(set) var records: [String: Record] = [:]
    private var scenesByID: [String: CheckInScene] = [:]
    private var firstCheckInDays: [String: DayKey] = [:]
    private var checkInsByScene: [String: [DayKey: [String: CheckIn]]] = [:]

    init(_ records: [Record] = []) {
        for record in records { set(record) }
    }

    var scenes: [CheckInScene] {
        scenesByID.values.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
    }

    func scene(id: String) -> CheckInScene? { scenesByID[id] }

    func visibleScenes(showArchived: Bool) -> [CheckInScene] {
        scenes.filter { showArchived || !$0.archived }
    }

    var checkIns: [CheckIn] { records.values.compactMap { if case .checkIn(let row) = $0 { row } else { nil } } }

    var accounts: [Account] {
        records.values.compactMap { if case .account(let row) = $0 { row } else { nil } }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    var balances: [Balance] { records.values.compactMap { if case .balance(let row) = $0 { row } else { nil } } }

    func balanceKeys(for accountID: String) -> [String] {
        balances.filter { $0.accountID == accountID }.map { Record.balance($0).key }
    }

    var legacyExpenseCategoryNames: [String: String] {
        records.values.reduce(into: [:]) { names, record in
            if case .expenseCategory(let category) = record {
                names[category.id] = category.name
            }
        }
    }

    var transactions: [Transaction] {
        records.values.compactMap { if case .transaction(let row) = $0 { row } else { nil } }
            .sorted { ($0.day, $0.id) > ($1.day, $1.id) }
    }

    var strengthPlans: [StrengthPlan] {
        records.values.compactMap { if case .strengthPlan(let plan) = $0 { plan } else { nil } }
            .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
    }

    func strengthPlan(id: UUID) -> StrengthPlan? {
        guard case .strengthPlan(let plan) = records["strengthPlan/\(id)"] else { return nil }
        return plan
    }

    var activeStrengthSession: StrengthSession? {
        for case .strengthSession(let session) in records.values where session.finishedAt == nil {
            return session
        }
        return nil
    }

    var strengthHistory: [StrengthSession] {
        records.values.compactMap { record -> StrengthSession? in
            guard case .strengthSession(let session) = record, session.finishedAt != nil else { return nil }
            return session
        }
        .sorted { ($0.startedAt, $0.id.uuidString) > ($1.startedAt, $1.id.uuidString) }
    }

    func checkIn(for sceneID: String, on day: DayKey) -> CheckIn? {
        guard case .checkIn(let entry) = records["checkin/\(sceneID)/\(day.rawValue)"] else { return nil }
        return entry
    }

    func firstCheckInDay(for sceneID: String) -> DayKey? { firstCheckInDays[sceneID] }

    func checkInDays(for sceneID: String) -> Set<DayKey> {
        guard let days = checkInsByScene[sceneID] else { return [] }
        return Set(days.keys)
    }

    func checkInDay(for sceneID: String, on day: DayKey) -> CheckInDay? {
        guard let entries = checkInsByScene[sceneID]?[day] else { return nil }
        return CheckInDay(entries: entries.values.sorted { $0.id < $1.id })
    }

    func checkInKeys(for sceneID: String) -> [String] {
        guard let days = checkInsByScene[sceneID] else { return [] }
        return days.values.flatMap { $0.keys }
    }

    mutating func set(_ record: Record) {
        records[record.key] = record
        switch record {
        case .scene(let scene):
            scenesByID[scene.id] = scene
        case .checkIn(let entry):
            firstCheckInDays[entry.sceneID] = min(firstCheckInDays[entry.sceneID] ?? entry.day, entry.day)
            checkInsByScene[entry.sceneID, default: [:]][entry.day, default: [:]][record.key] = entry
        default:
            break
        }
    }
}

enum LogbookError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}
