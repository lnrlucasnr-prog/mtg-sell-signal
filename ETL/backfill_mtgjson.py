"""
backfill_mtgjson.py
-------------------
One-time (rerunnable) backfill of ~90 days of price history from MTGJSON,
so trend analysis works before the daily Scryfall snapshots have built up.

Steps
  1. Download AllIdentifiers.json.gz (MTGJSON uuid -> Scryfall ID) and
     AllPrices.json.gz (90 days of prices) to data/raw/mtgjson/.
  2. Map MTGJSON cards to the printings already in dw.dim_card.
  3. For each printing + finish, take TCGplayer retail prices (the same
     marketplace behind Scryfall's usd price) and compress the daily series
     into change-only rows: one row per stretch of unchanged price.
  4. Stage the rows and run dw.usp_apply_price_backfill.

Only dates before the first Scryfall snapshot are loaded. MTGJSON prices on
that first snapshot day are staged separately to compare the two sources
(see dw.vw_backfill_source_check).

Usage (from the project root):
  python ETL\\backfill_mtgjson.py
"""

import gzip
import sys
from datetime import date, timedelta
from decimal import Decimal, InvalidOperation
from pathlib import Path

import ijson
import pyodbc
import requests

from load_scryfall import connect
from profile_scryfall import HEADERS

MTGJSON_BASE = "https://mtgjson.com/api/v5/"
RAW_DIR = Path("data/raw/mtgjson")
BATCH_SIZE = 20000
FINISH_MAP = {"normal": "nonfoil", "foil": "foil", "etched": "etched"}


def download(name: str) -> Path:
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    target = RAW_DIR / name
    if target.exists() and date.fromtimestamp(target.stat().st_mtime) == date.today():
        print(f"Already downloaded today: {target}")
        return target
    print(f"Downloading {name}...")
    with requests.get(MTGJSON_BASE + name, headers=HEADERS, stream=True, timeout=600) as r:
        r.raise_for_status()
        tmp = Path(str(target) + ".part")
        done = 0
        with open(tmp, "wb") as f:
            for chunk in r.iter_content(chunk_size=1 << 20):
                f.write(chunk)
                done += len(chunk)
                if sys.stdout.isatty():
                    print(f"\r  {done / 1e6:,.0f} MB", end="")
        tmp.replace(target)
    print(f"\r  saved {target} ({done / 1e6:,.0f} MB)")
    return target


def to_price(v):
    try:
        p = Decimal(str(v)).quantize(Decimal("0.01"))
        return p if p > 0 else None
    except (InvalidOperation, TypeError):
        return None


def load_known_cards(conn) -> tuple[set, date]:
    cur = conn.cursor()
    known = {str(r[0]).lower() for r in cur.execute("SELECT scryfall_id FROM dw.dim_card")}
    cutoff = cur.execute(
        "SELECT MIN(valid_from) FROM dw.fact_price WHERE source = 'scryfall'").fetchone()[0]
    if cutoff is None:
        sys.exit("No Scryfall prices loaded yet. Run ETL\\load_scryfall.py first.")
    if isinstance(cutoff, str):
        cutoff = date.fromisoformat(cutoff)
    return known, cutoff


def build_id_map(path: Path, known: set) -> dict:
    """MTGJSON uuid -> Scryfall ID, only for printings in dim_card."""
    print("Mapping MTGJSON IDs to Scryfall IDs (a few minutes)...")
    id_map = {}
    with gzip.open(path, "rb") as f:
        for prefix, event, value in ijson.parse(f):
            if event == "string" and prefix.endswith(".identifiers.scryfallId"):
                sid = value.lower()
                if sid in known:
                    id_map[prefix.split(".")[1]] = sid
    print(f"  {len(id_map):,} MTGJSON cards matched to your card table")
    return id_map


def compress(points: list[tuple[date, Decimal]], end: date) -> list[tuple]:
    """Daily (date, price) points -> change-only (valid_from, valid_to, price) runs.
    A price holds until the next observed change; the last run ends at `end`."""
    runs = []
    start, price = points[0]
    for d, p in points[1:]:
        if p != price:
            runs.append((start, d - timedelta(days=1), price))
            start, price = d, p
    runs.append((start, end, price))
    return runs


def parse_prices(path: Path, id_map: dict, cutoff: date):
    """Yield ('history', row) and ('overlap', row) tuples."""
    print("Reading 90 days of prices (a few minutes)...")
    last_history_day = cutoff - timedelta(days=1)
    seen = set()
    with gzip.open(path, "rb") as f:
        for uuid, entry in ijson.kvitems(f, "data"):
            sid = id_map.get(uuid)
            if not sid:
                continue
            retail = (((entry or {}).get("paper") or {}).get("tcgplayer") or {}).get("retail") or {}
            for mj_finish, series in retail.items():
                finish = FINISH_MAP.get(mj_finish)
                if not finish or (sid, finish) in seen or not series:
                    continue
                seen.add((sid, finish))   # double-faced cards share one Scryfall ID

                points = []
                for d, p in series.items():
                    price = to_price(p)
                    if price is not None:
                        points.append((date.fromisoformat(d), price))
                points.sort()

                history = [pt for pt in points if pt[0] < cutoff]
                if history:
                    for valid_from, valid_to, price in compress(history, last_history_day):
                        yield "history", (sid, finish, price, valid_from, valid_to)
                for d, p in points:
                    if d == cutoff:
                        yield "overlap", (sid, finish, d, p)


def main() -> None:
    conn = connect()
    known, cutoff = load_known_cards(conn)
    print(f"First Scryfall snapshot: {cutoff}. Backfilling dates before it.")

    ids_file = download("AllIdentifiers.json.gz")
    prices_file = download("AllPrices.json.gz")
    id_map = build_id_map(ids_file, known)

    cur = conn.cursor()
    cur.fast_executemany = True
    cur.execute("TRUNCATE TABLE stg.price_backfill;")
    cur.execute("TRUNCATE TABLE stg.price_overlap;")
    conn.commit()

    hist_sql = ("INSERT INTO stg.price_backfill (scryfall_id, finish, price_usd, valid_from, valid_to) "
                "VALUES (?, ?, ?, ?, ?)")
    over_sql = ("INSERT INTO stg.price_overlap (scryfall_id, finish, price_date, price_usd) "
                "VALUES (?, ?, ?, ?)")
    batches = {"history": [], "overlap": []}
    counts = {"history": 0, "overlap": 0}

    def flush(kind):
        rows = batches[kind]
        if not rows:
            return
        if kind == "history":
            cur.setinputsizes([None, None, (pyodbc.SQL_DECIMAL, 12, 2), None, None])
            cur.executemany(hist_sql, rows)
        else:
            cur.setinputsizes([None, None, None, (pyodbc.SQL_DECIMAL, 12, 2)])
            cur.executemany(over_sql, rows)
        conn.commit()
        counts[kind] += len(rows)
        rows.clear()
        if sys.stdout.isatty():
            print(f"\r  staged {counts['history']:,} history rows", end="")

    for kind, row in parse_prices(prices_file, id_map, cutoff):
        batches[kind].append(row)
        if len(batches[kind]) >= BATCH_SIZE:
            flush(kind)
    flush("history")
    flush("overlap")
    print(f"\r  staged {counts['history']:,} history rows, "
          f"{counts['overlap']:,} overlap prices for the source check")

    conn.autocommit = True
    result = conn.cursor().execute("EXEC dw.usp_apply_price_backfill").fetchone()
    print("\nBackfill complete:")
    print(f"  cutoff_date     {result.cutoff_date}")
    print(f"  earliest_date   {result.earliest_date}")
    print(f"  price_series    {result.price_series:,}")
    print(f"  backfill_rows   {result.backfill_rows:,}")
    conn.close()


if __name__ == "__main__":
    main()
