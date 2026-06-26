import AVKit

/// A single, app-lifetime player reused across channel changes.
///
/// Creating a fresh `AVPlayer` for every channel tears down any active AirPlay
/// session — the Apple TV goes blank and the user has to recast. By keeping one
/// player alive and only swapping its item, AirPlay (and local inline playback)
/// continues seamlessly across channel changes.
///
/// Because the player is shared, a *previous* channel's scrape can finish late
/// and try to load its stream after the user has moved on. Every load is tagged
/// with the channel's id and rejected unless it still matches `activeID`, so a
/// slow source can't hijack the screen with the wrong game.
///
/// While a channel is loading (and casting), the player loops a generated
/// color-bars "Loading…" clip so the TV shows the same retro pattern as the
/// in-app loading screen until the real stream is ready. An `AVQueuePlayer` +
/// `AVPlayerLooper` give a seamless, flicker-free loop.
@MainActor
final class PlaybackEngine {
  static let shared = PlaybackEngine()

  let player = AVQueuePlayer()
  /// The channel/game id that currently owns the player. Loads tagged with any
  /// other id are stale and ignored.
  private(set) var activeID: String?

  private var looper: AVPlayerLooper?
  /// Set when a filler was requested before the clip finished generating; we
  /// start it as soon as `ColorBarsVideo` signals ready.
  private var pendingFillerID: String?

  private init() {
    // Send video — not just audio — to AirPlay / HDMI, and keep using AirPlay
    // video even while an external screen is connected.
    player.allowsExternalPlayback = true
    player.usesExternalPlaybackWhileExternalScreenIsActive = true

    ColorBarsVideo.onReady = { [weak self] in
      guard let self, let id = self.pendingFillerID else { return }
      self.showFiller(for: id)
    }
    ColorBarsVideo.prewarm()
  }

  /// Claim the player for a channel. Call when a PlayerView appears.
  func activate(_ id: String) { activeID = id }

  /// Loop the color-bars "finding the next stream" clip on the (external)
  /// screen until a real stream is loaded. No-op if the channel is no longer
  /// active; defers itself until the clip is generated if it isn't ready yet.
  func showFiller(for id: String) {
    guard id == activeID else { return }
    guard let item = ColorBarsVideo.makeLoopingItem() else {
      pendingFillerID = id
      ColorBarsVideo.prewarm()
      return
    }
    pendingFillerID = nil
    looper?.disableLooping()
    looper = nil
    player.removeAllItems()
    looper = AVPlayerLooper(player: player, templateItem: item)
    player.play()
  }

  /// Hot-swap to a real stream item, keeping the same player (and any active
  /// AirPlay route) alive. Returns false — and changes nothing — if the channel
  /// is no longer active (a stale, late-finishing scrape). Ends the filler loop.
  @discardableResult
  func load(_ item: AVPlayerItem, for id: String) -> Bool {
    guard id == activeID else { return false }
    pendingFillerID = nil
    looper?.disableLooping()
    looper = nil
    player.removeAllItems()
    player.insert(item, after: nil)
    player.play()
    return true
  }

  /// Stop playback and clear the queue. Used when leaving the player while not
  /// casting, and on the stall/fail fallback.
  func stop() {
    pendingFillerID = nil
    looper?.disableLooping()
    looper = nil
    player.removeAllItems()
    player.pause()
  }
}
