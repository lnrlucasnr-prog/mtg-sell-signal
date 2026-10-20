/* =============================================================================
   10_tableau_views.sql  -  datasets shaped for the Tableau Public dashboard
   -----------------------------------------------------------------------------
   Tableau Public can't connect to SQL Server, so ETL\export_tableau.py writes
   these views (plus a few existing views and tables) to CSV files that
   Tableau Public reads. The export runs at the end of the daily batch.

     dw.dim_date                     calendar table (used to turn change-only
                                     prices back into daily points)
     dw.vw_tableau_price_history     daily market price + CK buylist, last 90 days,
                                     for every sell candidate (all prices, so every
                                     card on the dashboard has a chart)
     dw.vw_tableau_collection        every owned card: value, CK offer, deck demand
     dw.vw_tableau_set_value_curve   how sets' prices moved after release:
                                     top 10 chases vs. all cards worth $2+, for
                                     sets released in any stretch of price history
     dw.vw_tableau_run_info          data freshness for the dashboard footer
     dw.vw_dashboard_findings        data-driven finding sentences for the dashboard
============================================================================= */
USE mtg;
GO

/* -----------------------------------------------------------------------------
   Calendar table
----------------------------------------------------------------------------- */
IF OBJECT_ID('dw.dim_date') IS NULL
CREATE TABLE dw.dim_date (
    date_value   DATE    NOT NULL PRIMARY KEY,
    year_num     INT     NOT NULL,
    month_num    INT     NOT NULL,
    week_start   DATE    NOT NULL     -- Monday of that week
);
GO

IF NOT EXISTS (SELECT 1 FROM dw.dim_date)
BEGIN
    ;WITH n AS (
        SELECT TOP (DATEDIFF(DAY, '2015-01-01', '2035-12-31') + 1)
               ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
        FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
    )
    INSERT dw.dim_date (date_value, year_num, month_num, week_start)
    SELECT d, YEAR(d), MONTH(d),
           DATEADD(DAY, -((DATEPART(WEEKDAY, d) + @@DATEFIRST - 2) % 7), d)
    FROM (SELECT DATEADD(DAY, i, CAST('2015-01-01' AS DATE)) AS d FROM n) AS x;
END
GO

/* -----------------------------------------------------------------------------
   Daily price history for sell candidates (market + Card Kingdom)
----------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dw.vw_tableau_price_history AS
WITH latest AS (
    SELECT MAX(as_of_date) AS last_day FROM dw.card_metrics
), cand AS (
    SELECT DISTINCT s.card_key, s.finish
    FROM dw.vw_sell_candidates AS s
), days AS (
    SELECT d.date_value
    FROM dw.dim_date AS d
    CROSS JOIN latest AS l
    WHERE d.date_value BETWEEN DATEADD(DAY, -90, l.last_day) AND l.last_day
)
SELECT c.card_key,
       c.finish,
       dc.card_name,
       ds.set_name,
       d.date_value,
       f.price_usd                 AS market_price,
       b.price_usd                 AS ck_cash,
       f.source                    AS market_price_source
FROM cand AS c
CROSS JOIN days AS d
JOIN dw.dim_card AS dc ON dc.card_key = c.card_key
JOIN dw.dim_set  AS ds ON ds.set_code = dc.set_code
LEFT JOIN dw.fact_price AS f
       ON f.card_key = c.card_key AND f.finish = c.finish
      AND d.date_value BETWEEN f.valid_from AND ISNULL(f.valid_to, '9999-12-31')
LEFT JOIN dw.fact_buylist_price AS b
       ON b.card_key = c.card_key AND b.finish = c.finish AND b.vendor = 'cardkingdom'
      AND d.date_value BETWEEN b.valid_from AND ISNULL(b.valid_to, '9999-12-31');
GO

/* -----------------------------------------------------------------------------
   Every owned card with value and deck demand (for collection KPIs)
----------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dw.vw_tableau_collection AS
SELECT f.card_name,
       f.set_code,
       s.set_name,
       s.release_date,
       c.rarity,
       f.finish,
       f.quantity,
       f.binder_name,
       f.card_condition,
       f.card_language,
       f.is_proxy,
       f.purchase_price,
       p.price_usd                         AS market_price,
       f.quantity * p.price_usd            AS market_value,
       b.ck_cash_usd,
       b.ck_credit_usd,
       f.quantity * b.ck_credit_usd        AS ck_credit_value,
       pos.owned_qty                       AS card_owned_total,
       pos.demand_now                      AS card_needed_by_decks,
       pos.surplus_now                     AS card_spare_copies,
       CASE WHEN pos.demand_now = 0 THEN 'Not in any deck'
            WHEN pos.surplus_now > 0 THEN 'Some copies spare'
            ELSE 'All copies in decks' END AS deck_status,
       f.card_key,
       f.oracle_id
FROM dw.fact_collection AS f
LEFT JOIN dw.dim_card AS c ON c.card_key = f.card_key
LEFT JOIN dw.dim_set  AS s ON s.set_code = c.set_code
LEFT JOIN dw.fact_price AS p
       ON p.card_key = f.card_key AND p.finish = f.finish AND p.valid_to IS NULL
LEFT JOIN dw.vw_current_buylist AS b
       ON b.card_key = f.card_key AND b.finish = f.finish
LEFT JOIN dw.vw_card_position AS pos ON pos.oracle_id = f.oracle_id;
GO

/* -----------------------------------------------------------------------------
   Set value curve: price index (1.0 = price when first seen after release)
   by days since release, for sets seen within ~6 weeks of release.
   Two lines per set: the 10 most valuable cards ("chases") and all cards $2+.
   Sets are tracked inside the stretch of price history (dw.vw_price_window)
   they were released in; stretches shorter than 30 days are skipped.
   period_name is the LAST column so the existing Tableau data source still matches.
----------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dw.vw_tableau_set_value_curve AS
WITH bounds AS (
    SELECT w.period_name, w.first_date AS first_day,
           CASE WHEN w.period_type = 'Daily'
                THEN (SELECT MAX(as_of_date) FROM dw.card_metrics)
                ELSE w.last_date END AS last_day
    FROM dw.vw_price_window AS w
    WHERE w.days >= 30
), sets AS (
    SELECT s.set_code, s.set_name, s.set_type, s.release_date, b.last_day, b.period_name,
           CASE WHEN s.release_date > b.first_day THEN s.release_date ELSE b.first_day END AS early_date
    FROM dw.dim_set AS s
    JOIN bounds AS b
      ON s.release_date BETWEEN DATEADD(DAY, -45, b.first_day) AND b.last_day
    WHERE s.set_type IN ('expansion', 'core', 'masters', 'draft_innovation', 'commander')
), cards AS (
    SELECT st.set_code, st.set_name, st.release_date, st.early_date, st.last_day, st.period_name,
           c.card_key, fe.price_usd AS early_price,
           ROW_NUMBER() OVER (PARTITION BY st.set_code ORDER BY fe.price_usd DESC) AS value_rank
    FROM sets AS st
    JOIN dw.dim_card AS c ON c.set_code = st.set_code
    JOIN dw.fact_price AS fe
         ON fe.card_key = c.card_key AND fe.finish = 'nonfoil'
        AND st.early_date BETWEEN fe.valid_from AND ISNULL(fe.valid_to, '9999-12-31')
    WHERE fe.price_usd >= 2
), daily AS (
    SELECT k.set_code, k.set_name, k.release_date, k.value_rank, k.period_name, d.date_value,
           DATEDIFF(DAY, k.release_date, d.date_value) AS days_since_release,
           f.price_usd / k.early_price AS price_index
    FROM cards AS k
    JOIN dw.dim_date AS d ON d.date_value BETWEEN k.early_date AND k.last_day
    JOIN dw.fact_price AS f
         ON f.card_key = k.card_key AND f.finish = 'nonfoil'
        AND d.date_value BETWEEN f.valid_from AND ISNULL(f.valid_to, '9999-12-31')
), grouped AS (
    SELECT set_code, set_name, release_date, period_name, date_value, days_since_release,
           price_index, 'All cards $2+' AS card_group
    FROM daily
    UNION ALL
    SELECT set_code, set_name, release_date, period_name, date_value, days_since_release,
           price_index, 'Top 10 chases'
    FROM daily WHERE value_rank <= 10
)
SELECT DISTINCT
       set_code, set_name, release_date, card_group, date_value, days_since_release,
       COUNT(*) OVER (PARTITION BY set_code, card_group, date_value) AS cards,
       CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY price_index)
            OVER (PARTITION BY set_code, card_group, date_value) AS DECIMAL(9,4)) AS median_price_index,
       period_name
FROM grouped;
GO

/* -----------------------------------------------------------------------------
   Data freshness for the dashboard footer
----------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dw.vw_tableau_run_info AS
SELECT (SELECT MAX(as_of_date)   FROM dw.card_metrics)          AS prices_as_of,
       (SELECT MIN(first_date)   FROM dw.vw_price_window
        WHERE period_type = 'Daily')                             AS history_starts,   -- continuous daily history
       (SELECT MAX(study_run_at) FROM dw.study_spike_stats)     AS spike_study_run_at,
       (SELECT COUNT(DISTINCT as_of_date) FROM dw.study_observation) AS study_dates_observed,
       (SELECT MAX(run_at)       FROM dw.backtest_by_signal)    AS backtest_run_at,
       (SELECT MAX(import_date)  FROM dw.fact_collection)       AS collection_imported,
       -- added at the END for Tableau: every stretch of price history, oldest first
       (SELECT STRING_AGG(period_name, N'; ') WITHIN GROUP (ORDER BY first_date)
        FROM dw.vw_price_window)                                 AS price_periods;
GO

/* -----------------------------------------------------------------------------
   Dashboard findings: the sentences shown on the "Does It Work?" page, built
   from the same results the charts use, so the text updates with every weekly
   study/backtest rerun and can never disagree with the charts.
   The CLAIMS are data-driven too (e.g. the riskiest spike pattern is whichever
   one currently has the highest fall rate), not just the numbers.
----------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dw.vw_dashboard_findings AS
WITH cfg AS (
    SELECT CAST(setting_value AS INT) AS spike_min_n
    FROM dw.app_setting WHERE setting_name = 'spike_min_examples'
), peer AS (
    SELECT median_next_30d, observations FROM dw.backtest_by_rule WHERE rule_no = 6
), spikes_all AS (
    SELECT COUNT(*) AS spikes,
           AVG(CASE WHEN fwd_chg_30d <= -0.10 THEN 1.0 ELSE 0 END) AS share_fell
    FROM dw.study_observation
    WHERE is_spike = 1 AND fwd_chg_30d IS NOT NULL
), riskiest AS (
    SELECT TOP 1 s.*
    FROM dw.study_spike_stats AS s
    CROSS JOIN cfg
    WHERE s.spikes >= cfg.spike_min_n
    ORDER BY s.share_fell_10pct DESC
), curve_last AS (
    -- Compare sets at the same horizon: each set's last tracked day within its first
    -- 90 days, counting only sets tracked for at least 30 days after release
    SELECT set_code, card_group, median_price_index, days_since_release,
           ROW_NUMBER() OVER (PARTITION BY set_code, card_group ORDER BY date_value DESC) AS rn
    FROM dw.vw_tableau_set_value_curve
    WHERE days_since_release <= 90
), curve AS (
    SELECT COUNT(DISTINCT set_code) AS sets,
           AVG(CASE WHEN card_group = 'Top 10 chases' THEN median_price_index END) AS chase_kept,
           AVG(CASE WHEN card_group = 'All cards $2+' THEN median_price_index END) AS all_kept,
           SUM(CASE WHEN card_group = 'Top 10 chases' AND median_price_index >= 1 THEN 1 ELSE 0 END)
                                                                                AS chase_sets_held
    FROM curve_last
    WHERE rn = 1 AND days_since_release >= 30
), study AS (
    SELECT COUNT(DISTINCT o.as_of_date) AS dates, MIN(o.as_of_date) AS first_date,
           MAX(o.as_of_date) AS last_date, COUNT(DISTINCT w.first_date) AS periods
    FROM dw.study_observation AS o
    LEFT JOIN dw.vw_price_window AS w ON o.as_of_date BETWEEN w.first_date AND w.last_date
)
SELECT 1 AS finding_order, 'backtest_peers' AS finding_key,
       CONCAT(N'Cards flagged Sell now because similar cards were declining ',
              CASE WHEN p.median_next_30d < 0
                   THEN CONCAT(N'fell a median ', FORMAT(-p.median_next_30d, 'P0'))
                   ELSE CONCAT(N'moved a median ', FORMAT(p.median_next_30d, 'P0')) END,
              N' over the next month (', FORMAT(p.observations, 'N0'), N' observations).') AS finding_text
FROM peer AS p
UNION ALL
SELECT 2, 'spike_patterns',
       CONCAT(FORMAT(1 - a.share_fell, 'P0'),
              N' of +25% spikes did not fall 10% or more the next month. Riskiest pattern: ',
              LOWER(CONCAT(r.spike_speed, N', ', r.spike_momentum, N', ', r.spike_breadth)),
              N' (', FORMAT(r.share_fell_10pct, 'P0'), N' fell 10%+, across ',
              FORMAT(r.spikes, 'N0'), N' spikes).')
FROM spikes_all AS a
CROSS JOIN riskiest AS r
UNION ALL
SELECT 3, 'set_curve',
       CONCAT(N'Across ', c.sets, N' sets, up to 3 months after release the top 10 chases sat at ',
              FORMAT(c.chase_kept, 'P0'), N' of their early price on average (all cards $2+: ',
              FORMAT(c.all_kept, 'P0'), N'). ',
              CASE WHEN c.chase_sets_held = 0 THEN N'In no set did the chases hold their value.'
                   ELSE CONCAT(N'Chases held their value in ', c.chase_sets_held, N' of ', c.sets,
                               N' sets.') END)
FROM curve AS c
UNION ALL
SELECT 4, 'footnote',
       CONCAT(N'Backtest covers ', s.dates, N' weekly dates',
              CASE WHEN s.periods > 1
                   THEN CONCAT(N' in ', s.periods, N' separate stretches of price history (',
                               FORMAT(s.first_date, 'MMM yyyy'), N' to ', FORMAT(s.last_date, 'MMM yyyy'), N')')
                   ELSE CONCAT(N' (', FORMAT(s.first_date, 'MMM d'), N' to ',
                               FORMAT(s.last_date, 'MMM d, yyyy'), N')') END,
              N'. It is in-sample: the rules were tuned on the same history. ',
              N'Findings re-run weekly as history grows.')
FROM study AS s;
GO
