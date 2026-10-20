"""
import_manabox.py
-----------------
Loads ManaBox exports from the synced Google Drive folder into SQL Server.

Expected files in the folder (set in ETL\\config.ini, [imports] folder):
  * Collection export: any .csv with "collection" in its name.
    If there are several, the most recently modified one is used.
  * Deck list exports: .txt files named "Deck: <name>" or "Edit: <name>".
    Google Drive / Windows turn ":" into "_", so "Deck_ <name>.txt" works too.
      Deck: = a list marked as fully built from the collection
      Edit: = a target list (partly owned or not owned)
    Other .txt files are ignored.

Deck file format (ManaBox text export):
    // COMMANDER
    1 Athreos, God of Passage (JOU) 146
    1 Sol Ring (C21) 263 *F*        <- optional foil (*F*) / etched (*E*) marker
    1 Sol Ring                      <- set and number are optional

Usage (from the project root):
  python ETL\\import_manabox.py
"""

import configparser
import csv
import re
import sys
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path

import pyodbc

from load_scryfall import CONFIG_PATH, connect

DECK_FILE_RE = re.compile(r"^(deck|edit)\s*[:_]\s*(.+)$", re.IGNORECASE)
DECK_LINE_RE = re.compile(
    r"^(\d+)x?\s+(.+?)"                         # quantity, card name
    r"(?:\s+\(([A-Za-z0-9]{2,8})\)\s+(\S+))?"   # optional (SET) collector_number
    r"(?:\s+\*([A-Za-z])\*)?\s*$"               # optional *F* / *E* finish marker
)
FINISH_MARKERS = {"F": "foil", "E": "etched"}


# ----------------------------------------------------------------------------- #
# Helpers
# ----------------------------------------------------------------------------- #
def import_folder() -> Path:
    cfg = configparser.ConfigParser()
    cfg.read(CONFIG_PATH)
    folder = Path(cfg.get("imports", "folder", fallback="").strip())
    if not str(folder) or not folder.is_dir():
        sys.exit(f"Import folder not found: '{folder}'. Set [imports] folder in {CONFIG_PATH}.")
    return folder


def modified(path: Path) -> datetime:
    return datetime.fromtimestamp(path.stat().st_mtime).replace(microsecond=0)


def to_bool(v) -> bool:
    return str(v).strip().lower() in ("true", "1", "yes")


def to_int(v):
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return None


def to_price(v):
    try:
        return Decimal(str(v).strip()).quantize(Decimal("0.01")) if str(v).strip() else None
    except InvalidOperation:
        return None


def to_datetime(v):
    v = (v or "").strip()
    if not v:
        return None
    try:
        return datetime.fromisoformat(v.replace("Z", "+00:00")).replace(tzinfo=None, microsecond=0)
    except ValueError:
        return None


def to_uuid(v):
    v = (v or "").strip()
    return v if re.fullmatch(r"[0-9a-fA-F-]{36}", v) else None


def clip(v, n):
    v = (v or "").strip()
    return v[:n] if v else None


# ----------------------------------------------------------------------------- #
# Parse
# ----------------------------------------------------------------------------- #
def read_collection(path: Path) -> list[tuple]:
    with open(path, encoding="utf-8-sig", newline="") as f:
        sample = f.read(4096)
        f.seek(0)
        dialect = csv.Sniffer().sniff(sample, delimiters=",\t;")
        reader = csv.DictReader(f, dialect=dialect)
        missing = {"Name", "Quantity", "Scryfall ID"} - set(reader.fieldnames or [])
        if missing:
            sys.exit(f"{path.name} is missing expected columns: {missing}")

        file_mod = modified(path)
        rows = []
        for r in reader:
            qty = to_int(r.get("Quantity"))
            name = clip(r.get("Name"), 300)
            if not name or not qty:
                continue
            rows.append((
                clip(r.get("Binder Name"), 200), clip(r.get("Binder Type"), 50), name,
                clip(r.get("Set code"), 10), clip(r.get("Set name"), 200),
                clip(r.get("Collector number"), 20), clip(r.get("Foil"), 10),
                clip(r.get("Rarity"), 20), qty, to_int(r.get("ManaBox ID")),
                to_uuid(r.get("Scryfall ID")), to_price(r.get("Purchase price")),
                to_bool(r.get("Misprint")), to_bool(r.get("Altered")), to_bool(r.get("Signed")),
                clip(r.get("Condition"), 30), clip(r.get("Language"), 10),
                to_bool(r.get("Proxy")), clip(r.get("Purchase price currency"), 5),
                to_datetime(r.get("Added")), path.name, file_mod,
            ))
    return rows


def read_deck(path: Path, list_type: str, deck_name: str) -> tuple[list[tuple], list[str]]:
    rows, skipped = [], []
    section, section_has_cards = "MAIN", False
    file_mod = modified(path)
    with open(path, encoding="utf-8-sig") as f:
        for line_no, raw in enumerate(f, start=1):
            line = raw.strip()
            if not line:
                # ManaBox ends a headed block (e.g. the commander) with a blank line;
                # the cards after it are the main deck.
                if section_has_cards:
                    section, section_has_cards = "MAIN", False
                continue
            if line.startswith("//"):                      # "// COMMANDER"
                section, section_has_cards = line.lstrip("/ ").upper()[:50] or "MAIN", False
                continue
            if line.endswith(":") and not line[0].isdigit():  # "Sideboard:" style headers
                section, section_has_cards = line.rstrip(":").upper()[:50], False
                continue
            section_has_cards = True
            m = DECK_LINE_RE.match(line)
            if not m:
                skipped.append(f"line {line_no}: {line}")
                continue
            qty, name, set_code, number, marker = m.groups()
            rows.append((
                path.name, list_type, deck_name[:200], section, line_no, int(qty),
                name.strip()[:300], set_code, number,
                FINISH_MARKERS.get((marker or "").upper(), "nonfoil"), file_mod,
            ))
    return rows, skipped


def find_files(folder: Path):
    collections = sorted((p for p in folder.glob("*.csv") if "collection" in p.name.lower()),
                         key=lambda p: p.stat().st_mtime, reverse=True)
    if not collections:
        sys.exit(f"No collection CSV (name containing 'collection') found in {folder}")

    decks = []
    for p in sorted(folder.glob("*.txt")):
        m = DECK_FILE_RE.match(p.stem.strip())
        if m:
            decks.append((p, m.group(1).capitalize(), m.group(2).strip()))
    return collections[0], decks


# ----------------------------------------------------------------------------- #
# Load
# ----------------------------------------------------------------------------- #
def stage(conn, table: str, columns: list[str], rows: list[tuple], decimal_cols=()):
    cur = conn.cursor()
    cur.fast_executemany = True
    cur.execute(f"TRUNCATE TABLE {table};")
    if rows:
        cur.setinputsizes([(pyodbc.SQL_DECIMAL, 12, 2) if c in decimal_cols else None
                           for c in columns])
        cur.executemany(
            f"INSERT INTO {table} ({', '.join(columns)}) VALUES ({', '.join('?' * len(columns))})",
            rows)
    conn.commit()


COLLECTION_COLUMNS = [
    "binder_name", "binder_type", "card_name", "set_code", "set_name", "collector_number",
    "finish", "rarity", "quantity", "manabox_id", "scryfall_id", "purchase_price",
    "is_misprint", "is_altered", "is_signed", "card_condition", "card_language", "is_proxy",
    "purchase_currency", "added_at", "source_file", "file_modified",
]
DECK_COLUMNS = [
    "source_file", "list_type", "deck_name", "section", "line_no", "quantity", "card_name",
    "set_code", "collector_number", "finish", "file_modified",
]


def main() -> None:
    folder = import_folder()
    collection_file, deck_files = find_files(folder)

    collection_rows = read_collection(collection_file)
    print(f"Collection: {collection_file.name} -> {len(collection_rows):,} rows, "
          f"{sum(r[8] for r in collection_rows):,} cards")

    deck_rows = []
    for path, list_type, deck_name in deck_files:
        rows, skipped = read_deck(path, list_type, deck_name)
        deck_rows += rows
        print(f"{list_type}: {deck_name} -> {sum(r[5] for r in rows)} cards")
        for s in skipped:
            print(f"    skipped unreadable {s}")
    if not deck_files:
        print("No Deck:/Edit: list files found.")

    conn = connect()
    try:
        stage(conn, "stg.manabox_collection", COLLECTION_COLUMNS, collection_rows,
              decimal_cols={"purchase_price"})
        stage(conn, "stg.manabox_deck_line", DECK_COLUMNS, deck_rows)

        conn.autocommit = True
        cur = conn.cursor()
        cur.execute("EXEC dw.usp_load_manabox @import_date = ?", date.today())
        row = cur.fetchone()
        log = dict(zip([c[0] for c in cur.description], row))
        print("\nImport complete:")
        for key in ("collection_rows", "collection_cards", "collection_unmatched",
                    "deck_lists", "deck_lines", "deck_lines_unmatched", "status"):
            print(f"  {key:<22} {log.get(key)}")

        issues = cur.execute("SELECT TOP 25 * FROM dw.vw_import_issues").fetchall()
        if issues:
            print("\nUnmatched (see dw.vw_import_issues for all):")
            for i in issues:
                print(f"  [{i.source}] {i.list_name or ''} | {i.card_name} "
                      f"({i.set_code or '-'} {i.collector_number or ''})")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
