import AppKit
import SwiftUI

enum Destination: String, Identifiable {
    case checkIns
    case accountBalances
    case monthlyCashFlow
    case settings

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .checkIns: "Check-in Heatmaps"
        case .accountBalances: "Account Balances"
        case .monthlyCashFlow: "Cash Flow"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .checkIns: "calendar"
        case .accountBalances: "wallet.bifold"
        case .monthlyCashFlow: "chart.line.uptrend.xyaxis"
        case .settings: "gearshape"
        }
    }
}

private enum SidebarGroup: String, CaseIterable, Identifiable {
    case checkIns, bookkeeping

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .checkIns: "Check-ins"
        case .bookkeeping: "Bookkeeping"
        }
    }

    var destinations: [Destination] {
        switch self {
        case .checkIns: [.checkIns]
        case .bookkeeping: [.accountBalances, .monthlyCashFlow]
        }
    }
}

struct RootView: View {
    @Environment(LogbookStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cashFlowCurrency: LedgerCurrency?
    @State private var cashFlowMetric = CashFlowMetric.netIncome
    @State private var balanceCurrency: LedgerCurrency?
    @State private var checkInSelection: CheckInSelection = .allScenes
    @State private var balanceAccountID: String?
    @State private var selection: Destination?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private struct Page: Equatable {
        let destination: Destination?
        let checkIn: CheckInSelection?
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: selection, onSelect: select)
                .navigationTitle("Logbook")
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            screen
        }
        .navigationSplitViewStyle(.balanced)
        .onOpenURL(perform: open)
    }

    private var screen: some View {
        let page = Page(destination: selection, checkIn: selection == .checkIns ? checkInSelection : nil)
        let reduceMotion = self.reduceMotion
        return detailContent
            .overlay {
                PhaseAnimator([0.0, 0.18], trigger: reduceMotion ? nil : page) { opacity in
                    Color(nsColor: .windowBackgroundColor).opacity(reduceMotion ? 0 : opacity)
                } animation: { opacity in
                    opacity == 0 ? .easeOut(duration: 0.16) : nil
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .navigationTitle(selection?.title ?? "Logbook")
            .onChange(of: store.preferences.defaultCurrency) {
                cashFlowCurrency = nil
                balanceCurrency = nil
            }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let selection {
            DestinationView(destination: selection, cashFlowCurrency: $cashFlowCurrency, cashFlowMetric: $cashFlowMetric,
                            balanceCurrency: $balanceCurrency, checkInSelection: $checkInSelection,
                            balanceAccountID: $balanceAccountID)
        } else {
            let greetingName = store.preferences.greetingName
            TimelineView(.everyMinute) { context in
                let greeting = WelcomeGreeting(date: context.date, displayName: greetingName)
                HStack(spacing: 24) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: greeting.title)
                            .font(.largeTitle.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(verbatim: greeting.message)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.leading)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func select(_ destination: Destination?) {
        if destination == .checkIns { checkInSelection = .allScenes }
        if destination == .accountBalances { balanceAccountID = nil }
        if destination == .monthlyCashFlow { cashFlowMetric = .netIncome }
        guard selection != destination else { return }
        selection = destination
    }

    private func open(_ url: URL) {
        guard url.scheme == "logbook", url.host == "scene" || url.host == "check-ins" else { return }
        checkInSelection = LogbookLinks.sceneID(from: url).map(CheckInSelection.scene) ?? .allScenes
        selection = .checkIns
    }
}

private struct SidebarView: View {
    let selection: Destination?
    let onSelect: (Destination?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(SidebarGroup.allCases) { section in
                            group(section.title, destinations: section.destinations)
                        }
                    }
                    .padding(12)
                    .frame(minHeight: viewport.size.height, alignment: .top)
                    .background { deselectionTarget }
                }
            }
            Divider()
            row(.settings)
                .padding(12)
                .background { deselectionTarget }
        }
    }

    private var deselectionTarget: some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture { onSelect(nil) }
            .accessibilityHidden(true)
    }

    private func group(_ title: LocalizedStringKey, destinations: [Destination]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 10)

            ForEach(destinations) { destination in
                row(destination)
            }
        }
    }

    private func row(_ destination: Destination) -> some View {
        Button {
            onSelect(destination)
        } label: {
            Label(destination == .checkIns ? "Heatmaps" : destination.title, systemImage: destination.icon)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 10)
                .background {
                    if selection == destination {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.tint.opacity(0.14))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == destination ? .isSelected : [])
    }
}
