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
  /// In landscape the stage takes over the whole screen — the TV box fills the
  /// available space and the guide/header are hidden by the parent — so the
  /// stream plays large with just the channel controls alongside.
  var isLandscape: Bool = false

  private let airplay = AirPlayController.shared

  /// TV bezel / stand color for the landscape "television" frame.
  private static let bezel = Color(white: 0.45)

  var body: some View {
    if isLandscape {
      landscapeStage
    } else {
      // Portrait: the stream spans the full guide width with the channel
      // controls overlaid on its trailing edge (liquid glass), rather than
      // sitting in a column beside it.
      ZStack(alignment: .trailing) {
        portraitTVBox
        controls
          .padding(.trailing, 10)
      }
      .padding(.horizontal, 16)
      .animation(.smooth, value: airplay.isExternalActive)
    }
  }

  /// The video surface: black backing + the player (or idle test pattern),
  /// plus the AirPlay "broadcasting" cover. Shared by both orientations.
  private var screen: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 14)
        .fill(Color.black)
      if let game {
        // Tapping the video reveals AVKit's native transport controls,
        // which include a full-screen (expand) button. Going full screen
        // that way reuses this same AVPlayer instead of spinning up a
        // second player, so there's never a double-video.
        //
        // The player stays mounted while AirPlaying (so the stream keeps
        // flowing to the TV) but is covered by the broadcasting panel — the
        // phone becomes a remote, with the channel controls alongside.
        PlayerView(game: game, embedded: true)
          .id(game.id)
          .clipShape(RoundedRectangle(cornerRadius: 14))
        if airplay.isExternalActive {
          broadcastingPanel(game: game)
        }
      } else {
        TestPatternView()
          .clipShape(RoundedRectangle(cornerRadius: 14))
      }
    }
  }

  /// Portrait: a fixed-height TV pinned at the top, filling the width.
  private var portraitTVBox: some View {
    screen
      .frame(height: 200)
      .frame(maxWidth: .infinity)
  }

  /// Landscape: a flat-screen TV (thin bezel) on a neck-and-base stand, sized
  /// from the available geometry so it stays large regardless of what the
  /// player is showing (stream, loading, or error). Centered on screen with
  /// the channel controls beside it.
  private var landscapeStage: some View {
    GeometryReader { geo in
      let bezel: CGFloat = 12
      let neckH: CGFloat = 14
      let baseH: CGFloat = 8
      let standTotal = neckH + baseH
      let controlsW: CGFloat = 52
      let edgePad: CGFloat = 12
      // Reserve symmetric room on both sides for the controls (so the
      // screen-centered set never collides with them) and top/bottom for the
      // stand (so the set stays centered while the stand still fits beneath).
      let availW = geo.size.width - (controlsW + edgePad) * 2
      let availH = geo.size.height - edgePad * 2 - standTotal * 2
      let maxScreenW = availW - bezel * 2
      let maxScreenH = availH - bezel * 2
      let screenH = max(0, min(maxScreenH, maxScreenW * 9.0 / 16.0))
      let screenW = screenH * 16.0 / 9.0

      ZStack {
        // The set (screen + thin bezel), centered both vertically and
        // horizontally. The stand hangs beneath it as an overlay so it doesn't
        // shift the set off-center.
        screen
          .frame(width: screenW, height: screenH)
          .padding(bezel)
          .background(
            RoundedRectangle(cornerRadius: 18).fill(Self.bezel)
          )
          .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
              Rectangle()
                .fill(Self.bezel)
                .frame(width: 18, height: neckH)
              RoundedRectangle(cornerRadius: 3)
                .fill(Self.bezel)
                .frame(width: screenW * 0.42, height: baseH)
            }
            .offset(y: standTotal)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        // Channel controls pinned to the right edge, vertically centered.
        controls
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
          .padding(.trailing, edgePad)
      }
      .animation(.smooth, value: airplay.isExternalActive)
    }
  }

  /// Shown over the (still-playing) inline player while the game is on an
  /// external screen. Makes it clear the phone is now a remote.
  private func broadcastingPanel(game: Game) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 14).fill(Color.black)
      VStack(spacing: 10) {
        Image(systemName: "tv.and.mediabox.fill")
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(.white)
        VStack(spacing: 3) {
          Text("Playing on \(airplay.routeName)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
          Text(game.title)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.65))
            .multilineTextAlignment(.center)
            .lineLimit(2)
        }
        .padding(.horizontal, 16)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 14))
    .transition(.opacity)
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
  var body: some View {
    ZStack {
      TVColorBarsView()
      VStack(spacing: 6) {
        Image(systemName: "antenna.radiowaves.left.and.right")
          .font(.system(size: 26, weight: .semibold))
        Text("No live games")
          .font(.subheadline.weight(.semibold))
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }
  }
}

// MARK: - Shared "broadcast" visuals (color bars + static)

/// SMPTE-style color-bar test pattern. The bar order rotates on a timer so the
/// pattern reads as a live, animated signal rather than a static image.
struct TVColorBarsView: View {
  private static let bars: [Color] = [
    Color(white: 0.78), .yellow, .cyan, .green,
    Color(red: 1, green: 0, blue: 1), .red, .blue
  ]
  private static let period: TimeInterval = 0.5

  var body: some View {
    TimelineView(.periodic(from: .now, by: Self.period)) { context in
      let step = Int(context.date.timeIntervalSinceReferenceDate / Self.period)
      let shift = ((step % Self.bars.count) + Self.bars.count) % Self.bars.count
      HStack(spacing: 0) {
        ForEach(0..<Self.bars.count, id: \.self) { i in
          Self.bars[(i + shift) % Self.bars.count]
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .animation(.easeInOut(duration: 0.35), value: shift)
    }
  }
}

/// Animated TV "snow" / static. Drawn as a grid of random-gray cells that
/// refresh each tick — cheap enough to run continuously behind an error state.
struct TVStaticView: View {
  private let cols = 46
  private let rows = 28

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.08)) { context in
      Canvas { ctx, size in
        _ = context.date
        let w = size.width / CGFloat(cols)
        let h = size.height / CGFloat(rows)
        var rng = SystemRandomNumberGenerator()
        for r in 0..<rows {
          for c in 0..<cols {
            let v = Double.random(in: 0...1, using: &rng)
            let rect = CGRect(x: CGFloat(c) * w, y: CGFloat(r) * h,
                              width: w + 0.5, height: h + 0.5)
            ctx.fill(Path(rect), with: .color(Color(white: v)))
          }
        }
      }
    }
    .background(Color.black)
  }
}
