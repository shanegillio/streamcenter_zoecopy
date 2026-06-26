import SwiftUI
import AVKit

/// Tracks whether playback is currently routed to an external screen (AirPlay
/// or HDMI) and owns the app's audio-session configuration. Configuring the
/// session for `.playback` / `.moviePlayback` is what lets AVPlayer send *video*
/// to an Apple TV instead of only mirroring audio. Observed by the home-screen
/// TV so it can flip into "remote" mode while the game plays on the big screen.
@MainActor
@Observable
final class AirPlayController {
  static let shared = AirPlayController()

  /// True while the current audio route outputs to AirPlay or HDMI.
  private(set) var isExternalActive = false
  /// Friendly name of the external destination (e.g. "Living Room"), for the
  /// "Playing on …" label. Falls back to a generic name.
  private(set) var routeName = "AirPlay"

  private var observer: NSObjectProtocol?

  private init() {
    configureAudioSession()
    refresh()
    observer = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  /// Sets the playback category so AVPlayer external playback (AirPlay video)
  /// works and audio keeps playing when the app is backgrounded. Safe to call
  /// repeatedly; cheap no-op once configured.
  func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
    } catch {
      // Non-fatal: playback still works locally; AirPlay video may be limited.
    }
  }

  private func refresh() {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    if let external = outputs.first(where: {
      $0.portType == .airPlay || $0.portType == .HDMI
    }) {
      routeName = external.portName.isEmpty ? "AirPlay" : external.portName
      isExternalActive = true
    } else {
      isExternalActive = false
    }
  }
}

/// SwiftUI wrapper around `AVRoutePickerView` — the system AirPlay button.
/// `prioritizesVideoDevices` makes it surface video-capable destinations (Apple
/// TV, AirPlay-2 TVs) so the user picks a screen, not just speakers.
struct AirPlayRoutePicker: UIViewRepresentable {
  var tint: Color = GuideTheme.text
  var activeTint: Color = .accentColor

  func makeUIView(context: Context) -> AVRoutePickerView {
    let picker = AVRoutePickerView()
    picker.prioritizesVideoDevices = true
    picker.backgroundColor = .clear
    picker.tintColor = UIColor(tint)
    picker.activeTintColor = UIColor(activeTint)
    return picker
  }

  func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
    uiView.tintColor = UIColor(tint)
    uiView.activeTintColor = UIColor(activeTint)
  }
}
