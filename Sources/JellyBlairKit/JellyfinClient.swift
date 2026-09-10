import AVFoundation
import Foundation

/// Talks to the Jellyfin server: authentication, library queries, and playback reports.
public final class JellyfinClient {
    public let serverURL: URL

    private static let clientName = "JellyBlair"

    /// The app version the server sees, from the bundle, where the build
    /// stamps it out of the VERSION file. A bare development binary has no
    /// bundle version.
    private static let clientVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    #if os(macOS)
    private static let deviceName = "Mac"
    #else
    private static let deviceName = "iPhone"
    #endif

    private static var deviceID: String { DeviceIdentifier.value }

    private var accessToken: String?

    /// Called when the server rejects the stored token mid-session.
    var onUnauthorized: (() -> Void)?

    /// The last playback position whose report failed to send.
    /// Kept until a later report for the same book succeeds, then flushed on reconnect.
    private var unsentProgress: (bookID: String, positionSeconds: Double)?

    init(serverURL: URL, accessToken: String? = nil) {
        self.serverURL = serverURL
        self.accessToken = accessToken
    }

    var sessionToken: String? { accessToken }

    private var authorizationHeader: String {
        var fields = [
            "Client=\"\(Self.clientName)\"",
            "Device=\"\(Self.deviceName)\"",
            "DeviceId=\"\(Self.deviceID)\"",
            "Version=\"\(Self.clientVersion)\"",
        ]
        if let accessToken {
            fields.append("Token=\"\(accessToken)\"")
        }
        return "MediaBrowser " + fields.joined(separator: ", ")
    }

    // MARK: - Requests

    private func makeRequest(path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) -> URLRequest {
        var components = URLComponents(url: serverURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError.badStatus(-1)
        }
        if http.statusCode == 401 {
            if accessToken != nil {
                onUnauthorized?()
            }
            throw JellyfinError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw JellyfinError.badStatus(http.statusCode)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    // MARK: - Health

    /// Asks for the server's public information, which needs no token, and
    /// gives up after a few seconds.
    private func publicInfoRequest() -> URLRequest {
        var request = makeRequest(path: "System/Info/Public")
        request.timeoutInterval = 5
        return request
    }

    /// Returns whether the server answers within a few seconds.
    func pingServer() async -> Bool {
        (try? await send(publicInfoRequest())) != nil
    }

    /// The version the server reports. Returns nil when the server does not
    /// answer, or when it reports no version the parser can read.
    func fetchServerVersion() async -> ServerVersion? {
        guard let data = try? await send(publicInfoRequest()) else { return nil }
        guard let info = try? decode(PublicSystemInfo.self, from: data) else { return nil }
        return info.version.flatMap(ServerVersion.init)
    }

    // MARK: - Authentication

    func authenticate(username: String, password: String) async throws {
        let body = try JSONEncoder().encode(["Username": username, "Pw": password])
        let request = makeRequest(path: "Users/AuthenticateByName", method: "POST", body: body)
        let data = try await send(request)
        accessToken = try decode(AuthResponse.self, from: data).accessToken
    }

    enum TokenCheck {
        case valid
        case invalid
        case unreachable
    }

    /// Checks the stored token against the server.
    func verifyStoredToken() async -> TokenCheck {
        let request = makeRequest(path: "Users/Me")
        do {
            _ = try await send(request)
            return .valid
        } catch JellyfinError.unauthorized {
            return .invalid
        } catch JellyfinError.badStatus(let code) where (400..<500).contains(code) {
            return .invalid
        } catch {
            return .unreachable
        }
    }

    // MARK: - Library

    func fetchAudiobooks() async throws -> [Book] {
        let query = [
            URLQueryItem(name: "IncludeItemTypes", value: "AudioBook"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "Fields", value: "People,MediaSources,Genres"),
        ]
        let request = makeRequest(path: "Items", query: query)
        let data = try await send(request)
        return try decode(ItemsResponse.self, from: data).items
    }

    /// Fetches a single book with fresh user data, such as the resume position.
    public func fetchBook(id: String) async -> Book? {
        let request = makeRequest(path: "Items/\(id)")
        guard let data = try? await send(request) else { return nil }
        return try? decode(Book.self, from: data)
    }

    /// Fetches a book's lyric sidecar, parsed by the server into transcript
    /// lines. Returns no lines for a book without a sidecar; only a failed
    /// request throws.
    func fetchLyrics(bookID: String) async throws -> [LyricLine] {
        let request = makeRequest(path: "Audio/\(bookID)/Lyrics")
        let data: Data
        do {
            data = try await send(request)
        } catch JellyfinError.badStatus(404) {
            return []
        }
        return try decode(LyricsResponse.self, from: data).transcriptLines
    }

    // MARK: - URLs

    public func imageURL(for book: Book) -> URL {
        var components = URLComponents(url: serverURL.appendingPathComponent("Items/\(book.id)/Images/Primary"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "maxWidth", value: "600")]
        return components.url!
    }

    /// Builds the asset for a book's audio stream. The token travels in an
    /// Authorization header instead of the URL, so it stays out of server logs.
    func streamAsset(for book: Book) -> AVURLAsset {
        AVURLAsset(url: streamURL(for: book), options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": authorizationHeader]])
    }

    /// An authenticated request for the book's file, for downloading it.
    func streamRequest(for book: Book) -> URLRequest {
        var request = URLRequest(url: streamURL(for: book))
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        return request
    }

    private func streamURL(for book: Book) -> URL {
        var components = URLComponents(url: serverURL.appendingPathComponent("Audio/\(book.id)/stream"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "static", value: "true")]
        return components.url!
    }

    // MARK: - Playback reports

    /// The route for the started report, which is also the base the other
    /// two routes extend.
    private static let startedPath = "Sessions/Playing"
    private static let progressPath = startedPath + "/Progress"
    private static let stoppedPath = startedPath + "/Stopped"

    /// Clears the book's played state and resume position for the user.
    /// Throws when the server does not confirm.
    func resetPlayback(bookID: String) async throws {
        _ = try await send(makeRequest(path: "UserPlayedItems/\(bookID)", method: "DELETE"))
    }

    func reportPlaybackStarted(bookID: String, positionSeconds: Double) async {
        let request = makeStartedReportRequest(bookID: bookID, positionSeconds: positionSeconds)
        await sendPlaybackReport(request, bookID: bookID, positionSeconds: positionSeconds)
    }

    func reportPlaybackProgress(bookID: String, positionSeconds: Double, isPaused: Bool) async {
        let request = makeProgressReportRequest(bookID: bookID, positionSeconds: positionSeconds, isPaused: isPaused)
        await sendPlaybackReport(request, bookID: bookID, positionSeconds: positionSeconds)
    }

    func reportPlaybackStopped(bookID: String, positionSeconds: Double) async {
        let request = makeStopReportRequest(bookID: bookID, positionSeconds: positionSeconds)
        await sendPlaybackReport(request, bookID: bookID, positionSeconds: positionSeconds)
    }

    /// Re-sends the last failed position report, if any.
    func flushUnsentProgressReport() async {
        guard let unsent = unsentProgress else { return }
        await reportPlaybackProgress(bookID: unsent.bookID, positionSeconds: unsent.positionSeconds, isPaused: true)
    }

    /// Sends a stop report and blocks up to one second for it to leave.
    /// Used only during app termination, when async work cannot finish.
    func reportPlaybackStoppedBlocking(bookID: String, positionSeconds: Double) {
        let request = makeStopReportRequest(bookID: bookID, positionSeconds: positionSeconds)
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1)
    }

    /// Sends one report, and keeps its position when the send fails so that
    /// a later report can carry it.
    private func sendPlaybackReport(_ request: URLRequest, bookID: String, positionSeconds: Double) async {
        do {
            _ = try await send(request)
            if unsentProgress?.bookID == bookID {
                unsentProgress = nil
            }
        } catch {
            unsentProgress = (bookID: bookID, positionSeconds: positionSeconds)
        }
    }

    private func makeStartedReportRequest(bookID: String, positionSeconds: Double) -> URLRequest {
        makeProgressBodyRequest(path: Self.startedPath, bookID: bookID, positionSeconds: positionSeconds, isPaused: false)
    }

    private func makeProgressReportRequest(bookID: String, positionSeconds: Double, isPaused: Bool) -> URLRequest {
        makeProgressBodyRequest(path: Self.progressPath, bookID: bookID, positionSeconds: positionSeconds, isPaused: isPaused)
    }

    /// Builds a report the server reads as PlaybackProgressInfo, which the
    /// started and progress routes both take.
    private func makeProgressBodyRequest(path: String, bookID: String, positionSeconds: Double, isPaused: Bool) -> URLRequest {
        makeReportRequest(path: path, body: [
            "ItemId": bookID,
            "PositionTicks": positionTicks(positionSeconds),
            "IsPaused": isPaused,
            "CanSeek": true,
            "PlayMethod": "DirectStream",
        ])
    }

    /// Builds a report the server reads as PlaybackStopInfo. That model
    /// carries no paused, seekable, or play method field, so a stop report
    /// states only the book and the position.
    private func makeStopReportRequest(bookID: String, positionSeconds: Double) -> URLRequest {
        makeReportRequest(path: Self.stoppedPath, body: [
            "ItemId": bookID,
            "PositionTicks": positionTicks(positionSeconds),
        ])
    }

    private func makeReportRequest(path: String, body: [String: Any]) -> URLRequest {
        makeRequest(path: path, method: "POST", body: try? JSONSerialization.data(withJSONObject: body))
    }

    private func positionTicks(_ seconds: Double) -> Int64 {
        Int64(seconds * ticksPerSecond)
    }
}

enum JellyfinError: Error, LocalizedError {
    case unauthorized
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "The server rejected the credentials."
        case .badStatus(let code):
            return "The server returned status \(code)."
        }
    }
}
