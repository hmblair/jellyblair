#if canImport(AppKit)
import AppKit
#endif
import Foundation
import MediaPlayer

/// Publishes playback state to the system Now Playing center and routes
/// remote commands (media keys, AirPods, Control Center) to the player.
@MainActor
final class NowPlayingCenter {
    private weak var player: PlayerController?

    /// The registered command handlers, kept so detach can remove them.
    private var commandTargets: [(MPRemoteCommand, Any)] = []

    func attach(to player: PlayerController) {
        self.player = player
        configureCommands()
    }

    /// Unregisters every command handler. The command center is a process-wide
    /// singleton, so a center that goes away must take its targets with it.
    func detach() {
        for (command, token) in commandTargets {
            command.removeTarget(token)
        }
        commandTargets = []
    }

    func update(bookTitle: String?, author: String?, chapterTitle: String?, elapsed: Double, duration: Double, rate: Double, isPlaying: Bool, artwork: PlatformImage?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let bookTitle else {
            center.nowPlayingInfo = nil
            setPlaybackState(on: center, playing: false, stopped: true)
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapterTitle.map { "\(bookTitle) · \($0)" } ?? bookTitle,
            MPMediaItemPropertyAlbumTitle: bookTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let author {
            info[MPMediaItemPropertyArtist] = author
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        center.nowPlayingInfo = info
        setPlaybackState(on: center, playing: isPlaying, stopped: false)
        syncSkipIntervals()
    }

    /// Keeps the remote skip buttons' labels at the stored intervals, which
    /// the settings screens can change at any time.
    private func syncSkipIntervals() {
        let commands = MPRemoteCommandCenter.shared()
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: TransportSkip.back.intervalSeconds)]
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: TransportSkip.forward.intervalSeconds)]
    }

    /// The explicit playback state only exists on macOS; iOS infers it.
    private func setPlaybackState(on center: MPNowPlayingInfoCenter, playing: Bool, stopped: Bool) {
        #if os(macOS)
        center.playbackState = stopped ? .stopped : (playing ? .playing : .paused)
        #endif
    }

    private func configureCommands() {
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { $0.play() }
        register(center.pauseCommand) { $0.pause() }
        register(center.togglePlayPauseCommand) { $0.togglePlayback() }
        register(center.skipForwardCommand) { TransportSkip.forward.perform(on: $0) }
        register(center.skipBackwardCommand) { TransportSkip.back.perform(on: $0) }
        syncSkipIntervals()
        // The AirPods taps arrive as the track commands, and perform the
        // transport's skips like every other surface.
        register(center.nextTrackCommand) { TransportSkip.forward.perform(on: $0) }
        register(center.previousTrackCommand) { TransportSkip.back.perform(on: $0) }
        registerScrub(center.changePlaybackPositionCommand)
    }

    /// Registers one command handler and keeps its token for detach.
    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor (PlayerController) -> Void) {
        let token = command.addTarget { [weak self] _ in
            self?.dispatch(action) ?? .commandFailed
        }
        commandTargets.append((command, token))
    }

    /// Registers the scrub handler, which is the one command that reads its
    /// event, and keeps its token for detach.
    private func registerScrub(_ command: MPChangePlaybackPositionCommand) {
        let token = command.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            return self?.dispatch { player in Task { await player.seekWithinCurrentChapter(to: position) } } ?? .commandFailed
        }
        commandTargets.append((command, token))
    }

    /// Runs a command against the player on the main actor. Remote command
    /// callbacks can arrive off the main thread.
    private func dispatch(_ action: @escaping @MainActor (PlayerController) -> Void) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor [weak self] in
            guard let player = self?.player else { return }
            action(player)
        }
        return .success
    }
}
