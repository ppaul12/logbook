import Foundation
import Observation

struct StrengthExercise: Codable, Equatable, Identifiable, Sendable {
    static let restRange = 0...3600

    enum Phase: String, Codable, CaseIterable, Sendable {
        case warmup, cooldown

        var title: String {
            switch self {
            case .warmup: "Warm-up"
            case .cooldown: "Cool-down"
            }
        }
    }

    var id = UUID()
    var name: String
    var targetSets = 2
    var restSeconds = 60
    var targetReps: Int?
    var muscleGroup: String?
    var notes: String?
    var phase: Phase?

    static func numbers(for phases: [Phase?]) -> [Int?] {
        var number = 0
        return phases.map { phase in
            guard phase == nil else { return nil }
            number += 1
            return number
        }
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LogbookError.message("Enter a name for each exercise.")
        }
        guard (1...30).contains(targetSets), Self.restRange.contains(restSeconds) else {
            throw LogbookError.message("Use 1 to 30 sets and 0 to 3600 seconds of rest per exercise.")
        }
        if let targetReps, targetReps <= 0 {
            throw LogbookError.message("Use a positive whole number for reps per set.")
        }
    }
}

struct StrengthPlan: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var exercises: [StrengthExercise]

    var targetSets: Int { exercises.reduce(0) { $0 + $1.targetSets } }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LogbookError.message("Enter a plan name.")
        }
        guard !exercises.isEmpty, Set(exercises.map(\.id)).count == exercises.count else {
            throw LogbookError.message("A plan needs at least one exercise, with a distinct entry for each exercise.")
        }
        for exercise in exercises { try exercise.validate() }
    }
}

struct StrengthSet: Codable, Equatable, Sendable {
    var reps: Int?
    var weight: Double?

    func validate() throws {
        if let reps, reps <= 0 { throw LogbookError.message("Enter a positive whole number of reps.") }
        if let weight, !weight.isFinite || weight < 0 {
            throw LogbookError.message("Enter a nonnegative weight.")
        }
    }
}

extension StrengthSet {
    init(repsText: String, weightText: String, locale: Locale = .autoupdatingCurrent) throws {
        let repsText = repsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let weightText = weightText.trimmingCharacters(in: .whitespacesAndNewlines)
        reps = Int(repsText)
        guard repsText.isEmpty || reps != nil else {
            throw LogbookError.message("Enter a positive whole number of reps.")
        }

        if !weightText.isEmpty {
            let scanner = Scanner(string: weightText)
            scanner.locale = locale
            scanner.charactersToBeSkipped = nil
            weight = Double(weightText)
            if weight == nil, let localized = scanner.scanDouble(), scanner.isAtEnd {
                weight = localized
            }
            guard weight != nil else { throw LogbookError.message("Enter a nonnegative weight.") }
        }
        try validate()
    }
}

struct StrengthSession: Codable, Equatable, Identifiable, Sendable {
    struct SetPosition {
        let index: Int
        let exercise: StrengthExercise
        let number: Int
    }

    var id = UUID()
    let plan: StrengthPlan
    let startedAt: Date
    let day: DayKey
    let timeZoneID: String
    var completedSets: [StrengthSet] = []
    var restDeadline: Date?
    var finishedAt: Date?

    var nextSet: SetPosition? { setPosition(at: completedSets.count) }

    var checkInNote: String { "Fitness: \(plan.name)" }

    var checkInDays: [DayKey] {
        guard let finishedAt, let timeZone = TimeZone(identifier: timeZoneID) else { return [day] }
        let finishDay = DayKey(finishedAt, in: timeZone)
        return finishDay == day ? [day] : [day, finishDay]
    }

    func checkInDateOptions(through today: DayKey) -> [DayKey] {
        let days = checkInDays
        let available = days.filter { $0 <= today }
        return available.count == days.count || available.contains(today) ? available : available + [today]
    }

    var displayedSet: SetPosition? {
        if restDeadline == nil, let nextSet { return nextSet }
        return setPosition(at: completedSets.count - 1)
    }

    private func setPosition(at index: Int) -> SetPosition? {
        guard index >= 0 else { return nil }
        var remaining = index
        for exercise in plan.exercises {
            if remaining < exercise.targetSets {
                return SetPosition(index: index, exercise: exercise, number: remaining + 1)
            }
            remaining -= exercise.targetSets
        }
        return nil
    }

    func sets(for exerciseID: UUID) -> ArraySlice<StrengthSet> {
        var offset = 0
        for exercise in plan.exercises {
            if exercise.id == exerciseID {
                return completedSets.dropFirst(offset).prefix(exercise.targetSets)
            }
            offset += exercise.targetSets
        }
        return completedSets.prefix(0)
    }

    func validate() throws {
        try plan.validate()
        guard completedSets.count <= plan.targetSets, startedAt.timeIntervalSinceReferenceDate.isFinite,
              TimeZone(identifier: timeZoneID) != nil else {
            throw LogbookError.message("This training session has invalid progress or dates.")
        }
        if let finishedAt {
            guard finishedAt.timeIntervalSinceReferenceDate.isFinite, finishedAt >= startedAt,
                  !completedSets.isEmpty, restDeadline == nil else {
                throw LogbookError.message("A saved training session needs completed sets and a valid end time.")
            }
        }
        if let restDeadline {
            guard restDeadline.timeIntervalSinceReferenceDate.isFinite, !completedSets.isEmpty, nextSet != nil else {
                throw LogbookError.message("A rest timer requires a completed set and a set still to do.")
            }
        }
        try completedSets.forEach { try $0.validate() }
    }
}

@MainActor
@Observable
final class StrengthRestTimer {
    private let onAlarmChange: @MainActor (Bool) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    private var deadline: ContinuousClock.Instant?
    private(set) var isRinging = false

    init(onAlarmChange: @escaping @MainActor (Bool) -> Void) {
        self.onAlarmChange = onAlarmChange
    }

    var remainingSeconds: Int {
        let now = ContinuousClock.now
        guard let deadline, deadline > now else { return 0 }
        let remaining = now.duration(to: deadline).components
        return Int(remaining.seconds) + (remaining.attoseconds > 0 ? 1 : 0)
    }

    var overtimeSeconds: Int {
        guard let deadline else { return 0 }
        return Int(max(0, deadline.duration(to: .now).components.seconds))
    }

    func replaceDeadline(with date: Date?) {
        task?.cancel()
        task = nil
        guard let date else {
            deadline = nil
            setRinging(false)
            return
        }
        // The saved Date allows reopening the app. Use a monotonic clock while it runs.
        let remaining = min(max(date.timeIntervalSinceNow, -Double(Int32.max)), Double(StrengthExercise.restRange.upperBound))
        let deadline = ContinuousClock.now.advanced(by: .seconds(remaining))
        self.deadline = deadline
        setRinging(remaining <= 0)
        guard remaining > 0 else { return }
        task = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(until: deadline, tolerance: .zero)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.deadline == deadline else { return }
            self.task = nil
            self.setRinging(true)
        }
    }

    private func setRinging(_ ringing: Bool) {
        guard isRinging != ringing else { return }
        isRinging = ringing
        onAlarmChange(ringing)
    }
}
