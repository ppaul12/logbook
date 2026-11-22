import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(LogbookStore.self) private var store
    @State private var kind = CSVKind.scenes
    @State private var input: Input = .csv(.scenes)
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var export: Export?
    @State private var preview: PendingImport?
    @State private var error: String?
    @State private var notice: (message: String, isBackup: Bool)?

    private enum Input {
        case csv(CSVKind), backup
        var type: UTType {
            switch self {
            case .csv: .commaSeparatedText
            case .backup: .json
            }
        }
    }

    private struct PendingImport: Identifiable {
        let id = UUID()
        let plan: ImportPreview
        let generation: Int
    }

    private struct Export {
        var document: LogbookDocument
        var type: UTType
        var filename: String
    }

    var body: some View {
        Form {
            Section("General") {
                TextField("Greeting name", text: preference(\.greetingName), prompt: Text("Optional"))
                TimeZonePicker(selection: preference(\.timeZoneID))
            }

            Section("Check-ins") {
                Picker("Week starts on", selection: preference(\.weekStart)) {
                    ForEach(WeekStart.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Show archived scenes", isOn: preference(\.showArchivedScenes))
                    .toggleStyle(.switch)
            }

            Section("Bookkeeping") {
                CurrencySelection("Default currency", currency: preference(\.defaultCurrency))
            }

            Section("Data Management") {
                csvSettings
                backupSettings
            }
        }
        .formStyle(.grouped)
        .logbookError($error)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [input.type]) { result in
            do { try loadImport(result.get()) }
            catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $showingExporter, document: export?.document,
                      contentType: export?.type ?? .data, defaultFilename: export?.filename) { result in
            do {
                let url = try result.get()
                notice = ("Saved \(url.lastPathComponent).", isBackup: export?.type == .json)
            } catch { self.error = error.localizedDescription }
        }
        .sheet(item: $preview) { pending in
            ImportReview(plan: pending.plan) { changes, preferences in
                guard store.generation == pending.generation else {
                    throw LogbookError.message("Logbook changed while this preview was open. Close it and import the file again.")
                }
                try store.save(changes, preferences: preferences, restoringBackup: pending.plan.isBackup)
                notice = ("Saved \(changes.count) imported \(changes.count == 1 ? "record" : "records").",
                          isBackup: pending.plan.isBackup)
            }
        }
    }

    @ViewBuilder
    private var csvSettings: some View {
        Text("CSV Import & Export")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
        Picker("Data type", selection: $kind) {
            ForEach(CSVKind.allCases) { Text($0.label).tag($0) }
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { csvActions }
            VStack(alignment: .leading, spacing: 8) { csvActions }
        }
        .buttonStyle(.bordered)

        Text("Import scenes and accounts before importing their entries and snapshots.")
            .font(.footnote)
            .foregroundStyle(.secondary)

        if let notice, !notice.isBackup {
            Label(notice.message, systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var backupSettings: some View {
        Text("Backup & Restore")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { backupActions }
            VStack(alignment: .leading, spacing: 8) { backupActions }
        }
        .buttonStyle(.bordered)

        Text("A backup includes all records and preferences. Review the backup before restoring and choose whether to restore preferences.")
            .font(.footnote)
            .foregroundStyle(.secondary)

        if let notice, notice.isBackup {
            Label(notice.message, systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var csvActions: some View {
        Button("Import CSV…") {
            input = .csv(kind)
            showingImporter = true
        }
        Button("Export CSV…") {
            do {
                let csv = try kind.export(store.library)
                prepareExport(Data(csv.utf8), type: .commaSeparatedText, filename: kind.filename)
            } catch { self.error = error.localizedDescription }
        }
        Button("Save Template…") {
            prepareExport(Data(kind.template.utf8), type: .commaSeparatedText, filename: kind.filename)
        }
    }

    @ViewBuilder
    private var backupActions: some View {
        Button("Create Backup…") {
            do {
                let backup = try LogbookBackup(library: store.library, preferences: store.preferences)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try prepareExport(encoder.encode(backup), type: .json, filename: "Logbook-backup.json")
            } catch { self.error = error.localizedDescription }
        }
        Button("Restore from Backup…") {
            input = .backup
            showingImporter = true
        }
    }

    private func preference<Value>(_ path: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding {
            store.preferences[keyPath: path]
        } set: { value in
            var preferences = store.preferences
            preferences[keyPath: path] = value
            do { try store.save(preferences: preferences) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func prepareExport(_ data: Data, type: UTType, filename: String) {
        export = Export(document: LogbookDocument(data: data), type: type, filename: filename)
        showingExporter = true
    }

    private func loadImport(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let plan: ImportPreview
        switch input {
        case .csv(let kind):
            guard let csv = String(data: data, encoding: .utf8) else {
                throw LogbookError.message("Choose a CSV file encoded as UTF-8.")
            }
            plan = ImportPreview(csv: csv, kind: kind, library: store.library)
        case .backup:
            plan = try ImportPreview(backup: LogbookBackup.read(data), library: store.library)
        }
        preview = PendingImport(plan: plan, generation: store.generation)
    }
}

private struct TimeZonePicker: View {
    @Binding var selection: String
    @State private var showingZones = false
    @State private var search = ""

    private var zones: [String] {
        let known = Set(TimeZone.knownTimeZoneIdentifiers + [selection, "UTC"])
        return known.sorted().filter { search.isEmpty || label($0).localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Button {
            search = ""
            showingZones = true
        } label: {
            LabeledContent("Recording time zone", value: label(selection))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingZones) {
            NavigationStack {
                List(zones, id: \.self) { zone in
                    Button {
                        selection = zone
                        showingZones = false
                    } label: {
                        HStack {
                            Text(label(zone))
                            Spacer()
                            if zone == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .searchable(text: $search, prompt: "Search time zones")
                .navigationTitle("Recording Time Zone")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingZones = false } }
                }
            }
            .frame(minWidth: 430, minHeight: 360)
        }
    }

    private func label(_ zone: String) -> String {
        let identifier = zone.replacingOccurrences(of: "_", with: " ")
        guard let name = TimeZone(identifier: zone)?.localizedName(for: .generic, locale: .autoupdatingCurrent)
        else { return identifier }
        return String(localized: "\(name) (\(identifier))")
    }
}

private struct ImportReview: View {
    let plan: ImportPreview
    let apply: ([Record], Preferences?) throws -> Void
    @State private var choices: [String: String] = [:]
    @State private var restorePreferences = true

    var body: some View {
        let result = Result { try plan.changes(choices: choices) }
        Editor(title: plan.preferences == nil ? "Review CSV Import" : "Review Backup Restore",
               action: plan.preferences == nil ? "Import" : "Restore", save: {
            try apply(result.get(), restorePreferences ? plan.preferences : nil)
        }) {
            Section("Summary") {
                ForEach(ImportPreview.Item.Status.allCases, id: \.self) { status in
                    LabeledContent(status.rawValue, value: String(plan.count(status)))
                }
                if plan.preferences != nil {
                    Toggle("Restore preferences", isOn: $restorePreferences)
                }
                if case .failure(let error) = result {
                    Text(error.localizedDescription).foregroundStyle(.red)
                }
            }
            if !plan.conflicts.isEmpty {
                Section("Resolve Conflicts") {
                    ForEach(plan.conflicts) { conflict in
                        conflictPicker(conflict)
                    }
                }
            }
            if !plan.items.isEmpty {
                Section("Rows") {
                    ForEach(plan.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(item.status.rawValue) · \(item.location)").fontWeight(.medium)
                            Text(item.detail)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func conflictPicker(_ conflict: ImportPreview.Conflict) -> some View {
        Picker("Use record", selection: Binding(
            get: { choices[conflict.id] ?? conflict.defaultChoice },
            set: { choices[conflict.id] = $0 }
        )) {
            if conflict.existing != nil { Text("Keep saved record").tag("") }
            ForEach(conflict.incoming) { item in
                Text("Use line \(item.line)").tag(item.id)
            }
        }
        if let existing = conflict.existing {
            Text("Saved record · \(plan.existingDetails(existing))")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(conflict.incoming) { item in
            Text("\(item.location) · \(item.detail)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct LogbookDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText, .json]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
