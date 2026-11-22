import Foundation
import Observation
import SwiftData

@Model
final class StoredRecord {
    @Attribute(.unique) var key: String
    var data: Data

    init(key: String, data: Data) {
        self.key = key
        self.data = data
    }
}

@MainActor
@Observable
final class LogbookStore {
    private static let preferencesKey = "preferences"
    private let container: ModelContainer
    private let context: ModelContext
    private var rows: [String: StoredRecord]
    private var versions: [String: VersionedRecord]
    private(set) var library: Library
    private(set) var preferences: Preferences
    private(set) var generation = 0

    init(url: URL? = nil, inMemory: Bool = false, defaults: UserDefaults = .standard) throws {
        let schema = Schema([StoredRecord.self])
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, groupContainer: .none, cloudKitDatabase: .none)
        }
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let rows = try context.fetch(FetchDescriptor<StoredRecord>())
        let decoder = JSONDecoder()
        let storedVersions = try rows.filter { $0.key != Self.preferencesKey }.map {
            try decoder.decode(VersionedRecord.self, from: $0.data)
        }
        var loadedLibrary = Library(storedVersions.compactMap(\.value))
        let categoryNames = loadedLibrary.legacyExpenseCategoryNames
        let versions = storedVersions.map { stored in
            guard case .transaction(var entry)? = stored.value, let id = entry.categoryID else { return stored }
            if entry.category.isEmpty { entry.category = categoryNames[id] ?? "" }
            entry.categoryID = nil
            var migrated = stored
            migrated.value = .transaction(entry)
            loadedLibrary.set(.transaction(entry))
            return migrated
        }
        self.container = container
        self.context = context
        self.rows = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
        self.versions = Dictionary(uniqueKeysWithValues: versions.map { ($0.key, $0) })
        library = loadedLibrary
        if let data = rows.first(where: { $0.key == Self.preferencesKey })?.data {
            preferences = try decoder.decode(Preferences.self, from: data)
        } else {
            let currency = defaults.string(forKey: "defaultCurrency").flatMap(LedgerCurrency.init(rawValue:))
            let initial = Preferences(defaultCurrency: currency ?? .jpy)
            preferences = initial
            let row = StoredRecord(key: Self.preferencesKey, data: try JSONEncoder().encode(initial))
            context.insert(row)
            try context.save()
            self.rows[Self.preferencesKey] = row
        }
    }

    func save(_ records: [Record] = [], removing keys: [String] = [], preferences: Preferences? = nil,
              restoringBackup: Bool = false) throws {
        var changes: [String: VersionedRecord] = [:]
        for record in records where versions[record.key]?.value != record {
            if !restoringBackup, case .transaction(let entry) = record {
                try entry.validateNote()
            }
            changes[record.key] = try nextVersion(key: record.key, value: record)
        }
        for key in keys where versions[key]?.value != nil {
            changes[key] = try nextVersion(key: key, value: nil)
        }
        try validateCheckInChanges(changes)
        try validateBalanceChanges(changes)
        try commit(Array(changes.values), preferences: preferences)
    }

    func resetScene(_ sceneID: String) throws {
        try save(removing: library.checkInKeys(for: sceneID))
    }

    func deleteScene(_ sceneID: String) throws {
        try save(removing: library.checkInKeys(for: sceneID) + ["scene/\(sceneID)"])
    }

    func resetAccount(_ accountID: String) throws {
        try save(removing: library.balanceKeys(for: accountID))
    }

    func deleteAccount(_ accountID: String) throws {
        try save(removing: library.balanceKeys(for: accountID) + ["account/\(accountID)"])
    }

    private func validateBalanceChanges(_ changes: [String: VersionedRecord]) throws {
        for change in changes.values {
            if case .balance(let snapshot)? = change.value {
                let key = "account/\(snapshot.accountID)"
                let parent = changes[key] ?? versions[key]
                guard case .account(let account)? = parent?.value, account.includes(snapshot.month) else {
                    throw LogbookError.message("The balance no longer matches a saved account.")
                }
            } else if change.value == nil, case .account(let account)? = versions[change.key]?.value,
                      library.balanceKeys(for: account.id).contains(where: { changes[$0] == nil }) {
                throw LogbookError.message("Remove an account’s snapshots when deleting the account.")
            }
        }
    }

    private func validateCheckInChanges(_ changes: [String: VersionedRecord]) throws {
        for change in changes.values {
            if case .checkIn(let entry)? = change.value {
                let key = "scene/\(entry.sceneID)"
                let parent = changes[key] ?? versions[key]
                guard case .scene(let scene)? = parent?.value, scene.accepts(entry) else {
                    throw LogbookError.message("The check-in no longer matches a saved scene.")
                }
            } else if case .scene(let saved)? = versions[change.key]?.value {
                if case .scene(let updated)? = change.value, updated.kind != saved.kind,
                   library.firstCheckInDay(for: saved.id) != nil {
                    throw LogbookError.message("Reset this scene’s check-ins before changing its record type.")
                }
                if change.value == nil, library.checkInKeys(for: saved.id).contains(where: { changes[$0] == nil }) {
                    throw LogbookError.message("Remove this scene’s check-ins when deleting the scene.")
                }
            }
        }
    }

    private func nextVersion(key: String, value: Record?) throws -> VersionedRecord {
        let counter = versions[key]?.revision.counter ?? 0
        guard counter < Int64.max else { throw LogbookError.message("This record has reached its revision limit.") }
        return VersionedRecord(key: key, revision: Revision(counter: counter + 1, writer: UUID().uuidString), value: value)
    }

    private func commit(_ changes: [VersionedRecord], preferences: Preferences?) throws {
        let newPreferences = preferences == self.preferences ? nil : preferences
        guard !changes.isEmpty || newPreferences != nil else { return }
        let encoder = JSONEncoder()
        var data = try changes.map { ($0.key, try encoder.encode($0)) }
        if let newPreferences {
            data.append((Self.preferencesKey, try encoder.encode(newPreferences)))
        }

        var inserted: [String: StoredRecord] = [:]
        for (key, value) in data {
            if let row = rows[key] {
                row.data = value
            } else {
                let row = StoredRecord(key: key, data: value)
                context.insert(row)
                inserted[key] = row
            }
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        rows.merge(inserted) { existing, _ in existing }
        for change in changes { versions[change.key] = change }
        if !changes.isEmpty { library = Library(versions.values.compactMap(\.value)) }
        if let newPreferences { self.preferences = newPreferences }
        generation += 1
    }
}
