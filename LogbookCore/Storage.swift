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
    let strengthRestTimer: StrengthRestTimer

    init(url: URL? = nil, inMemory: Bool = false, defaults: UserDefaults = .standard,
         onStrengthRestAlarmChange: @escaping @MainActor (Bool) -> Void = { _ in }) throws {
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
        strengthRestTimer = StrengthRestTimer(onAlarmChange: onStrengthRestAlarmChange)
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
        strengthRestTimer.replaceDeadline(with: library.activeStrengthSession?.restDeadline)
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
        try validateStrengthChanges(changes, restoringBackup: restoringBackup)
        try commit(Array(changes.values), preferences: preferences)
    }

    var strengthPlans: [StrengthPlan] {
        let plans = library.strengthPlans
        guard !preferences.strengthPlanOrder.isEmpty else { return plans }
        var remaining = Dictionary(uniqueKeysWithValues: plans.map { ($0.id, $0) })
        let ordered = preferences.strengthPlanOrder.compactMap { remaining.removeValue(forKey: $0) }
        return ordered + plans.filter { remaining[$0.id] != nil }
    }

    var defaultStrengthCheckInScene: CheckInScene? {
        guard let id = preferences.strengthCheckInSceneID, let scene = library.scene(id: id),
              !scene.archived else { return nil }
        return scene
    }

    func moveStrengthPlan(_ id: UUID, to targetID: UUID?) throws {
        var order = strengthPlans.map(\.id)
        guard let source = order.firstIndex(of: id) else { return }
        let destination: Int
        if let targetID {
            guard let targetIndex = order.firstIndex(of: targetID) else { return }
            destination = targetIndex
        } else {
            destination = order.count - 1
        }
        guard source != destination else { return }
        order.remove(at: source)
        order.insert(id, at: destination)
        var updated = preferences
        updated.strengthPlanOrder = order
        try save(preferences: updated)
    }

    func saveStrengthPlan(_ draft: StrengthPlan) throws {
        var plan = draft
        plan.name = plan.name.trimmingCharacters(in: .whitespacesAndNewlines)
        for index in plan.exercises.indices {
            plan.exercises[index].name = plan.exercises[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var updated = preferences
        if !updated.strengthPlanOrder.isEmpty, library.strengthPlan(id: plan.id) == nil {
            updated.strengthPlanOrder = strengthPlans.map(\.id) + [plan.id]
        }
        try save([.strengthPlan(plan)], preferences: updated)
    }

    func deleteStrengthPlan(_ plan: StrengthPlan) throws {
        guard let saved = library.strengthPlan(id: plan.id) else { return }
        guard saved == plan else {
            throw LogbookError.message("This plan has changed. Review it again before deleting.")
        }
        var updated = preferences
        updated.strengthPlanOrder.removeAll { $0 == saved.id }
        try save(removing: [Record.strengthPlan(saved).key], preferences: updated)
    }

    @discardableResult
    func startStrengthSession(planID: UUID) throws -> StrengthSession {
        guard library.activeStrengthSession == nil else {
            throw LogbookError.message("Resume or end the current training session first.")
        }
        guard let plan = library.strengthPlan(id: planID) else {
            throw LogbookError.message("This training plan is no longer available.")
        }
        let startedAt = Date.now
        let timeZone = preferences.timeZone
        let session = StrengthSession(plan: plan, startedAt: startedAt, day: DayKey(startedAt, in: timeZone),
                                      timeZoneID: timeZone.identifier)
        try save([.strengthSession(session)])
        return session
    }

    func completeStrengthSet(sessionID: UUID, index: Int, result: StrengthSet, restSeconds: Int? = nil) throws {
        var session = try currentStrengthSession(id: sessionID, completedCount: index)
        guard let next = session.nextSet else {
            throw LogbookError.message("All sets in this training session are complete.")
        }
        guard session.restDeadline == nil else {
            throw LogbookError.message("End the rest timer or stop its alarm before recording the next set.")
        }
        session.completedSets.append(result)
        let seconds = restSeconds ?? next.exercise.restSeconds
        let deadline = try strengthRestDeadline(seconds: seconds)
        session.restDeadline = session.nextSet != nil && seconds > 0 ? deadline : nil
        try save([.strengthSession(session)])
    }

    func changeStrengthRest(sessionID: UUID, completedCount: Int, seconds: Int) throws {
        var session = try currentStrengthSession(id: sessionID, completedCount: completedCount)
        guard session.restDeadline != nil, !strengthRestTimer.isRinging else {
            throw LogbookError.message("The rest countdown is no longer running.")
        }
        session.restDeadline = try strengthRestDeadline(seconds: seconds)
        try save([.strengthSession(session)])
    }

    private func strengthRestDeadline(seconds: Int) throws -> Date {
        guard StrengthExercise.restRange.contains(seconds) else {
            throw LogbookError.message("Choose a rest time between 0 and 3600 seconds.")
        }
        return Date.now.addingTimeInterval(Double(seconds))
    }

    func endStrengthRest(sessionID: UUID, completedCount: Int) throws {
        var session = try currentStrengthSession(id: sessionID, completedCount: completedCount)
        session.restDeadline = nil
        try save([.strengthSession(session)])
    }

    @discardableResult
    func finishStrengthSession(sessionID: UUID, completedCount: Int) throws -> StrengthSession {
        var session = try currentStrengthSession(id: sessionID, completedCount: completedCount)
        session.finishedAt = max(.now, session.startedAt)
        session.restDeadline = nil
        try session.validate()
        try save(removing: [Record.strengthSession(session).key])
        return session
    }

    @discardableResult
    func addStrengthCheckIn(to scene: CheckInScene, on day: DayKey, quantity: String = "", note: String,
                           entryID: UUID = UUID()) throws -> Bool {
        guard let current = library.scene(id: scene.id), !current.archived else {
            throw LogbookError.message("This scene is no longer available. Choose another scene.")
        }
        guard current.kind == scene.kind, current.unit == scene.unit else {
            throw LogbookError.message("The scene changed. Review its current check-in fields and try again.")
        }
        guard day <= preferences.today else {
            throw LogbookError.message("Choose a date that has already started in Heatmaps.")
        }

        if scene.kind == .completion {
            guard library.checkIn(for: scene.id, on: day) == nil else { return false }
            try save([.checkIn(CheckIn(sceneID: scene.id, day: day, value: 1, note: note))])
        } else {
            guard let value = CheckIn.parseQuantity(quantity) else {
                throw LogbookError.message("Enter a nonnegative quantity.")
            }
            try save([.checkIn(CheckIn(sceneID: scene.id, day: day, value: value, note: note, entryID: entryID))])
        }
        return true
    }

    func discardStrengthSession(sessionID: UUID, completedCount: Int) throws {
        let session = try currentStrengthSession(id: sessionID, completedCount: completedCount)
        try save(removing: [Record.strengthSession(session).key])
    }

    private func currentStrengthSession(id: UUID, completedCount: Int) throws -> StrengthSession {
        guard let session = library.activeStrengthSession, session.id == id,
              session.completedSets.count == completedCount else {
            throw LogbookError.message("The training session has changed. Review its current progress and try again.")
        }
        return session
    }

    private func validateStrengthChanges(_ changes: [String: VersionedRecord], restoringBackup: Bool) throws {
        var activeID: UUID?
        for change in changes.values {
            switch change.value {
            case .strengthPlan(let plan): try plan.validate()
            case .strengthSession(let session):
                try session.validate()
                if restoringBackup, session.finishedAt == nil || session.id == library.activeStrengthSession?.id {
                    throw LogbookError.message("Finish the current training session before restoring that record.")
                }
                if session.finishedAt == nil {
                    guard activeID == nil, library.activeStrengthSession.map({ $0.id == session.id }) ?? true else {
                        throw LogbookError.message("Only one training session can be in progress.")
                    }
                    activeID = session.id
                }
            default: break
            }
        }
    }

    func resetScene(_ sceneID: String) throws {
        try save(removing: library.checkInKeys(for: sceneID))
    }

    func deleteScene(_ sceneID: String) throws {
        var updated = preferences
        if updated.strengthCheckInSceneID == sceneID { updated.strengthCheckInSceneID = nil }
        try save(removing: library.checkInKeys(for: sceneID) + ["scene/\(sceneID)"], preferences: updated)
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
        if !changes.isEmpty {
            let previousRest = library.activeStrengthSession?.restDeadline
            library = Library(versions.values.compactMap(\.value))
            let currentRest = library.activeStrengthSession?.restDeadline
            if previousRest != currentRest { strengthRestTimer.replaceDeadline(with: currentRest) }
        }
        if let newPreferences { self.preferences = newPreferences }
        generation += 1
    }
}
