import AppKit
import Observation
import SwiftUI

struct StrengthTrainingNavigation {
    enum Page: Equatable { case gallery, plan(UUID), newPlan, workout }

    var page: Page = .gallery
    var drafts: [UUID: StrengthPlanDraft] = [:]
    var newPlanDraft: StrengthPlanDraft?

    var isEditingPlan: Bool {
        switch page {
        case .plan(let id): drafts[id] != nil
        case .newPlan: newPlanDraft != nil
        default: false
        }
    }
}

struct StrengthTrainingView: View {
    @Environment(LogbookStore.self) private var store
    @Binding var navigation: StrengthTrainingNavigation
    @State private var review: StrengthSession?
    @State private var historyDay: HistoryDay?
    @State private var discard: StrengthSession?
    @State private var deletingPlan: StrengthPlan?
    @State private var error: String?
    @State private var planDropTarget: PlanDropTarget?
    @State private var planCardFrames: [PlanDropTarget: CGRect] = [:]
    @State private var galleryViewport: CGRect = .zero

    private enum PlanDropTarget: Hashable {
        case card(UUID)
        case end
    }

    private struct HistoryDay: Identifiable {
        let scene: CheckInScene
        let day: DayKey
        var id: DayKey { day }
    }

    private var active: StrengthSession? { store.library.activeStrengthSession }
    private var plans: [StrengthPlan] { store.strengthPlans }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tint(Color(logbookHex: "#237F69"))
            .sheet(item: $review, onDismiss: {
                if navigation.page == .workout && active == nil {
                    navigation.page = .gallery
                }
            }) { session in
                StrengthFinishSheet(session: session, startTime: startTime(of: session))
            }
            .sheet(item: $historyDay) { selection in
                SceneDayEditor(scene: selection.scene, day: selection.day)
            }
            .sheet(item: $discard) { session in
                RemovalConfirmation(
                    title: "Cancel this training?",
                    message: "This will remove the session and any sets recorded in it.",
                    actionTitle: "Discard Training",
                    cancel: { discard = nil },
                    confirm: {
                        discard = nil
                        perform {
                            try store.discardStrengthSession(sessionID: session.id, completedCount: session.completedSets.count)
                            navigation.page = .plan(session.plan.id)
                        }
                    }
                )
            }
            .sheet(item: $deletingPlan) { plan in
                RemovalConfirmation(
                    title: "Delete \(plan.name)?",
                    message: "This removes the plan from Plans. In-progress training keeps its original details.",
                    actionTitle: "Delete Plan",
                    cancel: { deletingPlan = nil },
                    confirm: {
                        deletingPlan = nil
                        perform {
                            try store.deleteStrengthPlan(plan)
                            updateNavigation {
                                $0.drafts.removeValue(forKey: plan.id)
                                $0.page = .gallery
                            }
                        }
                    }
                )
            }
            .logbookError($error)
    }

    @ViewBuilder
    private var content: some View {
        switch navigation.page {
        case .gallery:
            gallery
        case .plan(let id):
            if let plan = store.library.strengthPlan(id: id) {
                planPage(plan, draft: navigation.drafts[id])
            } else {
                gallery
            }
        case .newPlan:
            if let draft = navigation.newPlanDraft {
                planPage(nil, draft: draft)
            } else {
                gallery
            }
        case .workout:
            if let session = active ?? review {
                detailPage { workoutPage(session) }
                    .toolbar { workoutToolbar(session) }
            } else {
                gallery
            }
        }
    }

    private var gallery: some View {
        let columns = [GridItem(.adaptive(minimum: 180), spacing: 14)]
        let plans = self.plans
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let scene = store.defaultStrengthCheckInScene {
                    TimelineView(.everyMinute) { context in
                        let today = DayKey(context.date, in: store.preferences.timeZone)
                        SceneHeatmap(scene: scene, today: today, title: Text(scene.name)) {
                            historyDay = HistoryDay(scene: scene, day: $0)
                        }
                    }
                    .id(scene.id)
                }

                VStack(alignment: .leading, spacing: 12) {
                    galleryHeading("Plans")
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                            planDropZone(.card(plan.id)) {
                                Button {
                                    navigation.page = .plan(plan.id)
                                } label: {
                                    planCard(plan)
                                }
                                .buttonStyle(StrengthGalleryCardStyle())
                                .overlay(alignment: .topTrailing) {
                                    planDragHandle(plan, index: index, in: plans)
                                        .padding(StrengthGalleryCardStyle.contentInset)
                                }
                            }
                        }
                        planDropZone(.end) {
                            Button(action: openNewPlan) {
                                VStack(spacing: 8) {
                                    Image(systemName: "plus")
                                        .font(.title2.weight(.medium))
                                        .foregroundStyle(.tint)
                                    Text(navigation.newPlanDraft == nil ? "New Plan" : "Resume New Plan")
                                        .font(.headline)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(StrengthGalleryCardStyle(isAddCard: true))
                        }
                    }
                }
            }
            .frame(maxWidth: 1120)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { galleryViewport = $0 }
        .onDisappear { planDropTarget = nil }
        .toolbar {
            if active != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Resume Training", systemImage: "play.fill") { navigation.page = .workout }
                        .help("Resume training")
                }
            }
        }
    }

    private func galleryHeading(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }

    private func planDragHandle(_ plan: StrengthPlan, index: Int, in plans: [StrengthPlan]) -> some View {
        let earlier = index > 0 ? plans[index - 1].id : nil
        let later = index + 1 < plans.count ? plans[index + 1].id : nil
        return ListDragHandle { point in
            let target = dropTarget(at: point)
            planDropTarget = target == .card(plan.id) ? nil : target
        } onDrop: { point in
            planDropTarget = nil
            switch dropTarget(at: point) {
            case .card(let targetID): movePlan(plan.id, to: targetID)
            case .end: movePlan(plan.id, to: nil)
            case nil: break
            }
        }
            .opacity(0.75)
            .frame(width: StrengthGalleryCardStyle.headerIconSize.width,
                   height: StrengthGalleryCardStyle.headerIconSize.height)
            .help("Drag to reorder")
            .accessibilityLabel("Reorder \(plan.name)")
            .accessibilityActions {
                if let earlier {
                    Button("Move Earlier") { movePlan(plan.id, to: earlier) }
                }
                if let later {
                    Button("Move Later") { movePlan(plan.id, to: later) }
                }
            }
    }

    private func planDropZone<Card: View>(_ target: PlanDropTarget, @ViewBuilder card: () -> Card) -> some View {
        card()
            .overlay {
                if planDropTarget == target {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.tint, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                planCardFrames[target] = $0
            }
            .onDisappear { planCardFrames.removeValue(forKey: target) }
    }

    private func dropTarget(at point: CGPoint) -> PlanDropTarget? {
        guard galleryViewport.contains(point) else { return nil }
        return planCardFrames.first { $0.value.contains(point) }?.key
    }

    private func movePlan(_ id: UUID, to targetID: UUID?) {
        perform { try store.moveStrengthPlan(id, to: targetID) }
    }

    private func planCard(_ plan: StrengthPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "dumbbell")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: StrengthGalleryCardStyle.headerIconSize.width,
                           height: StrengthGalleryCardStyle.headerIconSize.height)
                    .accessibilityHidden(true)
                if navigation.drafts[plan.id] != nil {
                    Spacer()
                    Text("Draft").font(.caption).foregroundStyle(.secondary)
                        .padding(.trailing, 30)
                }
            }
            Spacer(minLength: 4)
            Text(plan.name).font(.headline).lineLimit(1)
            Text(plan.exercises.map(\.name).joined(separator: " · "))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(strengthPlanSummary(exercises: plan.exercises.count, sets: plan.targetSets))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func planPage(_ plan: StrengthPlan?, draft: StrengthPlanDraft?) -> some View {
        StrengthPlanPane(
            plan: plan,
            draft: draft,
            startLabel: active == nil ? "Start Training" : "Resume Training",
            onBack: { navigation.page = .gallery },
            onEdit: { if let plan { openEditor(plan) } },
            onStart: { if let plan { startTraining(plan) } },
            onDelete: { deletingPlan = plan },
            onSave: savePlan,
            onCancel: cancelEditor
        )
        .frame(maxWidth: 1050)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(draft?.id ?? plan?.id)
    }

    private func detailPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading) { content() }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func openNewPlan() {
        updateNavigation {
            if $0.newPlanDraft == nil { $0.newPlanDraft = StrengthPlanDraft(plan: nil) }
            $0.page = .newPlan
        }
    }

    private func openEditor(_ plan: StrengthPlan) {
        updateNavigation {
            if $0.drafts[plan.id] == nil { $0.drafts[plan.id] = StrengthPlanDraft(plan: plan) }
        }
    }

    private func cancelEditor(_ draft: StrengthPlanDraft) {
        updateNavigation {
            if let original = draft.original {
                $0.drafts.removeValue(forKey: original.id)
            } else {
                $0.newPlanDraft = nil
                $0.page = .gallery
            }
        }
    }

    private func savePlan(_ draft: StrengthPlanDraft) throws {
        let plan = try draft.plan()
        guard store.library.strengthPlan(id: plan.id) == draft.original else {
            throw LogbookError.message("This plan has changed. Reopen it before editing.")
        }
        try store.saveStrengthPlan(plan)
        updateNavigation {
            if draft.original == nil {
                $0.newPlanDraft = nil
            } else {
                $0.drafts.removeValue(forKey: plan.id)
            }
            $0.page = .plan(plan.id)
        }
    }

    private func startTraining(_ plan: StrengthPlan) {
        perform {
            if active == nil { try store.startStrengthSession(planID: plan.id) }
            navigation.page = .workout
        }
    }

    private func updateNavigation(_ update: (inout StrengthTrainingNavigation) -> Void) {
        var state = navigation
        update(&state)
        navigation = state
    }

    private func workoutPage(_ session: StrengthSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(session.plan.name,
                    subtitle: Text("\(session.completedSets.count) of \(session.plan.targetSets) sets completed"))
            HStack(spacing: 24) {
                Label("Started \(startTime(of: session))", systemImage: "clock")
                TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(session.startedAt)))
                    let elapsed = Duration.seconds(seconds)
                    Label("Elapsed \(elapsed.formatted(.time(pattern: .hourMinuteSecond)))", systemImage: "stopwatch")
                        .monospacedDigit()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            ProgressView(value: Double(session.completedSets.count), total: Double(session.plan.targetSets))
                .accessibilityLabel("Training progress")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    workoutPanel(session).frame(minWidth: 265)
                    workoutExercises(session).frame(minWidth: 155)
                }
                VStack(alignment: .leading, spacing: 18) {
                    workoutPanel(session)
                    workoutExercises(session)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func workoutToolbar(_ session: StrengthSession) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { discard = session } label: {
                Label("Cancel Training…", systemImage: "xmark")
            }
            .help("Cancel Training")

            if session.nextSet == nil {
                Button { review = session } label: {
                    Label("Finish Training…", systemImage: "checkmark")
                }
                .help("Finish Training")
            } else {
                Button { review = session } label: {
                    Label("End Early…", systemImage: "stop.fill")
                }
                .help("End Training Early")
                .disabled(session.completedSets.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func workoutPanel(_ session: StrengthSession) -> some View {
        if let position = session.displayedSet {
            StrengthWorkoutSetPanel(session: session, position: position)
                .id(session.id.uuidString + "/\(position.index)")
        }
    }

    private func workoutExercises(_ session: StrengthSession) -> some View {
        let currentExerciseID = session.nextSet == nil ? nil : session.displayedSet?.exercise.id
        return VStack(alignment: .leading, spacing: 0) {
            Text("This Session").font(.headline).padding(.bottom, 4)
            ForEach(session.plan.exercises) { exercise in
                let count = session.sets(for: exercise.id).count
                let progress = "\(count) / \(exercise.targetSets)"
                listRow(exercise.name) {
                    if exercise.id == currentExerciseID {
                        Text(progress)
                            .monospacedDigit()
                            .fontWeight(.semibold)
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.14), in: Capsule())
                            .accessibilityLabel("Current exercise, \(count) of \(exercise.targetSets) sets completed")
                    } else if count == exercise.targetSets {
                        Label(progress, systemImage: "checkmark")
                            .monospacedDigit()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                    } else {
                        Text(progress)
                            .monospacedDigit()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func startTime(of session: StrengthSession) -> String {
        var format = Date.FormatStyle(date: .omitted, time: .shortened)
        format.timeZone = TimeZone(identifier: session.timeZoneID) ?? .current
        return session.startedAt.formatted(format)
    }

    private func heading(_ title: String, subtitle: Text? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if let subtitle { subtitle.foregroundStyle(.secondary) }
        }
    }

    private func listRow(_ title: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).fontWeight(.medium)
                Spacer(minLength: 8)
                value().foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 9)
            Divider()
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { self.error = error.localizedDescription }
    }
}

private struct StrengthGalleryCardStyle: ButtonStyle {
    static let contentInset: CGFloat = 14
    static let headerIconSize = CGSize(width: 26, height: 24)

    var isAddCard = false

    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, isAddCard: isAddCard)
    }

    private struct CardBody: View {
        let configuration: Configuration
        let isAddCard: Bool
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 12)
            configuration.label
                .padding(StrengthGalleryCardStyle.contentInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .frame(height: 126)
                .background {
                    shape.fill(Color(nsColor: .controlBackgroundColor).opacity(isAddCard ? 0.42 : 1))
                        .overlay { shape.fill(.tint.opacity(hovered ? 0.08 : 0)) }
                }
                .overlay {
                    shape.strokeBorder(
                        hovered ? AnyShapeStyle(.tint.opacity(0.5)) : AnyShapeStyle(Color.secondary.opacity(isAddCard ? 0.45 : 0.22)),
                        style: StrokeStyle(lineWidth: 1, dash: isAddCard ? [5, 4] : [])
                    )
                    .allowsHitTesting(false)
                }
                .contentShape(shape)
                .onHover { hovered = $0 }
                .opacity(configuration.isPressed ? 0.76 : 1)
        }
    }
}

private struct StrengthFinishSheet: View {
    @Environment(LogbookStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: StrengthSession
    let startTime: String
    @State private var finished: StrengthSession?
    @State private var error: String?

    private var title: LocalizedStringKey {
        if finished != nil {
            return session.nextSet == nil ? "Training Completed" : "Training Ended Early"
        }
        return session.nextSet == nil ? "Finish Training" : "End Training Early"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(session.plan.name).font(.headline)
                Text("\(session.day.label) · Started \(startTime)")
                    .foregroundStyle(.secondary)
                if let finishedAt = finished?.finishedAt {
                    let elapsed = Duration.seconds(finishedAt.timeIntervalSince(session.startedAt))
                    Text("Elapsed \(elapsed.formatted(.time(pattern: .hourMinuteSecond)))")
                        .foregroundStyle(.secondary)
                }
            }

            if let finished {
                StrengthCheckInPrompt(session: finished, defaultSceneID: store.defaultStrengthCheckInScene?.id) {
                    dismiss()
                }
            } else {
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Finish Training", action: finish)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func finish() {
        do {
            finished = try store.finishStrengthSession(sessionID: session.id,
                                                       completedCount: session.completedSets.count)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct StrengthCheckInPrompt: View {
    @Environment(LogbookStore.self) private var store
    let session: StrengthSession
    let close: () -> Void
    @State private var sceneID: String?
    @State private var day: DayKey?
    @State private var note: String
    @State private var quantity = ""
    @State private var entryID = UUID()
    @State private var confirmation: String?
    @State private var error: String?

    init(session: StrengthSession, defaultSceneID: String?, close: @escaping () -> Void) {
        self.session = session
        self.close = close
        _sceneID = State(initialValue: defaultSceneID)
        _day = State(initialValue: session.day)
        _note = State(initialValue: session.checkInNote)
    }

    var body: some View {
        let scenes = store.library.visibleScenes(showArchived: false)
        let scene = scenes.first { $0.id == sceneID }

        if confirmation != nil || scenes.isEmpty {
            if let confirmation {
                Label(confirmation, systemImage: "checkmark.circle")
                    .foregroundStyle(.tint)
            }
            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        } else {
            TimelineView(.everyMinute) { context in
                let today = DayKey(context.date, in: store.preferences.timeZone)
                let options = session.checkInDateOptions(through: today)
                let selectedDay = day.flatMap { options.contains($0) ? $0 : nil }
                let alreadyCheckedIn = if let scene, scene.kind == .completion, let selectedDay {
                    store.library.checkIn(for: scene.id, on: selectedDay) != nil
                } else {
                    false
                }

                GroupBox("Check in to Heatmaps?") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Scene", selection: Binding(get: { scene?.id }, set: { sceneID = $0 })) {
                            Text("Choose a Scene").tag(nil as String?)
                            ForEach(scenes) { Text($0.name).tag(Optional($0.id)) }
                        }

                        if options.count > 1 || selectedDay != session.day {
                            Picker("Date", selection: Binding(get: { selectedDay }, set: { day = $0 })) {
                                if selectedDay == nil {
                                    Text("Choose a Date").tag(nil as DayKey?)
                                }
                                ForEach(options, id: \.self) { option in
                                    dateLabel(option).tag(Optional(option))
                                }
                            }
                        } else {
                            LabeledContent("Date", value: session.day.label)
                        }
                        if let latest = session.checkInDays.last, latest > today {
                            Text("Future dates are unavailable in Heatmaps.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if alreadyCheckedIn {
                            Label("Already checked in on this date", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        } else if let scene {
                            if scene.kind == .quantity {
                                LabeledContent("Quantity") {
                                    TextField("Enter amount", text: $quantity)
                                        .accessibilityLabel("Quantity")
                                    Text(scene.unit).foregroundStyle(.secondary)
                                }
                            }
                            TextField("Note (optional)", text: $note, axis: .vertical)
                        }

                        HStack {
                            Spacer()
                            if alreadyCheckedIn {
                                Button("Done", action: close)
                                    .keyboardShortcut(.defaultAction)
                            } else {
                                Button("Skip", action: close)
                                    .keyboardShortcut(.cancelAction)
                                Button("Check In") {
                                    if let scene, let selectedDay { checkIn(to: scene, on: selectedDay) }
                                }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                                .disabled(scene == nil || selectedDay == nil
                                          || (scene?.kind == .quantity
                                              && quantity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .onChange(of: scene) { old, new in
                if old?.id != new?.id || old?.kind != new?.kind || old?.unit != new?.unit {
                    quantity = ""
                }
            }
            .logbookError($error)
        }
    }

    private func dateLabel(_ date: DayKey) -> Text {
        if date == session.day { return Text("Training Started · \(date.label)") }
        if date == session.checkInDays.last { return Text("Training Confirmed · \(date.label)") }
        return Text("Heatmaps Today · \(date.label)")
    }

    private func checkIn(to scene: CheckInScene, on day: DayKey) {
        do {
            let added = try store.addStrengthCheckIn(to: scene, on: day, quantity: quantity,
                                                     note: note, entryID: entryID)
            confirmation = added ? String(localized: "Checked in to \(scene.name).")
                : String(localized: "Already checked in to \(scene.name) on this date.")
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct StrengthOverviewButton: View {
    let action: () -> Void

    var body: some View {
        Button("Overview", systemImage: "chevron.left", action: action)
            .help("Back to training overview")
    }
}

@Observable
final class StrengthPlanDraft: Identifiable {
    struct Exercise: Identifiable {
        let id: UUID
        var name: String
        var sets: String
        var rest: String
        var reps: String
        var muscleGroup: String
        var notes: String
        var phase: StrengthExercise.Phase?

        init(_ exercise: StrengthExercise) {
            id = exercise.id
            name = exercise.name
            sets = String(exercise.targetSets)
            rest = String(exercise.restSeconds)
            reps = exercise.targetReps.map(String.init) ?? ""
            muscleGroup = exercise.muscleGroup ?? ""
            notes = exercise.notes ?? ""
            phase = exercise.phase
        }

        static func placeholder() -> Self {
            var exercise = Self(StrengthExercise(name: ""))
            exercise.sets = ""
            exercise.rest = ""
            return exercise
        }

        var hasInput: Bool {
            phase != nil || [name, sets, rest, reps, muscleGroup, notes].contains { optionalText($0) != nil }
        }

        func exercise(usingDefaults: Bool = false) throws -> StrengthExercise {
            let defaults = StrengthExercise(name: name)
            guard let sets = Int(optionalText(sets) ?? (usingDefaults ? String(defaults.targetSets) : "")),
                  let rest = Int(optionalText(rest) ?? (usingDefaults ? String(defaults.restSeconds) : "")) else {
                throw LogbookError.message("Enter whole numbers for sets and rest seconds.")
            }
            let reps = optionalText(reps)
            let targetReps = reps.flatMap { Int($0) }
            guard reps == nil || targetReps != nil else {
                throw LogbookError.message("Enter a whole number for reps per set.")
            }
            return StrengthExercise(id: id, name: name, targetSets: sets, restSeconds: rest,
                                    targetReps: targetReps, muscleGroup: optionalText(muscleGroup),
                                    notes: optionalText(notes), phase: phase)
        }

        private func optionalText(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    let id: UUID
    let original: StrengthPlan?
    var name: String
    var exercises: [Exercise]
    var pendingExercise = Exercise.placeholder()

    init(plan: StrengthPlan?) {
        id = plan?.id ?? UUID()
        original = plan
        name = plan?.name ?? ""
        exercises = (plan?.exercises ?? []).map(Exercise.init)
    }

    func commitPendingExercise() throws {
        guard pendingExercise.hasInput else { return }
        let exercise = try pendingExercise.exercise(usingDefaults: true)
        try exercise.validate()
        exercises.append(Exercise(exercise))
        pendingExercise = .placeholder()
    }

    func plan() throws -> StrengthPlan {
        try StrengthPlan(id: id, name: name, exercises: exercises.map { try $0.exercise() })
    }
}

private struct StrengthPlanPane: View {
    let plan: StrengthPlan?
    let draft: StrengthPlanDraft?
    let startLabel: LocalizedStringKey
    let onBack: () -> Void
    let onEdit: () -> Void
    let onStart: () -> Void
    let onDelete: () -> Void
    let onSave: (StrengthPlanDraft) throws -> Void
    let onCancel: (StrengthPlanDraft) -> Void
    @FocusState private var focus: Field?
    @State private var error: String?
    @State private var pendingError: String?
    @State private var nextExerciseToFocus: UUID?
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var listFrame: CGRect = .zero
    @State private var insertion: Int?

    private enum Field: Hashable {
        case name
        case exercise(UUID, AnyKeyPath)

        var exerciseID: UUID? {
            if case .exercise(let id, _) = self { return id }
            return nil
        }
    }

    private var rows: [StrengthPlanDraft.Exercise] {
        draft?.exercises ?? plan?.exercises.map(StrengthPlanDraft.Exercise.init) ?? []
    }

    private var rowInsets: EdgeInsets { EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20) }

    var body: some View {
        let rows = self.rows
        let numbers = StrengthExercise.numbers(for: rows.map(\.phase))
        let displayedRows = rows + (draft.map { [$0.pendingExercise] } ?? [])
        GeometryReader { geometry in
            let nameWidth = min(235, max(150, (geometry.size.width - 40) * 0.31))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        header.padding(rowInsets)
                        Divider()
                        ForEach(Array(displayedRows.enumerated()), id: \.element.id) { index, exercise in
                            let pending = index == rows.count
                            VStack(alignment: .leading, spacing: 0) {
                                exerciseRow(exercise, at: index, number: pending ? nil : numbers[index],
                                            nameWidth: nameWidth, pending: pending)
                                    .padding(rowInsets)
                                if pending, let pendingError {
                                    Text(pendingError).font(.caption).foregroundStyle(.red)
                                        .padding(.horizontal, rowInsets.leading)
                                        .padding(.bottom, 8)
                                }
                                Divider().padding(.leading, rowInsets.leading)
                            }
                            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                                rowFrames[exercise.id] = $0
                            }
                            .onDisappear { rowFrames.removeValue(forKey: exercise.id) }
                            .task(id: nextExerciseToFocus) {
                                guard nextExerciseToFocus == exercise.id else { return }
                                await Task.yield()
                                guard !Task.isCancelled, nextExerciseToFocus == exercise.id else { return }
                                focus = .exercise(exercise.id, \StrengthPlanDraft.Exercise.name)
                                nextExerciseToFocus = nil
                            }
                        }
                    }
                    .frame(minHeight: geometry.size.height, alignment: .topLeading)
                    .background {
                        if draft != nil {
                            Color.clear.contentShape(.rect).onTapGesture { focus = nil }
                        }
                    }
                }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { listFrame = $0 }
                .onChange(of: draft?.pendingExercise.id) { old, new in
                    if let new, nextExerciseToFocus == new {
                        proxy.scrollTo(new, anchor: .bottom)
                    } else if let old, focus == nil {
                        proxy.scrollTo(old, anchor: .bottom)
                    }
                }
            }
        }
        .toolbar {
            if draft == nil {
                ToolbarItem(placement: .navigation) {
                    StrengthOverviewButton(action: onBack)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                actions
            }
        }
        .task(id: draft?.id) {
            insertion = nil
            pendingError = nil
            nextExerciseToFocus = nil
            if let draft, draft.name.isEmpty { focus = .name }
        }
        .onChange(of: focus) { previous, current in
            guard let draft, previous?.exerciseID == draft.pendingExercise.id,
                  current?.exerciseID != draft.pendingExercise.id else { return }
            commitPendingExercise(in: draft)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let draft {
            Button("Cancel", systemImage: "xmark") {
                error = nil
                onCancel(draft)
            }
            .help("Cancel editing")
            Button("Save Plan", systemImage: "checkmark", action: save)
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .keyboardShortcut("s", modifiers: .command)
                .help("Save plan")
        } else {
            Button(startLabel, systemImage: "play.fill", action: onStart)
                .help(startLabel)
            Button("Edit Exercises", systemImage: "pencil", action: onEdit)
                .help("Edit exercises")
            Button("Delete Plan", systemImage: "trash", role: .destructive, action: onDelete)
                .help("Delete plan")
        }
    }

    @discardableResult
    private func commitPendingExercise(in draft: StrengthPlanDraft) -> Bool {
        do {
            try draft.commitPendingExercise()
            pendingError = nil
            return true
        } catch {
            pendingError = error.localizedDescription
            return false
        }
    }

    private func submitPendingExercise(_ id: UUID, in draft: StrengthPlanDraft) {
        guard draft.pendingExercise.id == id, draft.pendingExercise.hasInput,
              commitPendingExercise(in: draft) else { return }
        nextExerciseToFocus = draft.pendingExercise.id
    }

    private var header: some View {
        let count = rows.count
        let sets = rows.compactMap { Int($0.sets) }.filter { (1...30).contains($0) }.reduce(0, +)
        return VStack(alignment: .leading, spacing: 6) {
            Group {
                if let draft {
                    @Bindable var draft = draft
                    TextField("Plan Name", text: $draft.name, prompt: Text("Untitled Plan"))
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Plan Name")
                        .focused($focus, equals: .name)
                } else {
                    Text(plan?.name ?? "")
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .font(.largeTitle.weight(.semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(strengthPlanSummary(exercises: count, sets: sets))
                .foregroundStyle(.secondary)
            if let error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
    }

    private func exerciseRow(_ exercise: StrengthPlanDraft.Exercise, at index: Int, number: Int?,
                             nameWidth: CGFloat, pending: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                dragHandle(for: exercise, at: index, pending: pending)
                Group {
                    if let number {
                        Text(number.formatted())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Exercise \(number)")
                    } else {
                        Color.clear.frame(height: 1).accessibilityHidden(true)
                    }
                }
                .frame(width: 22, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    phaseIcon(for: exercise)
                        .frame(width: 24)
                    field("Exercise Name", exercise, \.name, previewLines: 2,
                          prompt: pending ? Text("New exercise") : Text("—"))
                        .font(.headline)
                }
            }
            .frame(width: nameWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 14) {
                    metric("Sets", exercise, \.sets, prompt: pending ? Text("2") : Text("—"))
                    metric("Reps per Set", exercise, \.reps)
                    metric("Rest (sec)", exercise, \.rest, prompt: pending ? Text("60") : Text("—"))
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Muscle Group").foregroundStyle(.secondary)
                        field("Muscle Group", exercise, \.muscleGroup)
                    }
                    GridRow(alignment: .top) {
                        Text("Notes").foregroundStyle(.secondary)
                        field("Notes", exercise, \.notes, axis: .vertical)
                    }
                }
                .font(.callout)
            }
            Button(role: .destructive) {
                draft?.exercises.removeAll { $0.id == exercise.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(pending || (draft?.exercises.count ?? 0) < 2)
            .opacity(draft == nil || pending ? 0 : 1)
            .accessibilityHidden(draft == nil || pending)
            .accessibilityLabel("Remove Exercise")
            .help("Remove Exercise")
        }
        .overlay(alignment: .top) {
            if !pending, insertion == index { insertionLine.offset(y: -5) }
        }
        .overlay(alignment: .bottom) {
            if index == rows.count - 1, insertion == rows.count { insertionLine.offset(y: 5) }
        }
    }

    @ViewBuilder
    private func phaseIcon(for exercise: StrengthPlanDraft.Exercise) -> some View {
        let icon = StrengthExercisePhaseIcon(phase: exercise.phase)
        if let draft {
            Menu {
                Picker("Exercise Type", selection: binding(in: draft, exercise, \.phase)) {
                    Text("Regular").tag(Optional<StrengthExercise.Phase>.none)
                    ForEach(StrengthExercise.Phase.allCases, id: \.self) { phase in
                        Text(phase.title).tag(Optional(phase))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                icon
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Exercise Type")
            .accessibilityValue(icon.title)
            .help(icon.title)
            .focused($focus, equals: .exercise(exercise.id, \StrengthPlanDraft.Exercise.phase))
        } else {
            icon
        }
    }

    private var insertionLine: some View {
        Rectangle().fill(.tint).frame(height: 2).allowsHitTesting(false)
    }

    @ViewBuilder
    private func dragHandle(for exercise: StrengthPlanDraft.Exercise, at index: Int, pending: Bool) -> some View {
        if !pending, draft != nil, rows.count > 1 {
            ListDragHandle { point in
                let destination = destination(at: point)
                insertion = destination == index || destination == index + 1 ? nil : destination
            } onDrop: { point in
                insertion = nil
                if let destination = destination(at: point) { move(exercise.id, to: destination) }
            }
                .frame(width: 16, height: 22)
                .accessibilityLabel("Reorder \(exercise.name)")
                .accessibilityActions {
                    if index > 0 {
                        Button("Move Up") { move(exercise.id, to: index - 1) }
                    }
                    if index + 1 < rows.count {
                        Button("Move Down") { move(exercise.id, to: index + 2) }
                    }
                }
                .help("Drag to Reorder")
        } else {
            Color.clear.frame(width: 16, height: 22).accessibilityHidden(true)
        }
    }

    private func destination(at point: CGPoint) -> Int? {
        guard listFrame.contains(point), let draft else { return nil }
        var lastVisible: Int?
        for (index, exercise) in draft.exercises.enumerated() {
            guard let frame = rowFrames[exercise.id], frame.intersects(listFrame) else { continue }
            if point.y < frame.midY { return index }
            lastVisible = index
        }
        return lastVisible.map { $0 + 1 }
    }

    private func move(_ id: UUID, to destination: Int) {
        guard let draft, (0...draft.exercises.count).contains(destination),
              let source = draft.exercises.firstIndex(where: { $0.id == id }),
              destination != source, destination != source + 1 else { return }
        draft.exercises.move(fromOffsets: IndexSet(integer: source), toOffset: destination)
    }

    private func metric(_ title: LocalizedStringKey, _ exercise: StrengthPlanDraft.Exercise,
                        _ keyPath: WritableKeyPath<StrengthPlanDraft.Exercise, String>, prompt: Text = Text("—")) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            field(title, exercise, keyPath, prompt: prompt)
                .monospacedDigit()
        }
    }

    private func field(_ title: LocalizedStringKey, _ exercise: StrengthPlanDraft.Exercise,
                       _ keyPath: WritableKeyPath<StrengthPlanDraft.Exercise, String>,
                       axis: Axis = .horizontal, previewLines: Int = 1, prompt: Text = Text("—")) -> some View {
        let value = exercise[keyPath: keyPath]
        return Group {
            if let draft {
                TextField(title, text: binding(in: draft, exercise, keyPath), prompt: prompt, axis: axis)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(Text(title))
                    .lineLimit(axis == .vertical ? 1...4 : 1...1)
                    .focused($focus, equals: .exercise(exercise.id, keyPath))
                    .onKeyPress(.return, phases: .down) { press in
                        guard draft.pendingExercise.id == exercise.id, !press.modifiers.contains(.shift) else {
                            return .ignored
                        }
                        submitPendingExercise(exercise.id, in: draft)
                        return .handled
                    }
                    .onSubmit {
                        submitPendingExercise(exercise.id, in: draft)
                    }
            } else {
                Text(value.isEmpty ? "—" : value)
                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
                    .lineLimit(axis == .vertical ? 4 : previewLines)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func binding<Value>(in draft: StrengthPlanDraft, _ exercise: StrengthPlanDraft.Exercise,
                                _ keyPath: WritableKeyPath<StrengthPlanDraft.Exercise, Value>) -> Binding<Value> {
        Binding {
            let current = draft.pendingExercise.id == exercise.id
                ? draft.pendingExercise : draft.exercises.first { $0.id == exercise.id } ?? exercise
            return current[keyPath: keyPath]
        } set: { updated in
            if draft.pendingExercise.id == exercise.id {
                draft.pendingExercise[keyPath: keyPath] = updated
                // Keep an existing validation message until the row is checked again.
            } else if let index = draft.exercises.firstIndex(where: { $0.id == exercise.id }) {
                draft.exercises[index][keyPath: keyPath] = updated
            }
        }
    }

    private func save() {
        guard let draft else { return }
        error = nil
        guard commitPendingExercise(in: draft) else {
            focus = .exercise(draft.pendingExercise.id, \StrengthPlanDraft.Exercise.name)
            return
        }
        do {
            try onSave(draft)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct StrengthWorkoutSetPanel: View {
    @Environment(LogbookStore.self) private var store
    let session: StrengthSession
    let position: StrengthSession.SetPosition
    @State private var reps = ""
    @State private var weight = ""
    @State private var restOverride: Int?
    @State private var minutesDraft = ""
    @State private var secondsDraft = ""
    @State private var restAtEditStart: Int?
    @State private var error: String?
    @FocusState private var restField: RestField?

    private enum RestField { case minutes, seconds }
    private static let clockHeight: CGFloat = 43

    private var exercise: StrengthExercise { position.exercise }
    private var timer: StrengthRestTimer { store.strengthRestTimer }
    private var resting: Bool { session.restDeadline != nil }
    private var ringing: Bool { resting && timer.isRinging }
    private var finished: Bool { session.nextSet == nil }
    private var finalSet: Bool { position.index == session.plan.targetSets - 1 }
    private var restSeconds: Int { restOverride ?? exercise.restSeconds }
    private var editingRest: Bool { restAtEditStart != nil }
    private var isRepeatedKey: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }
    private var restLabel: LocalizedStringKey {
        if ringing { return "Overtime" }
        return resting ? "Rest Remaining" : "Rest"
    }

    private var recorded: StrengthSet? {
        session.completedSets.indices.contains(position.index) ? session.completedSets[position.index] : nil
    }

    private var proposedRest: Int? {
        guard let minutes = Int(minutesDraft), (0...60).contains(minutes),
              let seconds = Int(secondsDraft), (0...59).contains(seconds) else { return nil }
        let total = minutes * 60 + seconds
        return StrengthExercise.restRange.contains(total) ? total : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            exerciseHeading
            HStack(spacing: 16) {
                target("Set", value: "\(position.number) / \(exercise.targetSets)")
                target("Target Reps", value: exercise.targetReps?.formatted() ?? "—")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    StrengthExerciseNotes(exercise: exercise, showsPlaceholders: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .frame(height: 36)
            setFields
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(restLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ringing ? Color.red : Color.secondary)
                HStack(spacing: 10) {
                    restClock
                        .frame(width: 122, height: Self.clockHeight, alignment: .leading)
                    Spacer(minLength: 0)
                    setAction
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.tint.opacity(0.12), in: .rect(cornerRadius: 10))
        .onChange(of: ringing) { _, isRinging in
            if isRinging { closeRestEditor() }
        }
        .task(id: restField) {
            guard editingRest else { return }
            let field = restField
            await Task.yield()
            guard !Task.isCancelled, editingRest, restField == field else { return }
            if let field {
                selectRestDigits(in: field)
            } else {
                finishRestEditing()
            }
        }
        .logbookError($error)
    }

    private var exerciseHeading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(recorded == nil ? "Current Exercise" : "Set Completed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StrengthExercisePhaseIcon(phase: exercise.phase).font(.title3)
                Text(exercise.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .help(exercise.name)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    private func target(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 30, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.background.opacity(0.42), in: .rect(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }

    private var setFields: some View {
        VStack(alignment: .leading, spacing: 2) {
            setInputs
            ZStack(alignment: .leading) {
                Color.clear.accessibilityHidden(true)
                if let previous = session.sets(for: exercise.id).prefix(position.number - 1).last,
                   previous.reps != nil || previous.weight != nil {
                    LabeledContent("Previous Set") { strengthSetResult(previous) }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 13)
        }
    }

    private var setInputs: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Reps").font(.caption).foregroundStyle(.secondary)
                TextField("Reps", text: recorded.map { .constant($0.reps?.formatted() ?? "") } ?? $reps,
                          prompt: Text(recorded == nil ? "Optional" : "—"))
                    .labelsHidden()
                    .accessibilityLabel("Reps")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Weight (kg)").font(.caption).foregroundStyle(.secondary)
                TextField("Weight (kg)", text: recorded.map { .constant($0.weight?.formatted() ?? "") } ?? $weight,
                          prompt: Text(recorded == nil ? "Optional" : "—"))
                    .labelsHidden()
                    .accessibilityLabel("Weight in kilograms")
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(recorded != nil)
    }

    @ViewBuilder
    private var restClock: some View {
        if finalSet {
            clockDigits("—").accessibilityLabel("No rest after final set")
        } else if ringing {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                clockDigits("+\(strengthClockText(timer.overtimeSeconds))")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Overtime")
                    .accessibilityValue("\(timer.overtimeSeconds) seconds")
            }
        } else if editingRest {
            clockSegments {
                restField(.minutes, text: restDigitsBinding($minutesDraft, field: .minutes))
            } seconds: {
                restField(.seconds, text: restDigitsBinding($secondsDraft, field: .seconds))
            }
            .background(RestClockFocusBoundary(onOutsideClick: finishRestEditing))
        } else if resting {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                editableDigits(timer.remainingSeconds)
            }
        } else {
            editableDigits(restSeconds)
        }
    }

    private var clockFont: Font { .system(size: 36, weight: .semibold, design: .monospaced) }

    private func clockDigits(_ value: String) -> some View {
        Text(value)
            .font(clockFont)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
    }

    private func clockSegments<Minutes: View, Seconds: View>(
        @ViewBuilder minutes: () -> Minutes, @ViewBuilder seconds: () -> Seconds
    ) -> some View {
        HStack(spacing: 0) {
            minutes()
                .frame(width: 44)
            Text(":")
                .font(clockFont)
                .frame(width: 22)
                .accessibilityHidden(true)
            seconds()
                .frame(width: 44)
        }
        .frame(height: Self.clockHeight)
    }

    private func editableDigits(_ total: Int) -> some View {
        let minutes = String(format: "%02d", total / 60)
        let seconds = String(format: "%02d", total % 60)
        return clockSegments {
            digitButton(minutes, field: .minutes, total: total)
        } seconds: {
            digitButton(seconds, field: .seconds, total: total)
        }
    }

    private func digitButton(_ digits: String, field: RestField, total: Int) -> some View {
        Button {
            minutesDraft = String(format: "%02d", total / 60)
            secondsDraft = String(format: "%02d", total % 60)
            restAtEditStart = total
            restField = field
        } label: {
            clockDigits(digits)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(field == .minutes ? "Edit Rest Minutes" : "Edit Rest Seconds")
        .accessibilityValue(digits)
        .help(field == .minutes ? "Edit rest minutes" : "Edit rest seconds")
    }

    private func restField(_ field: RestField, text: Binding<String>) -> some View {
        TextField(field == .minutes ? "Rest minutes" : "Rest seconds", text: text)
            .textFieldStyle(.plain)
            .font(clockFont)
            .multilineTextAlignment(.center)
            .background(.tint.opacity(0.12), in: .rect(cornerRadius: 4))
            .focused($restField, equals: field)
            .onSubmit(applyRest)
            .onExitCommand(perform: closeRestEditor)
            .simultaneousGesture(TapGesture().onEnded {
                Task { @MainActor in
                    await Task.yield()
                    selectRestDigits(in: field)
                }
            })
    }

    private func restDigitsBinding(_ draft: Binding<String>, field: RestField) -> Binding<String> {
        Binding {
            draft.wrappedValue
        } set: { input in
            let digits = String(input.filter { ("0"..."9").contains($0) }.prefix(2))
            let changed = digits != draft.wrappedValue
            draft.wrappedValue = digits
            guard changed, restField == field, digits.count == 2 else { return }
            switch field {
            case .minutes:
                restField = .seconds
            case .seconds:
                applyRest()
            }
        }
    }

    private func selectRestDigits(in field: RestField) {
        guard editingRest, restField == field,
              let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor else { return }
        editor.selectAll(nil)
    }

    @ViewBuilder
    private var setAction: some View {
        if finished {
            Label("All Sets Completed", systemImage: "checkmark")
                .labelStyle(.iconOnly)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: Self.clockHeight, height: Self.clockHeight)
                .foregroundStyle(.tint)
                .help("All sets completed")
        } else if ringing {
            timerButton("Stop Alarm & Continue", symbol: "bell.slash", action: endRest)
                .keyboardShortcut(.defaultAction)
                .help("Stop alarm and continue (Return)")
        } else if editingRest {
            timerButton("Apply Rest Time", symbol: "checkmark", action: applyRest)
                .disabled(proposedRest == nil)
                .help("Apply rest time (Return)")
        } else if resting {
            timerButton("Skip Rest", symbol: "forward.end", action: endRest)
                .help("Skip rest")
        } else {
            timerButton("Complete Set", symbol: "checkmark", action: complete)
                .keyboardShortcut(.defaultAction)
                .help("Complete set (Return)")
        }
    }

    private func timerButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(TimerButtonStyle(diameter: Self.clockHeight))
    }

    private struct TimerButtonStyle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled
        let diameter: CGFloat

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(.tint, in: Circle())
                .contentShape(Circle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
        }
    }

    private func applyRest() {
        guard !isRepeatedKey, proposedRest != nil else { return }
        finishRestEditing()
    }

    private func finishRestEditing() {
        guard let initial = restAtEditStart else { return }
        closeRestEditor()
        guard !ringing, let proposedRest, proposedRest != initial else { return }
        do {
            if resting {
                try store.changeStrengthRest(sessionID: session.id, completedCount: session.completedSets.count, seconds: proposedRest)
            } else {
                restOverride = proposedRest
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func closeRestEditor() {
        restAtEditStart = nil
        restField = nil
    }

    private func complete() {
        guard !editingRest, !isRepeatedKey else { return }
        if let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .leftMouseDown,
           event.clickCount > 1 { return }
        do {
            let result = try StrengthSet(repsText: reps, weightText: weight)
            try store.completeStrengthSet(sessionID: session.id, index: position.index, result: result, restSeconds: restOverride)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func endRest() {
        guard !isRepeatedKey else { return }
        do {
            try store.endStrengthRest(sessionID: session.id, completedCount: session.completedSets.count)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct RestClockFocusBoundary: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> ClickBoundary { ClickBoundary() }

    func updateNSView(_ view: ClickBoundary, context: Context) {
        view.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ view: ClickBoundary, coordinator: ()) {
        view.stopMonitoring()
    }

    final class ClickBoundary: NSView {
        var onOutsideClick: (() -> Void)?
        private var monitor: Any?
        private weak var monitoredWindow: NSWindow?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard let window else { return }
            monitoredWindow = window
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                                                   name: NSWindow.didResignKeyNotification, object: window)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !bounds.contains(convert(event.locationInWindow, from: nil)) else { return event }
                Task { @MainActor [weak self] in
                    self?.onOutsideClick?()
                }
                return event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let monitoredWindow {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: monitoredWindow)
            }
            monitoredWindow = nil
        }

        @objc private func windowResignedKey(_ notification: Notification) { onOutsideClick?() }
    }
}

private func strengthSetResult(_ set: StrengthSet) -> Text {
    if let reps = set.reps, let weight = set.weight {
        Text("\(reps) reps · \(weight.formatted()) kg")
    } else if let reps = set.reps {
        Text("\(reps) reps")
    } else if let weight = set.weight {
        Text("\(weight.formatted()) kg")
    } else {
        Text("Completed")
    }
}

private struct StrengthExercisePhaseIcon: View {
    let phase: StrengthExercise.Phase?

    var title: Text { phase.map { Text($0.title) } ?? Text("Regular") }

    var body: some View {
        let symbol = switch phase {
        case .warmup: "flame"
        case .cooldown: "wind"
        case nil: "dumbbell"
        }
        Image(systemName: symbol)
            .foregroundStyle(.secondary)
            .frame(width: 20)
            .accessibilityLabel(title)
            .help(title)
    }
}

private struct StrengthExerciseNotes: View {
    let exercise: StrengthExercise
    var showsPlaceholders = false

    var body: some View {
        if exercise.muscleGroup != nil || showsPlaceholders {
            LabeledContent("Muscle Group") { Text(exercise.muscleGroup ?? "—").textSelection(.enabled) }
                .font(.callout)
        }
        if exercise.notes != nil || showsPlaceholders {
            LabeledContent("Notes") { Text(exercise.notes ?? "—").textSelection(.enabled) }
                .font(.callout)
        }
    }
}

private func strengthClockText(_ seconds: Int) -> String {
    String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

private func strengthSetCountText(_ count: Int) -> String {
    "\(count) \(count == 1 ? "set" : "sets")"
}

private func strengthPlanSummary(exercises: Int, sets: Int) -> String {
    "\(exercises) \(exercises == 1 ? "exercise" : "exercises") · \(strengthSetCountText(sets))"
}
