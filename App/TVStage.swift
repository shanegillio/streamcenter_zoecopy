import SwiftUI

/// The TV at the top of the home screen. Hosts the embedded player for the
/// currently selected game and the channel-surfing controls (up / down /
/// prev). When nothing is selected it shows an idle "test pattern".
struct TVStageView: View {
  let game: Game?
  let canGoPrev: Bool
  let onChannelUp: () -> Void
  let onChannelDown: () -> Void
  let onPrev: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      tvBox
      controls
    }
    .padding(.horizontal, 14)
  }

  private var tvBox: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 14)
        .fill(Color.black)
      if let game {
        // Tapping the video reveals AVKit's native transport controls,
        // which include a full-screen (expand) button. Going full screen
        // that way reuses this same AVPlayer instead of spinning up a
        // second player, so there's never a double-video.
        PlayerView(game: game, embedded: true)
          .id(game.id)
          .clipShape(RoundedRectangle(cornerRadius: 14))
      } else {
        TestPatternView()
          .clipShape(RoundedRectangle(cornerRadius: 14))
      }
    }
    .frame(height: 200)
    .frame(maxWidth: .infinity)
  }

  private var controls: some View {
    VStack(spacing: 12) {
      Button(action: onChannelUp) {
        controlIcon("chevron.up")
      }
      .accessibilityLabel("Previous channel")
      Button(action: onChannelDown) {
        controlIcon("chevron.down")
      }
      .accessibilityLabel("Next channel")
      Button(action: onPrev) {
        Text("prev.")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(canGoPrev ? GuideTheme.text : GuideTheme.textDim)
          .padding(.horizontal, 10)
          .frame(height: 30)
          .glassBackground(in: Capsule())
      }
      .disabled(!canGoPrev)
      .accessibilityLabel("Previous channel viewed")
    }
    .frame(width: 52)
  }

  private func controlIcon(_ name: String) -> some View {
    Image(systemName: name)
      .font(.system(size: 18, weight: .bold))
      .foregroundStyle(GuideTheme.text)
      .frame(width: 46, height: 42)
      .glassBackground(in: RoundedRectangle(cornerRadius: 13))
  }
}

/// Idle "no signal" pattern shown in the TV when no game is selected.
struct TestPatternView: View {
  private let bars: [Color] = [.white, .yellow, .cyan, .green, .red, .blue, .purple]

  var body: some View {
    ZStack {
      HStack(spacing: 0) {
        ForEach(0..<bars.count, id: \.self) { i in
          bars[i].frame(maxWidth: .infinity)
        }
      }
      VStack(spacing: 6) {
        Image(systemName: "antenna.radiowaves.left.and.right")
          .font(.system(size: 26, weight: .semibold))
        Text("No live games")
          .font(.subheadline.weight(.semibold))
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }
  }
}
