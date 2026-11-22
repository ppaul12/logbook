import SwiftUI

@main
struct LogbookApp: App {
    private let startup = Result { () throws -> LogbookStore in
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.logbook"
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appending(path: bundleID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try LogbookStore(url: directory.appending(path: "Logbook.store"))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch startup {
                case .success(let store):
                    RootView()
                        .environment(store)
                case .failure(let error):
                    ContentUnavailableView(
                        "Couldn’t Open Logbook", systemImage: "externaldrive.badge.exclamationmark",
                        description: Text(error.localizedDescription)
                    )
                }
            }
            .scrollIndicators(.never, axes: .vertical)
            .frame(minWidth: 680, minHeight: 440)
        }
    }
}
