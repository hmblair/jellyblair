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

    func attach(to player: PlayerController) {
        self.player = player
        configureCommands()
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
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: SkipIntervals.back)]
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: SkipIntervals.forward)]
    }

    /// The explicit playback state only exists on macOS; iOS infers it.
    private func setPlaybackState(on center: MPNowPlayingInfoCenter, playing: Bool, stopped: Bool) {
        #if os(macOS)
        center.playbackState = stopped ? .stopped : (playing ? .playing : .paused)
        #endif
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
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.dispatch { player in Task { await player.skip(by: SkipIntervals.forward) } } ?? .commandFailed
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.dispatch { player in Task { await player.skip(by: -SkipIntervals.back) } } ?? .commandFailed
        }
        syncSkipIntervals()
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.dispatch { player in Task { await player.nextChapter() } } ?? .commandFailed
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.dispatch { player in Task { await player.previousChapter() } } ?? .commandFailed
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            return self?.dispatch { player in Task { await player.seekWithinCurrentChapter(to: position) } } ?? .commandFailed
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
