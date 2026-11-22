import Foundation

enum LogbookLinks {
    static func sceneURL(_ id: String) -> URL? {
        var url = URLComponents()
        url.scheme = "logbook"
        url.host = "scene"
        url.queryItems = [URLQueryItem(name: "id", value: id)]
        return url.url
    }

    static func sceneID(from url: URL) -> String? {
        guard url.scheme == "logbook", url.host == "scene" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "id" })?.value
    }
}
