"""
load_boosters.py
----------------
Loads MTGJSON's booster layouts (what can appear in each pack type of each set)
for the "Which pack should I open?" views in sql/13_packs.sql.

Booster layouts only change when a new set comes out, so this refreshes at most
every REFRESH_DAYS days; the daily batch calls it and it usually exits at once.

Steps
  1. Download AllPrintings.json.gz from MTGJSON (~100+ MB) if the copy in
     data\\raw\\mtgjson is missing or older than REFRESH_DAYS.
  2. Stream it set by set and keep only the "booster" section: pack
     configurations, how many cards each takes from each sheet, and the cards
     (with weights) on each sheet.
  3. Stage and run dw.usp_apply_boosters (replaces all booster data).

Usage (from the project root):
  python ETL\\load_boosters.py            refresh if due
  python ETL\\load_boosters.py --force    refresh now (e.g. a new set just released)
"""

import argparse
import gzip
import sys
from datetime import date, datetime, timedelta
from pathlib import Path

import ijson
import requests

from load_scryfall import connect
from profile_scryfall import HEADERS

MTGJSON_URL = "https://mtgjson.com/api/v5/AllPrintings.json.gz"
RAW_FILE = Path("data/raw/mtgjson/AllPrintings.json.gz")
REFRESH_DAYS = 14
BATCH_SIZE = 20000
SKIP_TYPES = ("arena", "mtgo")          # digital-only pack types
FRIENDLY = {"play": "Play Booster", "collector": "Collector Booster", "draft": "Draft Booster",
            "set": "Set Booster", "jumpstart": "Jumpstart Booster",
            "collector-sample": "Collector Booster Sample", "default": "Booster"}


def needs_refresh(cur, force: bool) -> bool:
    if force:
        return True
    last = cur.execute("SELECT MAX(loaded_at) FROM dw.booster_set").fetchone()[0]
    return last is None or datetime.now() - last > timedelta(days=REFRESH_DAYS)


def download() -> Path:
    RAW_FILE.parent.mkdir(parents=True, exist_ok=True)
    if RAW_FILE.exists() and date.fromtimestamp(RAW_FILE.stat().st_mtime) > date.today() - timedelta(days=REFRESH_DAYS):
        print(f"Using {RAW_FILE} (downloaded {date.fromtimestamp(RAW_FILE.stat().st_mtime)})")
        return RAW_FILE
    print("Downloading AllPrintings.json.gz from MTGJSON...")
    tmp = Path(str(RAW_FILE) + ".part")
    done = 0
    with requests.get(MTGJSON_URL, headers=HEADERS, stream=True, timeout=600) as r:
        r.raise_for_status()
        with open(tmp, "wb") as f:
            for chunk in r.iter_content(chunk_size=1 << 20):
                f.write(chunk)
                done += len(chunk)
                if sys.stdout.isatty():
                    print(f"\r  {done / 1e6:,.0f} MB", end="")
    tmp.replace(RAW_FILE)
    print(f"\r  saved {RAW_FILE} ({done / 1e6:,.0f} MB)")
    return RAW_FILE


def parse(path: Path):
    """Yield (table, row) tuples for every set that has booster data."""
    with gzip.open(path, "rb") as f:
        for code, s in ijson.kvitems(f, "data"):
            boosters = (s or {}).get("booster") or {}
            if not boosters:
                continue
            code = str(code).upper()[:10]
            release = s.get("releaseDate")
            yield "set", (code, (s.get("name") or code)[:200],
                          date.fromisoformat(release) if release else None)
            # this set's own cards: MTGJSON uuid -> Scryfall ID
            own = {c["uuid"]: (c.get("identifiers") or {}).get("scryfallId")
                   for c in (s.get("cards") or []) if c.get("uuid")}

            for btype, b in boosters.items():
                if any(x in btype for x in SKIP_TYPES) or not isinstance(b, dict):
                    continue
                btype = btype[:150]
                name = (b.get("name") or FRIENDLY.get(btype) or btype.replace("-", " ").title())[:200]
                configs = b.get("boosters") or []
                total = int(b.get("boostersTotalWeight") or sum(int(c.get("weight") or 0) for c in configs))
                if not configs or total <= 0:
                    continue
                for n, cfg in enumerate(configs, 1):
                    weight = int(cfg.get("weight") or 0)
                    if weight <= 0:
                        continue
                    yield "config", (code, btype, name, n, weight, total)
                    for sheet, picks in (cfg.get("contents") or {}).items():
                        if int(picks) > 0:
                            yield "config_sheet", (code, btype, n, sheet[:150], int(picks))
                for sheet, sh in (b.get("sheets") or {}).items():
                    cards = sh.get("cards") or {}
                    total_w = int(sh.get("totalWeight") or sum(int(w) for w in cards.values()))
                    if total_w <= 0:
                        continue
                    yield "sheet", (code, btype, sheet[:150], total_w, bool(sh.get("foil")))
                    for uuid, w in cards.items():
                        yield "sheet_card", (code, btype, sheet[:150], uuid, own.get(uuid), int(w))


INSERTS = {
    "set":          "INSERT INTO stg.booster_set (set_code, set_name, release_date) VALUES (?, ?, ?)",
    "config":       "INSERT INTO stg.booster_config (set_code, booster_type, booster_name, config_no, "
                    "config_weight, total_config_weight) VALUES (?, ?, ?, ?, ?, ?)",
    "config_sheet": "INSERT INTO stg.booster_config_sheet (set_code, booster_type, config_no, sheet_name, "
                    "picks) VALUES (?, ?, ?, ?, ?)",
    "sheet":        "INSERT INTO stg.booster_sheet (set_code, booster_type, sheet_name, total_weight, "
                    "is_foil) VALUES (?, ?, ?, ?, ?)",
    "sheet_card":   "INSERT INTO stg.booster_sheet_card (set_code, booster_type, sheet_name, mtgjson_uuid, "
                    "scryfall_id, card_weight) VALUES (?, ?, ?, ?, ?, ?)",
}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true", help="refresh even if loaded recently")
    args = ap.parse_args()

    conn = connect()
    cur = conn.cursor()
    if not needs_refresh(cur, args.force):
        print(f"Booster data is less than {REFRESH_DAYS} days old; skipped.")
        conn.close()
        return

    path = download()
    cur.fast_executemany = True
    for t in ("booster_set", "booster_config", "booster_config_sheet", "booster_sheet", "booster_sheet_card"):
        cur.execute(f"TRUNCATE TABLE stg.{t};")
    conn.commit()

    print("Reading booster layouts (a few minutes)...")
    batches = {k: [] for k in INSERTS}
    counts = {k: 0 for k in INSERTS}

    def flush(kind):
        if batches[kind]:
            cur.executemany(INSERTS[kind], batches[kind])
            conn.commit()
            counts[kind] += len(batches[kind])
            batches[kind].clear()

    for kind, row in parse(path):
        batches[kind].append(row)
        if len(batches[kind]) >= BATCH_SIZE:
            flush(kind)
    for kind in INSERTS:
        flush(kind)
    print(f"  {counts['set']:,} sets with boosters, {counts['config']:,} pack layouts, "
          f"{counts['sheet_card']:,} sheet cards")

    conn.autocommit = True
    r = conn.cursor().execute("EXEC dw.usp_apply_boosters").fetchone()
    print("Booster data loaded:")
    print(f"  sets            {r.sets:,}")
    print(f"  pack_types      {r.pack_types:,}")
    print(f"  sheet_cards     {r.sheet_cards:,}")
    print(f"  unmapped_cards  {r.unmapped_cards:,}  (printings not in your card table, e.g. non-English)")
    conn.close()


if __name__ == "__main__":
    main()
