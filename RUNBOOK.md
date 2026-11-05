# MTG Sell Signal: Runbook

How the pipeline runs, what is automated, what is manual, what can break, and how to recover.

---

## 1. What runs, and when

### Daily (automated)

Windows Task Scheduler runs `run_daily_load.bat` **daily at 8:00 AM** and **5 minutes after log on**. Every step is safe to run more than once a day, so the double trigger is intentional: if the PC was off at 8:00, the log-on run catches up.

Steps run in this order. Each step runs even if an earlier one failed, so one problem doesn't hide another; the batch exits with a non-zero code if any step failed.

| # | Script | What it does | Writes to |
|---|---|---|---|
| 1 | `ETL/load_scryfall.py` | Downloads Scryfall's `default_cards` bulk file (~80 MB, gzipped JSON Lines), keeps paper English game cards, stages them, runs `dw.usp_load_snapshot`. Deletes raw files older than 30 days. | `stg.scryfall_card` → `dw.dim_set`, `dw.dim_card`, `dw.fact_price`, `etl.load_log` |
| 2 | `ETL/load_buylist.py` | Downloads MTGJSON `AllPricesToday`, extracts Card Kingdom buylist prices, runs `dw.usp_load_buylist_snapshot`. Refreshes the MTGJSON → Scryfall ID map when it is older than 7 days. | `dw.fact_buylist_price`, `dw.map_mtgjson_scryfall`, `etl.buylist_log` |
| 2b | `ETL/load_boosters.py` | Every 14 days (otherwise exits at once): downloads MTGJSON `AllPrintings` (~100+ MB) and loads each set's booster layouts, runs `dw.usp_apply_boosters`. | `dw.booster_*` tables |
| 3 | `ETL/import_manabox.py` | Reads the newest collection CSV and all `Deck:` / `Edit:` lists from the Google Drive folder, runs `dw.usp_load_manabox`. | `dw.fact_collection`, `dw.dim_deck`, `dw.fact_deck_card`, `etl.import_log` |
| 4 | `ETL/refresh_analytics.py` | Rebuilds card trend metrics as of the latest prices; keeps 7 days of snapshots. | `dw.card_metrics` |
| 5 | `ETL/export_tableau.py` | Writes the dashboard datasets to CSV. | `exports/tableau/*.csv` |

All output is appended to `logs/daily_load.log`.

### Weekly (automated, inside step 4)

When the saved spike study is more than 7 days old, `refresh_analytics.py` also:

- reruns the **spike study** (`dw.usp_run_spike_study`): re-measures how past spikes and peer groups behaved, using all available history
- reruns the **backtest** (`dw.usp_run_backtest`): re-scores past dates with the current rules and logs one line per signal

The sell signals (`dw.vw_sell_signals`) are a view, so they pick up the new study results immediately.

Force a rerun at any time: `python ETL\refresh_analytics.py --study`

### Manual

| Task | When | How |
|---|---|---|
| Update collection / decks | After buying, selling or rebuilding decks | Export from ManaBox to the `MTG Exports` Google Drive folder. The next daily run imports it. |
| Publish the dashboard | Weekly | Open the workbook in Tableau Public → Data → Refresh → republish. |
| Review thresholds | Every 1–2 months | Look at the backtest results, then adjust `dw.app_setting` if needed (see section 5). |
| Check data quality | After each ManaBox export | Query `dw.vw_deck_shortages` and `dw.vw_import_issues` (both should be empty). |

### One-time setup scripts (do not schedule)

| Script | Purpose |
|---|---|
| `ETL/profile_scryfall.py` | Profiles the Scryfall file (field types, lengths, price coverage) before designing tables. |
| `ETL/backfill_mtgjson.py` | Loads ~90 days of market price history from MTGJSON, before the first Scryfall snapshot. |
| `ETL/load_buylist.py --backfill` | Loads ~90 days of Card Kingdom buylist history. Refuses to run once daily buylist rows exist, unless `--force`. |
| `ETL/load_boosters.py --force` | Reloads MTGJSON booster layouts now (e.g. right after a new set releases). The daily run already refreshes them every 14 days. |
| `ETL/load_tcgcsv.py` | Loads daily TCGplayer market prices from Feb 8, 2024 up to the regular history, from the [TCGCSV](https://tcgcsv.com) price archive. Downloads each daily file once into `data/raw/tcgcsv/` (about 1 GB, kept; reruns reuse it). Rerunnable: replaces all `tcgcsv` rows. Run after `load_archive.py`, then `refresh_analytics.py --study`. |
| `ETL/load_archive.py` | Loads older seasons of market + buylist prices from archived MTGJSON files in `data/raw/archive/` (saved from the Wayback Machine). Rerunnable: replaces all archive rows each time. Follow with `refresh_analytics.py --study`. |

**Archive files** (`data/raw/archive/`, not in Git; keep a copy, the loader needs them to rerun):

| File | Prices cover |
|---|---|
| `AllPrices_2022-01-05.json.zip` | Oct 5, 2021 – Jan 5, 2022 |
| `AllPrices_2023-05-29.json.zip` | Feb 28 – May 29, 2023 |
| `AllPricesToday_2025-07-08.json.zip` | Jul 8, 2025 (one day; not used by the study, kept for long-range comparisons) |

The Jul 2025 file is superseded once `load_tcgcsv.py` has run (its rows are replaced by the continuous TCGCSV history); the loader then skips it.

The years between these stretches have no prices; nothing is filled in. `dw.vw_price_window` lists every stretch, and the spike study only observes dates with 30 days of history before and after inside one stretch.

---

## 2. Weak points (what can break)

| Weak point | What happens | Prevention / detection |
|---|---|---|
| **PC off or asleep** | No run that day; that day's prices are never captured. | The log-on trigger catches up the same day. A missed day only loses that day's detail: change-only history resumes with the next run. |
| **Google Drive not synced** | ManaBox import fails (folder not found) or imports a stale file. | Log-on trigger is delayed 5 minutes. Check the collection file's "Date modified" after exporting. |
| **Drive folder path changes** | Import fails: `Import folder not found`. | Path is `[imports] folder` in `ETL/config.ini`. |
| **Deck files misnamed** | A list is silently ignored. | Names must start with `Deck:` or `Edit:` (Drive turns `:` into `_`, which also works). Check `deck_lists` in the log. |
| **Scryfall changes its bulk format** | Download or parsing fails. Happened once already: the response moved from `download_uri` (JSON) to `jsonl_download_uri` (gzipped JSON Lines). | `load_scryfall.py` prints Scryfall's raw response when it can't find a download link. |
| **MTGJSON changes its files** | Buylist load fails, or loads nothing. | An empty buylist file is rejected (`Buylist staging is empty`) rather than treated as "CK stopped buying everything". |
| **SQL Server not running** | Every step fails to connect. | Check the SQL Server service in Windows Services. |
| **Python moved or upgraded** | Batch fails immediately. | The full Python path is set at the top of `run_daily_load.bat`. |
| **Unexpected data values** | Load fails on a column size or type. | Precedent: Gleemax's mana value (1,000,000) overflowed `cmc`. Over-length text is trimmed and reported; numeric overflows need a column change. |
| **Disk space** | Downloads fail. | Raw Scryfall files level off at ~2.4 GB (30-day retention, `RAW_RETENTION_DAYS` in `load_scryfall.py`). SQL Server Express caps a database at 10 GB; change-only storage keeps growth well under 1 GB/year. |

---

## 3. Checking that it worked

**Log file:** the end of `logs/daily_load.log` should show today's run with `exit code 0`.

**SQL:**

```sql
-- Latest runs of each loader
SELECT TOP 5 snapshot_date, status, prices_new, prices_changed, run_finished
FROM etl.load_log ORDER BY run_id DESC;

SELECT TOP 5 run_type, snapshot_date, prices_new, prices_changed, dropped_off, run_at
FROM etl.buylist_log ORDER BY run_id DESC;

SELECT TOP 5 import_date, status, collection_cards, collection_unmatched,
       deck_lists, deck_lines_unmatched
FROM etl.import_log ORDER BY run_id DESC;

-- Freshness of every layer, in one row
SELECT * FROM dw.vw_tableau_run_info;
```

**Expected values on a normal day:** `prices_changed` in the thousands to tens of thousands (not ~144,000, which would mean every price changed); `collection_unmatched` and `deck_lines_unmatched` = 0.

**Data quality views:**

| View | Should be | If not |
|---|---|---|
| `dw.vw_deck_shortages` | empty | A `Deck:` list uses a card the collection doesn't cover: scan the missing card into ManaBox, or fix the list. |
| `dw.vw_import_issues` | empty | A card couldn't be matched to Scryfall: check its set code and collector number in ManaBox. |

---

## 4. Recovering from problems

All loads are **idempotent** (safe to rerun on the same day), so the first fix is almost always: **fix the cause, then double-click `run_daily_load.bat`.**

| Situation | Fix |
|---|---|
| Missed a day | Nothing to do; the next run continues the history. |
| A step failed | Read the error in `logs/daily_load.log`, fix the cause, rerun the batch file. Failed runs are marked `failed` in the `etl` log tables and roll back completely. |
| Need to rerun one step | Run that script alone from the project folder, e.g. `python ETL\import_manabox.py`. |
| "Snapshot date is older than existing price history" | Expected protection: the daily loads only move forward in time. Older dates require a backfill script. |
| Bad ManaBox export | Export again; each import fully replaces the collection and deck tables. |
| Rebuild everything from scratch | See section 6. |

---

## 5. Tunable settings (`dw.app_setting`)

Change with `UPDATE dw.app_setting SET setting_value = ... WHERE setting_name = '...';`. Signals update immediately; study settings apply at the next study run.

| Setting | Default | Meaning |
|---|---|---|
| `min_sell_price` | 2.00 | Below this market price: "Not worth selling" |
| `spike_pct` | 0.25 | 30-day rise that counts as a spike |
| `watch_pct` | 0.10 | 30-day move (either way) that triggers Watch |
| `sharp_spike_share` | 0.60 | Share of a spike's gain in the last 7 days that makes it "Sharp" |
| `broad_breadth_pct` | 0.10 | Other printings' rise that makes a spike "Broad" |
| `spike_sell_fell_share` | 0.25 | Sell a spike if this share of similar past spikes fell 10%+ |
| `spike_hold_rising_share` | 0.55 | Hold a spike if this share of similar past spikes kept rising |
| `spike_min_examples` | 100 | Past spikes needed before a pattern's track record is trusted |
| `peer_sell_threshold` | −0.05 | Sell when similar cards typically drop this much next month |
| `peer_min_examples` | 30 | Observations needed before a peer group is trusted |
| `study_max_dates` | 24 | Past dates the spike study observes per stretch of price history: weekly, or spread evenly over a longer stretch |
| `metrics_retain_days` | 7 | Days of daily `card_metrics` snapshots kept |

Sell channels (Card Kingdom buylist, local store estimate percentages) are in `dw.dim_sell_channel`.

---

## 6. Rebuilding from scratch

1. Install Python, then `pip install -r requirements.txt`. Install the Microsoft ODBC Driver for SQL Server if none is present.
2. Copy `ETL/config.example.ini` to `ETL/config.ini` and fill in the server, database and Drive folder.
3. Run the SQL scripts in SSMS **in order**: `01` through `13`. (`02_fix_cmc_size.sql` is only needed for databases created before the `cmc` fix; it is harmless otherwise.)
4. From the project folder, run once, in order:
   ```
   python ETL\load_scryfall.py
   python ETL\backfill_mtgjson.py
   python ETL\load_buylist.py --backfill
   python ETL\load_archive.py
   python ETL\load_tcgcsv.py
   python ETL\import_manabox.py
   python ETL\refresh_analytics.py --study
   python ETL\export_tableau.py
   ```
5. Check `SELECT * FROM dw.vw_backfill_source_check;`: MTGJSON and Scryfall should agree on ~99% of prices within 5%.
6. Create the Task Scheduler task (section 1 triggers; Conditions: not AC-power-only, network required).

---

## 7. File map

```
mtg-sell-signal/
├── run_daily_load.bat        daily pipeline (Task Scheduler entry point)
├── requirements.txt          Python packages
├── RUNBOOK.md                this file
├── ETL/
│   ├── load_scryfall.py      daily: Scryfall cards + market prices
│   ├── load_buylist.py       daily: Card Kingdom buylist (--backfill once)
│   ├── import_manabox.py     daily: collection + deck lists
│   ├── refresh_analytics.py  daily: metrics; weekly: spike study + backtest
│   ├── export_tableau.py     daily: CSVs for Tableau Public
│   ├── backfill_mtgjson.py   one-time: 90-day market price history
│   ├── load_archive.py       one-time: older seasons from archived MTGJSON files
│   ├── load_tcgcsv.py        one-time: daily TCGplayer prices from Feb 2024 (TCGCSV)
│   ├── load_boosters.py      every 14 days: MTGJSON booster layouts (pack odds)
│   ├── profile_scryfall.py   one-time: data profiling
│   ├── config.example.ini    settings template (config.ini is not in Git)
├── sql/
│   ├── 01_schema.sql              core tables, change-only price load
│   ├── 02_fix_cmc_size.sql        one-time column fix
│   ├── 03_collection_decks.sql    collection, decks, buy list, sell candidates
│   ├── 04_mtgjson_backfill.sql    price backfill + source check
│   ├── 05_buylist.sql             Card Kingdom buylist
│   ├── 06_channels_metrics.sql    settings, sell channels, trend metrics
│   ├── 07_spike_study.sql         spike study + peer baselines
│   ├── 08_sell_signals.sql        signal rules (dw.fn_sell_signal) + live view
│   ├── 09_backtest.sql            backtest
│   ├── 10_tableau_views.sql       dashboard datasets
│   ├── 11_archive_prices.sql      archived price seasons (Wayback MTGJSON files)
│   ├── 12_tcgcsv_prices.sql       daily TCGplayer history from Feb 2024 + source check
│   └── 13_packs.sql               booster layouts + "which pack should I open?" odds
├── data/                     raw downloads (not in Git)
├── logs/                     daily_load.log (not in Git)
└── exports/tableau/          dashboard CSVs (not in Git: contain collection data)
```
