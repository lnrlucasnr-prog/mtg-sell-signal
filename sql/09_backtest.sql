/* =============================================================================
   09_backtest.sql  -  Do the sell signals actually work?
   -----------------------------------------------------------------------------
   Runs the SAME rules as the live signals (dw.fn_sell_signal) on every past
   snapshot in dw.study_observation (cards worth min_sell_price or more, on the
   dates the spike study observed), then compares what each signal's cards did
   over the following 30 days.

   A working signal set means: "Sell now" cards fell more than "Hold" cards.

   Honest caveat (put this in the README): today this is IN-SAMPLE. The spike
   and peer statistics the rules use were measured on these same dates, so
   results look better than truly unseen data would. As daily history grows,
   compare new dates against stats from older ones for an out-of-sample test.

   Robustness check: dw.backtest_by_period repeats the signal results for each
   stretch of price history (archived seasons vs. the daily history). Rules that
   only work in one season are luck; rules that hold in every season are real.

   Re-run any time; it always reflects the latest study and settings.
============================================================================= */
USE mtg;
GO

/* Every observed card, the signal it would have received then, and what happened next */
CREATE OR ALTER VIEW dw.vw_backtest_observation AS
SELECT o.as_of_date,
       o.card_key,
       o.finish,
       o.set_age_bucket,
       o.rarity,
       o.price_tier,
       o.price_now                   AS price_then,
       o.price_30d_later,
       o.fwd_chg_30d,
       o.price_30d_later - o.price_now AS fwd_usd_30d,
       bl.price_usd                  AS ck_cash_then,
       s.rule_no,
       s.signal,
       s.signal_sort,
       CASE s.rule_no
           WHEN 2 THEN 'Preorder'
           WHEN 9 THEN 'CK pays market or more'   -- Hold (rising): a leading indicator
           WHEN 3 THEN 'Risky spike'
           WHEN 4 THEN 'Rising spike'
           WHEN 5 THEN 'Unclear spike'
           WHEN 6 THEN 'Peers declining'
           WHEN 7 THEN 'Big move, no pattern'
           WHEN 8 THEN 'Stable'
           ELSE 'Below floor' END   AS rule_name
FROM dw.study_observation AS o
OUTER APPLY (SELECT TOP 1 b.price_usd
             FROM dw.fact_buylist_price AS b
             WHERE b.card_key = o.card_key AND b.finish = o.finish AND b.vendor = 'cardkingdom'
               AND o.as_of_date BETWEEN b.valid_from AND ISNULL(b.valid_to, '9999-12-31')
             ORDER BY b.valid_from DESC) AS bl
CROSS APPLY dw.fn_sell_signal(o.price_now, o.set_age_bucket, o.rarity, o.price_tier,
                              o.chg_7d, o.chg_30d, o.spike_share_7d,
                              o.other_printings_priced, o.other_printings_chg_30d,
                              bl.price_usd) AS s
WHERE o.fwd_chg_30d IS NOT NULL;
GO

/* Results are saved to tables so the dashboard and README queries are instant */
IF OBJECT_ID('dw.backtest_by_signal') IS NULL
CREATE TABLE dw.backtest_by_signal (
    signal               VARCHAR(20)   NOT NULL PRIMARY KEY,
    signal_sort          INT           NOT NULL,
    observations         INT           NOT NULL,
    median_next_30d      DECIMAL(9,4)  NULL,
    avg_next_30d         DECIMAL(9,4)  NULL,
    share_fell_10pct     DECIMAL(5,3)  NULL,
    share_rose_10pct     DECIMAL(5,3)  NULL,
    avg_usd_next_30d     DECIMAL(12,2) NULL,
    run_at               DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME()
);
GO

IF OBJECT_ID('dw.backtest_by_rule') IS NULL
CREATE TABLE dw.backtest_by_rule (
    rule_no              INT           NOT NULL PRIMARY KEY,
    rule_name            VARCHAR(30)   NOT NULL,
    signal               VARCHAR(20)   NOT NULL,
    observations         INT           NOT NULL,
    median_next_30d      DECIMAL(9,4)  NULL,
    avg_next_30d         DECIMAL(9,4)  NULL,
    share_fell_10pct     DECIMAL(5,3)  NULL,
    share_rose_10pct     DECIMAL(5,3)  NULL,
    run_at               DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME()
);
GO

IF OBJECT_ID('dw.backtest_by_date') IS NULL
CREATE TABLE dw.backtest_by_date (
    as_of_date           DATE          NOT NULL,
    signal               VARCHAR(20)   NOT NULL,
    observations         INT           NOT NULL,
    median_next_30d      DECIMAL(9,4)  NULL,
    share_fell_10pct     DECIMAL(5,3)  NULL,
    run_at               DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT pk_backtest_by_date PRIMARY KEY (as_of_date, signal)
);
GO

-- Upgrade: which stretch of price history each date belongs to (added at the END for Tableau)
IF COL_LENGTH('dw.backtest_by_date', 'period_name') IS NULL
    ALTER TABLE dw.backtest_by_date ADD period_name NVARCHAR(40) NULL;
GO

IF OBJECT_ID('dw.backtest_by_period') IS NULL
CREATE TABLE dw.backtest_by_period (
    period_name          NVARCHAR(40)  NOT NULL,
    period_start         DATE          NOT NULL,
    signal               VARCHAR(20)   NOT NULL,
    signal_sort          INT           NOT NULL,
    dates_observed       INT           NOT NULL,
    observations         INT           NOT NULL,
    median_next_30d      DECIMAL(9,4)  NULL,
    avg_next_30d         DECIMAL(9,4)  NULL,
    share_fell_10pct     DECIMAL(5,3)  NULL,
    share_rose_10pct     DECIMAL(5,3)  NULL,
    run_at               DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT pk_backtest_by_period PRIMARY KEY (period_name, signal)
);
GO

CREATE OR ALTER PROCEDURE dw.usp_run_backtest
AS
BEGIN
    SET NOCOUNT ON;

    SELECT b.*, w.period_name, w.first_date AS period_start
    INTO #bt
    FROM dw.vw_backtest_observation AS b
    LEFT JOIN dw.vw_price_window AS w
           ON b.as_of_date BETWEEN w.first_date AND w.last_date;

    TRUNCATE TABLE dw.backtest_by_signal;
    INSERT dw.backtest_by_signal (signal, signal_sort, observations, median_next_30d,
        avg_next_30d, share_fell_10pct, share_rose_10pct, avg_usd_next_30d)
    SELECT DISTINCT signal, signal_sort,
           COUNT(*) OVER (PARTITION BY signal),
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY fwd_chg_30d) OVER (PARTITION BY signal),
           AVG(fwd_chg_30d) OVER (PARTITION BY signal),
           AVG(CASE WHEN fwd_chg_30d <= -0.10 THEN 1.0 ELSE 0 END) OVER (PARTITION BY signal),
           AVG(CASE WHEN fwd_chg_30d >=  0.10 THEN 1.0 ELSE 0 END) OVER (PARTITION BY signal),
           AVG(fwd_usd_30d) OVER (PARTITION BY signal)
    FROM #bt;

    TRUNCATE TABLE dw.backtest_by_rule;
    INSERT dw.backtest_by_rule (rule_no, rule_name, signal, observations, median_next_30d,
        avg_next_30d, share_fell_10pct, share_rose_10pct)
    SELECT DISTINCT rule_no, rule_name, signal,
           COUNT(*) OVER (PARTITION BY rule_no),
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY fwd_chg_30d) OVER (PARTITION BY rule_no),
           AVG(fwd_chg_30d) OVER (PARTITION BY rule_no),
           AVG(CASE WHEN fwd_chg_30d <= -0.10 THEN 1.0 ELSE 0 END) OVER (PARTITION BY rule_no),
           AVG(CASE WHEN fwd_chg_30d >=  0.10 THEN 1.0 ELSE 0 END) OVER (PARTITION BY rule_no)
    FROM #bt;

    TRUNCATE TABLE dw.backtest_by_date;
    INSERT dw.backtest_by_date (as_of_date, signal, observations, median_next_30d, share_fell_10pct,
        period_name)
    SELECT DISTINCT as_of_date, signal,
           COUNT(*) OVER (PARTITION BY as_of_date, signal),
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY fwd_chg_30d) OVER (PARTITION BY as_of_date, signal),
           AVG(CASE WHEN fwd_chg_30d <= -0.10 THEN 1.0 ELSE 0 END) OVER (PARTITION BY as_of_date, signal),
           period_name
    FROM #bt;

    TRUNCATE TABLE dw.backtest_by_period;
    INSERT dw.backtest_by_period (period_name, period_start, signal, signal_sort, dates_observed,
        observations, median_next_30d, avg_next_30d, share_fell_10pct, share_rose_10pct)
    SELECT p.period_name, p.period_start, p.signal, p.signal_sort, d.dates_observed,
           p.observations, p.median_next_30d, p.avg_next_30d, p.share_fell_10pct, p.share_rose_10pct
    FROM (
        SELECT DISTINCT period_name, period_start, signal, signal_sort,
               COUNT(*) OVER (PARTITION BY period_name, signal) AS observations,
               PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY fwd_chg_30d)
                   OVER (PARTITION BY period_name, signal) AS median_next_30d,
               AVG(fwd_chg_30d) OVER (PARTITION BY period_name, signal) AS avg_next_30d,
               AVG(CASE WHEN fwd_chg_30d <= -0.10 THEN 1.0 ELSE 0 END)
                   OVER (PARTITION BY period_name, signal) AS share_fell_10pct,
               AVG(CASE WHEN fwd_chg_30d >=  0.10 THEN 1.0 ELSE 0 END)
                   OVER (PARTITION BY period_name, signal) AS share_rose_10pct
        FROM #bt
        WHERE period_name IS NOT NULL
    ) AS p
    JOIN (SELECT period_name, COUNT(DISTINCT as_of_date) AS dates_observed
          FROM #bt GROUP BY period_name) AS d
      ON d.period_name = p.period_name;

    SELECT * FROM dw.backtest_by_signal ORDER BY signal_sort;
    SELECT * FROM dw.backtest_by_rule   ORDER BY median_next_30d;
    SELECT period_name, signal, dates_observed, observations, median_next_30d, share_fell_10pct
    FROM dw.backtest_by_period ORDER BY period_start, signal_sort;
END
GO
