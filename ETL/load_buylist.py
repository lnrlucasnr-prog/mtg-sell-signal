"""
load_buylist.py
---------------
Card Kingdom buylist prices (what CK pays for a card) from MTGJSON.

  python ETL\\load_buylist.py              daily load (AllPricesToday, small file)
  python ETL\\load_buylist.py --backfill   one-time 90-day history (AllPrices, big file)

Run the backfill once at setup, before the daily load starts. The daily load
then runs every day from run_daily_load.bat.

The MTGJSON -> Scryfall ID mapping is stored in dw.map_mtgjson_scryfall and
refreshed when it is more than MAP_MAX_AGE_DAYS old.
"""

import argparse
import gzip
import sys
from datetime import date, datetime, timedelta

import ijson
import pyodbc

from backfill_mtgjson import build_id_map, compress, download, to_price
from load_scryfall import connect

FINISH_MAP = {"normal": "nonfoil", "foil": "foil", "etched": "etched"}
MAP_MAX_AGE_DAYS = 7
BATCH_SIZE = 20000


# ----------------------------------------------------------------------------- #
# MTGJSON -> Scryfall ID map (cached in SQL)
# ----------------------------------------------------------------------------- #
def ensure_id_map(conn) -> dict:
    cur = conn.cursor()
    count, refreshed = cur.execute(
        "SELECT COUNT(*), MAX(refreshed_at) FROM dw.map_mtgjson_scryfall").fetchone()
    stale = (count == 0 or refreshed is None
             or datetime.now() - refreshed > timedelta(days=MAP_MAX_AGE_DAYS))

    if stale:
        print("Refreshing MTGJSON -> Scryfall ID map...")
        known = {str(r[0]).lower() for r in cur.execute("SELECT scryfall_id FROM dw.dim_card")}
        id_map = build_id_map(download("AllIdentifiers.json.gz"), known)
        cur.fast_executemany = True
        cur.execute("TRUNCATE TABLE dw.map_mtgjson_scryfall;")
        rows = list(id_map.items())
        for i in range(0, len(rows), BATCH_SIZE):
            cur.executemany("INSERT INTO dw.map_mtgjson_scryfall (mtgjson_uuid, scryfall_id) "
                            "VALUES (?, ?)", rows[i:i + BATCH_SIZE])
        conn.commit()
        return id_map

    return {str(u).lower(): str(s).lower() for u, s in
            cur.execute("SELECT mtgjson_uuid, scryfall_id FROM dw.map_mtgjson_scryfall")}


def ck_buylist(entry) -> dict:
    return ((((entry or {}).get("paper") or {}).get("cardkingdom") or {}).get("buylist")) or {}


# ----------------------------------------------------------------------------- #
# Daily
# ----------------------------------------------------------------------------- #
def parse_today(path, id_map: dict):
    """Return (snapshot_date, rows) with one price per printing + finish."""
    rows, seen = [], set()
    with gzip.open(path, "rb") as f:
        for uuid, entry in ijson.kvitems(f, "data"):
            sid = id_map.get(uuid.lower())
            if not sid:
                continue
            for mj_finish, series in ck_buylist(entry).items():
                finish = FINISH_MAP.get(mj_finish)
                if not finish or not series or (sid, finish) in seen:
                    continue
                latest_day = max(series)
                price = to_price(series[latest_day])
                if price is not None:
                    seen.add((sid, finish))   # double-faced cards share one Scryfall ID
                    rows.append((sid, finish, date.fromisoformat(latest_day), price))
    if not rows:
        sys.exit("No Card Kingdom buylist prices found in today's file; nothing loaded.")
    snapshot = max(r[2] for r in rows)
    return snapshot, [r for r in rows if r[2] == snapshot]


def run_daily(conn, id_map):
    snapshot, rows = parse_today(download("AllPricesToday.json.gz"), id_map)
    print(f"Card Kingdom buylist for {snapshot}: {len(rows):,} prices")

    cur = conn.cursor()
    cur.fast_executemany = True
    cur.execute("TRUNCATE TABLE stg.buylist_price;")
    cur.setinputsizes([None, None, None, (pyodbc.SQL_DECIMAL, 12, 2)])
    cur.executemany("INSERT INTO stg.buylist_price (scryfall_id, finish, price_date, price_usd) "
                    "VALUES (?, ?, ?, ?)", rows)
    conn.commit()

    conn.autocommit = True
    log = conn.cursor().execute("EXEC dw.usp_load_buylist_snapshot @snapshot_date = ?",
                                snapshot).fetchone()
    print("Buylist load complete:")
    print(f"  prices_new      {log.prices_new}")
    print(f"  prices_changed  {log.prices_changed}")
    print(f"  dropped_off     {log.dropped_off}")


# ----------------------------------------------------------------------------- #
# Backfill
# ----------------------------------------------------------------------------- #
def parse_history(path, id_map: dict) -> list[tuple]:
    """Change-only runs per printing + finish. The last run stays open (valid_to
    NULL) only if the card is still on the buylist on the file's final day."""
    print("Reading 90 days of Card Kingdom buylist prices (a few minutes)...")
    runs, last_runs, seen = [], [], set()
    file_last_day = date.min
    with gzip.open(path, "rb") as f:
        for uuid, entry in ijson.kvitems(f, "data"):
            sid = id_map.get(uuid.lower())
            if not sid:
                continue
            for mj_finish, series in ck_buylist(entry).items():
                finish = FINISH_MAP.get(mj_finish)
                if not finish or not series or (sid, finish) in seen:
                    continue
                points = sorted((date.fromisoformat(d), p) for d, p in
                                ((d, to_price(v)) for d, v in series.items()) if p is not None)
                if not points:
                    continue
                seen.add((sid, finish))
                file_last_day = max(file_last_day, points[-1][0])
                series_runs = compress(points, points[-1][0])
                for valid_from, valid_to, price in series_runs[:-1]:
                    runs.append((sid, finish, price, valid_from, valid_to))
                last_runs.append((sid, finish, *series_runs[-1]))

    for sid, finish, valid_from, valid_to, price in last_runs:
        still_listed = valid_to == file_last_day
        runs.append((sid, finish, price, valid_from, None if still_listed else valid_to))
    print(f"  {len(seen):,} price series through {file_last_day}, {len(runs):,} change-only rows")
    return runs


def run_backfill(conn, id_map, force: bool):
    rows = parse_history(download("AllPrices.json.gz"), id_map)
    cur = conn.cursor()
    cur.fast_executemany = True
    cur.execute("TRUNCATE TABLE stg.buylist_backfill;")
    cur.setinputsizes([None, None, (pyodbc.SQL_DECIMAL, 12, 2), None, None])
    for i in range(0, len(rows), BATCH_SIZE):
        cur.executemany("INSERT INTO stg.buylist_backfill "
                        "(scryfall_id, finish, price_usd, valid_from, valid_to) "
                        "VALUES (?, ?, ?, ?, ?)", rows[i:i + BATCH_SIZE])
    conn.commit()

    conn.autocommit = True
    r = conn.cursor().execute("EXEC dw.usp_apply_buylist_backfill @force = ?",
                              1 if force else 0).fetchone()
    print("Buylist backfill complete:")
    print(f"  history_rows          {r.history_rows:,}")
    print(f"  currently_on_buylist  {r.currently_on_buylist:,}")
    print(f"  earliest_date         {r.earliest_date}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backfill", action="store_true", help="load ~90 days of history")
    parser.add_argument("--force", action="store_true", help="allow backfill over daily rows")
    args = parser.parse_args()

    conn = connect()
    try:
        id_map = ensure_id_map(conn)
        if args.backfill:
            run_backfill(conn, id_map, args.force)
        else:
            run_daily(conn, id_map)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
