import AVKit

/// A single, app-lifetime `AVPlayer` reused across channel changes.
///
/// Creating a fresh `AVPlayer` for every channel tears down any active AirPlay
/// session — the Apple TV goes blank and the user has to recast. By keeping one
/// player alive and only swapping its current item, AirPlay (and local inline
/// playback) continues seamlessly: the previous channel keeps playing on the TV
/// while the next stream is still being scraped, then we hot-swap the item the
/// moment it's ready. Nothing ever fully stops.
@MainActor
final class PlaybackEngine {
  static let shared = PlaybackEngine()

  let player: AVPlayer

  private init() {
    player = AVPlayer()
    // Send video — not just audio — to AirPlay / HDMI, and keep using AirPlay
    // video even while an external screen is connected.
    player.allowsExternalPlayback = true
    player.usesExternalPlaybackWhileExternalScreenIsActive = true
  }

  /// Hot-swap to a new stream item, keeping the same `AVPlayer` instance (and
  /// therefore any active AirPlay route) alive.
  func load(_ item: AVPlayerItem) {
    player.replaceCurrentItem(with: item)
  }

  /// Stop playback and release the current item. Used when leaving the player
  /// while *not* casting, so the prior channel's audio doesn't bleed into the
  /// next channel's loading screen.
  func stop() {
    player.pause()
    player.replaceCurrentItem(with: nil)
  }
}
