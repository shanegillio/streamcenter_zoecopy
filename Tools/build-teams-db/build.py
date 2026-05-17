#!/usr/bin/env python3
"""Builds teams.json from ESPN's public /teams endpoints + manually-curated
fragments for content ESPN doesn't cover (IPL, national cricket sides,
international soccer, AFL, NRL, etc.).

Usage:
    python3 Tools/build-teams-db/build.py > App/teams.json

Re-run any time roster turnover or a new league is needed. The output is a
single JSON file consumed by:
    1. App/teams.json (bundled baseline shipped with the IPA)
    2. raw.githubusercontent.com/shanegillio/altstore-source/main/teams.json
       (live overlay fetched by TeamDatabase at runtime)
"""

from __future__ import annotations
import json
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

SCRIPT_DIR = Path(__file__).resolve().parent


# League key (must match SportLeague raw value) → (ESPN sport, ESPN slug,
# displayName, popularityRank). Keys here become top-level dict keys in
# teams.json. ESPN provides full current rosters; we add aliases from the
# nickname / abbreviation / shortDisplayName fields.
ESPN_LEAGUES: list[tuple[str, str, str, str, int]] = [
    # key,           sport,         slug,                          displayName,         popularityRank
    ("nba",          "basketball",  "nba",                         "NBA",                2),
    ("wnba",         "basketball",  "wnba",                        "WNBA",              19),
    ("ncaab",        "basketball",  "mens-college-basketball",     "NCAA Men's Basketball", 13),
    ("nfl",          "football",    "nfl",                         "NFL",                1),
    ("ncaaf",        "football",    "college-football",            "NCAA Football",     11),
    ("mlb",          "baseball",    "mlb",                         "MLB",                4),
    ("nhl",          "hockey",      "nhl",                         "NHL",                5),
    ("mls",          "soccer",      "usa.1",                       "MLS",               20),
    ("premierLeague","soccer",      "eng.1",                       "Premier League",     8),
    ("laLiga",       "soccer",      "esp.1",                       "La Liga",            9),
    ("serieA",       "soccer",      "ita.1",                       "Serie A",           14),
    ("bundesliga",   "soccer",      "ger.1",                       "Bundesliga",        15),
    ("ligue1",       "soccer",      "fra.1",                       "Ligue 1",           16),
    ("eredivisie",   "soccer",      "ned.1",                       "Eredivisie",        24),
    ("ligaMx",       "soccer",      "mex.1",                       "Liga MX",           23),
    ("championsLeague","soccer",    "uefa.champions",              "Champions League",  10),
    ("europaLeague", "soccer",      "uefa.europa",                 "Europa League",     22),
]


def fetch_espn_teams(sport: str, slug: str) -> list[dict]:
    """Fetch ESPN /teams endpoint. Returns the list of `team` dicts."""
    url = (
        f"https://site.api.espn.com/apis/site/v2/sports/"
        f"{sport}/{slug}/teams"
    )
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 (StreamCenter teams-db generator)",
        },
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.load(resp)
    sports = data.get("sports", [])
    if not sports:
        return []
    leagues = sports[0].get("leagues", [])
    if not leagues:
        return []
    return [t.get("team", {}) for t in leagues[0].get("teams", [])]


def normalize_aliases(name: str, *raw: str | None) -> list[str]:
    """Dedupe + drop the canonical name + drop empties/duplicates."""
    seen: set[str] = set()
    out: list[str] = []
    canonical = name.strip()
    for a in raw:
        if not a:
            continue
        a = a.strip()
        if not a or a == canonical:
            continue
        key = a.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append(a)
    return out


def team_entry(espn_team: dict) -> dict | None:
    """Convert ESPN team JSON → our schema entry."""
    name = espn_team.get("displayName", "").strip()
    if not name:
        return None
    aliases = normalize_aliases(
        name,
        espn_team.get("name"),
        espn_team.get("shortDisplayName"),
        espn_team.get("abbreviation"),
        espn_team.get("nickname"),
    )
    entry: dict = {"name": name}
    if aliases:
        entry["aliases"] = aliases
    return entry


def load_manual_fragments() -> dict[str, dict]:
    """Load Tools/build-teams-db/manual/*.json. Each file is one league's
    entries, keyed by file name (e.g. cricket.json → "cricket" league key).
    """
    manual_dir = SCRIPT_DIR / "manual"
    out: dict[str, dict] = {}
    if not manual_dir.exists():
        return out
    for path in sorted(manual_dir.glob("*.json")):
        key = path.stem
        with path.open() as f:
            out[key] = json.load(f)
    return out


def build() -> dict:
    leagues: dict[str, dict] = {}

    # ESPN-sourced leagues
    for key, sport, slug, display_name, rank in ESPN_LEAGUES:
        print(f"fetching {key} ({sport}/{slug})…", file=sys.stderr)
        try:
            raw_teams = fetch_espn_teams(sport, slug)
        except Exception as e:
            print(f"  ! failed: {e}", file=sys.stderr)
            continue
        entries = [e for e in (team_entry(t) for t in raw_teams) if e]
        print(f"  → {len(entries)} teams", file=sys.stderr)
        leagues[key] = {
            "displayName": display_name,
            "espnSlug": f"{sport}/{slug}",
            "popularityRank": rank,
            "teams": entries,
        }

    # Manual fragments — overlay (manual wins for keys ESPN also covers,
    # otherwise it's new content like cricket / international).
    for key, payload in load_manual_fragments().items():
        if key in leagues:
            # Merge teams arrays, dedupe on canonical name (case-insensitive).
            existing_names = {
                t["name"].lower() for t in leagues[key]["teams"]
            }
            for t in payload.get("teams", []):
                if t["name"].lower() not in existing_names:
                    leagues[key]["teams"].append(t)
                    existing_names.add(t["name"].lower())
            # Allow manual to override displayName / popularityRank
            for f in ("displayName", "popularityRank", "espnSlug"):
                if f in payload:
                    leagues[key][f] = payload[f]
        else:
            leagues[key] = payload

    return {
        "schemaVersion": 1,
        "updatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "leagues": leagues,
    }


def main() -> int:
    db = build()
    total = sum(len(l["teams"]) for l in db["leagues"].values())
    print(
        f"\nbuilt {len(db['leagues'])} leagues, {total} total teams",
        file=sys.stderr,
    )
    json.dump(db, sys.stdout, indent=2, ensure_ascii=False)
    print("", file=sys.stdout)  # trailing newline
    return 0


if __name__ == "__main__":
    sys.exit(main())
