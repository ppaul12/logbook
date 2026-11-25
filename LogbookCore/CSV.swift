import Foundation

enum CSVKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case scenes, checkins, accounts, balanceSnapshots = "balance_snapshots", transactions

    var id: Self { self }
    var filename: String { rawValue + ".csv" }

    var label: String {
        switch self {
        case .scenes: "Scenes"
        case .checkins: "Check-ins"
        case .accounts: "Accounts"
        case .balanceSnapshots: "Balance Snapshots"
        case .transactions: "Transactions"
        }
    }

    var columns: [String] {
        switch self {
        case .scenes: ["scene_id", "name", "kind", "unit", "color", "maximum"]
        case .checkins: ["scene_id", "date", "value", "note", "entry_id"]
        case .accounts: ["account_id", "name", "currency", "opened_month", "closed_month", "color"]
        case .balanceSnapshots: ["account_id", "month", "balance"]
        case .transactions:
            ["transaction_id", "date", "kind", "amount", "currency", "payment_method", "note", "settles_next_month", "category"]
        }
    }

    var legacyColumns: [[String]] {
        switch self {
        case .scenes: [["scene_id", "name", "kind", "unit", "color", "thresholds"]]
        case .checkins: [["scene_id", "date", "value", "note"]]
        case .accounts: [["account_id", "name", "currency", "opened_month", "closed_month"]]
        case .transactions: [Array(columns.dropLast()) + ["category_id"], Array(columns.dropLast()), Array(columns.dropLast(2))]
        case .balanceSnapshots: []
        }
    }

    var template: String { CSV.encode([columns]) }

    func export(_ library: Library) throws -> String {
        let rows: [Record]
        switch self {
        case .scenes:
            rows = library.scenes.map(Record.scene)
        case .checkins:
            rows = library.checkIns.sorted {
                ($0.sceneID, $0.day, $0.id) < ($1.sceneID, $1.day, $1.id)
            }.map(Record.checkIn)
        case .accounts:
            rows = library.accounts.map(Record.account)
        case .balanceSnapshots:
            rows = library.balances.sorted { ($0.accountID, $0.month) < ($1.accountID, $1.month) }.map(Record.balance)
        case .transactions:
            rows = library.transactions.map(Record.transaction)
        }
        let currencies = Dictionary(uniqueKeysWithValues: library.accounts.map { ($0.id, $0.currency) })
        return CSV.encode([columns] + (try rows.map { record in
            if case .balance(let balance) = record, currencies[balance.accountID] == nil {
                throw LogbookError.message("Account \(balance.accountID) is required to export its snapshots.")
            }
            return record.csvValues(balanceCurrency: currencies)
        }))
    }
}

extension Record {
    func csvValues(balanceCurrency: [String: LedgerCurrency] = [:]) -> [String] {
        switch self {
        case .scene(let item):
            [item.id, item.name, item.kind.rawValue, item.unit, item.color,
             item.maximum.map { String($0) } ?? ""]
        case .checkIn(let item):
            [item.sceneID, item.day.rawValue, String(item.value), item.note, item.entryID?.uuidString ?? ""]
        case .account(let item):
            [item.id, item.name, item.currency.rawValue, item.opened.rawValue, item.closed?.rawValue ?? "", item.color ?? ""]
        case .balance(let item):
            [item.accountID, item.month.rawValue,
             balanceCurrency[item.accountID]?.plain(item.minorUnits) ?? String(item.minorUnits)]
        case .expenseCategory(let item):
            [item.id, item.name]
        case .transaction(let item):
            [item.id, item.day.rawValue, item.kind.rawValue, item.currency.plain(item.minorUnits),
             item.currency.rawValue, item.kind == .expense ? item.paymentMethod : "", item.note,
             item.kind == .expense ? String(item.settlesNextMonth) : "",
             item.kind == .expense ? item.category : ""]
        case .strengthPlan, .strengthSession:
            []
        }
    }
}

enum CSV {
    struct Row {
        var line: Int
        var values: [String]
    }

    private enum Field {
        case unquoted, quoted, closed
    }

    static func encode(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { value in
                if value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) {
                    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return value
            }.joined(separator: ",")
        }.joined(separator: "\r\n") + "\r\n"
    }

    static func decode(_ input: String) throws -> [Row] {
        var rows: [Row] = []
        var state = Field.unquoted
        var values: [String] = []
        var field = ""
        var line = 1
        var rowStart = 1

        func finishRow() {
            if !values.isEmpty || !field.isEmpty || state == .closed {
                rows.append(Row(line: rowStart, values: values + [field]))
            }
            values = []
            field = ""
            state = .unquoted
        }

        let input = input.first == "\u{feff}" ? input.dropFirst() : input[...]
        for character in input {
            let newline = character == "\n" || character == "\r" || character == "\r\n"
            switch state {
            case .quoted:
                if character == "\"" {
                    state = .closed
                } else {
                    field.append(character)
                }
            case .closed where character == "\"":
                field.append(character)
                state = .quoted
            case _ where character == ",":
                values.append(field)
                field = ""
                state = .unquoted
            case _ where newline:
                finishRow()
                rowStart = line + 1
            case .unquoted where character == "\"" && field.isEmpty:
                state = .quoted
            case .unquoted where character != "\"":
                field.append(character)
            default:
                throw LogbookError.message("Unexpected quotation mark or character at line \(line).")
            }
            if newline { line += 1 }
        }
        guard state != .quoted else {
            throw LogbookError.message("An opening quote at line \(rowStart) has no closing quote.")
        }
        finishRow()
        return rows
    }
}
