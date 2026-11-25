import AVFoundation
import SwiftUI
import UserNotifications

@main
struct LogbookApp: App {
    private let startup = Result { () throws -> LogbookStore in
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.logbook"
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appending(path: bundleID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Clear reminders scheduled by the previous notification-based rest timer.
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["strength-rest-complete"])
        let alarm = Bundle.main.url(forResource: "RestAlarm", withExtension: "wav").flatMap {
            try? AVAudioPlayer(contentsOf: $0)
        }
        alarm?.numberOfLoops = -1
        return try LogbookStore(url: directory.appending(path: "Logbook.store")) { ringing in
            if ringing {
                alarm?.play()
            } else {
                alarm?.stop()
                alarm?.currentTime = 0
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch startup {
                case .success(let store):
                    RootView(resumeStrengthRest: store.library.activeStrengthSession?.restDeadline != nil)
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
