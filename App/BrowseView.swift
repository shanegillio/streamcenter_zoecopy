import SwiftUI
import WebKit
import AVKit

// Full-screen WebView for a custom source. The user navigates the site manually;
// the m3u8 interceptor catches any stream and hands it to AVPlayer automatically.
struct BrowseView: View {
  let source: AnyStreamSource
  @State private var ruleList: WKContentRuleList? = nil
  @State private var avPlayer: AVPlayer? = nil
  @State private var rulesReady = false

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if rulesReady {
        StreamWebView(
          url: source.baseURL,
          ruleList: ruleList,
          onStreamURLFound: { streamURL, _ in
            let p = AVPlayer(url: streamURL)
            avPlayer = p
            p.play()
          },
          browseMode: true
        )
        .ignoresSafeArea()
        .opacity(avPlayer == nil ? 1 : 0)

        if let avPlayer {
          VideoPlayerView(player: avPlayer)
            .ignoresSafeArea()
        }
      } else {
        ProgressView()
          .tint(.white)
          .scaleEffect(1.5)
      }
    }
    .navigationTitle(source.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .task {
      ruleList = await AdBlockRules.compile()
      rulesReady = true
    }
  }
}
