/* =============================================================================
   07_spike_study.sql  -  "Is this spike a peak or the start of growth?"
   -----------------------------------------------------------------------------
   dw.usp_run_spike_study looks back at past dates (at least 30 days ago, weekly),
   rebuilds card metrics AS OF each date (no lookahead), and records where each
   card's price actually was 30 days later. Results:

     dw.study_observation        one row per card per observed date (cards >= min_sell_price)
     dw.vw_study_spike_patterns  outcomes of +25% spikes, by speed / momentum / breadth
     dw.vw_study_peer_baseline   typical next-30-day move by set age, rarity, price tier
     dw.study_spike_stats,       saved copies of the results that the sell signals
     dw.study_peer_stats,        read (rebuilt at the end of every study run)
     dw.study_peer_stats_by_age

   Momentum is split three ways because many cards trade rarely:
     Still rising (7-day change > 0), Cooling (< 0), Flat (no change: no recent sales)

   Price history can have gaps (archived seasons from 11_archive_prices.sql plus
   the continuous daily history). dw.vw_price_window lists each stretch of
   history; the study only picks dates with 30 days before AND after inside
   one stretch, up to study_max_dates per stretch.

   Re-run it monthly (EXEC dw.usp_run_spike_study): as daily history grows,
   more dates become observable and the findings get sturdier.
============================================================================= */
USE mtg;
GO

INSERT dw.app_setting (setting_name, setting_value, description)
SELECT v.setting_name, v.setting_value, v.description
FROM (VALUES
    ('sharp_spike_share', 0.60, N'A spike is "Sharp" when at least this share of its 30-day gain came in the last 7 days'),
    ('broad_breadth_pct', 0.10, N'A spike is "Broad" when the card''s other printings rose at least this much over 30 days'),
    ('study_max_dates',   12,   N'Maximum number of weekly past dates the spike study observes in each stretch of price history')
) AS v(setting_name, setting_value, description)
WHERE NOT EXISTS (SELECT 1 FROM dw.app_setting s WHERE s.setting_name = v.setting_name);
GO

/* Archived stretches of price history (filled by dw.usp_apply_archive_prices) */
IF OBJECT_ID('dw.price_window') IS NULL
CREATE TABLE dw.price_window (
    file_name        NVARCHAR(200) NOT NULL PRIMARY KEY,
    first_date       DATE          NOT NULL,
    last_date        DATE          NOT NULL,
    cards_matched    INT           NULL,
    cards_unmatched  INT           NULL,
    market_rows      INT           NULL,
    buylist_rows     INT           NULL,
    loaded_at        DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME()
);
GO

/* Every stretch of price history: archived windows + the continuous daily history */
CREATE OR ALTER VIEW dw.vw_price_window AS
WITH w AS (
    SELECT first_date, last_date, CAST('Archive' AS VARCHAR(7)) AS period_type
    FROM dw.price_window
    UNION ALL
    SELECT MIN(valid_from), MAX(valid_from), 'Daily'
    FROM dw.fact_price
    WHERE source <> 'mtgjson_archive'
    HAVING COUNT(*) > 0
)
SELECT CAST(CASE WHEN period_type = 'Daily'
                     THEN CONCAT(FORMAT(first_date, 'MMM yyyy'), N' - now')
                 WHEN first_date = last_date
                     THEN FORMAT(first_date, 'MMM d, yyyy')
                 WHEN YEAR(first_date) = YEAR(last_date)
                     THEN CONCAT(FORMAT(first_date, 'MMM'), N' - ', FORMAT(last_date, 'MMM yyyy'))
                 ELSE CONCAT(FORMAT(first_date, 'MMM yyyy'), N' - ', FORMAT(last_date, 'MMM yyyy'))
            END AS NVARCHAR(40)) AS period_name,
       first_date, last_date, period_type,
       DATEDIFF(DAY, first_date, last_date) + 1 AS days
FROM w;
GO

IF OBJECT_ID('dw.study_observation') IS NULL
CREATE TABLE dw.study_observation (
    as_of_date              DATE          NOT NULL,
    card_key                INT           NOT NULL,
    finish                  VARCHAR(8)    NOT NULL,
    set_age_bucket          VARCHAR(20)   NULL,
    rarity                  NVARCHAR(20)  NULL,
    price_tier              VARCHAR(10)   NULL,
    price_30d_ago           DECIMAL(12,2) NULL,
    price_now               DECIMAL(12,2) NOT NULL,
    chg_7d                  DECIMAL(12,4) NULL,
    chg_30d                 DECIMAL(12,4) NULL,
    spike_share_7d          DECIMAL(12,4) NULL,
    other_printings_priced  INT           NULL,
    other_printings_chg_30d DECIMAL(12,4) NULL,
    is_spike                BIT           NOT NULL,
    spike_speed             VARCHAR(10)   NULL,   -- Sharp / Gradual
    spike_momentum          VARCHAR(15)   NULL,   -- Still rising / Cooling / Flat
    spike_breadth           VARCHAR(25)   NULL,   -- Broad / Single printing / Only priced printing
    price_30d_later         DECIMAL(12,2) NULL,
    fwd_chg_30d             DECIMAL(12,4) NULL,   -- what happened next
    spike_gain_retained     DECIMAL(12,4) NULL,   -- 1 = kept the whole spike, 0 = fully reverted
    CONSTRAINT pk_study_observation PRIMARY KEY (as_of_date, card_key, finish)
) WITH (DATA_COMPRESSION = PAGE);
GO

/* Saved study results, read by the sell signals */
IF OBJECT_ID('dw.study_spike_stats') IS NULL
CREATE TABLE dw.study_spike_stats (
    spike_speed          VARCHAR(10)  NOT NULL,
    spike_momentum       VARCHAR(15)  NOT NULL,
    spike_breadth        VARCHAR(25)  NOT NULL,
    spikes               INT          NOT NULL,
    median_next_30d      DECIMAL(9,4) NULL,
    share_fell_10pct     DECIMAL(5,3) NULL,
    share_kept_rising    DECIMAL(5,3) NULL,
    median_gain_retained DECIMAL(9,4) NULL,
    study_run_at         DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT pk_study_spike_stats PRIMARY KEY (spike_speed, spike_momentum, spike_breadth)
);
GO

IF OBJECT_ID('dw.study_peer_stats') IS NULL
CREATE TABLE dw.study_peer_stats (
    set_age_bucket    VARCHAR(20)  NOT NULL,
    rarity            NVARCHAR(20) NOT NULL,
    price_tier        VARCHAR(10)  NOT NULL,
    observations      INT          NOT NULL,
    median_next_30d   DECIMAL(9,4) NULL,
    share_fell_10pct  DECIMAL(5,3) NULL,
    share_rose_10pct  DECIMAL(5,3) NULL,
    study_run_at      DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT pk_study_peer_stats PRIMARY KEY (set_age_bucket, rarity, price_tier)
);
GO

IF OBJECT_ID('dw.study_peer_stats_by_age') IS NULL
CREATE TABLE dw.study_peer_stats_by_age (
    set_age_bucket    VARCHAR(20)  NOT NULL PRIMARY KEY,
    observations      INT          NOT NULL,
    median_next_30d   DECIMAL(9,4) NULL,
    share_fell_10pct  DECIMAL(5,3) NULL,
    share_rose_10pct  DECIMAL(5,3) NULL,
    study_run_at      DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
GO

/* What happened to +25% spikes 30 days later, by pattern */
CREATE OR ALTER VIEW dw.vw_study_spike_patterns AS
WITH s AS (
    SELECT * FROM dw.study_observation
    WHERE is_spike = 1 AND fwd_chg_30d IS NOT NULL
)
SELECT DISTINCT
       spike_speed, spike_momentum, spike_breadth,
       COUNT(*) OVER (PARTITION BY spike_speed, spike_momentum, spike_breadth) AS spikes,
       CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY fwd_chg_30d)
            OVER (PARTITION BY spike_speed, spike_momentum, spike_breadth) AS DECIMAL(9,4)) AS median_next_30d,
       CAST(AVG(CASE WHEN fwd_chg_30d <= -0.10 THEN 1.0 ELSE 0 END)
            OVER (PARTITION BY spike_speed, spike_momentum, spike_breadth) AS DECIMAL(5,3)) AS share_fell_10pct,
       CAST(AVG(CASE WHEN fwd_chg_30d > 0 THEN 1.0 ELSE 0 END)
            OVER (PARTITION BY spike_speed, spike_momentum, spike_breadth) AS DECIMAL(5,3)) AS share_kept_rising,
       CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY spike_gain_retained)
            OVER (PARTITION BY spike_speed, spike_momentum, spike_breadth) AS DECIMAL(9,4)) AS median_gain_retained
FROM s;
GO

/* Typical next-30-day move for cards that are NOT spiking, by peer group */
CREATE OR ALTER VIEW dw.vw_study_peer_baseline AS
WITH s AS (
    SELECT * FROM dw.study_observation
    WHERE is_spike = 0 AND fwd_chg_30d IS NOT NULL
)
SELECT DISTINCT
       set_age_bucket, rarity, price_tier,
       COUNT(*) OVER (PARTITION BY set_age_bucket, rarity, price_tier) AS observations,
       CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY fwd_chg_30d)
            OVER (PARTITION BY set_age_bucket, rarity, price_tier) AS DECIMAL(9,4)) AS median_next_30d,
       CAST(AVG(CASE WHEN fwd_chg_30d <= -0.10 THEN 1.0 ELSE 0 END)
            OVER (PARTITION BY set_age_bucket, rarity, price_tier) AS DECIMAL(5,3)) AS share_fell_10pct,
       CAST(AVG(CASE WHEN fwd_chg_30d >= 0.10 THEN 1.0 ELSE 0 END)
            OVER (PARTITION BY set_age_bucket, rarity, price_tier) AS DECIMAL(5,3)) AS share_rose_10pct
FROM s;
GO

CREATE OR ALTER PROCEDURE dw.usp_run_spike_study
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @far      DATE = '9999-12-31',
            @min      DECIMAL(12,4) = (SELECT setting_value FROM dw.app_setting WHERE setting_name = 'min_sell_price'),
            @spike    DECIMAL(12,4) = (SELECT setting_value FROM dw.app_setting WHERE setting_name = 'spike_pct'),
            @sharp    DECIMAL(12,4) = (SELECT setting_value FROM dw.app_setting WHERE setting_name = 'sharp_spike_share'),
            @broad    DECIMAL(12,4) = (SELECT setting_value FROM dw.app_setting WHERE setting_name = 'broad_breadth_pct'),
            @max_n    INT           = (SELECT CAST(setting_value AS INT) FROM dw.app_setting WHERE setting_name = 'study_max_dates');

    DECLARE @as_of DATE, @fwd DATE;

    CREATE TABLE #sink (as_of_date DATE, cards_measured INT, with_30d_history INT);

    -- Observation dates: weekly, walking back from 30 days before the end of each
    -- stretch of history, while 30 days of history before the date are still inside it.
    CREATE TABLE #dates (as_of_date DATE PRIMARY KEY);
    WITH n AS (
        SELECT TOP (@max_n) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS k
        FROM sys.all_objects
    )
    INSERT #dates (as_of_date)
    SELECT DISTINCT DATEADD(DAY, -30 - 7 * n.k, w.last_date)
    FROM dw.vw_price_window AS w
    CROSS JOIN n
    WHERE DATEADD(DAY, -60 - 7 * n.k, w.last_date) >= w.first_date;

    TRUNCATE TABLE dw.study_observation;

    WHILE EXISTS (SELECT 1 FROM #dates)
    BEGIN
        SELECT @as_of = MAX(as_of_date) FROM #dates;
        SET @fwd = DATEADD(DAY, 30, @as_of);

        INSERT #sink EXEC dw.usp_build_card_metrics @as_of = @as_of;

        INSERT dw.study_observation (as_of_date, card_key, finish, set_age_bucket, rarity,
            price_tier, price_30d_ago, price_now, chg_7d, chg_30d, spike_share_7d,
            other_printings_priced, other_printings_chg_30d, is_spike, spike_speed,
            spike_momentum, spike_breadth, price_30d_later, fwd_chg_30d, spike_gain_retained)
        SELECT m.as_of_date, m.card_key, m.finish, m.set_age_bucket, m.rarity, m.price_tier,
               m.price_30d_ago, m.price_now, m.chg_7d, m.chg_30d, m.spike_share_7d,
               m.other_printings_priced, m.other_printings_chg_30d,
               x.is_spike,
               CASE WHEN x.is_spike = 1 THEN
                    CASE WHEN m.spike_share_7d >= @sharp THEN 'Sharp' ELSE 'Gradual' END END,
               CASE WHEN x.is_spike = 1 THEN
                    CASE WHEN m.chg_7d > 0 THEN 'Still rising'
                         WHEN m.chg_7d < 0 THEN 'Cooling'
                         ELSE 'Flat' END END,
               CASE WHEN x.is_spike = 1 THEN
                    CASE WHEN ISNULL(m.other_printings_priced, 0) = 0 THEN 'Only priced printing'
                         WHEN m.other_printings_chg_30d >= @broad THEN 'Broad'
                         ELSE 'Single printing' END END,
               f.price_usd,
               f.price_usd / m.price_now - 1,
               CASE WHEN x.is_spike = 1
                    THEN (f.price_usd - m.price_30d_ago) / NULLIF(m.price_now - m.price_30d_ago, 0) END
        FROM dw.card_metrics AS m
        CROSS APPLY (SELECT CAST(CASE WHEN m.chg_30d >= @spike THEN 1 ELSE 0 END AS BIT) AS is_spike) AS x
        LEFT JOIN dw.fact_price AS f
               ON f.card_key = m.card_key AND f.finish = m.finish
              AND @fwd BETWEEN f.valid_from AND ISNULL(f.valid_to, @far)
        WHERE m.as_of_date = @as_of
          AND m.price_now >= @min
          AND m.chg_30d IS NOT NULL;

        -- These past snapshots are only needed for the study
        DELETE FROM dw.card_metrics WHERE as_of_date = @as_of;
        DELETE FROM #dates WHERE as_of_date = @as_of;
    END

    -- Save the results the sell signals read
    TRUNCATE TABLE dw.study_spike_stats;
    INSERT dw.study_spike_stats (spike_speed, spike_momentum, spike_breadth, spikes,
        median_next_30d, share_fell_10pct, share_kept_rising, median_gain_retained)
    SELECT spike_speed, spike_momentum, spike_breadth, spikes, median_next_30d,
           share_fell_10pct, share_kept_rising, median_gain_retained
    FROM dw.vw_study_spike_patterns;

    TRUNCATE TABLE dw.study_peer_stats;
    INSERT dw.study_peer_stats (set_age_bucket, rarity, price_tier, observations,
        median_next_30d, share_fell_10pct, share_rose_10pct)
    SELECT set_age_bucket, rarity, price_tier, observations, median_next_30d,
           share_fell_10pct, share_rose_10pct
    FROM dw.vw_study_peer_baseline
    WHERE set_age_bucket IS NOT NULL AND rarity IS NOT NULL AND price_tier IS NOT NULL;

    TRUNCATE TABLE dw.study_peer_stats_by_age;
    INSERT dw.study_peer_stats_by_age (set_age_bucket, observations, median_next_30d,
        share_fell_10pct, share_rose_10pct)
    SELECT DISTINCT set_age_bucket,
           COUNT(*) OVER (PARTITION BY set_age_bucket),
           CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY fwd_chg_30d)
                OVER (PARTITION BY set_age_bucket) AS DECIMAL(9,4)),
           CAST(AVG(CASE WHEN fwd_chg_30d <= -0.10 THEN 1.0 ELSE 0 END)
                OVER (PARTITION BY set_age_bucket) AS DECIMAL(5,3)),
           CAST(AVG(CASE WHEN fwd_chg_30d >= 0.10 THEN 1.0 ELSE 0 END)
                OVER (PARTITION BY set_age_bucket) AS DECIMAL(5,3))
    FROM dw.study_observation
    WHERE is_spike = 0 AND fwd_chg_30d IS NOT NULL AND set_age_bucket IS NOT NULL;

    -- Summary: overall market drift vs. spikes
    SELECT COUNT(DISTINCT as_of_date)                           AS dates_observed,
           (SELECT COUNT(DISTINCT w.first_date) FROM dw.vw_price_window AS w
            WHERE EXISTS (SELECT 1 FROM dw.study_observation AS o
                          WHERE o.as_of_date BETWEEN w.first_date AND w.last_date)) AS periods_observed,
           MIN(as_of_date)                                       AS first_date,
           MAX(as_of_date)                                       AS last_date,
           COUNT(*)                                              AS observations,
           SUM(CAST(is_spike AS INT))                            AS spikes,
           AVG(CASE WHEN is_spike = 0 THEN fwd_chg_30d END)      AS avg_fwd_30d_non_spike,
           AVG(CASE WHEN is_spike = 1 THEN fwd_chg_30d END)      AS avg_fwd_30d_spike
    FROM dw.study_observation
    WHERE fwd_chg_30d IS NOT NULL;

    SELECT * FROM dw.study_spike_stats ORDER BY spikes DESC;
END
GO
