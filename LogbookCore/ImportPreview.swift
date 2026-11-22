import Foundation

struct LogbookBackup: Codable {
    var version = 6
    var files: [String: String]
    var preferences: Preferences
    var scenes: [String: SceneState]
    static let legacyCategoriesFile = "expense_categories.csv"

    struct SceneState: Codable {
        var position: Int
        var archived: Bool
    }

    init(library: Library, preferences: Preferences) throws {
        files = try Dictionary(uniqueKeysWithValues: CSVKind.allCases.map { ($0.filename, try $0.export(library)) })
        scenes = Dictionary(uniqueKeysWithValues: library.scenes.map {
            ($0.id, SceneState(position: $0.position, archived: $0.archived))
        })
        self.preferences = preferences
    }

    static func read(_ data: Data) throws -> Self {
        struct Header: Decodable { let version: Int }
        let decoder = JSONDecoder()
        guard try (1...6).contains(decoder.decode(Header.self, from: data).version) else {
            throw LogbookError.message("This backup format version is unsupported.")
        }
        let backup = try decoder.decode(Self.self, from: data)
        var expectedFiles = Set(CSVKind.allCases.map(\.filename))
        if backup.version == 5 { expectedFiles.insert(legacyCategoriesFile) }
        guard Set(backup.files.keys) == expectedFiles,
              TimeZone(identifier: backup.preferences.timeZoneID) != nil,
              backup.scenes.values.allSatisfy({ (0...1_000_000_000).contains($0.position) }) else {
            throw LogbookError.message("The backup’s files, preferences, or scene order are invalid.")
        }
        return backup
    }
}

struct ImportPreview {
    struct Item: Identifiable {
        enum Status: String, CaseIterable {
            case new = "New", duplicate = "Duplicate", conflict = "Conflict", invalid = "Invalid"
        }

        var kind: CSVKind
        var line: Int
        var status: Status
        var detail: String
        var record: Record?
        var id: String { "\(kind.filename):\(line)" }
        var location: String { line == 0 ? kind.filename : "\(kind.filename), line \(line)" }
    }

    struct Conflict: Identifiable {
        let id: String
        var existing: Record?
        var incoming: [Item]

        var defaultChoice: String { existing == nil ? (incoming.first?.id ?? "") : "" }
    }

    var items: [Item] = []
    var conflicts: [Conflict] = []
    var preferences: Preferences?
    let isBackup: Bool

    private let original: Library
    private var importedAccounts: [String: Account] = [:]
    private var importedScenes: [String: CheckInScene] = [:]
    private var balanceCurrencies: [String: LedgerCurrency] = [:]

    init(csv: String, kind: CSVKind, library: Library) {
        self.init(files: [kind.filename: csv], library: library)
    }

    init(backup: LogbookBackup, library: Library) {
        self.init(files: backup.files, library: library, sceneStates: backup.scenes, isBackup: true)
        preferences = backup.preferences
    }

    private init(files: [String: String], library: Library,
                 sceneStates: [String: LogbookBackup.SceneState] = [:], isBackup: Bool = false) {
        original = library
        self.isBackup = isBackup
        let existingAccounts = Dictionary(uniqueKeysWithValues: library.accounts.map { ($0.id, $0) })
        let existingScenes = Dictionary(uniqueKeysWithValues: library.scenes.map { ($0.id, $0) })
        let accountsWithHistory = Set(library.balances.map(\.accountID))
        let recordedMonths = Dictionary(grouping: library.balances, by: \.accountID)
        let scenesWithHistory = Set(library.checkIns.map(\.sceneID))
        let firstPosition = (library.scenes.last?.position ?? -1) + 1
        var positions: [String: Int] = [:]
        var byKey: [String: [Item]] = [:]
        let categoryNames = Self.legacyCategoryNames(in: files, library: library)

        for kind in CSVKind.allCases {
            guard let source = files[kind.filename] else { continue }
            let rows: [CSV.Row]
            do {
                rows = try CSV.decode(source)
            } catch {
                items.append(Item(kind: kind, line: 0, status: .invalid, detail: error.localizedDescription))
                continue
            }
            guard let header = rows.first, header.values == kind.columns || kind.legacyColumns.contains(header.values) else {
                items.append(Item(kind: kind, line: rows.first?.line ?? 0, status: .invalid,
                                  detail: "Expected columns: " + kind.columns.joined(separator: ", ")))
                continue
            }
            let legacy = header.values != kind.columns
            for row in rows.dropFirst() {
                do {
                    let values = row.values
                    guard values.count == header.values.count else {
                        throw LogbookError.message("Expected \(header.values.count) columns, found \(values.count).")
                    }
                    guard !values[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw LogbookError.message("Enter a record identifier.")
                    }
                    let id = values[0]
                    let record: Record
                    switch kind {
                    case .scenes:
                        let existing = existingScenes[id]
                        let position = positions[id] ?? firstPosition + positions.count
                        record = try Self.scene(values, legacy: legacy, existing: existing,
                                                state: sceneStates[id], position: position)
                        if case .scene(let scene) = record {
                            if let existing, existing.kind != scene.kind, scenesWithHistory.contains(id) {
                                throw LogbookError.message("This scene already has entries of a different type.")
                            }
                            positions[id] = position
                            importedScenes[id] = importedScenes[id] ?? scene
                        }
                    case .checkins:
                        guard let scene = importedScenes[id] ?? existingScenes[id] else {
                            throw LogbookError.message("Import scene \(id) before its check-ins.")
                        }
                        record = try Self.checkIn(values, scene: scene, legacy: legacy)
                    case .accounts:
                        record = try Self.account(values, legacy: legacy, existing: existingAccounts[id])
                        if case .account(let account) = record {
                            if let existing = existingAccounts[id], existing.currency != account.currency,
                               accountsWithHistory.contains(id) {
                                throw LogbookError.message("This account already has snapshots in \(existing.currency.rawValue).")
                            }
                            if (recordedMonths[id] ?? []).contains(where: { !account.includes($0.month) }) {
                                throw LogbookError.message("The account’s dates must include its saved snapshots.")
                            }
                            importedAccounts[id] = importedAccounts[id] ?? account
                        }
                    case .balanceSnapshots:
                        guard let account = importedAccounts[id] ?? existingAccounts[id] else {
                            throw LogbookError.message("Import account \(id) before its balance snapshots.")
                        }
                        record = try Self.balance(values, account: account)
                        balanceCurrencies[record.key] = account.currency
                    case .transactions:
                        record = try Self.transaction(values, existing: library.records["transaction/\(id)"],
                                                      usesCategoryIDs: header.values.last == "category_id",
                                                      categoryNames: categoryNames)
                    }
                    let existing = library.records[record.key]
                    let candidates = byKey[record.key] ?? []
                    let status: Item.Status
                    if record == existing || candidates.contains(where: { $0.record == record }) {
                        status = .duplicate
                    } else {
                        if !isBackup, case .transaction(let entry) = record {
                            try entry.validateNote()
                        }
                        status = existing == nil && candidates.isEmpty ? .new : .conflict
                    }
                    let previewValues = kind == .transactions ? record.csvValues() : values
                    var details = Self.localizedDates(in: previewValues, for: record)
                    if let state = sceneStates[id], kind == .scenes {
                        details.append(state.archived ? "Archived" : "Active")
                        details.append("Position \(state.position + 1)")
                    }
                    let item = Item(kind: kind, line: row.line, status: status,
                                    detail: details.joined(separator: " · "), record: record)
                    items.append(item)
                    if status != .duplicate { byKey[record.key, default: []].append(item) }
                } catch {
                    items.append(Item(kind: kind, line: row.line, status: .invalid, detail: error.localizedDescription))
                }
            }
        }
        conflicts = byKey.compactMap { key, incoming in
            guard incoming.contains(where: { $0.status == .conflict }) else { return nil }
            return Conflict(id: key, existing: library.records[key], incoming: incoming)
        }
        .sorted { ($0.incoming.first?.kind.rawValue ?? "", $0.incoming.first?.line ?? 0) <
            ($1.incoming.first?.kind.rawValue ?? "", $1.incoming.first?.line ?? 0) }
    }

    func count(_ status: Item.Status) -> Int { items.count { $0.status == status } }

    func changes(choices: [String: String]) throws -> [Record] {
        let conflictKeys = Set(conflicts.map(\.id))
        var changes = items.filter { $0.status == .new }.compactMap(\.record).filter { !conflictKeys.contains($0.key) }
        for conflict in conflicts {
            let choice = choices[conflict.id] ?? conflict.defaultChoice
            if let record = conflict.incoming.first(where: { $0.id == choice })?.record {
                changes.append(record)
            }
        }
        var proposed = original
        for change in changes { proposed.set(change) }
        let scenes = Dictionary(uniqueKeysWithValues: proposed.scenes.map { ($0.id, $0) })
        let accounts = Dictionary(uniqueKeysWithValues: proposed.accounts.map { ($0.id, $0) })
        for record in changes {
            switch record {
            case .checkIn(let entry):
                if let scene = scenes[entry.sceneID], !scene.accepts(entry) {
                    throw LogbookError.message("Choose a quantity scene for the imported check-ins for \(scene.name).")
                }
            case .balance(let balance):
                if let account = accounts[balance.accountID],
                   account.currency != balanceCurrencies[record.key] || !account.includes(balance.month) {
                    throw LogbookError.message("Choose the imported account details for \(account.name) to restore its snapshots.")
                }
            default:
                break
            }
        }
        return changes
    }

    func existingDetails(_ record: Record) -> String {
        let currencies = Dictionary(uniqueKeysWithValues: original.accounts.map { ($0.id, $0.currency) })
        var values = Self.localizedDates(in: record.csvValues(balanceCurrency: currencies), for: record)
        if case .scene(let scene) = record {
            values.append(scene.archived ? "Archived" : "Active")
            values.append("Position \(scene.position + 1)")
        }
        return values.joined(separator: " · ")
    }

    private static func localizedDates(in values: [String], for record: Record) -> [String] {
        var values = values
        switch record {
        case .scene, .expenseCategory: break
        case .checkIn(let entry): values[1] = entry.day.label
        case .account(let account):
            values[3] = account.opened.label
            values[4] = account.closed?.label ?? ""
        case .balance(let balance): values[1] = balance.month.label
        case .transaction(let entry): values[1] = entry.day.label
        }
        return values
    }

    private static func scene(
        _ values: [String], legacy: Bool, existing: CheckInScene?, state: LogbookBackup.SceneState?, position: Int
    ) throws -> Record {
        let name = values[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let color = values[4].uppercased()
        guard !name.isEmpty, let kind = SceneKind(rawValue: values[2]), LogbookColor.isValidHex(color) else {
            throw LogbookError.message("Enter a name, a supported scene type, and a hex color.")
        }
        let unit = values[3].trimmingCharacters(in: .whitespacesAndNewlines)
        let maximumText = values[5].trimmingCharacters(in: .whitespacesAndNewlines)
        let maximum = legacy ? CheckInScene.parseLegacyMaximum(maximumText) : CheckInScene.parseMaximum(maximumText)
        guard kind == .quantity ? !unit.isEmpty && maximum != nil : unit.isEmpty && maximumText.isEmpty else {
            throw LogbookError.message("Quantity scenes require a unit and a positive heatmap maximum. Leave both blank for completion scenes.")
        }
        return .scene(CheckInScene(
            id: values[0], name: name, kind: kind, unit: unit, color: color, maximum: maximum,
            position: state?.position ?? existing?.position ?? position, archived: state?.archived ?? existing?.archived ?? false
        ))
    }

    private static func checkIn(_ values: [String], scene: CheckInScene, legacy: Bool) throws -> Record {
        guard let day = DayKey(rawValue: values[1]), let value = Double(values[2]), value.isFinite,
              scene.kind == .completion ? value == 1 : value >= 0 else {
            throw LogbookError.message("Enter a YYYY-MM-DD date and \(scene.kind == .completion ? "1 for completion" : "a nonnegative quantity").")
        }
        let identifier = legacy ? "" : values[4].trimmingCharacters(in: .whitespacesAndNewlines)
        let entryID = UUID(uuidString: identifier)
        guard identifier.isEmpty || (scene.kind == .quantity && entryID != nil) else {
            throw LogbookError.message("Use a UUID for a quantity entry’s entry_id. Leave entry_id blank for completion.")
        }
        return .checkIn(CheckIn(sceneID: scene.id, day: day, value: value, note: values[3], entryID: entryID))
    }

    private static func account(_ values: [String], legacy: Bool, existing: Account?) throws -> Record {
        let name = values[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let currency = LedgerCurrency(rawValue: values[2]), let opened = MonthKey(rawValue: values[3]) else {
            throw LogbookError.message("Enter an account name, a valid ISO currency code, and an opening month (YYYY-MM).")
        }
        let closed = MonthKey(rawValue: values[4])
        guard values[4].isEmpty || (closed.map { $0 >= opened } ?? false) else {
            throw LogbookError.message("The closing month must be on or after the opening month.")
        }
        var color = existing?.color
        if !legacy {
            let hex = values[5].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard hex.isEmpty || LogbookColor.isValidHex(hex) else {
                throw LogbookError.message("Enter a six-digit hex color such as #237F69.")
            }
            color = hex.isEmpty ? nil : hex
        }
        return .account(Account(id: values[0], name: name, currency: currency, opened: opened, closed: closed, color: color))
    }

    private static func balance(_ values: [String], account: Account) throws -> Record {
        guard let month = MonthKey(rawValue: values[1]), account.includes(month),
              let amount = account.currency.parse(values[2]) else {
            throw LogbookError.message("Enter a month within the account’s dates and a balance in \(account.currency.rawValue).")
        }
        return .balance(Balance(accountID: account.id, month: month, minorUnits: amount))
    }

    private static func legacyCategoryNames(in files: [String: String], library: Library) -> [String: String] {
        var names = library.legacyExpenseCategoryNames
        if let file = files[LogbookBackup.legacyCategoriesFile],
           let rows = try? CSV.decode(file), rows.first?.values == ["category_id", "name"] {
            for row in rows.dropFirst() where row.values.count == 2 {
                names[row.values[0]] = row.values[1]
            }
        }
        return names
    }

    private static func transaction(_ values: [String], existing: Record?, usesCategoryIDs: Bool,
                                    categoryNames: [String: String]) throws -> Record {
        guard let day = DayKey(rawValue: values[1]), let kind = TransactionKind(rawValue: values[2]),
              let currency = LedgerCurrency(rawValue: values[4]),
              let amount = currency.parse(values[3]), amount > 0 else {
            throw LogbookError.message("Enter a valid date, direction, positive amount, and currency.")
        }
        var item = Transaction(id: values[0], day: day, kind: kind, minorUnits: amount, currency: currency, note: values[6])
        if kind == .expense {
            if values.count == 7 {
                guard let method = LegacyPaymentMethod(rawValue: values[5]) else {
                    throw LogbookError.message("Enter a valid legacy payment method.")
                }
                item.paymentMethod = method.label
                item.settlesNextMonth = method == .creditCard
            } else {
                let settlement = values[7].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard settlement.isEmpty || settlement == "true" || settlement == "false" else {
                    throw LogbookError.message("Use true, false, or a blank value for settles_next_month.")
                }
                item.paymentMethod = values[5].trimmingCharacters(in: .whitespacesAndNewlines)
                item.settlesNextMonth = settlement == "true"
            }
            if values.count == CSVKind.transactions.columns.count {
                let category = values[8].trimmingCharacters(in: .whitespacesAndNewlines)
                if usesCategoryIDs, !category.isEmpty {
                    guard let name = categoryNames[values[8]] else {
                        throw LogbookError.message("Category \(category) was not found. Restore the original backup or use a category column with names.")
                    }
                    item.category = name
                } else {
                    item.category = category
                }
            } else if case .transaction(let saved) = existing {
                item.category = saved.category
            }
        } else if values.count == CSVKind.transactions.columns.count,
                  !values[8].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LogbookError.message("Leave the category blank for income.")
        }
        guard item.postingMonth.index <= 119_999 else {
            throw LogbookError.message("Choose a date with a posting month before year 10000.")
        }
        return .transaction(item)
    }
}
