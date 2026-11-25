import Foundation
import Testing
@testable import LogbookCore

@Test func olderStrengthExercisesDecodeWithoutRepsOrNotes() throws {
    let legacy = """
    {"id":"908447B9-4ABD-4424-B733-91D189EDF119","name":"Row","targetSets":2,"restSeconds":60}
    """
    let exercise = try JSONDecoder().decode(StrengthExercise.self, from: Data(legacy.utf8))
    #expect(exercise.targetSets == 2)
    #expect(exercise.restSeconds == 60)
    #expect(exercise.targetReps == nil)
    #expect(exercise.muscleGroup == nil)
    #expect(exercise.notes == nil)
    #expect(exercise.phase == nil)
    var plan = StrengthPlan(name: "Upper Body", exercises: [exercise])
    try plan.validate()
    plan.exercises[0].targetReps = 0
    #expect(throws: LogbookError.self) { try plan.validate() }
}

@Test func strengthExerciseNumbersSkipWarmupAndCooldown() throws {
    let exercises = [
        StrengthExercise(name: "Warm-up", phase: .warmup),
        StrengthExercise(name: "First lift"),
        StrengthExercise(name: "Cool-down", phase: .cooldown),
        StrengthExercise(name: "Second lift")
    ]
    #expect(StrengthExercise.numbers(for: exercises.map(\.phase)) == [nil, 1, nil, 2])
    #expect(StrengthExercise.numbers(for: exercises.reversed().map(\.phase)) == [1, nil, 2, nil])
    let decoded = try JSONDecoder().decode([StrengthExercise].self, from: JSONEncoder().encode(exercises))
    #expect(decoded == exercises)
}

@Test func strengthSetWeightRequiresACompleteNumberAndAcceptsLocalizedDecimals() throws {
    let locale = Locale(identifier: "de_DE")
    #expect(try StrengthSet(repsText: "8", weightText: "22,5", locale: locale) == StrengthSet(reps: 8, weight: 22.5))
    #expect(try StrengthSet(repsText: "", weightText: "0", locale: locale) == StrengthSet(weight: 0))
    #expect(throws: LogbookError.self) { try StrengthSet(repsText: "", weightText: "25 kg", locale: locale) }
    #expect(throws: LogbookError.self) { try StrengthSet(repsText: "", weightText: "-1", locale: locale) }
}

@MainActor
@Test func strengthSetsRestBetweenActionsAndKeepTheOriginalPlanInFinishSummary() throws {
    var alarmUpdates: [Bool] = []
    let store = try LogbookStore(inMemory: true) { alarmUpdates.append($0) }
    var plan = StrengthPlan(name: "Upper Body", exercises: [
        StrengthExercise(name: "Dumbbell Press", targetSets: 1, restSeconds: 90, targetReps: 10,
                         muscleGroup: "Chest", notes: "Slow eccentric"),
        StrengthExercise(name: "Row", targetSets: 1, restSeconds: 60)
    ])
    try store.saveStrengthPlan(plan)
    let session = try store.startStrengthSession(planID: plan.id)
    let first = try #require(session.nextSet)
    try store.completeStrengthSet(sessionID: session.id, index: first.index,
                                  result: StrengthSet(reps: 8, weight: 20))
    #expect(store.strengthRestTimer.remainingSeconds > 0)
    #expect(store.strengthRestTimer.remainingSeconds <= 90)
    let resting = try #require(store.library.activeStrengthSession)
    #expect(resting.nextSet?.exercise.name == "Row")
    #expect(resting.displayedSet?.exercise.name == "Dumbbell Press")
    #expect(resting.displayedSet?.number == 1)
    #expect(throws: LogbookError.self) {
        try store.completeStrengthSet(sessionID: session.id, index: first.index, result: StrengthSet())
    }
    try store.endStrengthRest(sessionID: session.id, completedCount: resting.completedSets.count)
    #expect(store.library.activeStrengthSession?.displayedSet?.exercise.name == "Row")
    #expect(alarmUpdates.isEmpty)

    plan.name = "Renamed"
    plan.exercises = [StrengthExercise(name: "Push-up", targetSets: 1, restSeconds: 0)]
    try store.saveStrengthPlan(plan)
    let second = try #require(resting.nextSet)
    try store.completeStrengthSet(sessionID: session.id, index: second.index, result: StrengthSet())
    let completed = try #require(store.library.activeStrengthSession)
    #expect(completed.nextSet == nil)
    #expect(completed.restDeadline == nil)
    #expect(store.strengthRestTimer.remainingSeconds == 0)
    let summary = try store.finishStrengthSession(sessionID: session.id, completedCount: completed.completedSets.count)
    #expect(alarmUpdates.isEmpty)
    #expect(store.library.activeStrengthSession == nil)
    #expect(store.library.strengthHistory.isEmpty)
    #expect(store.library.checkIns.isEmpty)
    #expect(summary.plan.name == "Upper Body")
    #expect(summary.plan.exercises.map(\.name) == ["Dumbbell Press", "Row"])
    #expect(summary.plan.exercises[0].targetReps == 10)
    #expect(summary.plan.exercises[0].muscleGroup == "Chest")
    #expect(summary.plan.exercises[0].notes == "Slow eccentric")
    #expect(summary.sets(for: summary.plan.exercises[0].id) == [StrengthSet(reps: 8, weight: 20)])
    #expect(summary.checkInNote == "Fitness: Upper Body")
}

@MainActor
@Test func strengthDraftAndRestDeadlineSurviveReopeningAndAllowPartialSave() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "Training.store")
    let plan = StrengthPlan(name: "Lower Body", exercises: [
        StrengthExercise(name: "Squat", targetSets: 3, restSeconds: 120)
    ])
    let id: UUID
    let deadline: Date?
    do {
        let store = try LogbookStore(url: url)
        try store.saveStrengthPlan(plan)
        let session = try store.startStrengthSession(planID: plan.id)
        id = session.id
        #expect(throws: LogbookError.self) { try store.startStrengthSession(planID: plan.id) }
        #expect(throws: LogbookError.self) { try store.finishStrengthSession(sessionID: id, completedCount: 0) }
        try store.completeStrengthSet(sessionID: id, index: 0, result: StrengthSet(reps: 10, weight: 0))
        deadline = store.library.activeStrengthSession?.restDeadline
    }
    var alarmUpdates: [Bool] = []
    let reopened = try LogbookStore(url: url) { alarmUpdates.append($0) }
    let draft = try #require(reopened.library.activeStrengthSession)
    #expect(draft.id == id)
    #expect(draft.restDeadline == deadline)
    #expect(reopened.strengthRestTimer.remainingSeconds > 0)
    #expect(draft.nextSet?.number == 2)
    #expect(draft.completedSets == [StrengthSet(reps: 10, weight: 0)])
    #expect(reopened.library.strengthHistory.isEmpty)
    let summary = try reopened.finishStrengthSession(sessionID: id, completedCount: 1)
    #expect(alarmUpdates.isEmpty)
    #expect(reopened.strengthRestTimer.remainingSeconds == 0)
    #expect(summary.completedSets.count == 1)
    #expect(reopened.library.strengthHistory.isEmpty)
    #expect(reopened.library.activeStrengthSession == nil)

    let restarted = try reopened.startStrengthSession(planID: plan.id)
    try reopened.completeStrengthSet(sessionID: restarted.id, index: 0, result: StrengthSet())
    var expired = try #require(reopened.library.activeStrengthSession)
    expired.restDeadline = .distantPast
    try reopened.save([.strengthSession(expired)])
    #expect(reopened.strengthRestTimer.isRinging)
    #expect(reopened.strengthRestTimer.overtimeSeconds > 0)
    try reopened.discardStrengthSession(sessionID: restarted.id, completedCount: 1)
    #expect(alarmUpdates == [true, false])
}

@MainActor
@Test func strengthRestAlarmRequiresAcknowledgementAndZeroRestIsImmediatelyReady() async throws {
    var alarmUpdates: [Bool] = []
    let store = try LogbookStore(inMemory: true) { alarmUpdates.append($0) }
    let plan = StrengthPlan(name: "Circuit", exercises: [
        StrengthExercise(name: "Squat", targetSets: 1, restSeconds: 1),
        StrengthExercise(name: "Lunge", targetSets: 2, restSeconds: 0)
    ])
    try store.saveStrengthPlan(plan)
    let session = try store.startStrengthSession(planID: plan.id)
    #expect(throws: LogbookError.self) {
        try store.completeStrengthSet(sessionID: session.id, index: 0, result: StrengthSet(), restSeconds: -1)
    }
    try store.completeStrengthSet(sessionID: session.id, index: 0, result: StrengthSet(), restSeconds: 20)
    #expect(store.strengthRestTimer.remainingSeconds > 1)
    #expect(store.library.activeStrengthSession?.plan.exercises.first?.restSeconds == 1)
    try store.changeStrengthRest(sessionID: session.id, completedCount: 1, seconds: 1)
    #expect(throws: LogbookError.self) {
        try store.completeStrengthSet(sessionID: session.id, index: 1, result: StrengthSet())
    }
    try await Task.sleep(for: .milliseconds(1_150))
    #expect(store.strengthRestTimer.remainingSeconds == 0)
    #expect(store.strengthRestTimer.isRinging)
    #expect(store.library.activeStrengthSession?.displayedSet?.exercise.name == "Squat")
    #expect(alarmUpdates == [true])
    #expect(throws: LogbookError.self) {
        try store.changeStrengthRest(sessionID: session.id, completedCount: 1, seconds: 1)
    }
    #expect(throws: LogbookError.self) {
        try store.completeStrengthSet(sessionID: session.id, index: 1, result: StrengthSet())
    }
    try store.endStrengthRest(sessionID: session.id, completedCount: 1)
    #expect(!store.strengthRestTimer.isRinging)
    #expect(store.strengthRestTimer.overtimeSeconds == 0)
    #expect(alarmUpdates == [true, false])
    try store.completeStrengthSet(sessionID: session.id, index: 1, result: StrengthSet())
    #expect(store.strengthRestTimer.remainingSeconds == 0)
    #expect(store.library.activeStrengthSession?.nextSet?.number == 2)
}

@MainActor
@Test func deletingStrengthPlanKeepsItsSavedAndInProgressTraining() throws {
    let store = try LogbookStore(inMemory: true)
    var plan = StrengthPlan(name: "Upper Body", exercises: [StrengthExercise(name: "Row", targetSets: 1)])
    let another = StrengthPlan(name: "Lower Body", exercises: [StrengthExercise(name: "Squat")])
    try store.saveStrengthPlan(plan)
    try store.saveStrengthPlan(another)
    let completed = try store.startStrengthSession(planID: plan.id)
    try store.completeStrengthSet(sessionID: completed.id, index: 0, result: StrengthSet(reps: 8))
    let legacy = try store.finishStrengthSession(sessionID: completed.id, completedCount: 1)
    try store.save([.strengthSession(legacy)], restoringBackup: true)
    let active = try store.startStrengthSession(planID: plan.id)
    let stale = plan
    plan.name = "Updated plan"
    try store.saveStrengthPlan(plan)
    #expect(throws: LogbookError.self) { try store.deleteStrengthPlan(stale) }
    #expect(store.library.strengthPlan(id: plan.id) == plan)

    try store.deleteStrengthPlan(plan)
    #expect(store.library.strengthPlans == [another])
    #expect(store.library.activeStrengthSession == active)
    #expect(store.library.strengthHistory.first?.plan == stale)
    try store.completeStrengthSet(sessionID: active.id, index: 0, result: StrengthSet())
    let summary = try store.finishStrengthSession(sessionID: active.id, completedCount: 1)
    #expect(summary.plan == stale)
    #expect(store.library.strengthHistory == [legacy])
    #expect(throws: LogbookError.self) { try store.startStrengthSession(planID: plan.id) }
    try store.deleteStrengthPlan(plan)
}

@MainActor
@Test func strengthPlanOrderSurvivesReopeningAndKeepsNewPlansAtTheEnd() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "Training.store")
    let upper = StrengthPlan(name: "Upper", exercises: [StrengthExercise(name: "Press")])
    let lower = StrengthPlan(name: "Lower", exercises: [StrengthExercise(name: "Squat")])
    let core = StrengthPlan(name: "Core", exercises: [StrengthExercise(name: "Plank")])

    do {
        let store = try LogbookStore(url: url)
        try store.saveStrengthPlan(upper)
        try store.saveStrengthPlan(lower)
        #expect(store.strengthPlans == [lower, upper])
        try store.moveStrengthPlan(upper.id, to: lower.id)
        #expect(store.strengthPlans == [upper, lower])
        try store.saveStrengthPlan(core)
        #expect(store.strengthPlans == [upper, lower, core])
    }

    let store = try LogbookStore(url: url)
    #expect(store.strengthPlans == [upper, lower, core])
    try store.moveStrengthPlan(upper.id, to: nil)
    #expect(store.strengthPlans == [lower, core, upper])
    try store.deleteStrengthPlan(core)
    #expect(store.strengthPlans == [lower, upper])
    #expect(!store.preferences.strengthPlanOrder.contains(core.id))
}

@MainActor
@Test func strengthBackupRestoresPlansAndHistoryThroughImportPreview() throws {
    let store = try LogbookStore(inMemory: true)
    let plan = StrengthPlan(name: "Workout", exercises: [
        StrengthExercise(name: "Squat", restSeconds: 0, targetReps: 12,
                         muscleGroup: "Legs", notes: "Pause at the bottom")
    ])
    try store.saveStrengthPlan(plan)
    let session = try store.startStrengthSession(planID: plan.id)
    try store.completeStrengthSet(sessionID: session.id, index: 0, result: StrengthSet(reps: 8, weight: 15))
    let legacy = try store.finishStrengthSession(sessionID: session.id, completedCount: 1)
    try store.save([.strengthSession(legacy)], restoringBackup: true)
    try store.startStrengthSession(planID: plan.id)

    let backup = try LogbookBackup(library: store.library, preferences: store.preferences)
    let decoded = try LogbookBackup.read(JSONEncoder().encode(backup))
    let restored = try LogbookStore(inMemory: true)
    let preview = ImportPreview(backup: decoded, library: restored.library)
    #expect(preview.count(.new) == 2)
    try restored.save(preview.changes(choices: [:]), restoringBackup: true)
    #expect(restored.library.strengthPlans == [plan])
    #expect(restored.library.strengthHistory == store.library.strengthHistory)
    #expect(restored.library.activeStrengthSession == nil)
    let retry = ImportPreview(backup: decoded, library: restored.library)
    #expect(retry.count(.duplicate) == 2)
    #expect(try retry.changes(choices: [:]).isEmpty)
}

@Test func fitnessCheckInDatesUseTheTrainingTimeZoneAcrossMidnight() throws {
    let plan = StrengthPlan(name: "脚", exercises: [StrengthExercise(name: "Squat")])
    let startDay = try #require(DayKey(rawValue: "2026-11-24"))
    let finishDay = startDay.adding(days: 1)
    let startedAt = startDay.date.addingTimeInterval(2 * 3_600 + 40 * 60)
    var session = StrengthSession(plan: plan, startedAt: startedAt, day: startDay, timeZoneID: "Asia/Tokyo")
    session.finishedAt = startedAt.addingTimeInterval(15 * 60)
    #expect(session.checkInDays == [startDay])
    session.finishedAt = startedAt.addingTimeInterval(30 * 60)
    #expect(session.checkInDays == [startDay, finishDay])
    #expect(session.checkInDateOptions(through: finishDay) == [startDay, finishDay])
    #expect(session.checkInDateOptions(through: startDay) == [startDay])
    let heatmapsToday = startDay.adding(days: -1)
    #expect(session.checkInDateOptions(through: heatmapsToday) == [heatmapsToday])
    #expect(session.checkInNote == "Fitness: 脚")
}

@MainActor
@Test func defaultFitnessSceneCanBeRestoredAndOnlyResolvesToAnActiveScene() throws {
    let store = try LogbookStore(inMemory: true)
    var scene = CheckInScene(name: "Movement")
    #expect(store.defaultStrengthCheckInScene == nil)
    try store.save([.scene(scene)])
    var preferences = store.preferences
    preferences.strengthCheckInSceneID = scene.id
    try store.save(preferences: preferences)
    #expect(store.defaultStrengthCheckInScene == scene)
    let backup = try LogbookBackup(library: store.library, preferences: store.preferences)
    let decoded = try LogbookBackup.read(JSONEncoder().encode(backup))
    #expect(decoded.preferences.strengthCheckInSceneID == scene.id)
    let legacy = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(Preferences()))
    #expect(legacy.strengthCheckInSceneID == nil)

    scene.archived = true
    try store.save([.scene(scene)])
    #expect(store.defaultStrengthCheckInScene == nil)
    try store.deleteScene(scene.id)
    #expect(store.preferences.strengthCheckInSceneID == nil)
}

@MainActor
@Test func fitnessCheckInPreservesExistingCompletionAndAddsIndependentQuantities() throws {
    let store = try LogbookStore(inMemory: true)
    let day = store.preferences.today
    let completion = CheckInScene(name: "Movement")
    let quantity = CheckInScene(name: "Training Minutes", kind: .quantity, unit: "min", maximum: 30)
    try store.save([.scene(completion), .scene(quantity)])

    #expect(try store.addStrengthCheckIn(to: completion, on: day, note: "Fitness: Upper Body"))
    #expect(try !store.addStrengthCheckIn(to: completion, on: day, note: "Fitness: Lower Body"))
    #expect(store.library.checkIn(for: completion.id, on: day)?.note == "Fitness: Upper Body")
    #expect(throws: LogbookError.self) {
        try store.addStrengthCheckIn(to: completion, on: day.adding(days: 1), note: "Fitness: Upper Body")
    }

    let entryID = UUID()
    #expect(try store.addStrengthCheckIn(to: quantity, on: day, quantity: "45", note: "Fitness: Upper Body",
                                        entryID: entryID))
    #expect(try store.addStrengthCheckIn(to: quantity, on: day, quantity: "45", note: "Fitness: Upper Body",
                                        entryID: entryID))
    #expect(try store.addStrengthCheckIn(to: quantity, on: day, quantity: "45", note: "Fitness: Upper Body"))
    #expect(try store.addStrengthCheckIn(to: quantity, on: day, quantity: "0", note: "Edited note"))
    let summary = try #require(store.library.checkInDay(for: quantity.id, on: day))
    #expect(summary.total == 90)
    #expect(summary.entries.count == 3)
    #expect(throws: LogbookError.self) {
        try store.addStrengthCheckIn(to: quantity, on: day, quantity: "", note: "")
    }
    var edited = quantity
    edited.unit = "sets"
    try store.save([.scene(edited)])
    #expect(throws: LogbookError.self) {
        try store.addStrengthCheckIn(to: quantity, on: day, quantity: "5", note: "")
    }
    edited.archived = true
    try store.save([.scene(edited)])
    #expect(throws: LogbookError.self) {
        try store.addStrengthCheckIn(to: edited, on: day, quantity: "5", note: "")
    }
}
