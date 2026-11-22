import Foundation

struct WelcomeGreeting {
    let title: String
    let message: String

    init(date: Date, displayName: String, calendar: Calendar = .autoupdatingCurrent) {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let namedTitle: String

        switch calendar.component(.hour, from: date) {
        case 5..<12:
            namedTitle = String(localized: "Good morning, \(name)!")
            message = String(localized: "Here’s to a good day ahead.")
        case 12..<18:
            namedTitle = String(localized: "Good afternoon, \(name)!")
            message = String(localized: "Hope there’s a bright spot in your afternoon.")
        default:
            namedTitle = String(localized: "Good evening, \(name)!")
            message = String(localized: "Wishing you a quiet, restful evening.")
        }

        title = name.isEmpty ? String(localized: "Hello there!") : namedTitle
    }
}
