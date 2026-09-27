import Foundation

public struct YouTubeURL: Hashable, Sendable {
    public let videoID: String
    public let normalizedURL: URL

    public init(_ rawValue: String) throws {
        guard let components = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased()
        else {
            throw YouTubeImportError.invalidURL
        }

        let id: String?
        switch host {
        case "youtu.be", "www.youtu.be":
            id = components.path.split(separator: "/").first.map(String.init)
        case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com":
            let path = components.path.split(separator: "/").map(String.init)
            if components.path == "/watch" {
                id = components.queryItems?.first(where: { $0.name == "v" })?.value
            } else if let prefix = path.first,
                      ["shorts", "live", "embed"].contains(prefix),
                      path.count >= 2 {
                id = path[1]
            } else {
                id = nil
            }
        default:
            id = nil
        }

        guard let id,
              (6...64).contains(id.count),
              id.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
              })
        else {
            throw YouTubeImportError.invalidURL
        }

        var normalized = URLComponents()
        normalized.scheme = "https"
        normalized.host = "www.youtube.com"
        normalized.path = "/watch"
        normalized.queryItems = [URLQueryItem(name: "v", value: id)]
        guard let normalizedURL = normalized.url else {
            throw YouTubeImportError.invalidURL
        }

        self.videoID = id
        self.normalizedURL = normalizedURL
    }
}

