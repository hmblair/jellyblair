import AVFoundation
import Foundation

/// Talks to the Jellyfin server: authentication, library queries, and playback reports.
public final class JellyfinClient {
    public let serverURL: URL

    private static let clientName = "JellyBlair"
    private static let deviceName = "Mac"
    private static let deviceID = "jellyblair-mac"
    private static let clientVersion = "0.1"

    private var accessToken: String?
    private var userID: String?

    /// Called when the server rejects the stored token mid-session.
    var onUnauthorized: (() -> Void)?

    /// The last playback position whose report failed to send.
    /// Kept until a later report for the same book succeeds, then flushed on reconnect.
    private var unsentProgress: (bookID: String, positionSeconds: Double)?

    init(serverURL: URL, accessToken: String? = nil, userID: String? = nil) {
        self.serverURL = serverURL
        self.accessToken = accessToken
        self.userID = userID
    }

    var sessionToken: String? { accessToken }
    var sessionUserID: String? { userID }

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

    /// Returns whether the server answers within a few seconds.
    func pingServer() async -> Bool {
        var request = makeRequest(path: "System/Info/Public")
        request.timeoutInterval = 5
        return (try? await send(request)) != nil
    }

    // MARK: - Authentication

    func authenticate(username: String, password: String) async throws {
        let body = try JSONEncoder().encode(["Username": username, "Pw": password])
        let request = makeRequest(path: "Users/AuthenticateByName", method: "POST", body: body)
        let data = try await send(request)
        let auth = try decode(AuthResponse.self, from: data)
        accessToken = auth.accessToken
        userID = auth.user.id
    }

    enum TokenCheck {
        case valid
        case invalid
        case unreachable
    }

    /// Checks the stored token against the server and refreshes the user ID.
    func verifyStoredToken() async -> TokenCheck {
        let request = makeRequest(path: "Users/Me")
        do {
            let data = try await send(request)
            if let user = try? decode(AuthUser.self, from: data) {
                userID = user.id
            }
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
            URLQueryItem(name: "Fields", value: "People"),
            URLQueryItem(name: "UserId", value: userID),
        ]
        let request = makeRequest(path: "Items", query: query)
        let data = try await send(request)
        return try decode(ItemsResponse.self, from: data).items
    }

    /// Fetches a single book with fresh user data, such as the resume position.
    func fetchBook(id: String) async -> Book? {
        guard let userID else { return nil }
        let request = makeRequest(path: "Users/\(userID)/Items/\(id)")
        guard let data = try? await send(request) else { return nil }
        return try? decode(Book.self, from: data)
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
        var components = URLComponents(url: serverURL.appendingPathComponent("Audio/\(book.id)/stream"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "static", value: "true")]
        let headers = ["Authorization": authorizationHeader]
        return AVURLAsset(url: components.url!, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }

    // MARK: - Playback reports

    func reportPlaybackStarted(bookID: String, positionSeconds: Double) async {
        await sendPlaybackReport(path: "Sessions/Playing", bookID: bookID, positionSeconds: positionSeconds, isPaused: false)
    }

    func reportPlaybackProgress(bookID: String, positionSeconds: Double, isPaused: Bool) async {
        await sendPlaybackReport(path: "Sessions/Playing/Progress", bookID: bookID, positionSeconds: positionSeconds, isPaused: isPaused)
    }

    func reportPlaybackStopped(bookID: String, positionSeconds: Double) async {
        await sendPlaybackReport(path: "Sessions/Playing/Stopped", bookID: bookID, positionSeconds: positionSeconds, isPaused: true)
    }

    /// Re-sends the last failed position report, if any.
    func flushUnsentProgressReport() async {
        guard let unsent = unsentProgress else { return }
        await sendPlaybackReport(path: "Sessions/Playing/Progress", bookID: unsent.bookID, positionSeconds: unsent.positionSeconds, isPaused: true)
    }

    /// Sends a stop report and blocks up to one second for it to leave.
    /// Used only during app termination, when async work cannot finish.
    func reportPlaybackStoppedBlocking(bookID: String, positionSeconds: Double) {
        let request = makePlaybackReportRequest(path: "Sessions/Playing/Stopped", bookID: bookID, positionSeconds: positionSeconds, isPaused: true)
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1)
    }

    private func sendPlaybackReport(path: String, bookID: String, positionSeconds: Double, isPaused: Bool) async {
        let request = makePlaybackReportRequest(path: path, bookID: bookID, positionSeconds: positionSeconds, isPaused: isPaused)
        do {
            _ = try await send(request)
            if unsentProgress?.bookID == bookID {
                unsentProgress = nil
            }
        } catch {
            unsentProgress = (bookID: bookID, positionSeconds: positionSeconds)
        }
    }

    private func makePlaybackReportRequest(path: String, bookID: String, positionSeconds: Double, isPaused: Bool) -> URLRequest {
        let report: [String: Any] = [
            "ItemId": bookID,
            "PositionTicks": Int64(positionSeconds * ticksPerSecond),
            "IsPaused": isPaused,
            "CanSeek": true,
            "PlayMethod": "DirectStream",
        ]
        let body = try? JSONSerialization.data(withJSONObject: report)
        return makeRequest(path: path, method: "POST", body: body)
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
