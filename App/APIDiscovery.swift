import Foundation

/// Generic JSON-API discovery for any custom source.
///
/// Most modern sports-streaming sites are Vue/Nuxt/Next single-page apps
/// gated by Cloudflare or Turnstile — hostile to HTML scraping, but their
/// own front-end pulls structured data from a JSON endpoint that's usually
/// open. This actor probes a fixed set of common API paths (with subdomain
/// swaps), feeds successful responses through a small shape registry, and
/// returns games when any known shape matches. **No host names appear in
/// the discovery logic** — every source is treated identically.
///
/// Successful discoveries are cached per-host (10 min). Misses negative-cache
/// for 5 min so we re-probe periodically in case a site adds an API later.
actor APIDiscovery {
  static let shared = APIDiscovery()

  // MARK: - Configuration

  /// Common JSON-API paths used across Nuxt/Next/Vue/Express deployments.
  /// Ordered roughly by observed frequency (no per-site knowledge).
  private static let candidatePaths: [String] = [
    "/api/streams", "/api/games", "/api/events", "/api/matches",
    "/api/matches/all", "/api/matches/live", "/api/matches/upcoming",
    "/api/get-matches", "/api/get-games", "/api/get-events", "/api/get-streams",
    "/api/sport", "/api/sports", "/api/category", "/api/categories",
    "/api/v1/streams", "/api/v1/games", "/api/v1/events", "/api/v1/matches",
    "/api/v2/streams", "/api/v2/games",
    "/api/live", "/streams.json", "/games.json", "/events.json",
  ]

  /// Subdomain prefixes to also probe (in addition to the original host).
  /// Many sites split API to `api.foo.com` while the SPA lives on `foo.com`.
  private static let subdomainPrefixes = ["api", "data", "www"]

  private static let positiveTTL: TimeInterval = 600   // 10 min
  private static let negativeTTL: TimeInterval = 300   // 5 min
  private static let perRequestTimeout: TimeInterval = 6

  // MARK: - Cache

  /// Per-host: either the working endpoint URL, or `.some(nil)` to mean
  /// "we probed and found nothing this session." Distinguishes "haven't
  /// tried yet" (key missing) from "tried, no API" (value nil).
  private var workingEndpoint: [String: URL?] = [:]
  private var endpointExpiry:  [String: Date] = [:]

  // MARK: - Public API

  /// Result of one discovery attempt.
  struct Result {
    let endpoint: URL
    let games: [DiscoveredGame]
  }

  /// Tries to fetch games via API discovery. Returns nil if no API matches.
  func fetchGames(for baseURL: URL) async -> Result? {
    let host = baseURL.host?.lowercased() ?? baseURL.absoluteString.lowercased()

    // Cache check
    if let until = endpointExpiry[host], Date() < until {
      if let cached = workingEndpoint[host], let url = cached {
        if let games = await fetchAndDecode(url), !games.isEmpty {
          return Result(endpoint: url, games: games)
        }
      }
      // Negative cache or stale positive — fall through to re-probe below.
      // But if it's a negative entry and still fresh, bail.
      if let cached = workingEndpoint[host], cached == nil {
        return nil
      }
    }

    // Probe in parallel — first non-empty success wins.
    let candidates = buildCandidates(for: baseURL)
    let result = await firstSuccessfulProbe(among: candidates)

    if let result {
      workingEndpoint[host] = .some(result.endpoint)
      endpointExpiry[host] = Date().addingTimeInterval(Self.positiveTTL)
      return result
    } else {
      workingEndpoint[host] = .some(nil)
      endpointExpiry[host] = Date().addingTimeInterval(Self.negativeTTL)
      return nil
    }
  }

  /// Most recent endpoint hit for this host, for surfacing in DiagnosticsView.
  func cachedEndpoint(for baseURL: URL) -> URL? {
    let host = baseURL.host?.lowercased() ?? ""
    return workingEndpoint[host] ?? nil
  }

  /// Decode an explicit list of URLs (observed by the WebView's fetch/XHR
  /// shim during a scrape) and return the first non-empty `Result`. Bypasses
  /// the candidate-path probing — caller hands us URLs they know the page
  /// itself just fetched, so we don't have to guess. Used by
  /// `CustomStreamSource.fetchAvailableLeagues` to consume the JSON
  /// endpoints aggregator sites (bintv.net) pull from.
  ///
  /// The URLs may be cross-origin to `referer` (and usually are — aggregators
  /// fetch from github.io, ppv.to API, etc.). We set the Referer / Origin
  /// to the observing page so CORS-required endpoints accept us.
  func decodeObservedURLs(_ urls: [URL], referer: URL) async -> Result? {
    guard !urls.isEmpty else { return nil }
    let referHeader = referer.absoluteString
    let originHeader: String = {
      guard let scheme = referer.scheme, let host = referer.host else { return referHeader }
      return "\(scheme)://\(host)"
    }()
    return await withTaskGroup(of: Result?.self) { group in
      for url in urls {
        group.addTask { [weak self] in
          guard let self else { return nil }
          if let games = await self.fetchAndDecode(url, referer: referHeader, origin: originHeader),
             !games.isEmpty {
            return Result(endpoint: url, games: games)
          }
          return nil
        }
      }
      for await result in group {
        if let result {
          group.cancelAll()
          // Cache as a working endpoint for this host so subsequent calls
          // to `fetchGames(for:)` skip the candidate-path probe and go
          // straight here.
          let host = referer.host?.lowercased() ?? ""
          workingEndpoint[host] = .some(result.endpoint)
          endpointExpiry[host] = Date().addingTimeInterval(Self.positiveTTL)
          return result
        }
      }
      return nil
    }
  }

  // MARK: - Probing

  private func buildCandidates(for baseURL: URL) -> [URL] {
    var urls: [URL] = []
    var seen = Set<String>()
    let scheme = baseURL.scheme ?? "https"
    let host = baseURL.host ?? ""
    guard !host.isEmpty else { return [] }

    var hosts: [String] = [host]
    for prefix in Self.subdomainPrefixes where !host.hasPrefix(prefix + ".") {
      hosts.append("\(prefix).\(host)")
    }

    for h in hosts {
      for path in Self.candidatePaths {
        let s = "\(scheme)://\(h)\(path)"
        guard seen.insert(s).inserted, let u = URL(string: s) else { continue }
        urls.append(u)
      }
    }
    return urls
  }

  /// Issue all probes in parallel; return the first that successfully decodes
  /// a non-empty game list. Cancels remaining in-flight probes via TaskGroup
  /// cancellation when a winner is found.
  private func firstSuccessfulProbe(among urls: [URL]) async -> Result? {
    await withTaskGroup(of: Result?.self) { group in
      for url in urls {
        group.addTask { [weak self] in
          guard let self else { return nil }
          if let games = await self.fetchAndDecode(url), !games.isEmpty {
            return Result(endpoint: url, games: games)
          }
          return nil
        }
      }
      for await result in group {
        if let result {
          group.cancelAll()
          return result
        }
      }
      return nil
    }
  }

  private func fetchAndDecode(_ url: URL, referer: String? = nil, origin: String? = nil) async -> [DiscoveredGame]? {
    var request = URLRequest(url: url, timeoutInterval: Self.perRequestTimeout)
    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
    if let origin  { request.setValue(origin,  forHTTPHeaderField: "Origin") }

    guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
    let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
    guard ct.contains("json") else { return nil }
    guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }

    for shape in Self.shapes {
      if let games = shape.parse(raw, url), !games.isEmpty {
        return games
      }
    }
    return nil
  }

  // MARK: - Shape registry
  //
  // Each shape takes raw decoded JSON (any) and the endpoint URL (used for
  // resolving relative page URLs) and returns games-or-nil. First non-nil
  // non-empty result wins. No shape checks the host.

  private static let shapes: [APIShape] = [
    .nestedCategories,
    .flatGames,
    .flatEvents,
    .flatMatches,
    .flatLiveUpcoming,
    .bareGameArray,
    .liveMatchesArray,
  ]
}

// MARK: - DiscoveredGame

/// Cross-shape uniform game representation. Whatever shape we match, parsers
/// produce this so the caller has one schema to map into the app's Game model.
struct DiscoveredGame: Sendable {
  let externalID: String
  let categoryLabel: String   // raw site label, e.g. "Baseball", "MLB"
  let homeName: String
  let awayName: String        // "" for solo events
  let startsAt: Date?
  let endsAt: Date?
  let isLive: Bool
  let pageURL: URL
}

// MARK: - APIShape

struct APIShape {
  let id: String
  let parse: (Any, URL) -> [DiscoveredGame]?
}

extension APIShape {
  // MARK: 1) Nested-categories shape
  //
  //   { "streams": [
  //       { "id": …, "category": "Baseball",
  //         "streams": [
  //           { "id": 21785,
  //             "name": "Philadelphia Phillies vs. Pittsburgh Pirates",
  //             "uri_name": "mlb/2026-05-15/phi-pit",
  //             "starts_at": 1778884800, "ends_at": 1778897400,
  //             "always_live": 0,
  //             "iframe": "..." } … ] } … ] }
  //
  // Matches a wide class of sports-streaming SPAs that group streams by sport.
  static let nestedCategories = APIShape(id: "nestedCategories") { raw, endpoint in
    guard let dict = raw as? [String: Any],
          let categories = dict["streams"] as? [[String: Any]] ?? dict["categories"] as? [[String: Any]] else {
      return nil
    }
    var games: [DiscoveredGame] = []
    let host = (endpoint.scheme ?? "https") + "://" + endpoint.host!.replacingOccurrences(of: "api.", with: "")

    for cat in categories {
      guard let label = cat["category"] as? String ?? cat["name"] as? String else { continue }
      guard let streams = cat["streams"] as? [[String: Any]] ?? cat["items"] as? [[String: Any]] else { continue }
      for s in streams {
        guard let g = makeGame(from: s, category: label, host: host) else { continue }
        games.append(g)
      }
    }
    return games
  }

  // MARK: 2) Flat games shape
  //
  //   { "games": [
  //       { "id": …, "home_team": "...", "away_team": "...",
  //         "league": "...", "start_time": "ISO-8601-or-epoch",
  //         "stream_url": "..." }, … ] }
  static let flatGames = APIShape(id: "flatGames") { raw, endpoint in
    guard let dict = raw as? [String: Any] else { return nil }
    guard let games = dict["games"] as? [[String: Any]] else { return nil }
    let host = (endpoint.scheme ?? "https") + "://" + endpoint.host!.replacingOccurrences(of: "api.", with: "")
    var out: [DiscoveredGame] = []
    for g in games {
      let cat = (g["league"] as? String)
        ?? (g["category"] as? String)
        ?? (g["competition"] as? String)
        ?? ""
      guard let game = makeGame(from: g, category: cat, host: host) else { continue }
      out.append(game)
    }
    return out
  }

  // MARK: 3) Flat events shape
  //
  //   { "events": [
  //       { "id": …, "home_team": …, "away_team": …, "competition": …,
  //         "date": "ISO", "iframe": "..." }, … ] }
  static let flatEvents = APIShape(id: "flatEvents") { raw, endpoint in
    guard let dict = raw as? [String: Any] else { return nil }
    guard let events = dict["events"] as? [[String: Any]] else { return nil }
    let host = (endpoint.scheme ?? "https") + "://" + endpoint.host!.replacingOccurrences(of: "api.", with: "")
    var out: [DiscoveredGame] = []
    for e in events {
      let cat = (e["competition"] as? String)
        ?? (e["league"] as? String)
        ?? (e["category"] as? String)
        ?? ""
      guard let game = makeGame(from: e, category: cat, host: host) else { continue }
      out.append(game)
    }
    return out
  }

  // MARK: 7) Live + upcoming matches arrays in a wrapper object
  // (sportyhunter.net style)
  //
  //   { "matches": [], "liveMatches": [{…}], "upcomingMatches": [{…}], … }
  //
  // Each match:
  //   { "_id": "...", "slug": "slg-Team-A-vs-Team-B-…",
  //     "sport": "Football", "sportSlug": "football",
  //     "league": "MLS", "leagueSlug": "mls",
  //     "team1": "San Jose Earthquakes", "team2": "FC Dallas",
  //     "startTimestamp": 1778985000000 }
  //
  // Key differences from flatLiveUpcoming: team1/team2 instead of
  // home_team/away_team, the `league` field carries the *specific* league
  // (e.g. "MLS"), and games come from the `liveMatches` array key (others
  // shapes only check `live`). Match page URLs follow `/match/{slug}`.
  static let liveMatchesArray = APIShape(id: "liveMatchesArray") { raw, endpoint in
    guard let dict = raw as? [String: Any] else { return nil }
    var taggedGames: [(raw: [String: Any], live: Bool)] = []
    if let live = dict["liveMatches"] as? [[String: Any]] {
      taggedGames.append(contentsOf: live.map { ($0, true) })
    }
    if let upcoming = dict["upcomingMatches"] as? [[String: Any]] {
      taggedGames.append(contentsOf: upcoming.map { ($0, false) })
    }
    if let matches = dict["matches"] as? [[String: Any]], taggedGames.isEmpty {
      taggedGames.append(contentsOf: matches.map { ($0, false) })
    }
    guard !taggedGames.isEmpty else { return nil }

    let host = (endpoint.scheme ?? "https") + "://" + endpoint.host!
      .replacingOccurrences(of: "api.", with: "")
    var out: [DiscoveredGame] = []
    for (g0, isLive) in taggedGames {
      var g = g0
      if let t1 = g["team1"] as? String { g["home_team"] = t1 }
      if let t2 = g["team2"] as? String { g["away_team"] = t2 }
      // Prefer the specific league name (e.g. "MLS") over the sport (e.g.
      // "Football"). When a site separates the two, the league field is
      // unambiguous; the sport field is too coarse for chip mapping.
      let category = (g["league"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        ?? (g["sport"] as? String)
        ?? (g["sportSlug"] as? String)
        ?? ""
      // Tag isLive explicitly — `makeGame` honors `is_live` over the time
      // window heuristic, so liveMatches stay live even when their start
      // time is hours past.
      g["is_live"] = isLive
      // Page URL: `/match/{slug}` is the canonical sportyhunter pattern.
      // Verified live: returns 200; `/watch/{slug}` returns 404.
      if g["url"] == nil, g["page_url"] == nil, g["pageURL"] == nil {
        if let slug = g["slug"] as? String, !slug.isEmpty {
          g["url"] = "\(host)/match/\(slug)"
        } else if let id = g["_id"] as? String, !id.isEmpty {
          g["url"] = "\(host)/match/\(id)"
        }
      }
      if let game = makeGame(from: g, category: category, host: host) {
        out.append(game)
      }
    }
    return out
  }

  // MARK: 6) Bare top-level game array (streamed.pk / streamed.su style)
  //
  //   [ { "id": ..., "title": ..., "category": ..., "date": ms,
  //       "teams": { "home": {...}, "away": {...} }, "sources": [...] }, ... ]
  //
  // Same per-entry schema as `flatLiveUpcoming` but the response is the raw
  // array — no `{success: true, all: [...]}` wrapper. Used by streamed.pk's
  // `/api/matches/all` and `/api/matches/live` endpoints.
  static let bareGameArray = APIShape(id: "bareGameArray") { raw, endpoint in
    guard let rawGames = raw as? [[String: Any]], !rawGames.isEmpty else {
      return nil
    }
    let host = (endpoint.scheme ?? "https") + "://" + endpoint.host!
      .replacingOccurrences(of: "api.", with: "")
    var out: [DiscoveredGame] = []
    for g in rawGames {
      var g = g
      // Unwrap nested teams.home.name / teams.away.name to standard keys so
      // `makeGame` doesn't have to fall back to splitting the title string.
      if let teams = g["teams"] as? [String: Any] {
        if let home = (teams["home"] as? [String: Any])?["name"] as? String {
          g["home_team"] = home
        }
        if let away = (teams["away"] as? [String: Any])?["name"] as? String {
          g["away_team"] = away
        }
      }
      // Build a watch URL using the first source name and the game id, same
      // pattern as the flat live/upcoming shape uses.
      if g["url"] == nil, g["page_url"] == nil, g["pageURL"] == nil,
         let id = g["id"] as? String {
        let server: String
        if let sources = g["sources"] as? [[String: Any]],
           let s = (sources.first?["source"] as? String), !s.isEmpty {
          server = s
        } else {
          server = "alpha"
        }
        g["url"] = "\(host)/watch/\(id)/\(server)/1"
      }
      if let isLive = g["live"] as? Bool { g["is_live"] = isLive }
      let cat = (g["category"] as? String)
        ?? (g["league"] as? String)
        ?? (g["competition"] as? String)
        ?? ""
      if let game = makeGame(from: g, category: cat, host: host) {
        out.append(game)
      }
    }
    return out
  }

  // MARK: 5) Flat live/upcoming/all shape (NTVSTREAM and similar)
  //
  //   { "success": true,
  //     "all":      [ {…game…} ],   ← OR
  //     "live":     [ {…game…} ],
  //     "upcoming": [ {…game…} ] }
  //
  // Each game:
  //   { "id": "wests-tigers-vs-manly-sea-eagles-2417238",
  //     "title": "Wests Tigers vs Manly Sea Eagles",
  //     "category": "rugby",
  //     "date": 1778907600000,                ← epoch ms
  //     "teams": { "home": { "name": "..." }, "away": { "name": "..." } },
  //     "sources": [ { "source": "echo", "id": "..." } ],
  //     "live": true }
  //
  // We dedupe across the three list keys (preferring `all` if present, else
  // the union of `live` and `upcoming`) and reuse the standard `makeGame`
  // helper. Page URLs are constructed as `/watch/{source}/{game.id}` —
  // the same pattern the site's own JS uses.
  static let flatLiveUpcoming = APIShape(id: "flatLiveUpcoming") { raw, endpoint in
    guard let dict = raw as? [String: Any] else { return nil }
    var rawGames: [[String: Any]] = []
    if let all = dict["all"] as? [[String: Any]] {
      rawGames = all
    } else {
      var seen = Set<String>()
      for key in ["live", "upcoming"] {
        guard let arr = dict[key] as? [[String: Any]] else { continue }
        for g in arr {
          let id = (g["id"] as? String) ?? (g["title"] as? String) ?? UUID().uuidString
          guard seen.insert(id).inserted else { continue }
          rawGames.append(g)
        }
      }
    }
    guard !rawGames.isEmpty else { return nil }

    let host = (endpoint.scheme ?? "https") + "://" + endpoint.host!
      .replacingOccurrences(of: "api.", with: "")
    var out: [DiscoveredGame] = []
    for g in rawGames {
      var g = g
      // Surface team names from the nested teams.{home,away}.name shape so
      // `makeGame` doesn't have to fall back to splitting the title string.
      if let teams = g["teams"] as? [String: Any] {
        if let home = (teams["home"] as? [String: Any])?["name"] as? String {
          g["home_team"] = home
        }
        if let away = (teams["away"] as? [String: Any])?["name"] as? String {
          g["away_team"] = away
        }
      }
      // Construct the watch URL the front-end uses: /watch/{firstSource}/{id}.
      // Defaults to the kobra server when no source is listed — every server
      // serves the same match catalog.
      if g["url"] == nil, g["page_url"] == nil, g["pageURL"] == nil,
         let id = g["id"] as? String {
        let server: String
        if let sources = g["sources"] as? [[String: Any]],
           let s = (sources.first?["source"] as? String), !s.isEmpty {
          server = s
        } else {
          server = "kobra"
        }
        g["url"] = "\(host)/watch/\(server)/\(id)"
      }
      // Surface live boolean.
      if let isLive = g["live"] as? Bool { g["is_live"] = isLive }

      let cat = (g["category"] as? String)
        ?? (g["league"] as? String)
        ?? (g["competition"] as? String)
        ?? ""
      if let game = makeGame(from: g, category: cat, host: host) {
        out.append(game)
      }
    }
    return out
  }

  // MARK: 4) Flat matches shape
  //
  //   { "matches": [
  //       { "id": …, "teams": ["home", "away"], "league": …,
  //         "datetime": "ISO", "url": "..." }, … ] }
  static let flatMatches = APIShape(id: "flatMatches") { raw, endpoint in
    guard let dict = raw as? [String: Any] else { return nil }
    guard let matches = dict["matches"] as? [[String: Any]] else { return nil }
    let host = (endpoint.scheme ?? "https") + "://" + endpoint.host!.replacingOccurrences(of: "api.", with: "")
    var out: [DiscoveredGame] = []
    for m in matches {
      let cat = (m["league"] as? String) ?? (m["competition"] as? String) ?? ""
      if var d = m as? [String: Any], let teams = m["teams"] as? [String], teams.count == 2 {
        d["home_team"] = teams[0]
        d["away_team"] = teams[1]
        if let game = makeGame(from: d, category: cat, host: host) {
          out.append(game)
        }
      } else if let game = makeGame(from: m, category: cat, host: host) {
        out.append(game)
      }
    }
    return out
  }

  // MARK: - Field-extraction helper
  //
  // Tries every reasonable key for each field. This is where shape-tolerant
  // parsing lives — different sites use different field names but the
  // semantic meaning is the same.

  private static func makeGame(from raw: [String: Any], category: String, host: String) -> DiscoveredGame? {
    let id = stringOrInt(raw["id"]) ?? UUID().uuidString

    // Name resolution. Prefer explicit home/away, fall back to a "home vs away" full name.
    var home = (raw["home_team"] as? String)
      ?? (raw["home"] as? String)
      ?? ""
    var away = (raw["away_team"] as? String)
      ?? (raw["away"] as? String)
      ?? ""
    var isEvent = false

    if home.isEmpty || away.isEmpty {
      if let name = raw["name"] as? String ?? raw["title"] as? String {
        let (h, a, evt) = splitName(name)
        if home.isEmpty { home = h }
        if away.isEmpty { away = a }
        isEvent = evt
      }
    }
    if home.isEmpty && away.isEmpty { return nil }

    // Times. Accept epoch ints or ISO strings.
    // Field-name aliases cover the variants we've seen across sources: ppv.to
    // uses `starts_at`, NTVSTREAM uses `date` (epoch ms), sportyhunter uses
    // `startTimestamp`. The extras (kickoff, commenceTime, event_time, etc.)
    // are belt-and-suspenders for shapes we haven't probed yet — cheap to
    // add and otherwise leaves bintv-class games stranded with no scheduled
    // time, which the UI renders as "Upcoming" even when the source knew.
    let startsAt = firstNonNilDate(in: raw, keys: [
      "starts_at", "start_time", "start", "date", "datetime",
      "startTimestamp", "startsAtMs",
      "kickoff", "kick_off", "commenceTime", "commence_time",
      "event_time", "match_time", "time", "scheduled"
    ])
    let endsAt = firstNonNilDate(in: raw, keys: [
      "ends_at", "end_time", "end", "endTimestamp"
    ])
    let alwaysLive = (raw["always_live"] as? Int ?? 0) == 1
    // Some APIs (NTVSTREAM-style) include an explicit live boolean. Honor
    // it over the time-window heuristic; otherwise fall through.
    let explicitLive = (raw["is_live"] as? Bool) ?? (raw["live"] as? Bool)

    let now = Date()
    let isLive: Bool
    if let l = explicitLive {
      isLive = l
    } else if alwaysLive {
      isLive = true
    } else if let starts = startsAt, let ends = endsAt {
      isLive = now >= starts && now < ends
    } else if let starts = startsAt {
      isLive = abs(now.timeIntervalSince(starts)) < 4 * 3600
    } else {
      isLive = false
    }

    // Page URL. Prefer an explicit URL field; otherwise compose from uri_name.
    let pageURL: URL = {
      for key in ["page_url", "url", "stream_url", "link"] {
        if let s = raw[key] as? String, let u = URL(string: s) { return u }
      }
      if let uri = raw["uri_name"] as? String,
         let u = URL(string: "\(host)/live/\(uri)") {
        return u
      }
      if let iframe = raw["iframe"] as? String, let u = URL(string: iframe) {
        return u
      }
      return URL(string: host)!
    }()

    return DiscoveredGame(
      externalID: id,
      categoryLabel: category,
      homeName: home.trimmingCharacters(in: .whitespacesAndNewlines),
      awayName: isEvent ? "" : away.trimmingCharacters(in: .whitespacesAndNewlines),
      startsAt: startsAt,
      endsAt: endsAt,
      isLive: isLive,
      pageURL: pageURL
    )
  }

  /// Split "Home vs. Away" → (home, away, isEvent=false).
  /// Returns (name, "", true) for solo entries (no separator found).
  private static func splitName(_ name: String) -> (String, String, Bool) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    for separator in [" vs. ", " vs ", " v. ", " v ", " @ "] {
      if let r = trimmed.range(of: separator, options: .caseInsensitive) {
        let home = String(trimmed[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        let away = String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        if !home.isEmpty, !away.isEmpty { return (home, away, false) }
      }
    }
    return (trimmed, "", true)
  }

  /// Walks the keys in order and returns the first whose value parses to a Date.
  /// Broken out of the chained `??` form to keep the Swift type checker fast —
  /// long chains of `??` over `Any?` values were tripping the inference budget.
  private static func firstNonNilDate(in raw: [String: Any], keys: [String]) -> Date? {
    for key in keys {
      if let value = raw[key], let date = anyDate(value) {
        return date
      }
    }
    return nil
  }

  /// Parse a value that might be an epoch int or ISO 8601 string into a Date.
  /// Detects epoch milliseconds vs seconds by magnitude: anything >= 10^12 is
  /// treated as milliseconds (year ~33658 in seconds — clearly bogus, so the
  /// number must be ms representing year ~2001+). Threshold chosen at 10^12 so
  /// pre-2001 epoch seconds still parse correctly.
  private static func anyDate(_ value: Any?) -> Date? {
    if let epoch = value as? Int    { return epochToDate(TimeInterval(epoch)) }
    if let epoch = value as? Double { return epochToDate(epoch) }
    if let s = value as? String, !s.isEmpty {
      let iso = ISO8601DateFormatter()
      if let d = iso.date(from: s) { return d }
      let isoFrac = ISO8601DateFormatter()
      isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let d = isoFrac.date(from: s) { return d }
      if let epoch = TimeInterval(s) { return epochToDate(epoch) }
    }
    return nil
  }

  private static func epochToDate(_ value: TimeInterval) -> Date {
    let seconds = value >= 1_000_000_000_000 ? value / 1000 : value
    return Date(timeIntervalSince1970: seconds)
  }

  private static func stringOrInt(_ value: Any?) -> String? {
    if let s = value as? String { return s }
    if let i = value as? Int { return String(i) }
    return nil
  }
}
