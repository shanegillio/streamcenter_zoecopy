# scrape-cli

Headless macOS WebKit scraper for fast diagnostic iteration. Runs the **same
extraction JS** as the iOS app's `App/WebViewScraper.swift`, so what you see
here closely matches what the app sees on device.

## Sync rule

The JS literal in `Sources/scrape-cli/MacScraper.swift` (between the
`BEGIN EXTRACTION-JS` and `END EXTRACTION-JS` markers) **must stay byte-for-byte
identical** to the JS literal in `App/WebViewScraper.swift`. Always update both
in the same commit.

## Usage

```bash
swift run --package-path Tools/scrape-cli scrape-cli https://ppv.to
swift run --package-path Tools/scrape-cli scrape-cli --timeout 45 --click-delay 4 https://ppv.to/#36
```

Output is JSON to stdout — schema mirrors `ScrapeDiagnostic` + `ScrapedLink`.

### Modes

- (default) scrape + extraction JS, prints links.
- `--api-only` — JSON API discovery probe only (mirrors `App/APIDiscovery.swift`).
- `--full-flow` — API discovery → logo resolution + parallel fetch timings.
- `--llm <URL>` — scrape, then run the **on-device Foundation Model** over the
  links using the same two-phase pipeline as `App/FoundationModelScraper.swift`.
  This is the feedback loop for iterating on the LLM scraper: it reports the
  extracted games, chunk count, and per-phase timings. Requires Apple
  Intelligence enabled (macOS 26+, Apple silicon).
- `--measure` — diagnostic that probes the ~4096-token on-device window and
  whether `includeSchemaInPrompt: false` reduces overhead.

### Sync rule for the LLM path

`Sources/scrape-cli/LLMScrapeCLI.swift` deliberately duplicates the prompts,
`@Generable` schema, chunking (`matchChunkSize`), grounding instructions, and
`teamGrounded` post-validation from `App/FoundationModelScraper.swift`. When a
change here is confirmed to improve extraction, port it back to the app file in
the same commit. Key lessons baked in: send links in **small chunks** (the
window is shared by input+output), **never cap `maximumResponseTokens`** (it
truncates the JSON and loses the chunk), use **`temperature: 0`** (the model
otherwise loops/varies wildly), and **validate every result against its source
link** to kill hallucinated matchups and loop-duplicates.

## When to use

- Investigating why a source doesn't surface games in the app
- Verifying a scraping-JS change before building the .ipa
- Reproducing what the in-app `DiagnosticsView` would show, without doing a
  build → install → screenshot loop
