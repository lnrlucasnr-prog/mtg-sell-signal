"""
profile_scryfall.py
-------------------
Step 1 of the MTG sell-signal pipeline: download Scryfall's bulk card file and
profile it BEFORE designing the SQL Server schema.

What it does
  1. Asks Scryfall's /bulk-data endpoint for today's download link.
  2. Downloads the file (gzipped JSON Lines) to data/raw/ (skips if today's file exists).
     This raw file is also your first daily price snapshot - keep it.
  3. Streams through every card one line at a time (low memory) and writes:
       data/profile/field_profile.csv   - every field: % populated, data types, max length
       data/profile/value_counts.csv    - distributions of key categorical fields
       data/profile/price_coverage.csv  - how often each price type is populated
       data/profile/sample_cards.csv    - 1,000 flattened rows to eyeball in Excel
       data/profile/sample_cards.json   - a few full raw card objects (normal + multi-face)

Usage
  pip install requests
  python profile_scryfall.py                      # default_cards (recommended)
  python profile_scryfall.py --type oracle_cards  # one row per unique card instead
"""

import argparse
import csv
import gzip
import json
from collections import Counter, defaultdict
from datetime import date
from decimal import Decimal
from pathlib import Path

import requests

# Scryfall asks every client to send a descriptive User-Agent and an Accept header.
HEADERS = {
    "User-Agent": "MTGSellSignal/0.1 (personal portfolio project)",
    "Accept": "application/json",
}
BULK_INDEX_URL = "https://api.scryfall.com/bulk-data"

RAW_DIR = Path("data/raw")
PROFILE_DIR = Path("data/profile")

# Categorical fields worth seeing the full distribution of.
CATEGORICAL_FIELDS = [
    "object", "layout", "lang", "set_type", "rarity", "border_color", "frame",
    "games", "finishes", "promo", "digital", "reprint", "oversized", "booster",
]

# Columns for the flattened sample CSV - the ones most likely to end up in dim_card / fact_price.
SAMPLE_COLUMNS = [
    "id", "oracle_id", "name", "set", "set_name", "set_type", "released_at",
    "collector_number", "rarity", "layout", "lang", "type_line", "mana_cost", "cmc",
    "color_identity", "finishes", "digital", "promo", "reprint",
    "prices.usd", "prices.usd_foil", "prices.usd_etched", "prices.eur", "prices.tix",
    "legalities.commander", "legalities.standard", "edhrec_rank", "has_card_faces",
]
SAMPLE_ROWS = 1000


def _find_link(item: dict):
    """Return (download link, file format). Scryfall now serves gzipped JSON Lines;
    older responses used a single JSON file under download_uri."""
    if item.get("jsonl_download_uri"):
        return item["jsonl_download_uri"], "jsonl.gz"
    if item.get("download_uri"):
        return item["download_uri"], "json"
    return None, None


def get_download_uri(bulk_type: str) -> tuple[str, str, str]:
    resp = requests.get(BULK_INDEX_URL, headers=HEADERS, timeout=30)
    resp.raise_for_status()
    items = resp.json().get("data", [])
    item = next((i for i in items if i.get("type") == bulk_type), None)
    if item is None:
        raise ValueError(f"Bulk type '{bulk_type}' not found. "
                         f"Options: {[i.get('type') for i in items]}")

    link, fmt = _find_link(item)
    # Fallback: ask the item's own API endpoint for its full details.
    if not link and item.get("uri"):
        detail = requests.get(item["uri"], headers=HEADERS, timeout=30)
        detail.raise_for_status()
        item = {**item, **detail.json()}
        link, fmt = _find_link(item)

    if not link:
        print("\nScryfall's response didn't include a download link. Here's what it sent:")
        print(json.dumps(item, indent=2))
        raise SystemExit("Paste the output above into the chat so the script can be adjusted.")
    return link, fmt, item.get("updated_at", "unknown")


def download(bulk_type: str) -> Path:
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    stem = f"scryfall_{bulk_type}_{date.today():%Y-%m-%d}"
    existing = [f for f in RAW_DIR.glob(stem + ".*") if not f.name.endswith(".part")]
    if existing:
        print(f"Already downloaded today: {existing[0]}")
        return existing[0]

    uri, fmt, updated_at = get_download_uri(bulk_type)
    target = RAW_DIR / f"{stem}.{fmt}"
    print(f"Downloading {bulk_type} (Scryfall updated {updated_at})...")
    with requests.get(uri, headers=HEADERS, stream=True, timeout=300) as r:
        r.raise_for_status()
        tmp = Path(str(target) + ".part")
        done = 0
        with open(tmp, "wb") as f:
            for chunk in r.iter_content(chunk_size=1 << 20):
                f.write(chunk)
                done += len(chunk)
                print(f"\r  {done / 1e6:,.0f} MB", end="")
        tmp.replace(target)
    print(f"\nSaved to {target}")
    return target


def iter_cards(path: Path):
    """Yield one card dict at a time, whatever format the raw file is in."""
    name = path.name
    if name.endswith(".jsonl.gz") or name.endswith(".jsonl"):
        opener = gzip.open if name.endswith(".gz") else open
        with opener(path, "rt", encoding="utf-8") as f:
            for line in f:
                line = line.strip().rstrip(",")
                if line and line not in ("[", "]"):
                    yield json.loads(line)
    else:
        import ijson  # only needed for the older single-JSON format
        with open(path, "rb") as f:
            yield from ijson.items(f, "item")


def type_name(v) -> str:
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, (int, float, Decimal)):
        return "number"
    if isinstance(v, str):
        return "string"
    if isinstance(v, list):
        return "array"
    return "object"


def flatten(card: dict) -> dict:
    """Pull the sample columns out of a card, handling nested prices/legalities."""
    row = {}
    for col in SAMPLE_COLUMNS:
        if col == "has_card_faces":
            row[col] = "card_faces" in card
        elif "." in col:
            parent, child = col.split(".", 1)
            row[col] = (card.get(parent) or {}).get(child)
        else:
            v = card.get(col)
            # Multi-face cards keep mana_cost/type_line on the faces, not the top level.
            if v is None and col in ("mana_cost", "type_line") and card.get("card_faces"):
                v = " // ".join(str(f.get(col, "")) for f in card["card_faces"])
            row[col] = "|".join(map(str, v)) if isinstance(v, list) else v
    return row


def profile(path: Path) -> None:
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)

    total = 0
    present = Counter()                 # field -> cards where it's non-null
    types = defaultdict(Counter)        # field -> type -> count
    max_len = Counter()                 # field -> longest string value
    cats = defaultdict(Counter)         # categorical field -> value -> count
    price_populated = Counter()         # price key -> non-null count
    multi_face = 0
    samples, examples = [], {}

    for card in iter_cards(path):
        total += 1

        for field, v in card.items():
            types[field][type_name(v)] += 1
            if v is not None:
                present[field] += 1
            if isinstance(v, str):
                max_len[field] = max(max_len[field], len(v))

        for field in CATEGORICAL_FIELDS:
            v = card.get(field)
            for item in (v if isinstance(v, list) else [v]):
                cats[field][str(item)] += 1

        for k, v in (card.get("prices") or {}).items():
            if v is not None:
                price_populated[k] += 1

        if "card_faces" in card:
            multi_face += 1

        if len(samples) < SAMPLE_ROWS:
            samples.append(flatten(card))
        # Keep one full example of each layout to study the nested structure.
        layout = card.get("layout")
        if layout not in examples and len(examples) < 12:
            examples[layout] = card

        if total % 25000 == 0:
            print(f"  profiled {total:,} cards...")

    # --- write outputs ---
    with open(PROFILE_DIR / "field_profile.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["field", "pct_populated", "types_seen", "max_string_length"])
        for field in sorted(types, key=lambda k: -present[k]):
            w.writerow([
                field,
                round(100 * present[field] / total, 2),
                "; ".join(f"{t}:{c}" for t, c in types[field].most_common()),
                max_len.get(field, ""),
            ])

    with open(PROFILE_DIR / "value_counts.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["field", "value", "count"])
        for field in CATEGORICAL_FIELDS:
            for value, count in cats[field].most_common():
                w.writerow([field, value, count])

    with open(PROFILE_DIR / "price_coverage.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["price_type", "cards_with_price", "pct_of_cards"])
        for k, c in price_populated.most_common():
            w.writerow([k, c, round(100 * c / total, 2)])

    with open(PROFILE_DIR / "sample_cards.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=SAMPLE_COLUMNS)
        w.writeheader()
        w.writerows(samples)

    with open(PROFILE_DIR / "sample_cards.json", "w", encoding="utf-8") as f:
        json.dump(examples, f, indent=2, default=str)

    # --- console summary ---
    print(f"\n{'=' * 60}\nPROFILE SUMMARY: {path.name}\n{'=' * 60}")
    print(f"Total card objects: {total:,}")
    print(f"Multi-face cards (card_faces): {multi_face:,}")
    print("\nPrice coverage:")
    for k, c in price_populated.most_common():
        print(f"  {k:<12} {c:>8,}  ({100 * c / total:.1f}%)")
    print("\nTop layouts:", dict(cats["layout"].most_common(6)))
    print("Games:", dict(cats["games"].most_common()))
    print(f"\nFull outputs in {PROFILE_DIR.resolve()}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--type", default="default_cards",
                        help="default_cards | oracle_cards | unique_artwork | all_cards")
    args = parser.parse_args()
    profile(download(args.type))
