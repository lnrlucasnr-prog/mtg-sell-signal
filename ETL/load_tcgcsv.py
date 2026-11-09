"""
load_tcgcsv.py
--------------
One-time (rerunnable) load of DAILY TCGplayer market prices from the TCGCSV
price archive (https://tcgcsv.com), which starts on 2024-02-08. This fills the
gap between the archived 2021/2023 seasons and the regular daily history, so
the analysis can look 6-12+ months ahead instead of 30 days.

Steps
  1. Map TCGplayer product IDs to Scryfall printings, using the newest raw
     Scryfall file in data\\raw (Scryfall lists each printing's tcgplayer_id).
  2. Download each day's archive (prices-YYYY-MM-DD.ppmd.7z, 2-4 MB) to
     data\\raw\\tcgcsv\\. Files never change, so each is downloaded ONCE and
     kept; reruns reuse them. Downloads are paced and use a named User-Agent,
     per TCGCSV's usage guidelines.
  3. Read Magic's prices (category 1) day by day and turn them into change-only
     rows (a new row only when a price changes), like the rest of the warehouse.
  4. Stage them and run dw.usp_apply_tcgcsv_prices, which replaces all rows
     with source = 'tcgcsv' and validates against the regular history.

Only days BEFORE the regular history starts are loaded (no overlap). The first
regular day is staged separately to compare the two sources
(dw.vw_tcgcsv_source_check).

Usage (from the project root):
  pip install py7zr
  python ETL\\load_tcgcsv.py                 all days from 2024-02-08
  python ETL\\load_tcgcsv.py --every 7       one day per week (smaller, for a trial run)
  python ETL\\load_tcgcsv.py --download-only fetch the files, load nothing

First run: about 2-3 GB of downloads (several hours: it rests to stay under
TCGCSV's rate limit; safe to stop and rerun, finished files are kept), then
30-60 minutes of processing. Later reruns skip the downloads.
"""

import argparse
import json
import sys
import tempfile
import time
from datetime import date, timedelta
from decimal import Decimal, InvalidOperation
from pathlib import Path

import py7zr
import pyodbc
import requests

from load_scryfall import connect
from profile_scryfall import RAW_DIR as SCRYFALL_RAW_DIR, iter_cards

ARCHIVE_URL = "https://tcgcsv.com/archive/tcgplayer/prices-{d}.ppmd.7z"
# The project folder (mtg-sell-signal), so paths work whichever folder a script is run from
PROJECT_ROOT = Path(__file__).resolve().parent.parent
TCGCSV_DIR = PROJECT_ROOT / "data" / "raw" / "tcgcsv"
FIRST_DAY = date(2024, 2, 8)          # TCGCSV's archive starts here
MAGIC_CATEGORY = "1"
PAUSE_SECONDS = 6.0                   # between downloads (guidelines ask for >= 0.1 s; files are a few MB)
REST_EVERY = 40                       # TCGCSV throttled after ~68 files in a few minutes, so
REST_SECONDS = 10 * 60                # rest 10 minutes every 40 files, well under that
THROTTLE_WAIT = 11 * 60               # if throttled anyway (HTTP 429), wait out the 10-minute block
MAX_THROTTLE_WAITS = 6
MAX_CONNECTION_RETRIES = 5
HEADERS = {"User-Agent": "MTGSellSignal/1.0 (one-time history load)"}
BATCH_SIZE = 20000


# ----------------------------------------------------------------------------- #
# TCGplayer product -> Scryfall printing
# ----------------------------------------------------------------------------- #
def build_product_map() -> dict:
    """(productId, subTypeName) -> (scryfall_id, finish), from the newest Scryfall file."""
    files = sorted(f for f in SCRYFALL_RAW_DIR.glob("scryfall_default_cards_*")
                   if not f.name.endswith(".part"))
    if not files:
        sys.exit("No raw Scryfall file in data\\raw. Run ETL\\load_scryfall.py first.")
    print(f"Mapping TCGplayer IDs using {files[-1].name}...")
    pmap = {}
    for card in iter_cards(files[-1]):
        sid = card["id"]
        if card.get("tcgplayer_id"):
            pid = int(card["tcgplayer_id"])
            pmap.setdefault((pid, "Normal"), (sid, "nonfoil"))
            pmap.setdefault((pid, "Foil"), (sid, "foil"))
        if card.get("tcgplayer_etched_id"):
            # Etched foils are their own TCGplayer product
            pid = int(card["tcgplayer_etched_id"])
            pmap.setdefault((pid, "Foil"), (sid, "etched"))
            pmap.setdefault((pid, "Normal"), (sid, "etched"))
    print(f"  {len(pmap) // 2:,} TCGplayer products mapped")
    return pmap


# ----------------------------------------------------------------------------- #
# Download (once per file, ever)
# ----------------------------------------------------------------------------- #
def archive_path(d: date) -> Path:
    return TCGCSV_DIR / f"prices-{d:%Y-%m-%d}.ppmd.7z"


def missing_marker(d: date) -> Path:
    return TCGCSV_DIR / f"prices-{d:%Y-%m-%d}.missing"


def fetch(url: str):
    """GET with a fresh connection each time (a long wait can leave a pooled
    connection closed by the server), retrying dropped connections."""
    for attempt in range(1, MAX_CONNECTION_RETRIES + 1):
        try:
            return requests.get(url, headers=HEADERS, timeout=120)
        except (requests.ConnectionError, requests.Timeout):
            if attempt == MAX_CONNECTION_RETRIES:
                raise
            print(f"\n  connection dropped; retrying in 2 minutes (attempt {attempt + 1})...")
            time.sleep(120)


def download_days(days: list[date]) -> None:
    TCGCSV_DIR.mkdir(parents=True, exist_ok=True)
    todo = [d for d in days if not archive_path(d).exists() and not missing_marker(d).exists()]
    if not todo:
        print("All archive files already downloaded.")
        return
    est_minutes = len(todo) * PAUSE_SECONDS / 60 + (len(todo) // REST_EVERY) * REST_SECONDS / 60
    print(f"Downloading {len(todo):,} daily archives (about {len(todo) * 3 / 1000:,.1f} GB, "
          f"roughly {est_minutes / 60:.1f} hours with rests). Safe to stop and rerun any time.")
    waits = 0
    for i, d in enumerate(todo, 1):
        url = ARCHIVE_URL.format(d=f"{d:%Y-%m-%d}")
        r = fetch(url)
        while r.status_code == 429:           # throttled: wait it out, then retry this file
            waits += 1
            if waits > MAX_THROTTLE_WAITS:
                sys.exit("TCGCSV keeps throttling; stopping. Files so far are saved; rerun later.")
            delay = THROTTLE_WAIT
            retry_after = r.headers.get("Retry-After", "")
            if retry_after.isdigit():
                delay = max(int(retry_after) + 30, 60)
            print(f"\n  TCGCSV asked us to slow down; waiting {delay // 60} minutes "
                  f"({i - 1:,} of {len(todo):,} done, all saved)...")
            time.sleep(delay)
            r = fetch(url)
        if r.status_code == 404:
            missing_marker(d).touch()          # TCGCSV has no file for this day; don't ask again
        else:
            r.raise_for_status()
            tmp = archive_path(d).with_suffix(".part")
            tmp.write_bytes(r.content)
            tmp.replace(archive_path(d))
        print(f"\r  {i:,} / {len(todo):,}  ({d})", end="", flush=True)
        if i == len(todo):
            break
        time.sleep(PAUSE_SECONDS)
        if i % REST_EVERY == 0:
            print(f"\n  resting 10 minutes to stay under TCGCSV's rate limit "
                  f"({i:,} of {len(todo):,} done)...", flush=True)
            time.sleep(REST_SECONDS)
    print(f"\r  downloaded {len(todo):,} files" + " " * 20)


# ----------------------------------------------------------------------------- #
# Reading one day
# ----------------------------------------------------------------------------- #
def to_price(v):
    try:
        p = Decimal(str(v)).quantize(Decimal("0.01"))
        return p if p > 0 else None
    except (InvalidOperation, TypeError):
        return None


def read_day(path: Path):
    """Yield price result dicts for Magic from one daily archive."""
    with py7zr.SevenZipFile(path, "r") as z:
        targets = [n for n in z.getnames()
                   if n.replace("\\", "/").split("/")[1:2] == [MAGIC_CATEGORY]
                   and n.endswith("prices")]
        if not targets:
            return
        with tempfile.TemporaryDirectory() as tmp:
            z.extract(path=tmp, targets=targets)
            for name in targets:
                f = Path(tmp) / name
                if not f.is_file():
                    continue
                try:
                    payload = json.loads(f.read_text(encoding="utf-8"))
                except (ValueError, UnicodeDecodeError):
                    continue
                yield from payload.get("results") or []


def day_prices(path: Path, pmap: dict) -> dict:
    """(scryfall_id, finish) -> market price for one day."""
    out = {}
    for r in read_day(path):
        key = pmap.get((r.get("productId"), r.get("subTypeName")))
        price = to_price(r.get("marketPrice"))
        if key and price is not None:
            out.setdefault(key, price)    # a few printings share a product; first wins
    return out


# ----------------------------------------------------------------------------- #
# Change-only compression across days (streamed: one day in memory at a time)
# ----------------------------------------------------------------------------- #
class ChangeTracker:
    """Keeps the open run per printing+finish and emits closed runs.
    A missing day doesn't end a run (same as the MTGJSON loaders); a run ends
    when the price changes, or at the last day it was seen."""

    def __init__(self):
        self.open = {}    # key -> [valid_from, price, last_seen]

    def add_day(self, d: date, prices: dict):
        for key, price in prices.items():
            run = self.open.get(key)
            if run is None:
                self.open[key] = [d, price, d]
            elif run[1] != price:
                yield (*key, run[1], run[0], d - timedelta(days=1))
                self.open[key] = [d, price, d]
            else:
                run[2] = d

    def close_all(self):
        for key, (start, price, last_seen) in self.open.items():
            yield (*key, price, start, last_seen)
        self.open.clear()


# ----------------------------------------------------------------------------- #
# Main
# ----------------------------------------------------------------------------- #
def regular_history_start(cur) -> date:
    d = cur.execute("SELECT MIN(valid_from) FROM dw.fact_price "
                    "WHERE source NOT IN ('mtgjson_archive', 'tcgcsv')").fetchone()[0]
    if d is None:
        sys.exit("No regular price history yet. Run the daily load first.")
    return date.fromisoformat(d) if isinstance(d, str) else d


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--every", type=int, default=1, help="load every Nth day (default 1 = daily)")
    ap.add_argument("--download-only", action="store_true")
    args = ap.parse_args()

    conn = connect()
    cur = conn.cursor()
    cutoff = regular_history_start(cur)
    days = [FIRST_DAY + timedelta(days=i)
            for i in range(0, (cutoff - FIRST_DAY).days, args.every)]
    print(f"Regular history starts {cutoff}. TCGCSV days to load: {len(days):,} "
          f"({days[0]} to {days[-1]}).")

    download_days(days + [cutoff])     # cutoff day is only used for the source check
    if args.download_only:
        return

    pmap = build_product_map()
    cur.fast_executemany = True
    cur.execute("TRUNCATE TABLE stg.tcgcsv_price;")
    cur.execute("TRUNCATE TABLE stg.tcgcsv_overlap;")
    conn.commit()
    row_sql = ("INSERT INTO stg.tcgcsv_price (scryfall_id, finish, price_usd, valid_from, valid_to) "
               "VALUES (?, ?, ?, ?, ?)")
    sizes = [None, None, (pyodbc.SQL_DECIMAL, 12, 2), None, None]
    batch, staged, loaded_days, empty_days = [], 0, 0, 0

    def flush():
        nonlocal staged
        if batch:
            cur.setinputsizes(sizes)
            cur.executemany(row_sql, batch)
            conn.commit()
            staged += len(batch)
            batch.clear()

    tracker = ChangeTracker()
    print("Reading daily prices (30-60 minutes)...")
    for i, d in enumerate(days, 1):
        if not archive_path(d).exists():
            continue
        prices = day_prices(archive_path(d), pmap)
        if not prices:
            empty_days += 1
            continue
        loaded_days += 1
        for row in tracker.add_day(d, prices):
            batch.append(row)
            if len(batch) >= BATCH_SIZE:
                flush()
        if sys.stdout.isatty() and i % 10 == 0:
            print(f"\r  {d}  ({i:,}/{len(days):,} days, {staged + len(batch):,} rows)", end="")
    for row in tracker.close_all():
        batch.append(row)
        if len(batch) >= BATCH_SIZE:
            flush()
    flush()
    print(f"\r  read {loaded_days:,} days ({empty_days} without Magic prices), "
          f"staged {staged:,} change-only rows" + " " * 10)

    # Source check: TCGCSV prices on the first regular day
    if archive_path(cutoff).exists():
        overlap = [(sid, fin, cutoff, p) for (sid, fin), p in day_prices(archive_path(cutoff), pmap).items()]
        cur.setinputsizes([None, None, None, (pyodbc.SQL_DECIMAL, 12, 2)])
        for j in range(0, len(overlap), BATCH_SIZE):
            cur.executemany("INSERT INTO stg.tcgcsv_overlap (scryfall_id, finish, price_date, price_usd) "
                            "VALUES (?, ?, ?, ?)", overlap[j:j + BATCH_SIZE])
        conn.commit()

    print("Applying (replaces all earlier TCGCSV rows)...")
    conn.autocommit = True
    r = conn.cursor().execute("EXEC dw.usp_apply_tcgcsv_prices").fetchone()
    print(f"  first_date            {r.first_date}")
    print(f"  last_date             {r.last_date}")
    print(f"  price_rows            {r.price_rows:,}")
    print(f"  printings             {r.printings:,}")
    print(f"  archive_rows_replaced {r.archive_rows_replaced:,}")
    conn.close()
    print("\nDone. Check: SELECT * FROM dw.vw_tcgcsv_source_check;")
    print("Then: python ETL\\refresh_analytics.py --study")


if __name__ == "__main__":
    main()
