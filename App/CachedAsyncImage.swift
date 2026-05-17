import SwiftUI
import UIKit

/// Process-wide image cache shared by all CachedAsyncImage instances.
/// Lives outside the generic view because Swift can't nest static
/// properties inside generic types.
enum ImageMemoryCache {
  static let shared: NSCache<NSURL, UIImage> = {
    let c = NSCache<NSURL, UIImage>()
    c.countLimit = 500
    c.totalCostLimit = 32 * 1024 * 1024
    return c
  }()
}

/// Drop-in replacement for `AsyncImage` that **explicitly** consults
/// `URLCache.shared` and a tiny in-memory `NSCache<NSURL, UIImage>` before
/// going to the network. SwiftUI's stock `AsyncImage` has documented-vague
/// caching behaviour: on real devices with ~30 simultaneous fetches (a
/// Streams tab full of game cards), some instances stay in the `.empty`
/// phase indefinitely while the same URL renders fine in a less crowded
/// view (a per-league detail screen). `URLSession.shared.dataTask` *does*
/// reliably use `URLCache.shared`, so reading the cache directly here makes
/// the prefetcher's warm data actually visible to the UI.
///
/// Usage mirrors `AsyncImage(url:)`: pass a URL, a `content` builder for the
/// success case, and a `placeholder` builder for empty/loading/failure.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
  let url: URL?
  let content: (Image) -> Content
  let placeholder: () -> Placeholder

  @State private var uiImage: UIImage?

  /// In-memory cache of decoded images. Survives view rebuilds; cleared on
  /// memory warnings by NSCache automatically. Lives outside this generic
  /// view (Swift can't nest static properties in generic types).
  fileprivate static var memoryCache: NSCache<NSURL, UIImage> { ImageMemoryCache.shared }

  init(
    url: URL?,
    @ViewBuilder content: @escaping (Image) -> Content,
    @ViewBuilder placeholder: @escaping () -> Placeholder
  ) {
    self.url = url
    self.content = content
    self.placeholder = placeholder
    if let url, let cached = Self.memoryCache.object(forKey: url as NSURL) {
      _uiImage = State(initialValue: cached)
    } else if let url, let img = Self.imageFromURLCache(url) {
      Self.memoryCache.setObject(img, forKey: url as NSURL)
      _uiImage = State(initialValue: img)
    } else {
      _uiImage = State(initialValue: nil)
    }
  }

  var body: some View {
    Group {
      if let img = uiImage {
        content(Image(uiImage: img))
      } else {
        placeholder()
      }
    }
    .task(id: url) {
      await load()
    }
  }

  private func load() async {
    guard let url else { return }
    if uiImage != nil { return }   // already loaded
    // Re-check memory cache in case another instance loaded while we waited.
    if let cached = Self.memoryCache.object(forKey: url as NSURL) {
      uiImage = cached
      return
    }
    if let img = Self.imageFromURLCache(url) {
      Self.memoryCache.setObject(img, forKey: url as NSURL)
      uiImage = img
      return
    }
    var request = URLRequest(url: url, timeoutInterval: 12)
    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
    do {
      let (data, _) = try await URLSession.shared.data(for: request)
      guard let img = UIImage(data: data) else { return }
      Self.memoryCache.setObject(img, forKey: url as NSURL)
      uiImage = img
    } catch {
      // Network failed — placeholder stays.
    }
  }

  /// Look up an already-cached HTTP response for `url` and decode it as a
  /// UIImage. This is the fast path that makes `LogoPrefetcher`'s warming
  /// pay off: prefetcher writes the bytes; we read them synchronously.
  private static func imageFromURLCache(_ url: URL) -> UIImage? {
    let request = URLRequest(url: url)
    guard let cached = URLCache.shared.cachedResponse(for: request) else { return nil }
    return UIImage(data: cached.data)
  }
}
