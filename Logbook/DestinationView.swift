import SwiftUI

struct DestinationView: View {
    let destination: Destination

    var body: some View {
        switch destination {
        case .checkIns:
            ContentUnavailableView("No Check-in Scenes", systemImage: "calendar")
        case .accountBalances:
            FinancePage(
                chartTitle: "Balance Trend",
                chartMessage: "Balance snapshots appear here as you record them.",
                listTitle: "Monthly Snapshots",
                emptyMessage: "No balance snapshots"
            )
        case .monthlyCashFlow:
            FinancePage(
                chartTitle: "Recorded Net Income",
                chartMessage: "Income and expenses are grouped by posting month.",
                listTitle: "Transactions",
                emptyMessage: "No transactions"
            )
        case .settings:
            SettingsView()
        }
    }
}

private struct FinancePage: View {
    let chartTitle: LocalizedStringKey
    let chartMessage: LocalizedStringKey
    let listTitle: LocalizedStringKey
    let emptyMessage: LocalizedStringKey

    var body: some View {
        List {
            Section {
                ContentUnavailableView {
                    Label(chartTitle, systemImage: "chart.line.uptrend.xyaxis")
                } description: {
                    Text(chartMessage)
                }
                .frame(maxWidth: .infinity)
            }

            Section(listTitle) {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsView: View {
    @AppStorage("defaultCurrency") private var defaultCurrency = LedgerCurrency.jpy

    var body: some View {
        Form {
            Section("Bookkeeping") {
                Picker("Default currency", selection: $defaultCurrency) {
                    ForEach(LedgerCurrency.allCases, id: \.self) { currency in
                        Text(currency.label).tag(currency)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private enum LedgerCurrency: String, CaseIterable {
    case jpy = "JPY"
    case cny = "CNY"

    var label: LocalizedStringKey {
        switch self {
        case .jpy: "Japanese Yen (JPY)"
        case .cny: "Chinese Yuan (CNY)"
        }
    }
}
