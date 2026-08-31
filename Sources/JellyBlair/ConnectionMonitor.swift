import Foundation
import Observation

/// Polls the server and tracks whether it is reachable.
/// When the server comes back, flushes any progress report that failed to send.
@MainActor
@Observable
final class ConnectionMonitor {
    private let client: JellyfinClient

    private(set) var isServerReachable = true

    private var pollTask: Task<Void, Never>?

    /// Poll slowly while healthy, quickly while down so recovery shows promptly.
    private static let reachablePollInterval: TimeInterval = 15
    private static let unreachablePollInterval: TimeInterval = 5

    init(client: JellyfinClient) {
        self.client = client
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { await poll() }
    }

    private func poll() async {
        while !Task.isCancelled {
            let reachable = await client.pingServer()
            await update(reachable)
            let interval = reachable ? Self.reachablePollInterval : Self.unreachablePollInterval
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func update(_ reachable: Bool) async {
        let cameBack = reachable && !isServerReachable
        isServerReachable = reachable
        if cameBack {
            await client.flushUnsentProgressReport()
        }
    }
}
