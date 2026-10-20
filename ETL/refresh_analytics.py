"""
refresh_analytics.py
--------------------
Rebuilds the analysis layer after the daily loads:
  1. dw.usp_build_card_metrics  - trend metrics for every printing, as of the latest prices
  2. removes daily metric snapshots older than the metrics_retain_days setting
  3. reruns the spike study (dw.usp_run_spike_study) and the backtest
     (dw.usp_run_backtest) when the saved study results are
     older than STUDY_MAX_AGE_DAYS, so the sell signals keep learning from the
     growing price history

The sell signals (dw.vw_sell_signals) are a view, so they update automatically
from these results.

Usage (from the project root):
  python ETL\\refresh_analytics.py
  python ETL\\refresh_analytics.py --study    force a spike study rerun now
"""

import argparse
from datetime import datetime, timedelta

from load_scryfall import connect

STUDY_MAX_AGE_DAYS = 7


def study_is_stale(cur) -> bool:
    last_run = cur.execute("SELECT MAX(study_run_at) FROM dw.study_spike_stats").fetchone()[0]
    return last_run is None or datetime.now() - last_run > timedelta(days=STUDY_MAX_AGE_DAYS)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--study", action="store_true", help="rerun the spike study now")
    args = parser.parse_args()

    conn = connect()
    conn.autocommit = True
    cur = conn.cursor()
    try:
        r = cur.execute("EXEC dw.usp_build_card_metrics").fetchone()
        print("Card metrics rebuilt:")
        print(f"  as_of_date        {r.as_of_date}")
        print(f"  cards_measured    {r.cards_measured:,}")
        print(f"  with_30d_history  {r.with_30d_history:,}")

        cur.execute("""
            DECLARE @keep INT = (SELECT CAST(setting_value AS INT) FROM dw.app_setting
                                 WHERE setting_name = 'metrics_retain_days');
            DELETE FROM dw.card_metrics
            WHERE as_of_date < DATEADD(DAY, -ISNULL(@keep, 7),
                                       (SELECT MAX(as_of_date) FROM dw.card_metrics));
        """)

        if args.study or study_is_stale(cur):
            print("Rerunning the spike study (a few minutes)...")
            s = cur.execute("EXEC dw.usp_run_spike_study").fetchone()
            while cur.nextset():      # drain the pattern table result set
                pass
            print("Spike study complete:")
            print(f"  dates_observed    {s.dates_observed}  ({s.first_date} to {s.last_date}, "
                  f"{s.periods_observed} stretch(es) of history)")
            print(f"  observations      {s.observations:,}")
            print(f"  spikes            {s.spikes:,}")

            # Re-score the past with the freshly tuned rules
            rows = cur.execute("EXEC dw.usp_run_backtest").fetchall()
            cur.nextset()                 # by rule (not printed)
            periods = cur.fetchall() if cur.nextset() else []
            while cur.nextset():
                pass
            print("Backtest (median price move over the next 30 days, by signal):")
            for b in rows:
                print(f"  {b.signal:<14} {b.median_next_30d:>+8.1%}   ({b.observations:,} cards)")
            if len({p.period_name for p in periods}) > 1:
                print("Backtest by stretch of history (does each signal hold in every season?):")
                for p in periods:
                    print(f"  {p.period_name:<22} {p.signal:<14} {p.median_next_30d:>+8.1%}"
                          f"   ({p.observations:,} cards, {p.dates_observed} dates)")
        else:
            print("Spike study is less than a week old; skipped.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
