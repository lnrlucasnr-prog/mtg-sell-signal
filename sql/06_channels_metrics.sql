/* =============================================================================
   06_channels_metrics.sql  -  sell channels, settings and per-card price metrics
   -----------------------------------------------------------------------------
   dw.app_setting        tunable thresholds (min price, spike %, watch %)
   dw.dim_sell_channel   where cards get sold and what each place pays
   dw.vw_channel_value   expected cash / credit per sell candidate per channel
   dw.card_metrics       trend metrics per printing + finish, calculated "as of"
                         a date using only prices known on that date, so the
                         same procedure powers the daily view and the backtest

   Safe to re-run: seed rows are only inserted when missing, so values you
   change later are kept.
============================================================================= */
USE mtg;
GO

/* -----------------------------------------------------------------------------
   SETTINGS
----------------------------------------------------------------------------- */
IF OBJECT_ID('dw.app_setting') IS NULL
CREATE TABLE dw.app_setting (
    setting_name   VARCHAR(50)    NOT NULL PRIMARY KEY,
    setting_value  DECIMAL(12,4)  NOT NULL,
    description    NVARCHAR(300)  NULL
);
GO

INSERT dw.app_setting (setting_name, setting_value, description)
SELECT v.setting_name, v.setting_value, v.description
FROM (VALUES
    ('min_sell_price', 2.00, N'Cards below this market price are "Not worth selling"'),
    ('spike_pct',      0.25, N'30-day rise that counts as a spike (0.25 = +25%)'),
    ('watch_pct',      0.10, N'30-day move (up or down) that puts a card on Watch'),
    ('metrics_retain_days', 7, N'Days of daily card_metrics snapshots to keep')
) AS v(setting_name, setting_value, description)
WHERE NOT EXISTS (SELECT 1 FROM dw.app_setting s WHERE s.setting_name = v.setting_name);
GO

/* -----------------------------------------------------------------------------
   SELL CHANNELS
   uses_buylist = 1  -> cash = the channel's actual buylist offer
   uses_buylist = 0  -> cash = market price x cash_pct_of_market
   credit = cash x (1 + credit_bonus_pct), or market x credit_pct_of_market
----------------------------------------------------------------------------- */
IF OBJECT_ID('dw.dim_sell_channel') IS NULL
CREATE TABLE dw.dim_sell_channel (
    channel_key           INT IDENTITY(1,1) PRIMARY KEY,
    channel_name          NVARCHAR(100) NOT NULL UNIQUE,
    uses_buylist          BIT           NOT NULL,
    buylist_vendor        VARCHAR(20)   NULL,          -- matches fact_buylist_price.vendor
    credit_bonus_pct      DECIMAL(5,4)  NULL,          -- buylist channels
    cash_pct_of_market    DECIMAL(5,4)  NULL,          -- estimate channels
    credit_pct_of_market  DECIMAL(5,4)  NULL,
    is_active             BIT           NOT NULL DEFAULT 1,
    notes                 NVARCHAR(300) NULL
);
GO

INSERT dw.dim_sell_channel (channel_name, uses_buylist, buylist_vendor, credit_bonus_pct,
                            cash_pct_of_market, credit_pct_of_market, notes)
SELECT v.* FROM (VALUES
    (N'Card Kingdom / Mox Boarding House', 1, 'cardkingdom', 0.30, NULL, NULL,
     N'Actual CK buylist offer; CK adds 30% for store credit. Mox drop-offs sell to CK.'),
    (N'Local game store (estimate)', 0, NULL, NULL, 0.50, 0.65,
     N'Typical buylist rates; edit the percentages for a specific store.')
) AS v(channel_name, uses_buylist, buylist_vendor, credit_bonus_pct,
       cash_pct_of_market, credit_pct_of_market, notes)
WHERE NOT EXISTS (SELECT 1 FROM dw.dim_sell_channel c WHERE c.channel_name = v.channel_name);
GO

-- Card Kingdom offers, with the credit bonus read from the channel table
CREATE OR ALTER VIEW dw.vw_current_buylist AS
SELECT b.card_key, c.card_name, c.set_code, b.finish,
       b.price_usd                                       AS ck_cash_usd,
       CAST(b.price_usd * (1 + ISNULL(ch.credit_bonus_pct, 0)) AS DECIMAL(12,2)) AS ck_credit_usd,
       b.valid_from                                      AS offer_since
FROM dw.fact_buylist_price AS b
JOIN dw.dim_card AS c ON c.card_key = b.card_key
LEFT JOIN dw.dim_sell_channel AS ch ON ch.buylist_vendor = b.vendor AND ch.uses_buylist = 1
WHERE b.vendor = 'cardkingdom' AND b.valid_to IS NULL;
GO

-- What each active channel would pay for each sell candidate (one row per card per channel)
CREATE OR ALTER VIEW dw.vw_channel_value AS
SELECT s.card_key, s.finish, s.card_name, s.set_name, s.max_sellable_qty,
       s.current_price_usd                                AS market_price,
       ch.channel_name,
       CASE WHEN ch.uses_buylist = 1 THEN b.price_usd
            ELSE CAST(s.current_price_usd * ch.cash_pct_of_market AS DECIMAL(12,2)) END
                                                          AS cash_per_copy,
       CASE WHEN ch.uses_buylist = 1
                THEN CAST(b.price_usd * (1 + ISNULL(ch.credit_bonus_pct, 0)) AS DECIMAL(12,2))
            ELSE CAST(s.current_price_usd * ch.credit_pct_of_market AS DECIMAL(12,2)) END
                                                          AS credit_per_copy,
       CASE WHEN ch.uses_buylist = 0 THEN NULL
            WHEN b.price_usd IS NULL THEN 0 ELSE 1 END    AS on_buylist
FROM dw.vw_sell_candidates AS s
CROSS JOIN dw.dim_sell_channel AS ch
LEFT JOIN dw.fact_buylist_price AS b
       ON ch.uses_buylist = 1
      AND b.card_key = s.card_key AND b.finish = s.finish
      AND b.vendor = ch.buylist_vendor AND b.valid_to IS NULL
WHERE ch.is_active = 1;
GO

/* -----------------------------------------------------------------------------
   CARD METRICS (as-of snapshots)
----------------------------------------------------------------------------- */
IF OBJECT_ID('dw.card_metrics') IS NULL
CREATE TABLE dw.card_metrics (
    as_of_date              DATE             NOT NULL,
    card_key                INT              NOT NULL,
    finish                  VARCHAR(8)       NOT NULL,
    oracle_id               UNIQUEIDENTIFIER NULL,
    rarity                  NVARCHAR(20)     NULL,
    set_code                NVARCHAR(10)     NULL,
    days_since_release      INT              NULL,
    set_age_bucket          VARCHAR(20)      NULL,
    price_tier              VARCHAR(10)      NULL,
    price_now               DECIMAL(12,2)    NOT NULL,
    price_7d_ago            DECIMAL(12,2)    NULL,
    price_30d_ago           DECIMAL(12,2)    NULL,
    price_90d_ago           DECIMAL(12,2)    NULL,
    chg_7d                  DECIMAL(12,4)     NULL,   -- 0.10 = +10%
    chg_30d                 DECIMAL(12,4)     NULL,
    chg_90d                 DECIMAL(12,4)     NULL,
    high_90d                DECIMAL(12,2)    NULL,
    low_90d                 DECIMAL(12,2)    NULL,
    range_position          DECIMAL(12,4)     NULL,   -- 0 = at 90-day low, 1 = at 90-day high
    spike_share_7d          DECIMAL(12,4)     NULL,   -- share of the 30-day gain made in the last 7 days
    printings_total         INT              NULL,   -- all printings of this card (supply)
    other_printings_priced  INT              NULL,
    other_printings_chg_30d DECIMAL(12,4)     NULL,   -- breadth: are other printings moving too?
    edhrec_rank             INT              NULL,
    CONSTRAINT pk_card_metrics PRIMARY KEY (as_of_date, card_key, finish)
) WITH (DATA_COMPRESSION = PAGE);
GO

CREATE OR ALTER PROCEDURE dw.usp_build_card_metrics
    @as_of DATE = NULL      -- NULL = latest price date
AS
BEGIN
    SET NOCOUNT ON;
    IF @as_of IS NULL
        SELECT @as_of = MAX(valid_from) FROM dw.fact_price;

    DECLARE @d7  DATE = DATEADD(DAY, -7,  @as_of),
            @d30 DATE = DATEADD(DAY, -30, @as_of),
            @d90 DATE = DATEADD(DAY, -90, @as_of),
            @far DATE = '9999-12-31';

    DELETE FROM dw.card_metrics WHERE as_of_date = @as_of;

    -- Only price rows overlapping the 90-day window and known by @as_of (no lookahead)
    WITH pts AS (
        SELECT f.card_key, f.finish,
               MAX(CASE WHEN @as_of BETWEEN f.valid_from AND ISNULL(f.valid_to, @far) THEN f.price_usd END) AS price_now,
               MAX(CASE WHEN @d7    BETWEEN f.valid_from AND ISNULL(f.valid_to, @far) THEN f.price_usd END) AS p7,
               MAX(CASE WHEN @d30   BETWEEN f.valid_from AND ISNULL(f.valid_to, @far) THEN f.price_usd END) AS p30,
               MAX(CASE WHEN @d90   BETWEEN f.valid_from AND ISNULL(f.valid_to, @far) THEN f.price_usd END) AS p90,
               MAX(f.price_usd) AS high_90d,
               MIN(f.price_usd) AS low_90d
        FROM dw.fact_price AS f
        WHERE f.valid_from <= @as_of
          AND ISNULL(f.valid_to, @far) >= @d90
        GROUP BY f.card_key, f.finish
    ), base AS (
        SELECT p.*, c.oracle_id, c.rarity, c.set_code, c.edhrec_rank,
               DATEDIFF(DAY, s.release_date, @as_of) AS days_since_release,
               p.price_now / NULLIF(p.p7,  0) - 1   AS chg_7d,
               p.price_now / NULLIF(p.p30, 0) - 1   AS chg_30d,
               p.price_now / NULLIF(p.p90, 0) - 1   AS chg_90d
        FROM pts AS p
        JOIN dw.dim_card AS c ON c.card_key = p.card_key
        JOIN dw.dim_set  AS s ON s.set_code = c.set_code
        WHERE p.price_now IS NOT NULL
    ), printings AS (
        SELECT oracle_id, COUNT(*) AS printings_total
        FROM dw.dim_card WHERE oracle_id IS NOT NULL
        GROUP BY oracle_id
    ), breadth AS (
        SELECT b.*,
               COUNT(b.chg_30d) OVER (PARTITION BY b.oracle_id, b.finish) AS n_chg,
               SUM(b.chg_30d)   OVER (PARTITION BY b.oracle_id, b.finish) AS sum_chg
        FROM base AS b
    )
    INSERT dw.card_metrics (as_of_date, card_key, finish, oracle_id, rarity, set_code,
        days_since_release, set_age_bucket, price_tier, price_now, price_7d_ago,
        price_30d_ago, price_90d_ago, chg_7d, chg_30d, chg_90d, high_90d, low_90d,
        range_position, spike_share_7d, printings_total, other_printings_priced,
        other_printings_chg_30d, edhrec_rank)
    SELECT @as_of, b.card_key, b.finish, b.oracle_id, b.rarity, b.set_code,
           b.days_since_release,
           CASE WHEN b.days_since_release IS NULL THEN 'Unknown'
                WHEN b.days_since_release < 0    THEN 'Preorder'
                WHEN b.days_since_release <= 30  THEN '0-30 days'
                WHEN b.days_since_release <= 90  THEN '31-90 days'
                WHEN b.days_since_release <= 180 THEN '91-180 days'
                WHEN b.days_since_release <= 365 THEN '181-365 days'
                WHEN b.days_since_release <= 730 THEN '1-2 years'
                ELSE '2+ years' END,
           CASE WHEN b.price_now < 2  THEN 'Under $2'
                WHEN b.price_now < 5  THEN '$2-5'
                WHEN b.price_now < 20 THEN '$5-20'
                WHEN b.price_now < 50 THEN '$20-50'
                ELSE '$50+' END,
           b.price_now, b.p7, b.p30, b.p90,
           b.chg_7d, b.chg_30d, b.chg_90d,
           b.high_90d, b.low_90d,
           (b.price_now - b.low_90d) / NULLIF(b.high_90d - b.low_90d, 0),
           CASE WHEN b.price_now > b.p30
                THEN (b.price_now - b.p7) / NULLIF(b.price_now - b.p30, 0) END,
           pr.printings_total,
           CASE WHEN b.chg_30d IS NULL THEN b.n_chg ELSE b.n_chg - 1 END,
           CASE WHEN b.chg_30d IS NULL THEN b.sum_chg / NULLIF(b.n_chg, 0)
                ELSE (b.sum_chg - b.chg_30d) / NULLIF(b.n_chg - 1, 0) END,
           b.edhrec_rank
    FROM breadth AS b
    LEFT JOIN printings AS pr ON pr.oracle_id = b.oracle_id;

    SELECT @as_of AS as_of_date, COUNT(*) AS cards_measured,
           SUM(CASE WHEN chg_30d IS NOT NULL THEN 1 ELSE 0 END) AS with_30d_history
    FROM dw.card_metrics WHERE as_of_date = @as_of;
END
GO

-- Latest metrics joined to sell candidates: the input to the signal rules (step 4)
CREATE OR ALTER VIEW dw.vw_sell_candidate_metrics AS
SELECT s.card_name, s.set_name, s.max_sellable_qty, s.candidate_reason,
       m.*
FROM dw.vw_sell_candidates AS s
JOIN dw.card_metrics AS m
     ON m.card_key = s.card_key AND m.finish = s.finish
    AND m.as_of_date = (SELECT MAX(as_of_date) FROM dw.card_metrics);
GO
