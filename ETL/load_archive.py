"""
load_archive.py
---------------
One-time (rerunnable) load of OLD price history from archived MTGJSON files
(saved from the Internet Archive's Wayback Machine). Not part of the daily batch.

Why: the daily history only starts in 2026, so the spike study and backtest
only see one market "season". Each archived AllPrices file holds ~90 days of
daily TCGplayer and Card Kingdom prices from its time, so a few of them add
separate, older seasons to test the rules against.

Input: every file in data\\raw\\archive\\ named AllPrices*  (.zip, .gz, .bz2, .xz or .json)
  e.g. AllPrices_2022-01-05.json.zip       prices Oct 2021 - Jan 2022
       AllPrices_2023-05-29.json.zip       prices Feb 2023 - May 2023
       AllPricesToday_2025-07-08.json.zip  one day (Jul 8, 2025)

Steps
  1. Map MTGJSON card IDs to Scryfall printings (cached map in dw.map_mtgjson_scryfall;
     MTGJSON v5 card IDs are stable, so today's map fits old files too).
  2. For each file, read TCGplayer retail prices (same source as the daily Scryfall
     price) and the Card Kingdom buylist, and compress each card's daily series into
     change-only rows, like the rest of the warehouse.
  3. Stage everything and run dw.usp_apply_archive_prices, which replaces all
     archive rows (source = 'mtgjson_archive') in one transaction.

Rules
  * Each file is its own "price window". Windows must not overlap, and must end
    before the current daily history starts (dates after that are dropped here).
  * Gaps between windows stay gaps: no prices are invented for the missing years.
  * A card's price row ends on the last day the file has a price for it.

Rerunning loads every file in the folder again from scratch, so adding a new
archive file later = drop it in the folder and rerun.

Usage (from the project root; takes ~5-15 minutes per large file):
  python ETL\\load_archive.py
"""

import bz2
import gzip
import lzma
import sys
import zipfile
from collections import Counter
from contextlib import contextmanager
from datetime import date, timedelta
from pathlib import Path

import ijson
import pyodbc

from backfill_mtgjson import compress, to_price
from load_buylist import ensure_id_map
from load_scryfall import connect

# The project folder (mtg-sell-signal), so paths work whichever folder a script is run from
PROJECT_ROOT = Path(__file__).resolve().parent.parent
ARCHIVE_DIR = PROJECT_ROOT / "data" / "raw" / "archive"
BATCH_SIZE = 20000
FINISH_MAP = {"normal": "nonfoil", "foil": "foil", "etched": "etched"}
# kind -> (vendor key, price list) inside MTGJSON's paper prices
PRICE_KINDS = {"market": ("tcgplayer", "retail"), "buylist": ("cardkingdom", "buylist")}


# ----------------------------------------------------------------------------- #
# Reading
# ----------------------------------------------------------------------------- #
@contextmanager
def open_archive(path: Path):
    """Open an MTGJSON file in any of the formats MTGJSON publishes, as a binary stream."""
    name = path.name.lower()
    if name.endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            members = [m for m in z.namelist() if m.lower().endswith(".json")]
            if len(members) != 1:
                raise ValueError(f"{path.name}: expected one .json inside, found {members}")
            with z.open(members[0]) as f:
                yield f
    elif name.endswith(".gz"):
        with gzip.open(path, "rb") as f:
            yield f
    elif name.endswith(".bz2"):
        with bz2.open(path, "rb") as f:
            yield f
    elif name.endswith(".xz"):
        with lzma.open(path, "rb") as f:
            yield f
    else:
        with open(path, "rb") as f:
            yield f


def series_for(entry, vendor: str, price_list: str) -> dict:
    paper = (entry or {}).get("paper") or {}
    return ((paper.get(vendor) or {}).get(price_list)) or {}


def parse_file(path: Path, id_map: dict, cutoff: date, stats: Counter):
    """Yield (kind, scryfall_id, finish, price, valid_from, valid_to) change-only rows.
    Fills stats with counts and the first/last price date seen."""
    seen = set()
    first, last = date.max, date.min
    with open_archive(path) as f:
        for n, (uuid, entry) in enumerate(ijson.kvitems(f, "data"), 1):
            if sys.stdout.isatty() and n % 5000 == 0:
                print(f"\r  read {n:,} cards", end="")
            if not (entry or {}).get("paper"):
                continue
            sid = id_map.get(uuid.lower())
            if not sid:
                stats["cards_unmatched"] += 1
                continue
            stats["cards_matched"] += 1

            for kind, (vendor, price_list) in PRICE_KINDS.items():
                for mj_finish, series in series_for(entry, vendor, price_list).items():
                    finish = FINISH_MAP.get(mj_finish)
                    if not finish or not series or (kind, sid, finish) in seen:
                        continue
                    points = []
                    for d, v in series.items():
                        day, price = date.fromisoformat(d), to_price(v)
                        if price is not None and day < cutoff:
                            points.append((day, price))
                    if not points:
                        continue
                    seen.add((kind, sid, finish))   # double-faced cards share one Scryfall ID
                    points.sort()
                    first, last = min(first, points[0][0]), max(last, points[-1][0])
                    for valid_from, valid_to, price in compress(points, points[-1][0]):
                        stats[f"{kind}_rows"] += 1
                        yield kind, sid, finish, price, valid_from, valid_to
    if sys.stdout.isatty():
        print("\r", end="")
    stats["first_date"], stats["last_date"] = first, last


# ----------------------------------------------------------------------------- #
# Main
# ----------------------------------------------------------------------------- #
def current_history_start(cur) -> date:
    """First day of the regular (non-archive) price history; archive rows must end before it."""
    d = cur.execute("SELECT MIN(valid_from) FROM dw.fact_price "
                    "WHERE source <> 'mtgjson_archive'").fetchone()[0]
    if d is None:
        sys.exit("No regular price history loaded yet. Run the daily load (and backfill) first.")
    return date.fromisoformat(d) if isinstance(d, str) else d


def main() -> None:
    files = sorted(p for p in ARCHIVE_DIR.glob("AllPrices*") if p.is_file()
                   and not p.name.endswith(".part"))
    if not files:
        sys.exit(f"No AllPrices* files found in {ARCHIVE_DIR}.")

    conn = connect()
    cur = conn.cursor()
    cutoff = current_history_start(cur)
    print(f"Regular history starts {cutoff}; archive prices before that date will be loaded.")
    id_map = ensure_id_map(conn)
    print(f"ID map: {len(id_map):,} MTGJSON cards")

    cur.fast_executemany = True
    cur.execute("TRUNCATE TABLE stg.archive_price;")
    cur.execute("TRUNCATE TABLE stg.archive_window;")
    conn.commit()

    row_sql = ("INSERT INTO stg.archive_price (file_name, kind, scryfall_id, finish, price_usd, "
               "valid_from, valid_to) VALUES (?, ?, ?, ?, ?, ?, ?)")
    sizes = [None, None, None, None, (pyodbc.SQL_DECIMAL, 12, 2), None, None]

    for path in files:
        print(f"\n{path.name}")
        stats, batch = Counter(), []
        for row in parse_file(path, id_map, cutoff, stats):
            batch.append((path.name, *row))
            if len(batch) >= BATCH_SIZE:
                cur.setinputsizes(sizes)
                cur.executemany(row_sql, batch)
                conn.commit()
                batch.clear()
        if batch:
            cur.setinputsizes(sizes)
            cur.executemany(row_sql, batch)
            conn.commit()

        if not stats["market_rows"]:
            print("  no usable prices (or all on/after the cutoff); skipped")
            continue
        matched, unmatched = stats["cards_matched"], stats["cards_unmatched"]
        match_rate = matched / max(matched + unmatched, 1)
        print(f"  prices          {stats['first_date']} to {stats['last_date']}")
        print(f"  cards matched   {matched:,} of {matched + unmatched:,} ({match_rate:.1%})")
        print(f"  market rows     {stats['market_rows']:,}")
        print(f"  buylist rows    {stats['buylist_rows']:,}")
        conn.cursor().execute("INSERT INTO stg.archive_window (file_name, first_date, last_date, "
                    "cards_matched, cards_unmatched) VALUES (?, ?, ?, ?, ?)",
                    path.name, stats["first_date"], stats["last_date"], matched, unmatched)
        conn.commit()

    print("\nApplying (replaces all earlier archive rows)...")
    conn.autocommit = True
    out = conn.cursor()
    out.execute("EXEC dw.usp_apply_archive_prices")
    cols = [c[0] for c in out.description]
    print(f"  {'window':<24} {'from':<11} {'to':<11} {'days':>5} {'market rows':>12} {'buylist rows':>13}")
    for r in out.fetchall():
        r = dict(zip(cols, r))
        print(f"  {r['window_name']:<24} {str(r['first_date']):<11} {str(r['last_date']):<11} "
              f"{r['days']:>5} {r['market_rows']:>12,} {r['buylist_rows']:>13,}")
    conn.close()
    print("\nDone. Next: python ETL\\refresh_analytics.py --study")


if __name__ == "__main__":
    main()
