import Foundation

/// When a source's hostname fails DNS resolution on the user's device (most
/// commonly because content-filtering DNS — NextDNS, AdGuard, school/work
/// resolvers, iOS Screen Time content restrictions, carrier blocks — has
/// blocked the canonical TLD), this actor silently probes the same
/// hostname-prefix on a fixed list of other TLDs and returns the first one
/// that resolves. Streaming-site mirrors are commonly registered across
/// `.ms`, `.net`, `.app`, `.io`, `.live`, `.cc`, etc. The fallback is
/// transparent to the user — the working variant just replaces the
/// originally-typed URL in `SourceRegistry`.
///
/// Probes are HEAD requests with a 5 s per-request timeout, run in parallel
/// via `withTaskGroup` so total wallclock = slowest-successful-probe.
actor HostFallback {
  static let shared = HostFallback()

  /// TLDs commonly used by streaming-site mirrors (intersect with the FMHY
  /// wiki). Ordered roughly by observed frequency.
  private static let candidateTLDs = [
    "ms", "net", "app", "live", "io", "cc", "lc", "com", "co",
    "pk", "sx", "gd", "ga", "ph", "to", "sh", "cx", "vu", "su",
    "direct", "tv", "stream", "watch", "info", "xyz", "site", "fit",
    "lat", "click", "buzz", "vip", "space", "website", "moviebite",
  ]

  /// Cache: host-prefix ("crackstreams") → working host ("crackstreams.net").
  /// Survives the app session; not persisted (cheap to re-probe on cold launch).
  private var resolved: [String: String] = [:]
  /// Negative cache: don't pound retries while every variant is failing.
  private var negativeUntil: [String: Date] = [:]
  private static let negativeTTL: TimeInterval = 300   // 5 min

  /// Given a URL whose host failed DNS, try the same hostname-prefix with
  /// other common TLDs. Returns a working URL or nil if every variant fails.
  func tryVariants(of url: URL) async -> URL? {
    guard let host = url.host else { return nil }
    let prefix = Self.hostPrefix(of: host)
    let scheme = url.scheme ?? "https"

    if let working = resolved[prefix], working != host {
      return url.with(host: working)
    }
    if let until = negativeUntil[prefix], Date() < until { return nil }

    let variants = Self.candidateTLDs
      .map { "\(prefix).\($0)" }
      .filter { $0 != host }

    if let working = await firstWorkingHost(among: variants, scheme: scheme) {
      resolved[prefix] = working
      negativeUntil[prefix] = nil
      return url.with(host: working)
    }
    negativeUntil[prefix] = Date().addingTimeInterval(Self.negativeTTL)
    return nil
  }

  // MARK: - Internals

  private func firstWorkingHost(among hosts: [String], scheme: String) async -> String? {
    await withTaskGroup(of: String?.self) { group in
      for host in hosts {
        group.addTask {
          await Self.probe(host: host, scheme: scheme) ? host : nil
        }
      }
      for await result in group {
        if let host = result {
          group.cancelAll()
          return host
        }
      }
      return nil
    }
  }

  /// HEAD-request probe; treats any 2xx/3xx as a working host (some sites
  /// return 301 to a canonical mirror, which is still proof the DNS resolves).
  private static func probe(host: String, scheme: String) async -> Bool {
    guard let url = URL(string: "\(scheme)://\(host)/") else { return false }
    var req = URLRequest(url: url, timeoutInterval: 5)
    req.httpMethod = "HEAD"
    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
    guard let (_, resp) = try? await URLSession.shared.data(for: req),
          let http = resp as? HTTPURLResponse else { return false }
    return (200..<400).contains(http.statusCode)
  }

  /// Extracts the hostname prefix that we'll re-apply across TLDs. For
  /// `crackstreams.ms` we want `crackstreams`. For a multi-label host
  /// like `cdn.example.app` we want `cdn.example`.
  private static func hostPrefix(of host: String) -> String {
    let parts = host.split(separator: ".")
    guard parts.count >= 2 else { return host }
    return parts.dropLast().joined(separator: ".")
  }
}

private extension URL {
  /// Returns a copy of the URL with `host` replaced.
  func with(host newHost: String) -> URL {
    var comps = URLComponents(url: self, resolvingAgainstBaseURL: false)
    comps?.host = newHost
    return comps?.url ?? self
  }
}
