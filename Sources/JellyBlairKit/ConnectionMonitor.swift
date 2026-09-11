import Foundation
import Network
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Tracks whether the Jellyfin server is reachable, from two facts with one
/// owner each: the system's path monitor owns whether the device has a
/// network path, and real request outcomes own whether the server answers.
/// Views read the derived flag; the client's own requests feed the evidence.
/// Active probing runs only while a path exists but the server does not
/// answer, since that is the one state no organic traffic can exit, and it
/// backs off while the outage lasts.
/// When the server comes back, flushes any progress report that failed to send.
@MainActor
@Observable
public final class ConnectionMonitor {
    private let client: JellyfinClient

    /// True while the device has a usable network path. handlePathChange
    /// is the one writer.
    private var hasNetworkPath = true

    /// True while the latest evidence says the server answers requests.
    /// noteServerAnswer is the one writer.
    private var serverAnswers = true

    /// True while the app is in the background, which suspends probing.
    /// Background playback needs no reachability, and real traffic still
    /// updates the evidence.
    private var isSuspended = false

    public private(set) var isServerReachable = true

    private var probeTask: Task<Void, Never>?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []

    /// Probe delays: the first retry comes quickly so a short outage
    /// recovers promptly, then the delay doubles so a long one costs little.
    private static let initialProbeInterval: TimeInterval = 5
    private static let maxProbeInterval: TimeInterval = 120

    public init(client: JellyfinClient) {
        self.client = client
    }

    deinit {
        pathMonitor.cancel()
        // Owned by SwiftUI state, so deallocation happens on the main thread.
        MainActor.assumeIsolated {
            probeTask?.cancel()
            for observer in lifecycleObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        observeRequestOutcomes()
        observePath()
        observeAppLifecycle()
    }

    // MARK: - Evidence from real requests

    /// Every request the client sends doubles as a probe: its outcome is
    /// the evidence for whether the server answers. Playback reports ask
    /// the derived flag before touching the network.
    private func observeRequestOutcomes() {
        client.onRequestOutcome = { [weak self] answered in
            Task { @MainActor in
                self?.noteServerAnswer(answered)
            }
        }
        client.reportGate = { [weak self] in
            await self?.isServerReachable ?? true
        }
    }

    private func noteServerAnswer(_ answered: Bool) {
        guard answered != serverAnswers else { return }
        serverAnswers = answered
        updateDerivedState()
        if answered {
            Task { await client.flushUnsentProgressReport() }
        }
    }

    // MARK: - The network path

    /// Losing the path makes unreachability known instantly, with no
    /// request; regaining it triggers one confirming ping, since a live
    /// network does not guarantee a reachable server.
    private func observePath() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self?.handlePathChange(satisfied: satisfied)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "connection-path-monitor"))
    }

    private func handlePathChange(satisfied: Bool) {
        guard satisfied != hasNetworkPath else { return }
        hasNetworkPath = satisfied
        updateDerivedState()
        if satisfied {
            probeNow()
        }
    }

    // MARK: - App lifecycle

    #if canImport(UIKit)
    /// Suspends probing in the background and resumes it, with one prompt
    /// ping when the server was unreachable, on return to the foreground.
    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.setSuspended(true)
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.setSuspended(false)
                }
            },
        ]
    }
    #else
    /// The Mac app is never suspended, so probing runs whenever needed.
    private func observeAppLifecycle() {}
    #endif

    private func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        syncProbing()
        if !suspended, hasNetworkPath, !serverAnswers {
            probeNow()
        }
    }

    // MARK: - Derived state and probing

    /// The one writer of the public flag. An unchanged value writes
    /// nothing, so repeated evidence invalidates no observers.
    private func updateDerivedState() {
        let reachable = hasNetworkPath && serverAnswers
        if reachable != isServerReachable {
            isServerReachable = reachable
        }
        syncProbing()
    }

    /// Runs the probe loop exactly while a path exists, the server does
    /// not answer, and the app is frontmost. Every other state either
    /// needs no probing or learns from path events and real traffic.
    private func syncProbing() {
        let shouldProbe = hasNetworkPath && !serverAnswers && !isSuspended
        if shouldProbe, probeTask == nil {
            startProbing()
        } else if !shouldProbe, let probeTask {
            probeTask.cancel()
            self.probeTask = nil
        }
    }

    /// Pings until cancelled, backing off. The ping's outcome flows back
    /// through the request-outcome evidence, which cancels this loop when
    /// the server answers, so the loop itself keeps no state.
    /// The first ping waits one interval: the loop starts on fresh
    /// evidence, so asking again at once would learn nothing.
    private func startProbing() {
        probeTask = Task { [weak self] in
            var delay = Self.initialProbeInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                _ = await self.client.pingServer()
                delay = min(delay * 2, Self.maxProbeInterval)
            }
        }
    }

    /// One immediate ping, for the moments that deserve a prompt answer:
    /// the path coming back, or the app returning to the foreground while
    /// the server was unreachable. Its outcome feeds the evidence like any
    /// other request.
    private func probeNow() {
        Task {
            _ = await client.pingServer()
        }
    }
}
