"""
export_tableau.py
-----------------
Writes the dashboard datasets to CSV files for Tableau Public, which can't
connect to SQL Server directly. Runs at the end of the daily batch, so the
files are always current; refreshing the dashboard is then just
"open Tableau Public -> refresh data -> republish".

Output: exports\\tableau\\*.csv (kept out of GitHub by .gitignore)

Usage (from the project root):
  python ETL\\export_tableau.py
"""

import csv
from pathlib import Path

from load_scryfall import connect

EXPORT_DIR = Path("exports/tableau")

# file name -> query
DATASETS = {
    "sell_signals":        "SELECT * FROM dw.vw_sell_signals",
    "price_history":       "SELECT * FROM dw.vw_tableau_price_history",
    "collection":          "SELECT * FROM dw.vw_tableau_collection",
    "buy_list":            "SELECT * FROM dw.vw_buy_list WHERE missing_qty > 0",
    "backtest_by_signal":  "SELECT * FROM dw.backtest_by_signal",
    "backtest_by_rule":    "SELECT * FROM dw.backtest_by_rule",
    "backtest_by_date":    "SELECT * FROM dw.backtest_by_date",
    "backtest_by_period":  "SELECT * FROM dw.backtest_by_period",
    "spike_patterns":      "SELECT * FROM dw.study_spike_stats",
    "peer_baseline":       "SELECT * FROM dw.study_peer_stats",
    "peer_baseline_by_age": "SELECT * FROM dw.study_peer_stats_by_age",
    "set_value_curve":     "SELECT * FROM dw.vw_tableau_set_value_curve",
    "run_info":            "SELECT * FROM dw.vw_tableau_run_info",
    "findings":            "SELECT * FROM dw.vw_dashboard_findings ORDER BY finding_order",
}


def main() -> None:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    conn = connect()
    cur = conn.cursor()
    try:
        print("Tableau export:")
        for name, sql in DATASETS.items():
            cur.execute(sql)
            columns = [c[0] for c in cur.description]
            rows = cur.fetchall()
            path = EXPORT_DIR / f"{name}.csv"
            tmp = path.with_suffix(".tmp")
            # utf-8-sig so card names with accents open cleanly in Tableau and Excel
            with open(tmp, "w", newline="", encoding="utf-8-sig") as f:
                w = csv.writer(f)
                w.writerow(columns)
                w.writerows(rows)
            tmp.replace(path)   # never leave Tableau a half-written file
            print(f"  {name + '.csv':<26} {len(rows):>8,} rows")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
