"""
load_scryfall.py
----------------
Daily ETL: Scryfall bulk card data -> SQL Server (database: mtg).

Steps
  1. Download today's Scryfall default_cards file (skips if already downloaded).
  2. Filter to cards that matter for paper collecting:
       paper game, not digital-only, English, and not tokens / emblems / art cards.
  3. Truncate and reload stg.scryfall_card.
  4. Run dw.usp_load_snapshot, which updates dim_set and dim_card and writes
     change-only price history to dw.fact_price.
  5. Delete raw files older than RAW_RETENTION_DAYS (SQL is the system of record).

Usage (from the project root, mtg-sell-signal):
  pip install requests pyodbc
  python ETL\\load_scryfall.py

Connection settings come from ETL\\config.ini (not committed to GitHub).
See ETL\\config.example.ini.
"""

import configparser
import re
import sys
from datetime import date, datetime, timedelta
from decimal import Decimal, InvalidOperation
from pathlib import Path

import pyodbc

# Reuse the download + file-reading logic from the profiling script.
from profile_scryfall import RAW_DIR, download, iter_cards

CONFIG_PATH = Path(__file__).with_name("config.ini")
BULK_TYPE = "default_cards"
BATCH_SIZE = 5000
RAW_RETENTION_DAYS = 30

# Layouts that are not real, sellable game cards.
EXCLUDED_LAYOUTS = {"token", "double_faced_token", "emblem", "art_series"}

# Column order must match the INSERT statement below.
# Max lengths mirror stg.scryfall_card so an unexpectedly long value is trimmed
# (and counted) instead of failing the whole load.
STAGE_COLUMNS = [
    ("scryfall_id", None), ("oracle_id", None), ("card_name", 300), ("set_code", 10),
    ("set_name", 200), ("set_type", 50), ("released_at", None), ("collector_number", 20),
    ("rarity", 20), ("layout", 40), ("type_line", 300), ("mana_cost", 150), ("cmc", None),
    ("color_identity", 20), ("finishes", 60), ("is_promo", None), ("is_reprint", None),
    ("edhrec_rank", None), ("legal_commander", 20), ("price_usd", None),
    ("price_usd_foil", None), ("price_usd_etched", None), ("snapshot_date", None),
    ("image_url", 400),
]
MAX_LEN = {name: n for name, n in STAGE_COLUMNS if n}

# Exact SQL types for decimal columns. fast_executemany otherwise guesses decimal
# size from the first row of each batch, and an unusual value later in the batch
# (e.g. Gleemax's mana value of 1,000,000) fails the insert.
DECIMAL_TYPES = {
    "cmc": (10, 1),
    "price_usd": (12, 2), "price_usd_foil": (12, 2), "price_usd_etched": (12, 2),
}
truncated_fields: dict[str, int] = {}


# ----------------------------------------------------------------------------- #
# Connection
# ----------------------------------------------------------------------------- #
def pick_driver(preferred: str) -> str:
    if preferred:
        return preferred
    installed = pyodbc.drivers()
    for name in ("ODBC Driver 18 for SQL Server", "ODBC Driver 17 for SQL Server",
                 "SQL Server Native Client 11.0", "SQL Server"):
        if name in installed:
            return name
    sys.exit("No SQL Server ODBC driver found. Install 'ODBC Driver 18 for SQL Server' "
             "from Microsoft, then run this again.\nInstalled drivers: " + str(installed))


def connect() -> pyodbc.Connection:
    if not CONFIG_PATH.exists():
        sys.exit(f"Missing {CONFIG_PATH}. Copy config.example.ini to config.ini and fill it in.")
    cfg = configparser.ConfigParser()
    cfg.read(CONFIG_PATH)
    db = cfg["sqlserver"]
    driver = pick_driver(db.get("driver", "").strip())

    parts = [f"DRIVER={{{driver}}}", f"SERVER={db['server']}", f"DATABASE={db['database']}"]
    if db.getboolean("trusted_connection", fallback=True):
        parts.append("Trusted_Connection=yes")
    else:
        parts += [f"UID={db['username']}", f"PWD={db['password']}"]
    # Driver 18 encrypts by default; a local server uses a self-signed certificate.
    parts.append("TrustServerCertificate=yes")

    print(f"Connecting to {db['server']}/{db['database']} using '{driver}'...")
    return pyodbc.connect(";".join(parts))


# ----------------------------------------------------------------------------- #
# Transform
# ----------------------------------------------------------------------------- #
def keep(card: dict) -> bool:
    return (
        "paper" in (card.get("games") or [])
        and not card.get("digital", False)
        and card.get("lang") == "en"
        and card.get("layout") not in EXCLUDED_LAYOUTS
    )


def to_decimal(v, places: str):
    """Convert to Decimal with a fixed number of decimal places (e.g. '0.01')."""
    if v in (None, ""):
        return None
    try:
        return Decimal(str(v)).quantize(Decimal(places))
    except InvalidOperation:
        return None


def to_date(v):
    try:
        return datetime.strptime(v, "%Y-%m-%d").date() if v else None
    except ValueError:
        return None


def face_value(card: dict, field: str):
    """Multi-face cards keep mana_cost/type_line on each face, not the top level."""
    v = card.get(field)
    if v is None and card.get("card_faces"):
        v = " // ".join(str(f.get(field) or "") for f in card["card_faces"])
    return v


def image_url(card: dict):
    """Scryfall 'normal' image; double-faced cards keep images on each face (use the front)."""
    uris = card.get("image_uris") or ((card.get("card_faces") or [{}])[0].get("image_uris")) or {}
    return uris.get("normal")


def fit(name: str, v):
    limit = MAX_LEN.get(name)
    if limit and isinstance(v, str) and len(v) > limit:
        truncated_fields[name] = truncated_fields.get(name, 0) + 1
        return v[:limit]
    return v


def to_row(card: dict, snapshot_date: date) -> tuple:
    prices = card.get("prices") or {}
    values = {
        "scryfall_id": card["id"],
        "oracle_id": card.get("oracle_id"),
        "card_name": card.get("name"),
        "set_code": card.get("set"),
        "set_name": card.get("set_name"),
        "set_type": card.get("set_type"),
        "released_at": to_date(card.get("released_at")),
        "collector_number": card.get("collector_number"),
        "rarity": card.get("rarity"),
        "layout": card.get("layout"),
        "type_line": face_value(card, "type_line"),
        "mana_cost": face_value(card, "mana_cost"),
        "cmc": to_decimal(card.get("cmc"), "0.1"),
        "color_identity": "|".join(card.get("color_identity") or []),
        "finishes": "|".join(card.get("finishes") or []),
        "is_promo": bool(card.get("promo", False)),
        "is_reprint": bool(card.get("reprint", False)),
        "edhrec_rank": card.get("edhrec_rank"),
        "legal_commander": (card.get("legalities") or {}).get("commander"),
        "price_usd": to_decimal(prices.get("usd"), "0.01"),
        "price_usd_foil": to_decimal(prices.get("usd_foil"), "0.01"),
        "price_usd_etched": to_decimal(prices.get("usd_etched"), "0.01"),
        "snapshot_date": snapshot_date,
        "image_url": image_url(card),
    }
    return tuple(fit(name, values[name]) for name, _ in STAGE_COLUMNS)


def snapshot_date_from(path: Path) -> date:
    m = re.search(r"(\d{4}-\d{2}-\d{2})", path.name)
    return datetime.strptime(m.group(1), "%Y-%m-%d").date() if m else date.today()


# ----------------------------------------------------------------------------- #
# Load
# ----------------------------------------------------------------------------- #
def load_staging(conn: pyodbc.Connection, raw_file: Path, snapshot_date: date) -> int:
    cur = conn.cursor()
    cur.fast_executemany = True
    cur.execute("TRUNCATE TABLE stg.scryfall_card;")

    cols = ", ".join(name for name, _ in STAGE_COLUMNS)
    marks = ", ".join("?" for _ in STAGE_COLUMNS)
    sql = f"INSERT INTO stg.scryfall_card ({cols}) VALUES ({marks})"
    cur.setinputsizes([
        (pyodbc.SQL_DECIMAL, *DECIMAL_TYPES[name]) if name in DECIMAL_TYPES else None
        for name, _ in STAGE_COLUMNS
    ])

    batch, staged, skipped, seen = [], 0, 0, set()
    for card in iter_cards(raw_file):
        if not keep(card) or card["id"] in seen:
            skipped += 1
            continue
        seen.add(card["id"])
        batch.append(to_row(card, snapshot_date))
        if len(batch) >= BATCH_SIZE:
            cur.executemany(sql, batch)
            staged += len(batch)
            batch.clear()
            if sys.stdout.isatty():   # live counter only in a terminal, not in log files
                print(f"\r  staged {staged:,} cards", end="")
    if batch:
        cur.executemany(sql, batch)
        staged += len(batch)
    conn.commit()
    print(f"\r  staged {staged:,} cards ({skipped:,} filtered out)")
    if truncated_fields:
        print(f"  note: trimmed over-length values: {truncated_fields}")
    return staged


def run_snapshot_proc(conn: pyodbc.Connection, snapshot_date: date) -> None:
    conn.autocommit = True   # the procedure manages its own transaction
    cur = conn.cursor()
    cur.execute("EXEC dw.usp_load_snapshot @snapshot_date = ?", snapshot_date)
    row = cur.fetchone()
    if row:
        cols = [c[0] for c in cur.description]
        log = dict(zip(cols, row))
        print("\nLoad complete:")
        for key in ("snapshot_date", "rows_staged", "sets_inserted", "cards_inserted",
                    "cards_updated", "prices_new", "prices_changed", "status"):
            print(f"  {key:<15} {log.get(key)}")


def clean_old_raw_files() -> None:
    cutoff = date.today() - timedelta(days=RAW_RETENTION_DAYS)
    for f in RAW_DIR.glob(f"scryfall_{BULK_TYPE}_*"):
        if snapshot_date_from(f) < cutoff:
            f.unlink()
            print(f"  removed old raw file {f.name}")


def main() -> None:
    raw_file = download(BULK_TYPE)
    snapshot_date = snapshot_date_from(raw_file)
    print(f"Snapshot date: {snapshot_date}")

    conn = connect()
    try:
        load_staging(conn, raw_file, snapshot_date)
        run_snapshot_proc(conn, snapshot_date)
    finally:
        conn.close()
    clean_old_raw_files()


if __name__ == "__main__":
    main()
