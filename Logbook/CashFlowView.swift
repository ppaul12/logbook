import SwiftUI

struct CashFlowView: View {
    @Environment(LogbookStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Binding var currency: LedgerCurrency
    @State var month: MonthKey
    @Binding var metric: CashFlowMetric
    @State private var draft: Transaction?
    @State private var deletion: Transaction?
    @State private var error: String?

    var body: some View {
        let current = store.preferences.today.month
        let report = CashFlowReport(library: store.library, currency: currency)
        let history = report.history(through: current)
        let selected = min(max(month, history.lowerBound), history.upperBound)
        let monthSelection = Binding(get: { selected }, set: { month = $0 })
        let summary = report.month(selected)
        let average = report.average(before: selected, current: current, period: store.preferences.cashFlowAveragePeriod)
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    metricMenu
                    Spacer(minLength: 12)
                    CurrencySelection(currency: $currency, showsLabel: false)
                }
                Divider()
                CashFlowChart(currency: currency, report: report, metric: metric,
                              history: history, month: monthSelection)
                    .id(currency)
                Divider()
                transactions(summary, average: average, month: monthSelection, history: history)
            }
            .padding(20)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Transaction", systemImage: "plus") {
                    let today = store.preferences.today
                    let day = today.month == selected ? today : DayKey(selected.date)
                    draft = Transaction(day: day, kind: metric.transactionKind ?? .expense, currency: currency)
                }
            }
        }
        .onChange(of: history) { month = selected }
        .sheet(item: $draft) { entry in
            TransactionEditor(entry: entry) { saved in
                try store.save([.transaction(saved)])
                currency = saved.currency
                month = saved.postingMonth
            }
        }
        .confirmationDialog("Delete this transaction?", isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }
        ), titleVisibility: .visible, presenting: deletion) { entry in
            Button("Delete Transaction", role: .destructive) {
                do { try store.save(removing: [Record.transaction(entry).key]) }
                catch { self.error = error.localizedDescription }
            }
        }
        .logbookError($error)
    }

    private var palette: NordFinancePalette {
        NordFinancePalette(colorScheme: colorScheme)
    }

    private var metricMenu: some View {
        Menu {
            Picker("Cash Flow View", selection: $metric) {
                ForEach(CashFlowMetric.allCases, id: \.self) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(metric.title).font(.largeTitle.bold()).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .accessibilityLabel("Cash Flow View")
        .accessibilityValue(Text(metric.title))
        .accessibilityAddTraits(.isHeader)
    }

    private func transactions(_ summary: CashFlowMonth, average: CashFlowMonthlyAverage?, month: Binding<MonthKey>,
                              history: ClosedRange<MonthKey>) -> some View {
        let entries = metric.entries(in: summary)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transactions")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                MonthNavigation(title: "Transaction month", month: month, bounds: history)
            }
            monthlyTotals(summary, average: average)
            averageRange(average)
            if entries.isEmpty {
                Text("No transactions to show for this month.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        Divider()
                        transactionRow(entry)
                    }
                }
            }
        }
    }

    private func monthlyTotals(_ summary: CashFlowMonth, average: CashFlowMonthlyAverage?) -> some View {
        let totals = metric == .netIncome ? CashFlowMetric.allCases : [metric]
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                ForEach(totals, id: \.self) { item in
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            GridRow(alignment: .firstTextBaseline) {
                ForEach(totals, id: \.self) { item in
                    let amount = item.amount(in: summary)
                    let formatted = currency.format(amount)
                    Text(formatted)
                        .font((item == metric ? Font.title2 : .body).weight(.semibold).monospacedDigit())
                        .foregroundStyle(palette.amount(amount))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityLabel("\(Text(item.title)) \(formatted)")
                }
            }
            GridRow(alignment: .top) {
                ForEach(totals, id: \.self) { item in
                    CashFlowAverageBar(metric: item, amount: item.amount(in: summary),
                                       average: average.map { item.amount(in: $0) }, currency: currency)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func averageRange(_ average: CashFlowMonthlyAverage?) -> some View {
        HStack(spacing: 12) {
            Group {
                if let months = average?.months {
                    let start = months.lowerBound.label
                    let range = months.lowerBound == months.upperBound ? start : "\(start) – \(months.upperBound.label)"
                    Text("Based on \(range)")
                } else {
                    Text("No completed months to average")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Picker("Monthly average period", selection: averagePeriodSelection) {
                ForEach(CashFlowAveragePeriod.allCases, id: \.self) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var averagePeriodSelection: Binding<CashFlowAveragePeriod> {
        Binding {
            store.preferences.cashFlowAveragePeriod
        } set: { period in
            var preferences = store.preferences
            preferences.cashFlowAveragePeriod = period
            do { try store.save(preferences: preferences) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func transactionRow(_ entry: Transaction) -> some View {
        let amount = (entry.kind == .expense ? -1 : 1) * Decimal(entry.minorUnits)
        let note = entry.trimmedNote
        return Button {
            draft = entry
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if note.isEmpty {
                        Text("No note").foregroundStyle(.secondary)
                    } else {
                        Text(note).fontWeight(.medium)
                    }
                    Spacer(minLength: 0)
                    Text(currency.format(amount, showPlus: true))
                        .monospacedDigit()
                        .foregroundStyle(palette.amount(amount))
                        .minimumScaleFactor(0.65)
                        .layoutPriority(1)
                }
                .font(.callout)
                .lineLimit(1)
                HStack(spacing: 4) {
                    Text(entry.day.label).layoutPriority(1)
                    Text("·")
                    if entry.kind == .expense {
                        if entry.category.isEmpty {
                            Text("Uncategorized")
                        } else {
                            Text(entry.category)
                        }
                        if !entry.paymentMethod.isEmpty {
                            Text("·")
                            Text(entry.paymentMethod)
                        }
                    } else {
                        Text("Income")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete Transaction", role: .destructive) { deletion = entry }
        }
    }

}

private struct CashFlowAverageBar: View {
    @Environment(\.colorScheme) private var colorScheme
    let metric: CashFlowMetric
    let amount: Decimal
    let average: Decimal?
    let currency: LedgerCurrency

    var body: some View {
        let palette = NordFinancePalette(colorScheme: colorScheme)
        let progress = CashFlowAverageProgress(metric: metric, amount: amount, average: average)
        let signed = metric == .netIncome
        let fillStart = min(progress.zero, progress.fillEnd)
        let fillWidth = abs(progress.fillEnd - progress.zero)
        let fillColor = signed ? palette.amount(amount) : palette.comparisonAccent
        let percentColor = signed && progress.ratio != nil ? palette.amount(amount) : .secondary
        let averageValue = average.map { currency.format($0) } ?? "—"
        let format = Decimal.FormatStyle.Percent().precision(.fractionLength(0...1))
        let percent = progress.ratio.map {
            $0.formatted(signed ? format.sign(strategy: .always(includingZero: false)) : format)
        } ?? "—"
        let difference = average.map { currency.format(amount - $0, showPlus: true) } ?? "—"
        return VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.track).frame(height: 6)
                    if fillWidth > 0 {
                        Capsule().fill(fillColor)
                            .frame(width: geometry.size.width * fillWidth, height: 6)
                            .offset(x: geometry.size.width * fillStart)
                    }
                    if signed {
                        Rectangle().fill(palette.comparisonZero)
                            .frame(width: 1, height: 6)
                            .position(x: geometry.size.width * progress.zero, y: geometry.size.height / 2)
                    }
                    if let marker = progress.averageMarker {
                        Rectangle().fill(palette.comparisonAccent)
                            .frame(width: 1, height: 10)
                            .position(x: geometry.size.width * marker, y: geometry.size.height / 2)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 10)
            .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text("Avg. \(averageValue)").fixedSize()
                    Spacer(minLength: 0)
                    Text(percent).foregroundStyle(percentColor).fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Avg. \(averageValue)").lineLimit(1).minimumScaleFactor(0.7)
                    Text(percent).foregroundStyle(percentColor)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Text(metric.title)). Monthly average \(averageValue). Percentage of average \(percent). Difference from average \(difference).")
        .help("Difference from monthly average \(difference)")
    }
}

private extension CashFlowAveragePeriod {
    var title: LocalizedStringKey {
        if self == .allHistory { return "All History" }
        return "Last \(rawValue) months"
    }
}

extension CashFlowMetric {
    var title: LocalizedStringKey {
        switch self {
        case .netIncome: "Net Income"
        case .income: "Income"
        case .expense: "Expense"
        }
    }
}

private struct TransactionEditor: View {
    @Environment(LogbookStore.self) private var store
    @State private var entry: Transaction
    @State private var amount: String
    let save: (Transaction) throws -> Void

    init(entry: Transaction, save: @escaping (Transaction) throws -> Void) {
        _entry = State(initialValue: entry)
        _amount = State(initialValue: entry.minorUnits == 0 ? "" : entry.currency.plain(entry.minorUnits))
        self.save = save
    }

    var body: some View {
        let exists = store.library.transactions.contains { $0.id == entry.id }
        Editor(title: exists ? "Edit Transaction" : "New Transaction", save: saveEntry) {
            LabeledContent("Direction") {
                Picker("Direction", selection: $entry.kind) {
                    ForEach(TransactionKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
            }
            LogbookDatePicker(title: "Transaction date", day: $entry.day, todayShortcut: store.preferences.today)
            CurrencySelection(currency: $entry.currency)
            TextField("Amount (\(entry.currency.rawValue))", text: $amount)
            TextField("Note", text: $entry.note, axis: .vertical)
                .lineLimit(1...5)
            if entry.kind == .expense {
                TextField("Category (optional)", text: $entry.category)
                TextField("Payment method (optional)", text: $entry.paymentMethod)
                HStack {
                    Spacer(minLength: 0)
                    Toggle("Settle next month", isOn: $entry.settlesNextMonth)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                }
            }
        }
    }

    private func saveEntry() throws {
        try entry.validateNote()
        guard let minorUnits = entry.currency.parse(amount), minorUnits > 0 else {
            throw LogbookError.message("Enter a positive amount in \(entry.currency.rawValue) with up to \(entry.currency.fractionDigits) decimal places.")
        }
        guard entry.postingMonth.index <= 119_999 else {
            throw LogbookError.message("Choose a date with a posting month before year 10000.")
        }
        var saved = entry
        saved.note = entry.trimmedNote
        saved.minorUnits = minorUnits
        saved.paymentMethod = saved.kind == .expense
            ? saved.paymentMethod.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        saved.settlesNextMonth = saved.kind == .expense && saved.settlesNextMonth
        saved.category = saved.kind == .expense
            ? saved.category.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        try save(saved)
    }
}
