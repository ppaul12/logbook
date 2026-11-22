import AppKit
import SwiftUI

enum CheckInSelection: Hashable {
    case allScenes, scene(String)
}

struct CheckInsView: View {
    @Environment(LogbookStore.self) private var store
    @Binding var selection: CheckInSelection
    @State private var sheet: Sheet?
    @State private var error: String?
    @State private var isEditingScenes = false

    private enum Sheet: Identifiable {
        case scene(CheckInScene), day(CheckInScene, DayKey), removal(SceneRemoval)

        var id: String {
            switch self {
            case .scene(let scene): "scene/\(scene.id)"
            case .day(let scene, let day): "day/\(scene.id)/\(day.rawValue)"
            case .removal(let action): "removal/\(action.scene.id)"
            }
        }
    }

    private enum SceneRemoval {
        case reset(CheckInScene), delete(CheckInScene)

        var scene: CheckInScene {
            switch self {
            case .reset(let scene), .delete(let scene): scene
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .reset(let scene): "Reset \(scene.name)?"
            case .delete(let scene): "Delete \(scene.name)?"
            }
        }

        var buttonTitle: LocalizedStringKey {
            switch self {
            case .reset: "Reset Check-ins"
            case .delete: "Delete Scene"
            }
        }

        var message: LocalizedStringKey {
            switch self {
            case .reset: "All check-ins for this scene will be permanently removed."
            case .delete: "This scene and all of its check-ins will be permanently removed."
            }
        }
    }

    private func selectedScene(in scenes: [CheckInScene]) -> CheckInScene? {
        guard case .scene(let id) = selection else { return nil }
        return scenes.first { $0.id == id }
    }

    var body: some View {
        let scenes = store.library.visibleScenes(showArchived: store.preferences.showArchivedScenes)
        let scene = selectedScene(in: scenes)
        let hasHiddenScenes = scenes.isEmpty && !store.library.scenes.isEmpty
        Group {
            if scenes.isEmpty {
                ContentUnavailableView {
                    Label(hasHiddenScenes ? "No Active Scenes" : "No Check-in Scenes", systemImage: "calendar")
                } description: {
                    Text(hasHiddenScenes ? "Show archived scenes in Settings to see your saved scenes."
                                         : "Create a scene to start recording your days.")
                } actions: {
                    Button("New Scene", action: newScene).buttonStyle(.borderedProminent)
                }
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let today = DayKey(context.date, in: store.preferences.timeZone)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            VStack(alignment: .leading, spacing: 12) {
                                if isEditingScenes {
                                    Text("All Scenes").font(.largeTitle.bold())
                                        .accessibilityAddTraits(.isHeader)
                                } else {
                                    sceneTitleMenu(scenes, selected: scene)
                                }
                                if let scene { sceneSummary(scene, today: today) }
                            }
                            if let scene {
                                Divider()
                                VStack(alignment: .leading, spacing: 12) {
                                    SceneHeatmap(scene: scene, today: today) { editDay(scene, on: $0) }
                                        .id(scene.id)
                                    Divider()
                                    SceneCheckInStatistics(sceneID: scene.id, today: today)
                                }
                            } else {
                                AllScenesOverview(scenes: scenes, today: today, isEditing: isEditingScenes) { scene in
                                    selection = .scene(scene.id)
                                } editDay: { scene, day in
                                    editDay(scene, on: day)
                                } reset: { scene in
                                    sheet = .removal(.reset(scene))
                                } delete: { scene in
                                    sheet = .removal(.delete(scene))
                                }
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: 860)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .toolbar {
            if let scene {
                ToolbarItemGroup(placement: .primaryAction) {
                    sceneActions(scene)
                }
            } else {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("New Scene", systemImage: "plus", action: newScene)
                    if isEditingScenes {
                        Button("Done", systemImage: "checkmark") { isEditingScenes = false }
                            .buttonStyle(.borderedProminent)
                            .tint(.accentColor)
                    } else {
                        Button("Edit Scenes", systemImage: "pencil") { isEditingScenes = true }
                            .disabled(scenes.isEmpty)
                    }
                }
            }
        }
        .onChange(of: selection) {
            isEditingScenes = false
        }
        .onChange(of: scenes.isEmpty) { _, empty in
            if empty { isEditingScenes = false }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .scene(let draft):
                SceneEditor(scene: draft) { updated in
                    try store.save([.scene(updated)])
                    selection = updated.archived && !store.preferences.showArchivedScenes ? .allScenes : .scene(updated.id)
                }
            case .day(let scene, let day):
                if scene.kind == .quantity {
                    QuantityDayEditor(scene: scene, day: day)
                } else {
                    CheckInEditor(scene: scene, day: day, existing: store.library.checkIn(for: scene.id, on: day))
                }
            case .removal(let action):
                removalConfirmation(action)
            }
        }
        .logbookError($error)
    }

    private func removalConfirmation(_ action: SceneRemoval) -> some View {
        RemovalConfirmation(title: action.title, message: action.message, actionTitle: action.buttonTitle,
                            cancel: { sheet = nil }) {
            sheet = nil
            removeScene(action)
        }
    }

    private func removeScene(_ action: SceneRemoval) {
        do {
            switch action {
            case .reset(let scene):
                try store.resetScene(scene.id)
            case .delete(let scene):
                try store.deleteScene(scene.id)
                if selection == .scene(scene.id) { selection = .allScenes }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func newScene() {
        let position = (store.library.scenes.last?.position ?? -1) + 1
        sheet = .scene(CheckInScene(position: position))
    }

    private func sceneTitleMenu(_ scenes: [CheckInScene], selected: CheckInScene?) -> some View {
        let title = selected.map { Text(verbatim: $0.name) } ?? Text("All Scenes")
        return Menu {
            Picker("Scene", selection: Binding(
                get: { selected.map { .scene($0.id) } ?? .allScenes },
                set: { selection = $0 }
            )) {
                Text("All Scenes").tag(CheckInSelection.allScenes)
                ForEach(scenes) { scene in
                    Text(scene.name + (scene.archived ? " (Archived)" : "")).tag(CheckInSelection.scene(scene.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            title.font(.largeTitle.bold()).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .accessibilityLabel("Scene")
        .accessibilityValue(title)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func sceneActions(_ scene: CheckInScene) -> some View {
        Button("Edit Scene", systemImage: "pencil") { sheet = .scene(scene) }
            .help("Edit scene")
        Button("Reset Check-ins", systemImage: "arrow.counterclockwise", role: .destructive) {
            sheet = .removal(.reset(scene))
        }
        .disabled(store.library.firstCheckInDay(for: scene.id) == nil)
        .help("Reset check-ins")
        Button("Delete Scene", systemImage: "trash", role: .destructive) {
            sheet = .removal(.delete(scene))
        }
        .help("Delete scene")
    }

    private func sceneSummary(_ scene: CheckInScene, today: DayKey) -> some View {
        let entry = store.library.checkInDay(for: scene.id, on: today)
        return HStack(spacing: 12) {
            if scene.archived {
                Text("Archived scene").foregroundStyle(.secondary)
            } else if scene.kind == .quantity {
                Button("Add Record") { recordToday(scene) }.buttonStyle(.borderedProminent)
            } else if entry != nil {
                Button("Edit Today") { editDay(scene, on: today) }
            } else {
                Button("Check In Today") { recordToday(scene) }.buttonStyle(.borderedProminent)
            }
            if !scene.archived, let entry {
                Label(scene.kind == .completion ? "Completed today" : "\(entry.total.formatted()) \(scene.unit) today",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color(logbookHex: scene.color))
                    .lineLimit(1)
            }
        }
    }

    private func editDay(_ scene: CheckInScene, on day: DayKey) {
        sheet = .day(scene, day)
    }

    private func recordToday(_ scene: CheckInScene) {
        let day = store.preferences.today
        if scene.kind == .completion, store.library.checkIn(for: scene.id, on: day) == nil {
            do { try store.save([.checkIn(CheckIn(sceneID: scene.id, day: day, value: 1))]) }
            catch { self.error = error.localizedDescription }
        } else {
            editDay(scene, on: day)
        }
    }
}

private struct SceneHeatmap: View {
    @Environment(LogbookStore.self) private var store
    @State private var pickedDay: DayKey?
    @State private var reviewDay: DayKey?
    @State private var earliestRequestedDay: DayKey?
    @State private var pendingHistoryJump: DayKey?
    let scene: CheckInScene
    let today: DayKey
    let editDay: (DayKey) -> Void

    private let cellSize: CGFloat = 14
    private let cellSpacing: CGFloat = 3
    private let monthRowHeight: CGFloat = 20

    var body: some View {
        let earliestEntry = store.library.firstCheckInDay(for: scene.id) ?? today
        let history = HeatmapHistory(
            through: today, earliest: min(earliestEntry, earliestRequestedDay ?? today),
            weekStart: store.preferences.weekStart
        )
        let selectedDay = min(pickedDay ?? today, today)
        let highlightedDay = min(reviewDay ?? today, today)
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 12) {
                Text("Daily History").font(.title2.weight(.semibold))
                HStack {
                    LogbookDatePicker(title: "Date", day: Binding(
                        get: { selectedDay },
                        set: { pickedDay = $0 == today ? nil : $0 }
                    ), latest: today, showsLabel: false, todayShortcut: today)
                    .fixedSize()

                    Button("Go") {
                        reviewDay = selectedDay == today ? nil : selectedDay
                        let week = history.week(containing: selectedDay)
                        if history.weeks.contains(week) {
                            pendingHistoryJump = nil
                            proxy.scrollTo(week, anchor: .trailing)
                        } else {
                            pendingHistoryJump = selectedDay
                            earliestRequestedDay = selectedDay
                        }
                    }
                }
                HStack(alignment: .top, spacing: 7) {
                    weekdayLabels
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: cellSpacing) {
                            ForEach(history.weeks, id: \.self) { week in
                                weekColumn(history.days(in: week), selectedDay: highlightedDay)
                            }
                        }
                        .padding(.leading, 1)
                        .padding(.trailing, cellSize)
                        .padding(.bottom, 12)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _ in
                            guard let day = pendingHistoryJump else { return }
                            let week = history.week(containing: day)
                            guard history.weeks.contains(week) else { return }
                            // Scroll after the expanded content has finished laying out.
                            Task { @MainActor in
                                guard pendingHistoryJump == day else { return }
                                pendingHistoryJump = nil
                                proxy.scrollTo(week, anchor: .trailing)
                            }
                        }
                    }
                    .defaultScrollAnchor(.trailing)
                }
                .environment(\.layoutDirection, .leftToRight)

                if scene.kind == .quantity, let maximum = scene.maximum {
                    intensityLegend(maximum: maximum)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var weekdayLabels: some View {
        let symbols = LogCalendar.displayCalendar.shortStandaloneWeekdaySymbols
        let first = store.preferences.weekStart.rawValue - 1
        return VStack(alignment: .leading, spacing: cellSpacing) {
            ForEach(0..<7) { offset in
                Text(symbols[(first + offset) % 7])
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: cellSize)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.top, monthRowHeight + cellSpacing)
        .accessibilityHidden(true)
    }

    private func weekColumn(_ days: [DayKey?], selectedDay: DayKey) -> some View {
        VStack(spacing: cellSpacing) {
            Color.clear
                .frame(width: cellSize, height: monthRowHeight)
                .overlay(alignment: .leading) {
                    if let month = monthLabel(in: days) {
                        Text(month)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .accessibilityHidden(true)
                    }
                }
                .allowsHitTesting(false)

            ForEach(days.indices, id: \.self) { index in
                if let day = days[index] {
                    HeatmapCell(scene: scene, day: day, today: today, size: cellSize,
                                highlighted: day == selectedDay) { editDay(day) }
                } else {
                    Color.clear.frame(width: cellSize, height: cellSize)
                }
            }
        }
    }

    private func monthLabel(in days: [DayKey?]) -> String? {
        let calendar = LogCalendar.displayCalendar
        for case let day? in days where day <= today {
            let date = day.date
            let components = calendar.dateComponents([.month, .day], from: date)
            if components.day == 1 {
                return LogCalendar.label(date, template: components.month == 1 ? "yMMM" : "MMM")
            }
        }
        return nil
    }

    private func intensityLegend(maximum: Double) -> some View {
        let color = Color(logbookHex: scene.color)
        return HStack(spacing: 6) {
            Text("0")
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [color.opacity(scene.intensity(0)), color],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 56, height: 10)
            Text("\(maximum.formatted()) \(scene.unit)")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heatmap intensity from 0 to \(maximum.formatted()) \(scene.unit)")
    }
}

private struct SceneCheckInStatistics: View {
    @Environment(LogbookStore.self) private var store
    let sceneID: String
    let today: DayKey

    var body: some View {
        let stats = CheckInStatistics(days: store.library.checkInDays(for: sceneID), through: today)
        HStack(alignment: .top, spacing: 16) {
            metric("Current Streak", days: stats.currentStreak)
            metric("Longest Streak", days: stats.longestStreak)
            metric("Last 30 Days", days: stats.last30Days)
        }
    }

    private func metric(_ title: LocalizedStringKey, days: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Duration.seconds(Int64(days) * 86_400), format: .units(allowed: [.days], width: .wide))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct HeatmapCell: View {
    @Environment(LogbookStore.self) private var store
    @State private var hovered = false
    let scene: CheckInScene
    let day: DayKey
    let today: DayKey
    let size: CGFloat
    let highlighted: Bool
    let edit: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3)
        if day > today {
            shape.fill(.secondary.opacity(0.06)).frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            let entry = store.library.checkInDay(for: scene.id, on: day)
            let date = day.label
            let details = details(for: entry)
            Button(action: edit) {
                shape
                    .fill(entry.map { Color(logbookHex: scene.color).opacity(scene.intensity($0.total)) }
                          ?? Color.secondary.opacity(0.17))
                    .overlay {
                        if hovered || highlighted {
                            shape.strokeBorder(.primary.opacity(hovered ? 0.9 : 0.55), lineWidth: 1)
                        }
                    }
                    .frame(width: size, height: size)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help(([date] + details).joined(separator: "\n"))
            .accessibilityLabel(date)
            .accessibilityValue(details.joined(separator: ", "))
        }
    }

    private func details(for entry: CheckInDay?) -> [String] {
        guard let entry else { return [String(localized: "No entry")] }
        let headline = scene.kind == .quantity
            ? String(localized: "Total \(entry.total.formatted()) \(scene.unit)") : String(localized: "Completed")
        let notes = entry.entries.compactMap { record -> String? in
            guard !record.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if entry.entries.count > 1 {
                return "\(record.value.formatted()) \(scene.unit) · \(record.note)"
            }
            return record.note
        }
        return [headline] + notes
    }
}

private struct SceneEditor: View {
    @State var scene: CheckInScene
    let save: (CheckInScene) throws -> Void
    @Environment(LogbookStore.self) private var store
    @State private var maximum: String

    init(scene: CheckInScene, save: @escaping (CheckInScene) throws -> Void) {
        _scene = State(initialValue: scene)
        _maximum = State(initialValue: scene.maximum.map { String($0) } ?? "")
        self.save = save
    }

    var body: some View {
        let exists = store.library.scenes.contains { $0.id == scene.id }
        let hasHistory = store.library.firstCheckInDay(for: scene.id) != nil
        Editor(title: exists ? "Edit Scene" : "New Scene", save: saveScene) {
            TextField("Name", text: $scene.name)
            Picker("Record type", selection: $scene.kind) {
                ForEach(SceneKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .disabled(hasHistory)
            HStack {
                TextField("Color (hex)", text: $scene.color, prompt: Text("#237F69"))
                Circle().fill(Color(logbookHex: scene.color)).frame(width: 20, height: 20)
            }
            if scene.kind == .quantity {
                TextField("Unit", text: $scene.unit, prompt: Text("Minutes"))
                TextField("Heatmap maximum", text: $maximum, prompt: Text("60"))
                Text("Daily totals at or above this value use the darkest shade.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if exists { Toggle("Archived", isOn: $scene.archived) }
        }
    }

    private func saveScene() throws {
        var draft = scene
        draft.name = scene.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.unit = scene.kind == .quantity ? scene.unit.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        draft.color = scene.color.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !draft.name.isEmpty else { throw LogbookError.message("Enter a scene name.") }
        guard LogbookColor.isValidHex(draft.color) else { throw LogbookError.message("Enter a hex color such as #237F69.") }
        draft.maximum = nil
        if scene.kind == .quantity {
            guard !draft.unit.isEmpty, let parsed = CheckInScene.parseMaximum(maximum) else {
                throw LogbookError.message("Enter a unit and a positive heatmap maximum.")
            }
            draft.maximum = parsed
        }
        try save(draft)
    }
}

private struct CheckInEditor: View {
    let scene: CheckInScene
    let day: DayKey
    let existing: CheckIn?
    @Environment(LogbookStore.self) private var store
    @State private var completed = true
    @State private var note: String

    init(scene: CheckInScene, day: DayKey, existing: CheckIn?) {
        self.scene = scene
        self.day = day
        self.existing = existing
        _note = State(initialValue: existing?.note ?? "")
    }

    var body: some View {
        Editor(title: day.label, save: save) {
            Text(scene.name).foregroundStyle(.secondary)
            Toggle("Completed", isOn: $completed)
            if completed {
                TextField("Note (optional)", text: $note, axis: .vertical)
            }
        }
    }

    private func save() throws {
        guard store.library.checkIn(for: scene.id, on: day) == existing else {
            throw LogbookError.message("This check-in changed while the editor was open. Reopen it to edit the current record.")
        }
        let record = Record.checkIn(CheckIn(sceneID: scene.id, day: day, value: 1, note: note))
        if completed {
            try store.save([record])
        } else {
            try store.save(removing: [record.key])
        }
    }
}

private struct QuantityDayEditor: View {
    let scene: CheckInScene
    let day: DayKey
    @Environment(LogbookStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var quantity = ""
    @State private var note = ""
    @State private var editing: CheckIn?
    @State private var removing: CheckIn?
    @State private var error: String?
    @FocusState private var quantityFocused: Bool

    var body: some View {
        let summary = store.library.checkInDay(for: scene.id, on: day)
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Daily Total", value: valueLabel(summary?.total ?? 0))
                } header: {
                    Text(scene.name)
                }
                Section(editing == nil ? "New Record" : "Edit Record") {
                    TextField(scene.unit, text: $quantity)
                        .focused($quantityFocused)
                    TextField("Note (optional)", text: $note, axis: .vertical)
                    HStack {
                        Button(editing == nil ? "Add Record" : "Save Changes", action: save)
                            .buttonStyle(.borderedProminent)
                        if editing != nil { Button("Cancel Edit", action: clearDraft) }
                    }
                }
                if let summary {
                    Section("Records") {
                        ForEach(summary.entries) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(valueLabel(entry.value)).fontWeight(.medium)
                                    if !entry.note.isEmpty { Text(entry.note).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Button {
                                    editing = entry
                                    quantity = String(entry.value)
                                    note = entry.note
                                    quantityFocused = true
                                } label: {
                                    Label("Edit record", systemImage: "pencil").labelStyle(.iconOnly)
                                }
                                Button(role: .destructive) {
                                    removing = entry
                                } label: {
                                    Label("Delete record", systemImage: "trash").labelStyle(.iconOnly)
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(day.label)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360, idealHeight: 510)
        .alert("Delete this record?", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), presenting: removing) { entry in
            Button("Delete Record", role: .destructive) { delete(entry) }
            Button("Cancel", role: .cancel) {}
        }
        .logbookError($error)
    }

    private func valueLabel(_ value: Double) -> String { "\(value.formatted()) \(scene.unit)" }

    private func clearDraft() {
        editing = nil
        quantity = ""
        note = ""
    }

    private func save() {
        guard let value = Double(quantity.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value >= 0 else {
            error = "Enter a nonnegative quantity."
            return
        }
        do {
            var entry = CheckIn(sceneID: scene.id, day: day, value: value, note: note, entryID: UUID())
            if let editing {
                try ensureCurrent(editing)
                entry.entryID = editing.entryID
            }
            try store.save([.checkIn(entry)])
            clearDraft()
            quantityFocused = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ entry: CheckIn) {
        do {
            try ensureCurrent(entry)
            try store.save(removing: [Record.checkIn(entry).key])
            if editing?.id == entry.id { clearDraft() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func ensureCurrent(_ entry: CheckIn) throws {
        let record = Record.checkIn(entry)
        guard store.library.records[record.key] == record else {
            throw LogbookError.message("This record changed while the editor was open. Select it again to see the current record.")
        }
    }
}

private struct AllScenesOverview: View {
    @Environment(LogbookStore.self) private var store
    @State private var error: String?
    @State private var listFrame: CGRect = .zero
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var insertion: Int?

    let scenes: [CheckInScene]
    let today: DayKey
    let isEditing: Bool
    let selectScene: (CheckInScene) -> Void
    let editDay: (CheckInScene, DayKey) -> Void
    let reset: (CheckInScene) -> Void
    let delete: (CheckInScene) -> Void

    var body: some View {
        let showArchived = store.preferences.showArchivedScenes
        let canReorder = isEditing && scenes.count > 1
        let weeks = isEditing ? [] : HeatmapWindow(endingOn: today, count: 4).weeks
        return LazyVStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(today.label)
                Spacer()
                if !isEditing { Text("Last 4 Weeks") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
            .padding(.leading, canReorder ? 36 : 0)

            ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                VStack(spacing: 0) {
                    Divider()
                    sceneRow(scene, weeks: weeks, index: index, showArchived: showArchived, canReorder: canReorder)
                }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                    rowFrames[scene.id] = frame
                }
                .onDisappear { rowFrames.removeValue(forKey: scene.id) }
                .overlay(alignment: .top) {
                    if insertion == index { insertionLine }
                }
                .overlay(alignment: .bottom) {
                    if index == scenes.count - 1, insertion == scenes.count { insertionLine }
                }
            }
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { listFrame = $0 }
        .onChange(of: isEditing) { insertion = nil }
        .logbookError($error)
    }

    private func sceneRow(
        _ scene: CheckInScene, weeks: [[DayKey]], index: Int, showArchived: Bool, canReorder: Bool
    ) -> some View {
        HStack(spacing: 12) {
            if canReorder {
                SceneDragHandle { location in
                    let target = destination(at: location, in: scenes)
                    insertion = target == index || target == index + 1 ? nil : target
                } onDrop: { location in
                    insertion = nil
                    if let target = destination(at: location, in: scenes) {
                        move(scenes, from: IndexSet(integer: index), to: target, showArchived: showArchived)
                    }
                }
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            }
            if isEditing {
                sceneLabel(scene)
                    .accessibilityElement(children: .combine)
                    .accessibilityActions {
                        if index > 0 {
                            Button("Move Up") {
                                move(scenes, from: IndexSet(integer: index), to: index - 1, showArchived: showArchived)
                            }
                        }
                        if index + 1 < scenes.count {
                            Button("Move Down") {
                                move(scenes, from: IndexSet(integer: index), to: index + 2, showArchived: showArchived)
                            }
                        }
                    }
            } else {
                Button {
                    selectScene(scene)
                } label: {
                    sceneLabel(scene).contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if isEditing {
                Button("Reset", systemImage: "arrow.counterclockwise") { reset(scene) }
                    .disabled(store.library.firstCheckInDay(for: scene.id) == nil)
                    .help("Reset check-ins")
                Button("Delete", systemImage: "trash", role: .destructive) { delete(scene) }
                    .help("Delete scene")
            } else {
                recentHistory(for: scene, weeks: weeks)
            }
        }
        .padding(.vertical, 10)
    }

    private func sceneLabel(_ scene: CheckInScene) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color(logbookHex: scene.color)).frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(scene.name).font(.headline).lineLimit(1)
                todayStatus(for: scene, on: today)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func recentHistory(for scene: CheckInScene, weeks: [[DayKey]]) -> some View {
        HStack(spacing: 5) {
            ForEach(weeks, id: \.self) { week in
                HStack(spacing: 2) {
                    ForEach(week, id: \.self) { day in
                        HeatmapCell(scene: scene, day: day, today: today, size: 9,
                                    highlighted: day == today) {
                            editDay(scene, day)
                        }
                    }
                }
            }
        }
        .fixedSize()
        .environment(\.layoutDirection, .leftToRight)
    }

    private func todayStatus(for scene: CheckInScene, on today: DayKey) -> Text {
        if scene.archived { return Text("Archived") }
        guard let entry = store.library.checkInDay(for: scene.id, on: today) else { return Text("No entry today") }
        return scene.kind == .completion ? Text("Completed today") : Text("\(entry.total.formatted()) \(scene.unit) today")
    }

    private var insertionLine: some View {
        Rectangle().fill(.tint).frame(height: 2).allowsHitTesting(false)
    }

    private func destination(at location: CGPoint, in scenes: [CheckInScene]) -> Int? {
        guard listFrame.contains(location) else { return nil }
        var lastVisible: Int?
        for (index, scene) in scenes.enumerated() {
            guard let frame = rowFrames[scene.id] else { continue }
            if location.y < frame.midY { return index }
            lastVisible = index
        }
        return lastVisible.map { $0 + 1 }
    }

    private func move(_ visible: [CheckInScene], from offsets: IndexSet, to destination: Int, showArchived: Bool) {
        guard (0...visible.count).contains(destination),
              store.library.visibleScenes(showArchived: showArchived) == visible else { return }
        var reordered = visible
        reordered.move(fromOffsets: offsets, toOffset: destination)
        guard reordered != visible else { return }
        var next = reordered.makeIterator()
        let updates = store.library.scenes.enumerated().map { position, scene in
            var updated = scene
            if showArchived || !scene.archived, let replacement = next.next() { updated = replacement }
            updated.position = position
            return Record.scene(updated)
        }
        do { try store.save(updates) } catch { self.error = error.localizedDescription }
    }
}

private struct SceneDragHandle: NSViewRepresentable {
    let onDrag: (CGPoint) -> Void
    let onDrop: (CGPoint) -> Void

    func makeNSView(context: Context) -> Grip {
        let grip = Grip()
        grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
        grip.imageScaling = .scaleNone
        grip.contentTintColor = .secondaryLabelColor
        return grip
    }

    func updateNSView(_ grip: Grip, context: Context) {
        grip.onDrag = onDrag
        grip.onDrop = onDrop
    }

    final class Grip: NSImageView {
        var onDrag: ((CGPoint) -> Void)?
        var onDrop: ((CGPoint) -> Void)?
        private var dragging = false

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { dragging = false }

        override func mouseDragged(with event: NSEvent) {
            guard let location = location(inWindow: event) else { return }
            dragging = true
            onDrag?(location)
        }

        override func mouseUp(with event: NSEvent) {
            defer { dragging = false }
            if dragging, let location = location(inWindow: event) { onDrop?(location) }
        }

        private func location(inWindow event: NSEvent) -> CGPoint? {
            guard let content = window?.contentView else { return nil }
            let point = content.convert(event.locationInWindow, from: nil)
            return CGPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.maxY - point.y)
        }
    }
}
