import SwiftUI

struct DestinationView: View {
    let destination: Destination
    @Binding var cashFlowCurrency: LedgerCurrency?
    @Binding var cashFlowMetric: CashFlowMetric
    @Binding var balanceCurrency: LedgerCurrency?
    @Binding var checkInSelection: CheckInSelection
    @Binding var balanceAccountID: String?
    @Environment(LogbookStore.self) private var store

    var body: some View {
        switch destination {
        case .checkIns:
            CheckInsView(selection: $checkInSelection)
        case .accountBalances:
            AccountBalancesView(accountID: $balanceAccountID, currency: Binding(
                get: { balanceCurrency ?? store.preferences.defaultCurrency },
                set: { balanceCurrency = $0 }
            ))
        case .monthlyCashFlow:
            CashFlowView(currency: Binding(
                get: { cashFlowCurrency ?? store.preferences.defaultCurrency },
                set: { cashFlowCurrency = $0 }
            ), month: store.preferences.today.month, metric: $cashFlowMetric)
        case .settings:
            SettingsView()
        }
    }
}
