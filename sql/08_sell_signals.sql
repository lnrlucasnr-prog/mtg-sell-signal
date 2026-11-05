/* =============================================================================
   08_sell_signals.sql  -  Sell now / Watch / Hold for every sell candidate
   -----------------------------------------------------------------------------
   The rules live in ONE function, dw.fn_sell_signal, used by both the live
   signals (dw.vw_sell_signals) and the backtest (09_backtest.sql), so the two
   can never drift apart.

   Signals, most urgent first:
     Sell now     falling, or likely to fall, within the month (and the backtest shows
                  these keep falling: about -20% after 6 months)
     Sell soon    a rising spike: the climb usually continues for a few weeks, but the
                  backtest shows the edge is gone by about 3-6 months. Sell into the rise.
     Watch        a big move with no clear pattern; check weekly
     Hold (rising) Card Kingdom pays market or more (low risk, tends to rise)
     Hold         no reason to sell this month; the long-term direction is uncertain
     Not worth selling  under min_sell_price

   Rules are checked in order; the first match wins. Every threshold lives in
   dw.app_setting, and the spike and peer rules read the saved spike-study
   results, so each weekly study rerun retunes the signals.

     1. Not worth selling   market price below min_sell_price
     2. Sell now            set not released yet (preorder pricing)
     9. Hold (rising)       Card Kingdom's cash offer is at or above market price.
                            The backtest showed these cards usually RISE: CK raises its
                            buylist on demand before the market price catches up.
     3/4/5. Spikes (30-day rise >= spike_pct), judged by their pattern's track record:
          share of similar spikes that fell 10%+  >= spike_sell_fell_share   -> Sell now
          share of similar spikes that kept rising >= spike_hold_rising_share -> Sell soon
          otherwise (or too few examples)                                    -> Watch
     6. Sell now            peers (same set age, rarity, price tier) typically
                            drop peer_sell_threshold or more over the next 30 days
     7. Watch               moved watch_pct or more (either way) in 30 days
     8. Hold                everything else

   Thinly traded cards (no price change in 30 days) get a note: their market
   price is stale, so the Card Kingdom offer is the more reliable value.
============================================================================= */
USE mtg;
GO

INSERT dw.app_setting (setting_name, setting_value, description)
SELECT v.setting_name, v.setting_value, v.description
FROM (VALUES
    ('spike_sell_fell_share',   0.25,  N'Sell a spike when at least this share of similar past spikes fell 10%+ within 30 days'),
    ('spike_hold_rising_share', 0.55,  N'Flag a spike "Sell soon" (sell into the rise) when at least this share of similar past spikes kept rising'),
    ('spike_min_examples',      100,   N'Minimum past spikes in a pattern before its track record is trusted'),
    ('peer_sell_threshold',    -0.05,  N'Sell when similar cards typically drop at least this much over the next 30 days'),
    ('peer_min_examples',       30,    N'Minimum observations in a peer group before it is trusted')
) AS v(setting_name, setting_value, description)
WHERE NOT EXISTS (SELECT 1 FROM dw.app_setting s WHERE s.setting_name = v.setting_name);
GO

UPDATE dw.app_setting
SET description = N'Flag a spike "Sell soon" (sell into the rise) when at least this share of similar past spikes kept rising'
WHERE setting_name = 'spike_hold_rising_share';
GO

/* -----------------------------------------------------------------------------
   THE RULES: one row out per card in
----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dw.fn_sell_signal (
    @price_now               DECIMAL(12,2),
    @set_age_bucket          VARCHAR(20),
    @rarity                  NVARCHAR(20),
    @price_tier              VARCHAR(10),
    @chg_7d                  DECIMAL(12,4),
    @chg_30d                 DECIMAL(12,4),
    @spike_share_7d          DECIMAL(12,4),
    @other_printings_priced  INT,
    @other_printings_chg_30d DECIMAL(12,4),
    @ck_cash_usd             DECIMAL(12,2)
)
RETURNS TABLE
AS
RETURN
WITH cfg AS (
    SELECT MAX(CASE WHEN setting_name = 'min_sell_price'          THEN setting_value END) AS min_price,
           MAX(CASE WHEN setting_name = 'spike_pct'               THEN setting_value END) AS spike_pct,
           MAX(CASE WHEN setting_name = 'watch_pct'               THEN setting_value END) AS watch_pct,
           MAX(CASE WHEN setting_name = 'sharp_spike_share'       THEN setting_value END) AS sharp_share,
           MAX(CASE WHEN setting_name = 'broad_breadth_pct'       THEN setting_value END) AS broad_pct,
           MAX(CASE WHEN setting_name = 'spike_sell_fell_share'   THEN setting_value END) AS sell_fell_share,
           MAX(CASE WHEN setting_name = 'spike_hold_rising_share' THEN setting_value END) AS hold_rising_share,
           MAX(CASE WHEN setting_name = 'spike_min_examples'      THEN setting_value END) AS spike_min_n,
           MAX(CASE WHEN setting_name = 'peer_sell_threshold'     THEN setting_value END) AS peer_sell,
           MAX(CASE WHEN setting_name = 'peer_min_examples'       THEN setting_value END) AS peer_min_n
    FROM dw.app_setting
), c AS (
    SELECT cfg.*,
           CASE WHEN @chg_30d >= cfg.spike_pct THEN 1 ELSE 0 END AS is_spike,
           CASE WHEN @spike_share_7d >= cfg.sharp_share THEN 'Sharp' ELSE 'Gradual' END AS spike_speed,
           CASE WHEN @chg_7d > 0 THEN 'Still rising'
                WHEN @chg_7d < 0 THEN 'Cooling' ELSE 'Flat' END AS spike_momentum,
           CASE WHEN ISNULL(@other_printings_priced, 0) = 0 THEN 'Only priced printing'
                WHEN @other_printings_chg_30d >= cfg.broad_pct THEN 'Broad'
                ELSE 'Single printing' END AS spike_breadth
    FROM cfg
), j AS (
    SELECT c.*,
           sp.spikes            AS pattern_examples,
           sp.share_fell_10pct  AS pattern_share_fell,
           sp.share_kept_rising AS pattern_share_rising,
           COALESCE(pe.median_next_30d, pa.median_next_30d) AS peer_median_next_30d
    FROM c
    LEFT JOIN dw.study_spike_stats AS sp
           ON c.is_spike = 1
          AND sp.spike_speed = c.spike_speed AND sp.spike_momentum = c.spike_momentum
          AND sp.spike_breadth = c.spike_breadth
    LEFT JOIN dw.study_peer_stats AS pe
           ON pe.set_age_bucket = @set_age_bucket AND pe.rarity = @rarity
          AND pe.price_tier = @price_tier AND pe.observations >= c.peer_min_n
    LEFT JOIN dw.study_peer_stats_by_age AS pa
           ON pa.set_age_bucket = @set_age_bucket AND pa.observations >= c.peer_min_n
), r AS (
    SELECT j.*,
           CASE
               WHEN @price_now < j.min_price                          THEN 1
               WHEN @set_age_bucket = 'Preorder'                      THEN 2
               WHEN @ck_cash_usd >= @price_now                        THEN 9
               WHEN j.is_spike = 1 AND j.pattern_examples >= j.spike_min_n
                    AND j.pattern_share_fell >= j.sell_fell_share     THEN 3
               WHEN j.is_spike = 1 AND j.pattern_examples >= j.spike_min_n
                    AND j.pattern_share_rising >= j.hold_rising_share THEN 4
               WHEN j.is_spike = 1                                    THEN 5
               WHEN j.peer_median_next_30d <= j.peer_sell             THEN 6
               WHEN ABS(@chg_30d) >= j.watch_pct                      THEN 7
               ELSE 8
           END AS rule_no
    FROM j
)
SELECT r.rule_no,
       CASE WHEN r.rule_no = 1 THEN 'Not worth selling'
            WHEN r.rule_no IN (2, 3, 6) THEN 'Sell now'
            WHEN r.rule_no = 4 THEN 'Sell soon'
            WHEN r.rule_no = 9 THEN 'Hold (rising)'
            WHEN r.rule_no IN (5, 7) THEN 'Watch'
            ELSE 'Hold' END                                         AS signal,
       CASE WHEN r.rule_no IN (2, 3, 6) THEN 1
            WHEN r.rule_no = 4 THEN 2
            WHEN r.rule_no IN (5, 7) THEN 3
            WHEN r.rule_no = 9 THEN 4
            WHEN r.rule_no = 8 THEN 5
            ELSE 6 END                                              AS signal_sort,
       r.min_price,
       r.is_spike,
       r.spike_speed,
       r.spike_momentum,
       r.spike_breadth,
       r.pattern_examples,
       r.pattern_share_fell,
       r.pattern_share_rising,
       r.peer_median_next_30d
FROM r;
GO

/* The live signals quote backtest results, so the tables they are stored in
   must exist before the view (09_backtest.sql fills them). */
IF OBJECT_ID('dw.backtest_by_horizon') IS NULL
CREATE TABLE dw.backtest_by_horizon (
    horizon_days         INT           NOT NULL,   -- 30, 90, 180, 365
    signal               VARCHAR(20)   NOT NULL,
    signal_sort          INT           NOT NULL,
    observations         INT           NOT NULL,
    median_chg           DECIMAL(9,4)  NULL,
    share_fell_10pct     DECIMAL(5,3)  NULL,
    share_rose_10pct     DECIMAL(5,3)  NULL,
    run_at               DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT pk_backtest_by_horizon PRIMARY KEY (horizon_days, signal)
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

/* -----------------------------------------------------------------------------
   LIVE SIGNALS for your sell candidates
----------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dw.vw_sell_signals AS
SELECT m.card_name,
       m.set_name,
       m.set_code,
       dc.collector_number,                 -- identifies the exact printing (search on Scryfall/TCGplayer)
       m.rarity,
       m.finish,
       m.max_sellable_qty,
       m.candidate_reason,
       s.signal,
       s.signal_sort,
       CASE s.rule_no
           WHEN 1 THEN CONCAT(N'Market price under ', FORMAT(s.min_price, 'C0', 'en-US'),
                              N'; below what stores buy.')
           WHEN 2 THEN N'Set not released yet; preorder prices are usually the highest a card sees.'
           WHEN 9 THEN CONCAT(N'Card Kingdom pays ', FORMAT(b.ck_cash_usd, 'C2', 'en-US'),
                              N' cash, at or above the ', FORMAT(m.price_now, 'C2', 'en-US'),
                              N' market price. CK''s buylist tends to rise before the market',
                              CASE WHEN bt9.avg_next_30d IS NOT NULL
                                   THEN CONCAT(N': in the backtest, cards like this moved ',
                                               FORMAT(bt9.avg_next_30d, 'P0'),
                                               N' on average the next month.')
                                   ELSE N'.' END)
           WHEN 3 THEN CONCAT(N'Up ', FORMAT(m.chg_30d, 'P0'), N' in 30 days (', s.spike_speed, N', ',
                              LOWER(s.spike_momentum), N', ', LOWER(s.spike_breadth), N'). ',
                              FORMAT(s.pattern_share_fell, 'P0'),
                              N' of similar spikes fell 10%+ within a month.')
           WHEN 4 THEN CONCAT(N'Up ', FORMAT(m.chg_30d, 'P0'), N' in 30 days (', s.spike_speed, N', ',
                              LOWER(s.spike_momentum), N', ', LOWER(s.spike_breadth), N'). ',
                              FORMAT(s.pattern_share_rising, 'P0'),
                              N' of similar climbs kept rising, ',
                              CASE WHEN h180.median_chg IS NOT NULL
                                   THEN CONCAT(N'but the gain usually fades (median ',
                                               FORMAT(h90.median_chg, '+0%;-0%;0%'), N' after 3 months, ',
                                               FORMAT(h180.median_chg, '+0%;-0%;0%'), N' after 6). ')
                                   ELSE N'but the gain usually fades within months. ' END,
                              N'Sell into the rise within a few weeks.')
           WHEN 5 THEN CONCAT(N'Up ', FORMAT(m.chg_30d, 'P0'), N' in 30 days (', s.spike_speed, N', ',
                              LOWER(s.spike_momentum), N', ', LOWER(s.spike_breadth),
                              N'). No clear edge either way; check weekly.')
           WHEN 6 THEN CONCAT(N'Set is ', m.set_age_bucket, N' old. Similar cards typically move ',
                              FORMAT(s.peer_median_next_30d, 'P0'), N' over the next month.')
           WHEN 7 THEN CONCAT(N'Moved ', FORMAT(m.chg_30d, 'P0'),
                              N' in 30 days without a clear pattern; check weekly.')
           ELSE CONCAT(N'Stable. Similar cards typically move ',
                       ISNULL(FORMAT(s.peer_median_next_30d, 'P0'), N'about 0%'),
                       N' over the next month. No reason to rush',
                       CASE WHEN h365.share_rose_10pct IS NOT NULL
                            THEN CONCAT(N', but long-term it''s a coin flip: after a year, ',
                                        FORMAT(h365.share_rose_10pct, 'P0'), N' of cards like this were up 10%+ and ',
                                        FORMAT(h365.share_fell_10pct, 'P0'), N' down 10%+.')
                            ELSE N'.' END)
       END                                                          AS signal_reason,
       CASE WHEN m.chg_30d = 0
            THEN N'No price change in 30 days (thinly traded): the CK offer is the more reliable value.'
       END                                                          AS price_note,
       m.price_now                                                  AS market_price,
       m.chg_7d, m.chg_30d, m.chg_90d,
       m.range_position,
       m.set_age_bucket,
       m.days_since_release,
       m.price_tier,
       s.is_spike,
       CASE WHEN s.is_spike = 1 THEN CONCAT(s.spike_speed, N' / ', s.spike_momentum, N' / ', s.spike_breadth) END
                                                                    AS spike_pattern,
       s.pattern_examples,
       s.pattern_share_fell,
       s.pattern_share_rising,
       s.peer_median_next_30d,
       b.ck_cash_usd,
       b.ck_credit_usd,
       CASE WHEN b.ck_cash_usd IS NULL THEN 0 ELSE 1 END            AS on_ck_buylist,
       CASE WHEN b.ck_cash_usd >= m.price_now THEN 1 ELSE 0 END     AS ck_beats_market,
       CAST(m.price_now * lgs.cash_pct_of_market   AS DECIMAL(12,2)) AS lgs_cash_est,
       CAST(m.price_now * lgs.credit_pct_of_market AS DECIMAL(12,2)) AS lgs_credit_est,
       m.max_sellable_qty * b.ck_credit_usd                         AS total_ck_credit,
       m.max_sellable_qty * b.ck_cash_usd                           AS total_ck_cash,
       m.card_key,
       m.oracle_id,
       m.as_of_date,
       dc.image_url,                        -- new columns go at the END (keeps Tableau's CSV layout stable)
       CONCAT(m.card_name, N' · ', UPPER(m.set_code), N' #', dc.collector_number,
              N' (', m.finish, N')')        AS card_label   -- same text as the Card Detail page
FROM dw.vw_sell_candidate_metrics AS m
JOIN dw.dim_card AS dc ON dc.card_key = m.card_key
LEFT JOIN dw.vw_current_buylist AS b
       ON b.card_key = m.card_key AND b.finish = m.finish
CROSS APPLY dw.fn_sell_signal(m.price_now, m.set_age_bucket, m.rarity, m.price_tier,
                              m.chg_7d, m.chg_30d, m.spike_share_7d,
                              m.other_printings_priced, m.other_printings_chg_30d,
                              b.ck_cash_usd) AS s
OUTER APPLY (SELECT TOP 1 cash_pct_of_market, credit_pct_of_market
             FROM dw.dim_sell_channel
             WHERE uses_buylist = 0 AND is_active = 1
             ORDER BY channel_key) AS lgs
OUTER APPLY (SELECT avg_next_30d FROM dw.backtest_by_rule WHERE rule_no = 9) AS bt9
OUTER APPLY (SELECT median_chg FROM dw.backtest_by_horizon
             WHERE signal = 'Sell soon' AND horizon_days = 90)  AS h90
OUTER APPLY (SELECT median_chg FROM dw.backtest_by_horizon
             WHERE signal = 'Sell soon' AND horizon_days = 180) AS h180
OUTER APPLY (SELECT share_rose_10pct, share_fell_10pct FROM dw.backtest_by_horizon
             WHERE signal = 'Hold' AND horizon_days = 365)      AS h365;
GO
