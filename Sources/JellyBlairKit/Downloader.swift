import Foundation

/// Downloads one file with progress, reporting on the main actor.
/// A thin wrapper over URLSession's download task delegate callbacks.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: @MainActor (Double?) -> Void
    private let onFinish: @MainActor (Bool) -> Void

    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    init(
        destination: URL,
        onProgress: @escaping @MainActor (Double?) -> Void,
        onFinish: @escaping @MainActor (Bool) -> Void
    ) {
        self.destination = destination
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func start(_ request: URLRequest) {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: request)
        self.task = task
        task.resume()
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
        let succeeded: Bool
        if (downloadTask.response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false {
            try? FileManager.default.removeItem(at: destination)
            succeeded = (try? FileManager.default.moveItem(at: location, to: destination)) != nil
        } else {
            succeeded = false
        }
        Task { @MainActor [onFinish] in
            onFinish(succeeded)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        Task { @MainActor [onFinish] in
            onFinish(false)
        }
        session.invalidateAndCancel()
    }
}
