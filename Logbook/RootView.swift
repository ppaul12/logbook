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
        case .monthlyCashFlow: "Monthly Cash Flow"
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

struct RootView: View {
    @State private var selection: Destination = .checkIns

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSidebarOpen = false
    #endif

    var body: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            compactNavigation
        } else {
            splitNavigation
        }
        #else
        splitNavigation
        #endif
    }

    private var splitNavigation: some View {
        NavigationSplitView {
            SidebarView(selection: selection) { selection = $0 }
                .navigationTitle("Logbook")
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            screen
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
    }

    private var screen: some View {
        DestinationView(destination: selection)
            .navigationTitle(selection.title)
    }

    #if os(iOS)
    private var compactNavigation: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                NavigationStack {
                    screen
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    setSidebar(open: true)
                                } label: {
                                    Label("Show sidebar", systemImage: "sidebar.left")
                                }
                            }
                        }
                }
                .allowsHitTesting(!isSidebarOpen)
                .accessibilityHidden(isSidebarOpen)

                if isSidebarOpen {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { setSidebar(open: false) }
                        .accessibilityHidden(true)
                        .transition(.opacity)

                    VStack(spacing: 0) {
                        HStack {
                            Text("Logbook")
                                .font(.headline)
                            Spacer()
                            Button {
                                setSidebar(open: false)
                            } label: {
                                Label("Close sidebar", systemImage: "xmark")
                                    .labelStyle(.iconOnly)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .keyboardShortcut(.cancelAction)
                        }
                        .padding(.horizontal, 16)

                        SidebarView(selection: selection) { destination in
                            selection = destination
                            setSidebar(open: false)
                        }
                    }
                    .frame(width: min(300, geometry.size.width * 0.82))
                    .background(.background, ignoresSafeAreaEdges: .vertical)
                    .transition(.move(edge: .leading))
                    .zIndex(1)
                }
            }
        }
        .onDisappear { isSidebarOpen = false }
    }

    private func setSidebar(open: Bool) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            isSidebarOpen = open
        }
    }
    #endif
}

private struct SidebarView: View {
    let selection: Destination
    let onSelect: (Destination) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    group("Check-ins", destinations: [.checkIns])
                    group("Bookkeeping", destinations: [.accountBalances, .monthlyCashFlow])
                }
                .padding(12)
            }
            Divider()
            row(.settings)
                .padding(12)
        }
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
            Label(destination.title, systemImage: destination.icon)
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
