import Charts
import AppKit
import SwiftUI

struct NordFinancePalette {
    let colorScheme: ColorScheme

    private var isDark: Bool { colorScheme == .dark }

    // Nord Frost, Polar Night, and Snow Storm for the comparison bars.
    var comparisonAccent: Color { Color(logbookHex: isDark ? "#88C0D0" : "#526E91") }
    var comparisonZero: Color { Color(logbookHex: isDark ? "#D8DEE9" : "#4C566A") }
    var track: Color { Color(logbookHex: isDark ? "#434C5E" : "#D8DEE9") }

    // Nord Aurora (nord14 and nord11) with higher-contrast shades for small text.
    func amount(_ amount: Decimal?) -> Color {
        guard let amount, amount != 0 else { return .secondary }
        if amount > 0 { return Color(logbookHex: isDark ? "#A3BE8C" : "#617161") }
        return Color(logbookHex: isDark ? "#CD8D95" : "#9F5761")
    }

    func bar(_ amount: Decimal) -> Color {
        if amount > 0 { return Color(logbookHex: isDark ? "#A3BE8C" : "#798C71") }
        if amount < 0 { return Color(logbookHex: "#BF616A") }
        return .secondary
    }
}

struct CashFlowChart: View {
    @Environment(\.colorScheme) private var colorScheme
    let currency: LedgerCurrency
    let report: CashFlowReport
    let metric: CashFlowMetric
    let history: ClosedRange<MonthKey>
    @Binding var month: MonthKey
    @State private var windowEnd: Int?
    @State private var chartWidth: CGFloat = 600

    private struct PlotPoint: Identifiable {
        let month: MonthKey
        let amount: Decimal
        let value: Double
        var id: MonthKey { month }
    }

    var body: some View {
        let palette = NordFinancePalette(colorScheme: colorScheme)
        let recent = history.upperBound.index
        let first = min(history.lowerBound.index,
                        max(12, recent - FinanceMonthChart.visibleMonths + 1))
        let visible = min(FinanceMonthChart.visibleMonths, recent - first + 1)
        let earliestEnd = first + visible - 1
        let end = min(recent, max(earliestEnd, windowEnd ?? recent))
        let indices = (end - visible + 1)...end
        let points = report.recordedMonths.map { month in
            let summary = report.month(month)
            let amount = metric.amount(in: summary)
            let value = NSDecimalNumber(decimal: currency.amount(amount)).doubleValue
            return PlotPoint(month: month, amount: amount, value: value)
        }
        let plot = points.filter { indices.contains($0.month.index) }
        let values = points.map(\.value)
        let minValue = min(0, values.min() ?? 0)
        let maxValue = max(0, values.max() ?? 0)
        let padding = minValue == maxValue ? 1 : (maxValue - minValue) * 0.08
        let barWidth = FinanceMonthChart.barWidth(chartWidth: chartWidth, monthCount: visible)
        VStack(alignment: .leading, spacing: 12) {
            Chart {
                RuleMark(y: .value("Zero", 0.0))
                    .foregroundStyle(.secondary.opacity(0.38))
                    .accessibilityHidden(true)
                ForEach(plot) { item in
                    let label = item.month.label
                    let amount = currency.format(item.amount)
                    if item.amount == 0 {
                        PointMark(x: .value("Month", Double(item.month.index)), y: .value(currency.rawValue, 0.0))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(label)
                            .accessibilityValue(amount)
                    } else {
                        BarMark(x: .value("Month", Double(item.month.index)),
                                yStart: .value("Zero", 0.0), yEnd: .value(currency.rawValue, item.value),
                                width: .fixed(barWidth))
                            .foregroundStyle(palette.bar(item.amount))
                            .accessibilityLabel(label)
                            .accessibilityValue(amount)
                    }
                }
                SelectedMonthMark(month: month, indices: indices)
            }
            .chartYScale(domain: (minValue - padding)...(maxValue + padding))
            .modifier(FinanceMonthChart(indices: indices, month: $month, history: history,
                                        browse: earliestEnd < recent ? { offset in
                                            let currentEnd = min(recent, max(earliestEnd, windowEnd ?? recent))
                                            windowEnd = min(recent, max(earliestEnd, currentEnd + offset))
                                        } : nil))
            .environment(\.layoutDirection, .leftToRight)
            .frame(height: 190)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { chartWidth = $0 }
            .accessibilityLabel(Text(metric.title))
            .accessibilityValue("\(MonthKey(index: indices.lowerBound).label) – \(MonthKey(index: end).label)")
            if points.isEmpty {
                Text("Record a transaction to see cash flow.").foregroundStyle(.secondary).font(.callout)
            }
        }
        .onChange(of: month, initial: true) { _, selected in
            if selected.index < indices.lowerBound {
                windowEnd = min(recent, selected.index + visible - 1)
            } else if selected.index > indices.upperBound {
                windowEnd = selected.index
            }
        }
    }
}

struct AccountBalanceChart: View {
    let currency: LedgerCurrency
    let report: BalanceReport
    let history: ClosedRange<MonthKey>
    let recent: MonthKey
    let themes: [String: String]
    @Binding var month: MonthKey
    @State private var windowEnd: Int?
    @State private var chartWidth: CGFloat = 600

    static let visibleMonths = FinanceMonthChart.visibleMonths

    var body: some View {
        let first = history.lowerBound.index
        let last = history.upperBound.index
        let visible = min(Self.visibleMonths, last - first + 1)
        let firstEnd = first + visible - 1
        let end = min(last, max(firstEnd, windowEnd ?? recent.index))
        let indices = (end - visible + 1)...end
        let months = report.recordedMonths.map { month -> [Balance] in
            let summary = report.month(month)
            guard summary.total != nil else { return [] }
            return summary.accounts.compactMap { summary.snapshots[$0.id] }
        }
        let balances = months.flatMap { $0 }
        let visibleBalances = balances.filter { indices.contains($0.month.index) }
        let barWidth = FinanceMonthChart.barWidth(chartWidth: chartWidth, monthCount: visible)
        let scale = balanceScale(months)
        let plottedIDs = Set(balances.map(\.accountID))
        let accounts = report.accounts.filter { plottedIDs.contains($0.id) }
        let names = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        let colors = accounts.map { Color(logbookHex: themes[$0.id] ?? Account.palette[0]) }
        VStack(alignment: .leading, spacing: 12) {
            Chart {
                ForEach(visibleBalances) { balance in
                    let name = names[balance.accountID, default: ""]
                    let amount = Decimal(balance.minorUnits)
                    if balance.minorUnits == 0 {
                        PointMark(x: .value("Month", Double(balance.month.index)), y: .value(currency.rawValue, 0.0))
                            .foregroundStyle(by: .value("Account", balance.accountID))
                            .accessibilityLabel("\(name), \(balance.month.label)")
                            .accessibilityValue(currency.format(amount))
                    } else {
                        BarMark(x: .value("Month", Double(balance.month.index)),
                                y: .value(currency.rawValue, NSDecimalNumber(decimal: currency.amount(amount)).doubleValue),
                                width: .fixed(barWidth), stacking: .standard)
                            .foregroundStyle(by: .value("Account", balance.accountID))
                            .accessibilityLabel("\(name), \(balance.month.label)")
                            .accessibilityValue(currency.format(amount))
                    }
                }
                SelectedMonthMark(month: month, indices: indices)
            }
            .chartForegroundStyleScale(domain: accounts.map(\.id), range: colors)
            .chartLegend(.hidden)
            .chartYScale(domain: scale)
            .modifier(FinanceMonthChart(indices: indices, month: $month, history: history,
                                        browse: firstEnd < last ? { offset in
                                            let current = min(last, max(firstEnd, windowEnd ?? recent.index))
                                            windowEnd = min(last, max(firstEnd, current + offset))
                                        } : nil))
            .environment(\.layoutDirection, .leftToRight)
            .frame(height: 190)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { chartWidth = $0 }
            .accessibilityLabel("Account balance trend")
            .accessibilityValue("\(MonthKey(index: indices.lowerBound).label) – \(MonthKey(index: end).label)")

            if balances.isEmpty {
                Text("Complete a month’s snapshots to plot a balance.")
                    .foregroundStyle(.secondary).font(.callout)
            }
        }
        .onChange(of: month) { _, selected in
            if selected.index < indices.lowerBound {
                windowEnd = min(last, selected.index + visible - 1)
            } else if selected.index > indices.upperBound {
                windowEnd = selected.index
            }
        }
    }

    private func balanceScale(_ months: [[Balance]]) -> ClosedRange<Double> {
        var low: Decimal = 0
        var high: Decimal = 0
        for balances in months {
            var negative: Decimal = 0
            var positive: Decimal = 0
            for balance in balances {
                negative += Decimal(min(0, balance.minorUnits))
                positive += Decimal(max(0, balance.minorUnits))
            }
            low = min(low, negative)
            high = max(high, positive)
        }
        let lower = NSDecimalNumber(decimal: currency.amount(low)).doubleValue
        let upper = NSDecimalNumber(decimal: currency.amount(high)).doubleValue
        let padding = lower == upper ? 1 : max(0.01, (upper - lower) * 0.04)
        return (lower - padding)...(upper + padding)
    }
}

private struct SelectedMonthMark: ChartContent {
    let month: MonthKey
    let indices: ClosedRange<Int>

    var body: some ChartContent {
        if indices.contains(month.index) {
            RuleMark(x: .value("Selected month", Double(month.index)))
                .foregroundStyle(.primary.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .accessibilityHidden(true)
        }
    }
}

private struct FinanceMonthChart: ViewModifier {
    let indices: ClosedRange<Int>
    @Binding var month: MonthKey
    let history: ClosedRange<MonthKey>
    var browse: ((Int) -> Void)? = nil

    static let visibleMonths = 24

    static func barWidth(chartWidth: CGFloat, monthCount: Int) -> CGFloat {
        min(42, max(4, (chartWidth - 56) / CGFloat(monthCount) * 0.74))
    }

    private var tickStride: Double {
        switch indices.count {
        case 19...: 6
        case 7...: 3
        case 4...: 2
        default: 1
        }
    }

    func body(content: Content) -> some View {
        let lower = Double(indices.lowerBound) - 0.5
        let upper = Double(indices.upperBound) + 0.5
        content
            .chartXScale(domain: lower...upper)
            .chartXAxis {
                AxisMarks(values: .stride(by: tickStride, roundLowerBound: false, roundUpperBound: false)) { value in
                    AxisTick()
                    AxisValueLabel(anchor: .top) {
                        if let index = value.as(Double.self) { Text(MonthKey(index: Int(index)).label) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount.formatted(.number.notation(.compactName)))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let anchor = proxy.plotFrame {
                        let frame = geometry[anchor]
                        if let browse {
                            FinanceHistoryInput(monthCount: indices.count, browse: browse) { x in
                                select(at: x, in: proxy)
                            }
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            .accessibilityHidden(true)
                        } else {
                            Rectangle()
                                .fill(.clear)
                                .contentShape(.rect)
                                .gesture(SpatialTapGesture().onEnded { select(at: $0.location.x, in: proxy) })
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
    }

    private func select(at x: CGFloat, in proxy: ChartProxy) {
        guard let value: Double = proxy.value(atX: x) else { return }
        let index = min(indices.upperBound, max(indices.lowerBound, Int(value.rounded())))
        let selection = MonthKey(index: index)
        if history.contains(selection) { month = selection }
    }
}

private struct FinanceHistoryInput: NSViewRepresentable {
    let monthCount: Int
    let browse: (Int) -> Void
    let select: (CGFloat) -> Void

    func makeNSView(context: Context) -> InputView { InputView() }

    func updateNSView(_ view: InputView, context: Context) {
        view.monthCount = monthCount
        view.browse = browse
        view.select = select
    }

    final class InputView: NSView {
        var monthCount = 1
        var browse: ((Int) -> Void)?
        var select: ((CGFloat) -> Void)?
        private var scrollRemainder: CGFloat = 0
        private var dragStart: CGPoint?
        private var draggedMonths = 0

        private var monthWidth: CGFloat { max(1, bounds.width / CGFloat(monthCount)) }

        override func scrollWheel(with event: NSEvent) {
            if event.phase == .began { scrollRemainder = 0 }
            let horizontal = event.scrollingDeltaX
            guard abs(horizontal) > abs(event.scrollingDeltaY) else {
                super.scrollWheel(with: event)
                return
            }
            // AppKit deltas already reflect the system scroll direction. Move the viewport opposite the content.
            let delta = -horizontal
            scrollRemainder += event.hasPreciseScrollingDeltas ? delta / monthWidth : delta
            let offset = Int(scrollRemainder)
            guard offset != 0 else { return }
            scrollRemainder -= CGFloat(offset)
            browse?(offset)
        }

        override func mouseDown(with event: NSEvent) {
            dragStart = event.locationInWindow
            draggedMonths = 0
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart else { return }
            let dx = event.locationInWindow.x - start.x
            guard abs(dx) > abs(event.locationInWindow.y - start.y) else { return }
            let offset = Int((-dx / monthWidth).rounded())
            guard offset != draggedMonths else { return }
            browse?(offset - draggedMonths)
            draggedMonths = offset
        }

        override func mouseUp(with event: NSEvent) {
            defer { dragStart = nil }
            guard let start = dragStart,
                  hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) < 4 else { return }
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point) { select?(point.x) }
        }
    }
}

struct CurrencySelection: View {
    private let title: LocalizedStringKey
    private let showsLabel: Bool
    @Binding var currency: LedgerCurrency
    @State private var showingMenu = false
    @State private var search = ""

    init(_ title: LocalizedStringKey = "Currency", currency: Binding<LedgerCurrency>, showsLabel: Bool = true) {
        self.title = title
        self.showsLabel = showsLabel
        _currency = currency
    }

    var body: some View {
        if showsLabel {
            LabeledContent(title) { button }
        } else {
            button
        }
    }

    private var button: some View {
        Button {
            search = ""
            showingMenu = true
        } label: {
            Label(currency.label, systemImage: "chevron.up.chevron.down")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel(title)
        .accessibilityValue(currency.label)
        .popover(isPresented: $showingMenu) {
            VStack(spacing: 8) {
                TextField("Search currencies", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding([.horizontal, .top], 10)
                List(options) { option in
                    Button {
                        currency = option
                        showingMenu = false
                    } label: {
                        HStack {
                            Text(option.label)
                            Spacer()
                            if option == currency {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option == currency ? .isSelected : [])
                }
                .listStyle(.plain)
            }
            .frame(width: 330, height: 330)
        }
    }

    private var options: [LedgerCurrency] {
        let others = LedgerCurrency.available.filter { $0 != currency }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([currency] + others).filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) }
    }
}

struct MonthNavigation: View {
    let title: String
    @Binding var month: MonthKey
    let bounds: ClosedRange<MonthKey>
    @State private var showingPicker = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                month = month.adding(months: -1)
            } label: {
                Label("Previous Month", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
            .disabled(month <= bounds.lowerBound)
            Button(month.label) { showingPicker = true }
                .fontWeight(.medium)
                .accessibilityLabel("Selected month, \(month.label)")
                .popover(isPresented: $showingPicker) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title).font(.headline)
                        SystemMonthPicker(title: title, month: $month, bounds: bounds).fixedSize()
                        if bounds.lowerBound != bounds.upperBound {
                            Text("\(bounds.lowerBound.label) – \(bounds.upperBound.label)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(14)
                    .presentationCompactAdaptation(.popover)
                }
            Button {
                month = month.adding(months: 1)
            } label: {
                Label("Next Month", systemImage: "chevron.right").labelStyle(.iconOnly)
            }
            .disabled(month >= bounds.upperBound)
        }
        .buttonStyle(.bordered)
    }
}

struct MonthField: View {
    let title: String
    @Binding var month: MonthKey

    var body: some View {
        LabeledContent(title) {
            SystemMonthPicker(title: title, month: $month, bounds: nil).fixedSize()
        }
    }
}

private struct SystemMonthPicker: NSViewRepresentable {
    let title: String
    @Binding var month: MonthKey
    let bounds: ClosedRange<MonthKey>?

    func makeCoordinator() -> Coordinator { Coordinator(month: $month) }

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .yearMonth
        picker.locale = .autoupdatingCurrent
        picker.calendar = LogCalendar.displayMonthCalendar
        picker.timeZone = LogCalendar.utc
        picker.setAccessibilityLabel(title)
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.month = $month
        let minDate = bounds?.lowerBound.date ?? DayKey.dateBounds.lowerBound
        let endOfMonth = bounds.flatMap { LogCalendar.gregorian().dateInterval(of: .month, for: $0.upperBound.date)?.end }
        let maxDate = min(endOfMonth?.addingTimeInterval(-1) ?? DayKey.dateBounds.upperBound, DayKey.dateBounds.upperBound)
        if picker.minDate != minDate || picker.maxDate != maxDate {
            picker.minDate = nil
            picker.maxDate = maxDate
            picker.minDate = minDate
        }
        if MonthKey(picker.dateValue) != month { picker.dateValue = month.date }
    }

    final class Coordinator: NSObject {
        var month: Binding<MonthKey>
        init(month: Binding<MonthKey>) { self.month = month }

        @MainActor @objc func changed(_ picker: NSDatePicker) {
            month.wrappedValue = MonthKey(picker.dateValue)
        }
    }
}
