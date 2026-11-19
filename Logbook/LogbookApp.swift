import SwiftUI

@main
struct LogbookApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                #if os(macOS)
                .frame(minWidth: 680, minHeight: 440)
                #endif
        }
    }
}
