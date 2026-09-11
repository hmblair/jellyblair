import Foundation

/// The end of a download. A failure carries a message for the user, or
/// none when the user cancelled the download.
enum DownloadOutcome: Equatable {
    case succeeded
    case failed(message: String?)
}

/// Downloads one file with progress, reporting on the main actor.
/// A thin wrapper over URLSession's download task delegate callbacks.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: @MainActor (Double?) -> Void
    private let onFinish: @MainActor (DownloadOutcome) -> Void

    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    init(
        destination: URL,
        onProgress: @escaping @MainActor (Double?) -> Void,
        onFinish: @escaping @MainActor (DownloadOutcome) -> Void
    ) {
        self.destination = destination
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func start(_ request: URLRequest) {
        let session = URLSession(configuration: Self.makeConfiguration(), delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: request)
        self.task = task
        task.resume()
    }

    /// A background configuration on iOS, so the system carries the transfer
    /// while the app is suspended or the phone is locked. The identifier is
    /// unique for each download, since the system allows one live session
    /// for each identifier. The Mac app never suspends, so it keeps an
    /// in-process session.
    private static func makeConfiguration() -> URLSessionConfiguration {
        #if os(iOS)
        let identifier = (Bundle.main.bundleIdentifier ?? "JellyBlair") + ".download." + UUID().uuidString
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        // The app reports finished downloads only while it runs, so a
        // finished transfer must not relaunch it.
        configuration.sessionSendsLaunchEvents = false
        return configuration
        #else
        return .default
        #endif
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress: Double? = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : nil
        Task { @MainActor [onProgress] in
            onProgress(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file dies when this callback returns, so the move
        // happens here, on the session's queue.
        let outcome = adoptFile(at: location, from: downloadTask)
        Task { @MainActor [onFinish] in
            onFinish(outcome)
        }
    }

    /// Moves the finished file into place, and names what went wrong when
    /// the server refused or the move failed.
    private func adoptFile(at location: URL, from task: URLSessionDownloadTask) -> DownloadOutcome {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            return .failed(message: "The server returned status \(status).")
        }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            // The user-facing message stays short; the log keeps the cause.
            Log.downloads.error("Cannot move the finished download into place: \(String(describing: error), privacy: .public)")
            return .failed(message: "Cannot save the file.")
        }
        return .succeeded
    }

    /// Ends the session on every outcome. A completed transfer has already
    /// reported from didFinishDownloadingTo, so only a transport failure
    /// reports here. A cancelled download carries no message, since the
    /// user did it.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.invalidateAndCancel()
        guard let error else { return }
        let cancelled = (error as? URLError)?.code == .cancelled
        let outcome = DownloadOutcome.failed(message: cancelled ? nil : error.localizedDescription)
        Task { @MainActor [onFinish] in
            onFinish(outcome)
        }
    }
}
