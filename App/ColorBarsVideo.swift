import AVFoundation
import UIKit

/// Generates a short, looping SMPTE color-bars video clip — the same retro
/// rainbow pattern the guide uses — so it can be shown on an AirPlay screen via
/// `AVPlayer` while the next stream is being found. (SwiftUI views don't travel
/// over AirPlay; only the player's video does, so the pattern has to be actual
/// video.) The clip is one full shift cycle of the seven bars and is looped by
/// `PlaybackEngine`, reproducing the guide's animated, scrolling bars.
@MainActor
enum ColorBarsVideo {
  private static var cachedURL: URL?
  private static var generating = false

  /// A fresh player item looping the generated clip, or nil if it isn't ready
  /// yet (generation runs in the background; the first cast may briefly miss it).
  static func makeLoopingItem() -> AVPlayerItem? {
    guard let url = cachedURL else { return nil }
    return AVPlayerItem(url: url)
  }

  /// Generates the clip off the main thread and caches its URL. Safe to call
  /// repeatedly — it only generates once.
  static func prewarm() {
    guard cachedURL == nil, !generating else { return }
    generating = true
    Task.detached(priority: .utility) {
      let url = generateClip()
      await MainActor.run {
        cachedURL = url
        generating = false
      }
    }
  }

  // MARK: - Generation

  nonisolated private static func generateClip() -> URL? {
    let width = 960
    let height = 540
    // Bar colors and order match `TVColorBarsView` in TVStage.swift.
    let colors: [UIColor] = [
      UIColor(white: 0.78, alpha: 1), .systemYellow, .systemCyan, .systemGreen,
      UIColor(red: 1, green: 0, blue: 1, alpha: 1), .systemRed, .systemBlue,
    ]
    let count = colors.count
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
      guard let buffer = frame(width: width, height: height, shift: step, colors: colors)
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

  nonisolated private static func frame(
    width: Int, height: Int, shift: Int, colors: [UIColor]
  ) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attrs = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ] as CFDictionary
    CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer
    )
    guard let buffer = pixelBuffer else { return nil }

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

    let count = colors.count
    let barWidth = CGFloat(width) / CGFloat(count)
    for i in 0..<count {
      ctx.setFillColor(colors[(i + shift) % count].cgColor)
      // +1 px overlap avoids hairline seams between bars.
      ctx.fill(CGRect(x: CGFloat(i) * barWidth, y: 0, width: barWidth + 1, height: CGFloat(height)))
    }
    return buffer
  }
}
