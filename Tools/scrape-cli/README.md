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

## When to use

- Investigating why a source doesn't surface games in the app
- Verifying a scraping-JS change before building the .ipa
- Reproducing what the in-app `DiagnosticsView` would show, without doing a
  build → install → screenshot loop
