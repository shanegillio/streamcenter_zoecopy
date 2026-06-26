import AVFoundation
import SwiftUI
import UIKit

/// Generates a short, looping SMPTE color-bars video clip — the same retro
/// rainbow pattern (and "Loading…" band) the guide shows — so it can be played
/// on an AirPlay screen via `AVPlayer` while the next stream is found. SwiftUI
/// views don't travel over AirPlay; only the player's video does, so the loading
/// screen has to be actual video. The clip is one full shift cycle of the seven
/// bars and is looped by `PlaybackEngine`, reproducing the guide's scrolling.
@MainActor
enum ColorBarsVideo {
  private static var cachedURL: URL?
  private static var generating = false

  /// Invoked on the main actor when generation finishes, so a filler request
  /// that arrived before the clip was ready can start. Set by `PlaybackEngine`.
  static var onReady: (() -> Void)?

  static var isReady: Bool { cachedURL != nil }

  /// A fresh player item looping the generated clip, or nil if it isn't ready
  /// yet. After `prewarm()` completes (kicked off at launch) this is instant.
  static func makeLoopingItem() -> AVPlayerItem? {
    guard let cachedURL else { return nil }
    return AVPlayerItem(url: cachedURL)
  }

  /// Generates the clip off the main thread and caches its URL. Safe to call
  /// repeatedly — it only generates once, and fires `onReady` when done (or
  /// immediately if already generated).
  static func prewarm() {
    if cachedURL != nil { onReady?(); return }
    guard !generating else { return }
    generating = true
    // Resolve the guide's bar colors to RGBA on the main actor so the clip
    // matches `TVColorBarsView` exactly (and so no non-Sendable UIColors cross
    // actor boundaries).
    let guideBars: [Color] = [
      Color(white: 0.78), .yellow, .cyan, .green,
      Color(red: 1, green: 0, blue: 1), .red, .blue,
    ]
    let components: [[CGFloat]] = guideBars.map { color in
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
      return [r, g, b, a]
    }
    Task.detached(priority: .utility) {
      let url = generateClip(barComponents: components)
      await MainActor.run {
        cachedURL = url
        generating = false
        onReady?()
      }
    }
  }

  // MARK: - Generation

  nonisolated private static func generateClip(barComponents: [[CGFloat]]) -> URL? {
    let width = 960
    let height = 540
    let bars = barComponents.map {
      UIColor(red: $0[0], green: $0[1], blue: $0[2], alpha: $0[3])
    }
    let count = bars.count
    let fps: Int32 = 2  // each frame held 0.5 s, matching the guide's shift rate

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("streamcenter-colorbars.mp4")
    try? FileManager.default.removeItem(at: url)

    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input, sourcePixelBufferAttributes: attrs
    )
    guard writer.canAdd(input) else { return nil }
    writer.add(input)
    guard writer.startWriting() else { return nil }
    writer.startSession(atSourceTime: .zero)

    // One frame per shift step = one full scroll cycle.
    for step in 0..<count {
      guard let image = renderFrame(width: width, height: height, shift: step, bars: bars),
            let buffer = pixelBuffer(from: image, width: width, height: height)
      else { continue }
      while !input.isReadyForMoreMediaData { usleep(2000) }
      adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(step), timescale: fps))
    }

    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(count), timescale: fps))
    writer.finishWriting { done.signal() }
    done.wait()
    return writer.status == .completed ? url : nil
  }

  nonisolated private static func renderFrame(
    width: Int, height: Int, shift: Int, bars: [UIColor]
  ) -> CGImage? {
    let size = CGSize(width: width, height: height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    let image = renderer.image { context in
      let cg = context.cgContext
      let count = bars.count
      let barWidth = size.width / CGFloat(count)
      for i in 0..<count {
        bars[(i + shift) % count].setFill()
        // +1 px overlap avoids hairline seams between bars.
        cg.fill(CGRect(x: CGFloat(i) * barWidth, y: 0, width: barWidth + 1, height: size.height))
      }
      // Black broadcast band + "Loading…" label, mirroring StreamLoadingOverlay.
      let bandHeight = size.height * 0.20
      let bandRect = CGRect(
        x: 0, y: (size.height - bandHeight) / 2, width: size.width, height: bandHeight
      )
      UIColor.black.withAlphaComponent(0.88).setFill()
      cg.fill(bandRect)
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .center
      let attrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: size.height * 0.085, weight: .bold),
        .foregroundColor: UIColor.white,
        .paragraphStyle: paragraph,
      ]
      let text = "Loading…" as NSString
      let textSize = text.size(withAttributes: attrs)
      text.draw(
        in: CGRect(x: 0, y: bandRect.midY - textSize.height / 2,
                   width: size.width, height: textSize.height),
        withAttributes: attrs
      )
    }
    return image.cgImage
  }

  nonisolated private static func pixelBuffer(
    from image: CGImage, width: Int, height: Int
  ) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let attrs = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ] as CFDictionary
    CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pb
    )
    guard let buffer = pb else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard let ctx = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer),
      width: width, height: height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }

    // Flip to compensate for CGContext's bottom-left origin so the rendered
    // image (and its "Loading…" text) is stored upright in the pixel buffer.
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }
}
