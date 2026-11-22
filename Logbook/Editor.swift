import AppKit
import SwiftUI

struct Editor<Fields: View>: View {
    let title: String
    var action: String = "Save"
    let save: () throws -> Void
    @ViewBuilder let fields: () -> Fields
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                fields()
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .environment(\.locale, .autoupdatingCurrent)
            .environment(\.timeZone, LogCalendar.utc)
            .environment(\.calendar, LogCalendar.displayCalendar)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action) {
                        do {
                            try save()
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
            }
        }
        .frame(minWidth: 450, idealWidth: 510, minHeight: 320, idealHeight: 430)
    }
}

struct RemovalConfirmation: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            Text(message).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, role: .destructive, action: confirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 380)
    }
}

struct LogbookDatePicker: View {
    let title: LocalizedStringKey
    @Binding var day: DayKey
    var latest: DayKey? = nil
    var showsLabel = true
    var todayShortcut: DayKey? = nil
    @State private var showingPicker = false
    @State private var input = ""
    @State private var invalidDate = false

    private var bounds: ClosedRange<Date> {
        DayKey.dateBounds.lowerBound...(latest?.date ?? DayKey.dateBounds.upperBound)
    }

    var body: some View {
        if showsLabel {
            LabeledContent(title) { pickerButton }
        } else {
            pickerButton
        }
    }

    private var pickerButton: some View {
        Button {
            input = day.label
            invalidDate = false
            showingPicker = true
        } label: {
            Label(day.label, systemImage: "calendar")
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(day.label)
        .popover(isPresented: $showingPicker) {
            Grid(alignment: .leading, verticalSpacing: 8) {
                TextField(title, text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyInput)
                    .onChange(of: input) { invalidDate = false }
                    .gridCellUnsizedAxes(.horizontal)
                if invalidDate {
                    Group {
                        if let latest {
                            Text("Enter a valid date on or before \(latest.label).")
                        } else {
                            Text("Enter a valid date.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .gridCellUnsizedAxes(.horizontal)
                }
                DatePicker(title, selection: Binding(get: { day.date }, set: select),
                           in: bounds, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .fixedSize()
                HStack {
                    if let todayShortcut {
                        Button("Today") { select(todayShortcut.date) }
                    }
                    Spacer(minLength: 0)
                    Button("Apply", action: applyInput)
                }
                .gridCellUnsizedAxes(.horizontal)
            }
            .padding(12)
            .environment(\.locale, .autoupdatingCurrent)
            .environment(\.timeZone, LogCalendar.utc)
            .environment(\.calendar, LogCalendar.displayCalendar)
        }
    }

    private func applyInput() {
        let entered = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if entered == day.label, bounds.contains(day.date) {
            showingPicker = false
            return
        }
        let firstDayStart = LogCalendar.gregorian().startOfDay(for: bounds.lowerBound)
        guard let date = LogCalendar.parseDateLabel(entered), (firstDayStart...bounds.upperBound).contains(date) else {
            invalidDate = true
            return
        }
        select(date)
    }

    private func select(_ date: Date) {
        day = DayKey(date)
        showingPicker = false
    }
}

extension View {
    func logbookError(_ errors: Binding<String?>) -> some View {
        alert("Logbook", isPresented: Binding(
            get: { errors.wrappedValue != nil },
            set: { if !$0 { errors.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errors.wrappedValue ?? "")
        }
    }
}

extension Color {
    init(logbookHex hex: String) {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0x237F69
        self.init(
            red: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255,
            blue: Double(rgb & 255) / 255
        )
    }

    var logbookHex: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
            Int((min(1, max(0, $0)) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }
}
