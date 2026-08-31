import AppKit
import Foundation
import MediaPlayer

/// Publishes playback state to the system Now Playing center and routes
/// remote commands (media keys, AirPods, Control Center) to the player.
@MainActor
final class NowPlayingCenter {
    private weak var player: PlayerController?

    static let skipInterval: Double = 30

    func attach(to player: PlayerController) {
        self.player = player
        configureCommands()
    }

    func update(bookTitle: String?, chapterTitle: String?, elapsed: Double, duration: Double, rate: Double, isPlaying: Bool, artwork: NSImage?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let bookTitle else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapterTitle ?? bookTitle,
            MPMediaItemPropertyAlbumTitle: bookTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    private func configureCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.dispatch { $0.play() } ?? .commandFailed
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.dispatch { $0.pause() } ?? .commandFailed
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.dispatch { $0.togglePlayback() } ?? .commandFailed
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.dispatch { player in Task { await player.skip(by: Self.skipInterval) } } ?? .commandFailed
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.dispatch { player in Task { await player.skip(by: -Self.skipInterval) } } ?? .commandFailed
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            return self?.dispatch { player in Task { await player.seek(to: position) } } ?? .commandFailed
        }
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
