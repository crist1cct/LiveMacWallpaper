import Testing
@testable import WallpaperCore

@Suite("YouTube URL validation")
struct YouTubeURLTests {
    @Test("Accepted YouTube URL shapes", arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ",
        "https://youtube.com/shorts/dQw4w9WgXcQ",
        "https://m.youtube.com/live/dQw4w9WgXcQ"
    ])
    func acceptsKnownShapes(rawURL: String) throws {
        let parsed = try YouTubeURL(rawURL)
        #expect(parsed.videoID == "dQw4w9WgXcQ")
        #expect(parsed.normalizedURL.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    @Test("Rejects unsafe or unrelated URLs", arguments: [
        "http://youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com.example.org/watch?v=dQw4w9WgXcQ",
        "https://example.org/watch?v=dQw4w9WgXcQ",
        "not a url"
    ])
    func rejectsInvalidURLs(rawURL: String) {
        #expect(throws: YouTubeImportError.invalidURL) {
            try YouTubeURL(rawURL)
        }
    }
}

