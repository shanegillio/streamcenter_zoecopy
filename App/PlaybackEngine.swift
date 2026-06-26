import AVKit

/// A single, app-lifetime `AVPlayer` reused across channel changes.
///
/// Creating a fresh `AVPlayer` for every channel tears down any active AirPlay
/// session — the Apple TV goes blank and the user has to recast. By keeping one
/// player alive and only swapping its current item, AirPlay (and local inline
/// playback) continues seamlessly across channel changes.
///
/// Because the player is shared, a *previous* channel's scrape can finish late
/// and try to load its stream after the user has already moved on. Every load is
/// therefore tagged with the channel's id and rejected unless it still matches
/// `activeID`, so a slow source can't hijack the screen with the wrong game.
@MainActor
final class PlaybackEngine {
  static let shared = PlaybackEngine()

  let player: AVPlayer
  /// The channel/game id that currently owns the player. Set when a PlayerView
  /// becomes active; loads tagged with any other id are stale and ignored.
  private(set) var activeID: String?
  private var loopObserver: NSObjectProtocol?

  private init() {
    player = AVPlayer()
    // Send video — not just audio — to AirPlay / HDMI, and keep using AirPlay
    // video even while an external screen is connected.
    player.allowsExternalPlayback = true
    player.usesExternalPlaybackWhileExternalScreenIsActive = true
    ColorBarsVideo.prewarm()
  }

  /// Claim the player for a channel. Call when a PlayerView appears.
  func activate(_ id: String) { activeID = id }

  /// Play the looping color-bars "finding the next stream" filler so the
  /// external screen shows the retro test pattern while we scrape. No-op if the
  /// channel is no longer active or the clip isn't ready yet.
  func showFiller(for id: String) {
    guard id == activeID, let item = ColorBarsVideo.makeLoopingItem() else { return }
    installLoop(for: item)
    player.replaceCurrentItem(with: item)
    player.play()
  }

  /// Hot-swap to a real stream item, keeping the same `AVPlayer` instance (and
  /// any active AirPlay route) alive. Returns false — and changes nothing — if
  /// the channel is no longer active (a stale, late-finishing scrape).
  @discardableResult
  func load(_ item: AVPlayerItem, for id: String) -> Bool {
    guard id == activeID else { return false }
    clearLoop()
    player.replaceCurrentItem(with: item)
    return true
  }

  /// Stop playback and release the current item. Used when leaving the player
  /// while not casting, and on the stall/fail fallback.
  func stop() {
    clearLoop()
    player.pause()
    player.replaceCurrentItem(with: nil)
  }

  // MARK: - Looping

  /// Seek back to the start when the (short) filler clip plays out, so it loops
  /// continuously for as long as we're searching.
  private func installLoop(for item: AVPlayerItem) {
    clearLoop()
    loopObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.player.seek(to: .zero)
        self?.player.play()
      }
    }
  }

  private func clearLoop() {
    if let loopObserver {
      NotificationCenter.default.removeObserver(loopObserver)
      self.loopObserver = nil
    }
  }
}
