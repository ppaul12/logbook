import SwiftUI

struct AccountBalancesView: View {
    @Environment(LogbookStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedMonth: MonthKey?
    @State private var snapshotWidth: CGFloat = 460
    @Binding var accountID: String?
    @Binding var currency: LedgerCurrency
    @State private var sheet: Sheet?
    @State private var error: String?

    private var changeColumnWidth: CGFloat { min(284, snapshotWidth * 0.44) }

    private var palette: NordFinancePalette {
        NordFinancePalette(colorScheme: colorScheme)
    }

    private enum Sheet: Identifiable {
        case balance(Account, MonthKey, Balance?), account(Account, isNew: Bool), removal(AccountRemoval)

        var id: String {
            switch self {
            case .balance(let account, let month, _): "balance/\(account.id)/\(month.rawValue)"
            case .account(let account, _): "account/\(account.id)"
            case .removal(let action): "removal/\(action.account.id)"
            }
        }
    }

    private enum AccountRemoval {
        case reset(Account), delete(Account)

        var account: Account {
            switch self {
            case .reset(let account), .delete(let account): account
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .reset(let account): "Reset \(account.name)?"
            case .delete(let account): "Delete \(account.name)?"
            }
        }

        var buttonTitle: LocalizedStringKey {
            switch self {
            case .reset: "Reset Balances"
            case .delete: "Delete Account"
            }
        }

        var message: LocalizedStringKey {
            switch self {
            case .reset: "All balance snapshots for this account will be permanently removed. The account will be kept."
            case .delete: "This account and all of its balance snapshots will be permanently removed."
            }
        }
    }

    var body: some View {
        let accounts = store.library.accounts.filter { $0.currency == currency }
        let themes = Account.themeColors(for: accounts)
        let suggestedColor = Account.palette.first { !themes.values.contains($0) } ?? Account.palette[0]
        let selected = accounts.first { $0.id == accountID }
        let report = BalanceReport(library: store.library, currency: currency, accountID: selected?.id)
        let current = store.preferences.today.month
        let history = report.history(through: current)
        let present = min(max(current, history.lowerBound), history.upperBound)
        let latest = report.recordedMonths.last
        let recent = latest.flatMap { latest in
            latest > present || latest.index <= present.index - AccountBalanceChart.visibleMonths ? latest : nil
        } ?? present
        let month = selectedMonth.flatMap { history.contains($0) ? $0 : nil } ?? recent
        let monthSelection = Binding(get: { month }, set: { selectedMonth = $0 })
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    accountTitleMenu(accounts, selected: selected, color: selected.flatMap { themes[$0.id] })
                    Spacer(minLength: 12)
                    CurrencySelection(currency: $currency, showsLabel: false)
                }
                Divider()
                if accounts.isEmpty {
                    ContentUnavailableView {
                        Label("No Accounts in \(currency.rawValue)", systemImage: "wallet.bifold")
                    } actions: {
                        Button("New Account") { newAccount(opened: month, color: suggestedColor) }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    AccountBalanceChart(currency: currency, report: report,
                                        history: history, recent: recent, themes: themes,
                                        month: monthSelection)
                        .id(selected?.id)
                        .id(currency)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(selected == nil ? "Snapshots" : "Balance History")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            Spacer(minLength: 12)
                            MonthNavigation(title: "Balance month", month: monthSelection, bounds: history)
                        }
                        if let selected {
                            accountHistory(report.recordedBalances(for: selected.id), account: selected,
                                           month: month, snapshot: report.month(month).snapshots[selected.id])
                        } else {
                            snapshots(report.month(month), previous: report.previousMonth(before: month),
                                      for: month, themes: themes)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let selected {
                    accountActions(selected, hasSnapshots: latest != nil)
                } else {
                    Button("New Account", systemImage: "plus") { newAccount(opened: month, color: suggestedColor) }
                }
            }
        }
        .onChange(of: currency) {
            accountID = nil
            selectedMonth = nil
        }
        .onChange(of: accountID) { selectedMonth = nil }
        .onChange(of: accounts) { _, current in
            if let accountID, !current.contains(where: { $0.id == accountID }) { self.accountID = nil }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .balance(let account, let month, let balance):
                BalanceEditor(account: account, month: month, existing: balance)
            case .account(let account, let isNew):
                AccountEditor(account: account, isNew: isNew, suggestedColor: themes[account.id] ?? suggestedColor)
            case .removal(let action):
                RemovalConfirmation(title: action.title, message: action.message, actionTitle: action.buttonTitle,
                                    cancel: { sheet = nil }) {
                    sheet = nil
                    removeAccount(action)
                }
            }
        }
        .logbookError($error)
    }

    private func newAccount(opened month: MonthKey, color: String) {
        sheet = .account(Account(currency: currency, opened: month, color: color), isNew: true)
    }

    @ViewBuilder
    private func accountActions(_ account: Account, hasSnapshots: Bool) -> some View {
        Button("Edit Account", systemImage: "pencil") { sheet = .account(account, isNew: false) }
            .help("Edit account")
        Button("Reset Balances", systemImage: "arrow.counterclockwise", role: .destructive) {
            sheet = .removal(.reset(account))
        }
        .disabled(!hasSnapshots)
        .help("Reset balances")
        Button("Delete Account", systemImage: "trash", role: .destructive) {
            sheet = .removal(.delete(account))
        }
        .help("Delete account")
    }

    private func removeAccount(_ action: AccountRemoval) {
        do {
            switch action {
            case .reset(let account):
                try store.resetAccount(account.id)
            case .delete(let account):
                try store.deleteAccount(account.id)
                if accountID == account.id { accountID = nil }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func accountTitleMenu(_ accounts: [Account], selected: Account?, color: String?) -> some View {
        let title = selected.map { Text(verbatim: $0.name) } ?? Text("All Accounts")
        return Menu {
            Picker("Account", selection: $accountID) {
                Text("All Accounts").tag(nil as String?)
                ForEach(accounts) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 9) {
                if let color { themeDot(color, size: 11) }
                title.font(.largeTitle.bold()).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .accessibilityLabel("Account")
        .accessibilityValue(title)
        .accessibilityAddTraits(.isHeader)
    }

    private func themeDot(_ hex: String, size: CGFloat) -> some View {
        Circle().fill(Color(logbookHex: hex)).frame(width: size, height: size).accessibilityHidden(true)
    }

    private func snapshots(_ summary: BalanceMonth, previous: BalanceMonth?, for month: MonthKey,
                           themes: [String: String]) -> some View {
        let rows = summary.accounts.map { account in
            SnapshotRow(account: account, balance: summary.snapshots[account.id],
                        change: summary.change(for: account.id, from: previous))
        }
        let largestChange = rows.compactMap(\.change).map { abs($0) }.max() ?? 0
        let valueWidth = changeColumnWidth * 0.52
        let changeSpacing: CGFloat = 8
        let trackWidth = max(0, changeColumnWidth - valueWidth - changeSpacing)
        return VStack(alignment: .leading, spacing: 10) {
            if summary.accounts.isEmpty {
                Text("No accounts open in \(month.label).").foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(summary.missing.isEmpty ? "Total" : "Recorded subtotal")
                        .foregroundStyle(.secondary)
                    Text(currency.format(summary.subtotal))
                        .font(.title2.weight(.semibold).monospacedDigit())
                    if summary.hasSnapshots {
                        monthChange(summary.change(from: previous), fromSubtotal: summary.total == nil || previous?.total == nil)
                    }
                }
                .accessibilityElement(children: .combine)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                snapshotColumns {
                    Text("Account")
                } middle: {
                    Text("Monthly Change")
                } balance: {
                    Text("This Month")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

                ForEach(rows) { row in
                    let account = row.account
                    Divider()
                    Button {
                        sheet = .balance(account, month, row.balance)
                    } label: {
                        snapshotColumns {
                            HStack(spacing: 8) {
                                if let color = themes[account.id] { themeDot(color, size: 8) }
                                Text(account.name)
                            }
                        } middle: {
                            HStack(spacing: changeSpacing) {
                                contributionBar(row.change, largestChange: largestChange)
                                    .frame(width: trackWidth)
                                monthChange(row.change, hasBalance: row.balance != nil)
                                    .font(.callout.monospaced())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                                    .frame(width: valueWidth, alignment: .trailing)
                            }
                        } balance: {
                            if let snapshot = row.balance {
                                Text(currency.format(Decimal(snapshot.minorUnits)))
                                    .font(.callout.monospaced())
                            } else {
                                Text("Missing").foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Edit Account") { sheet = .account(account, isNew: false) } }
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { snapshotWidth = $0 }
    }

    private struct SnapshotRow: Identifiable {
        let account: Account
        let balance: Balance?
        let change: Decimal?
        var id: String { account.id }
    }

    private func snapshotColumns<Name: View, Middle: View, Amount: View>(
        @ViewBuilder name: () -> Name,
        @ViewBuilder middle: () -> Middle,
        @ViewBuilder balance: () -> Amount
    ) -> some View {
        let gap = min(24, snapshotWidth * 0.05)
        let sideWidth = (snapshotWidth - changeColumnWidth - 2 * gap) / 2
        return HStack(spacing: gap) {
            name().frame(width: sideWidth, alignment: .leading)
            middle().frame(width: changeColumnWidth, alignment: .leading)
            balance()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(width: sideWidth, alignment: .trailing)
        }
    }

    private func contributionBar(_ change: Decimal?, largestChange: Decimal) -> some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.track)
                    .frame(height: 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let change {
                    let center = geometry.size.width / 2
                    let fraction = largestChange == 0 ? 0 : NSDecimalNumber(decimal: abs(change) / largestChange).doubleValue
                    let length = center * fraction
                    Rectangle().fill(palette.comparisonZero)
                        .frame(width: change == 0 ? 3 : 1, height: 10)
                    if change != 0 {
                        RoundedRectangle(cornerRadius: 2).fill(palette.amount(change))
                            .frame(width: length, height: 6)
                            .position(x: center + (change > 0 ? length / 2 : -length / 2),
                                      y: geometry.size.height / 2)
                    }
                }
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    private func monthChange(_ change: Decimal?, hasBalance: Bool = true, fromSubtotal: Bool = false) -> some View {
        let amount = change.map { currency.format($0, showPlus: true) } ?? "—"
        let description: LocalizedStringKey
        if !hasBalance {
            description = "No balance recorded this month"
        } else if change == nil {
            description = "No balance recorded last month"
        } else if fromSubtotal {
            description = "Recorded subtotal change from last month, \(amount)"
        } else {
            description = "Change from last month, \(amount)"
        }
        return Text(amount)
            .fontWeight(.medium)
            .foregroundStyle(palette.amount(change))
            .help(Text(description))
            .accessibilityLabel(Text(description))
    }

    private func accountHistory(_ balances: [Balance], account: Account, month: MonthKey,
                                snapshot: Balance?) -> some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            if snapshot == nil, account.includes(month) {
                Button("Record Balance for \(month.label)", systemImage: "plus") {
                    sheet = .balance(account, month, nil)
                }
            }
            if balances.isEmpty {
                Text("No recorded balances.").foregroundStyle(.secondary)
            }
            ForEach(balances) { balance in
                Divider()
                Button {
                    selectedMonth = balance.month
                    sheet = .balance(account, balance.month, balance)
                } label: {
                    HStack {
                        Text(balance.month.label)
                        Spacer(minLength: 12)
                        Text(currency.format(Decimal(balance.minorUnits)))
                    }
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.tint.opacity(balance.month == month ? 0.12 : 0), in: .rect(cornerRadius: 5))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(balance.month == month ? .isSelected : [])
            }
        }
    }
}

private struct AccountEditor: View {
    @Environment(LogbookStore.self) private var store
    @State var account: Account
    let isNew: Bool
    let suggestedColor: String

    var body: some View {
        let hasSnapshots = store.library.balances.contains { $0.accountID == account.id }
        Editor(title: isNew ? "New Account" : "Edit Account", save: save) {
            TextField("Name", text: $account.name)
            ColorPicker("Theme Color", selection: Binding(
                get: { Color(logbookHex: account.color ?? suggestedColor) },
                set: { if let hex = $0.logbookHex { account.color = hex } }
            ), supportsOpacity: false)
            CurrencySelection(currency: $account.currency)
                .disabled(hasSnapshots)
                .help(hasSnapshots ? "Currency is fixed once an account has saved snapshots." : "Choose an account currency.")
            MonthField(title: "Opening month", month: $account.opened)
            Toggle("Closed", isOn: Binding(
                get: { account.closed != nil },
                set: { account.closed = $0 ? max(account.opened, store.preferences.today.month) : nil }
            ))
            if account.closed != nil {
                MonthField(title: "Closing month", month: Binding(
                    get: { account.closed ?? account.opened },
                    set: { account.closed = $0 }
                ))
            }
        }
    }

    private func save() throws {
        var draft = account
        draft.name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.name.isEmpty else { throw LogbookError.message("Enter an account name.") }
        if let closed = draft.closed, closed < draft.opened {
            throw LogbookError.message("The closing month must be on or after the opening month.")
        }
        let saved = store.library.accounts.first { $0.id == draft.id }
        guard isNew || saved != nil else { throw LogbookError.message("This account was deleted.") }
        let snapshots = store.library.balances.filter { $0.accountID == draft.id }
        if !snapshots.isEmpty, let saved, saved.currency != draft.currency {
            throw LogbookError.message("This account already has snapshots in \(saved.currency.rawValue).")
        }
        guard snapshots.allSatisfy({ draft.includes($0.month) }) else {
            throw LogbookError.message("The account’s dates must include its saved snapshots.")
        }
        try store.save([.account(draft)])
    }
}

private struct BalanceEditor: View {
    @Environment(LogbookStore.self) private var store
    @State private var amount: String
    @State private var recorded = true
    let account: Account
    let month: MonthKey
    let existing: Balance?

    init(account: Account, month: MonthKey, existing: Balance?) {
        self.account = account
        self.month = month
        self.existing = existing
        _amount = State(initialValue: existing.map { account.currency.plain($0.minorUnits) } ?? "")
    }

    var body: some View {
        Editor(title: "Balance for \(month.label)", save: save) {
            LabeledContent("Account", value: account.name)
            if existing != nil { Toggle("Recorded", isOn: $recorded) }
            if recorded {
                TextField("Balance (\(account.currency.rawValue))", text: $amount)
            }
        }
    }

    private func save() throws {
        if let existing, store.library.records[Record.balance(existing).key] != .balance(existing) {
            throw LogbookError.message("This snapshot changed. Reopen it to edit it.")
        }
        if !recorded, let existing {
            try store.save(removing: [Record.balance(existing).key])
            return
        }
        guard let current = store.library.accounts.first(where: { $0.id == account.id }),
              current.currency == account.currency, current.includes(month) else {
            throw LogbookError.message("This account changed. Reopen the snapshot to edit it.")
        }
        guard let minorUnits = account.currency.parse(amount) else {
            throw LogbookError.message("Enter an amount in \(account.currency.rawValue) with up to \(account.currency.fractionDigits) decimal places.")
        }
        try store.save([.balance(Balance(accountID: account.id, month: month, minorUnits: minorUnits))])
    }
}
