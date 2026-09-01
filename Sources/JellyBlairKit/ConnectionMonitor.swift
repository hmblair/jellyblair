import Foundation
import Observation

/// Polls the server and tracks whether it is reachable.
/// When the server comes back, flushes any progress report that failed to send.
@MainActor
@Observable
public final class ConnectionMonitor {
    private let client: JellyfinClient

    public private(set) var isServerReachable = true

    private var pollTask: Task<Void, Never>?

    /// Poll slowly while healthy, quickly while down so recovery shows promptly.
    private static let reachablePollInterval: TimeInterval = 15
    private static let unreachablePollInterval: TimeInterval = 5

    public init(client: JellyfinClient) {
        self.client = client
    }

    deinit {
        // Owned by SwiftUI state, so deallocation happens on the main thread.
        MainActor.assumeIsolated {
            pollTask?.cancel()
        }
    }

    public func start() {
        guard pollTask == nil else { return }
        // The task holds the monitor weakly and only for the duration of each
        // poll, so a discarded monitor stops polling instead of leaking.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.pollOnce() else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Runs one reachability check and returns the delay until the next one.
    private func pollOnce() async -> TimeInterval {
        let reachable = await client.pingServer()
        let cameBack = reachable && !isServerReachable
        isServerReachable = reachable
        if cameBack {
            await client.flushUnsentProgressReport()
        }
        return reachable ? Self.reachablePollInterval : Self.unreachablePollInterval
    }
}
