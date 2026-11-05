/* =============================================================================
   12_tcgcsv_prices.sql  -  daily TCGplayer prices from Feb 2024 (TCGCSV archive)
   -----------------------------------------------------------------------------
   ETL\load_tcgcsv.py reads TCGCSV's daily price archive (https://tcgcsv.com),
   compresses it to change-only rows and stages them here.
   dw.usp_apply_tcgcsv_prices swaps them into dw.fact_price with
   source = 'tcgcsv'.

   Rules
     * Rerunnable: every run replaces ALL tcgcsv rows.
     * Rows end before the regular history (MTGJSON backfill + Scryfall) starts,
       so the sources never overlap. Together they form ONE continuous stretch
       of daily history from Feb 2024 (see dw.vw_price_window).
     * Archived MTGJSON market rows inside the TCGCSV date range (the single-day
       Jul 2025 snapshot) are removed: the continuous daily data replaces them.
       Card Kingdom buylist rows are kept (TCGCSV has no buylist prices).

   Run after 11_archive_prices.sql. Then:
     python ETL\load_tcgcsv.py
     python ETL\refresh_analytics.py --study
============================================================================= */
USE mtg;
GO

IF OBJECT_ID('stg.tcgcsv_price') IS NULL
CREATE TABLE stg.tcgcsv_price (
    scryfall_id   UNIQUEIDENTIFIER NOT NULL,
    finish        VARCHAR(8)       NOT NULL,
    price_usd     DECIMAL(12,2)    NOT NULL,
    valid_from    DATE             NOT NULL,
    valid_to      DATE             NOT NULL
);
GO

IF OBJECT_ID('stg.tcgcsv_overlap') IS NULL
CREATE TABLE stg.tcgcsv_overlap (
    scryfall_id   UNIQUEIDENTIFIER NOT NULL,
    finish        VARCHAR(8)       NOT NULL,
    price_date    DATE             NOT NULL,
    price_usd     DECIMAL(12,2)    NOT NULL
);
GO

CREATE OR ALTER PROCEDURE dw.usp_apply_tcgcsv_prices
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @cutoff DATE = (SELECT MIN(valid_from) FROM dw.fact_price
                            WHERE source NOT IN ('mtgjson_archive', 'tcgcsv')),
            @first  DATE = (SELECT MIN(valid_from) FROM stg.tcgcsv_price),
            @last   DATE = (SELECT MAX(valid_to)   FROM stg.tcgcsv_price),
            @replaced INT = 0;

    IF @cutoff IS NULL
        THROW 50020, 'No regular price history yet; run the daily load first.', 1;
    IF @first IS NULL
        THROW 50021, 'Nothing staged; run ETL\load_tcgcsv.py.', 1;

    BEGIN TRAN;

    DELETE FROM dw.fact_price WHERE source = 'tcgcsv';

    -- Archived single-day/90-day market snapshots inside the TCGCSV range are superseded
    DELETE f
    FROM dw.fact_price AS f
    WHERE f.source = 'mtgjson_archive'
      AND f.valid_from >= @first
      AND f.valid_to   <= @last;
    SET @replaced = @@ROWCOUNT;

    DELETE FROM dw.price_window
    WHERE first_date >= @first AND last_date <= @last;

    INSERT dw.fact_price (card_key, finish, price_usd, valid_from, valid_to, source)
    SELECT c.card_key, t.finish, t.price_usd, t.valid_from,
           CASE WHEN t.valid_to >= @cutoff THEN DATEADD(DAY, -1, @cutoff) ELSE t.valid_to END,
           'tcgcsv'
    FROM stg.tcgcsv_price AS t
    JOIN dw.dim_card AS c ON c.scryfall_id = t.scryfall_id
    WHERE t.valid_from < @cutoff
      AND t.valid_from <= t.valid_to;

    COMMIT;

    SELECT MIN(valid_from)                          AS first_date,
           MAX(valid_to)                            AS last_date,
           COUNT(*)                                 AS price_rows,
           COUNT(DISTINCT CONCAT(card_key, finish)) AS printings,
           @replaced                                AS archive_rows_replaced
    FROM dw.fact_price
    WHERE source = 'tcgcsv';
END
GO

/* Do TCGCSV and the regular history agree on the first regular day?
   High agreement = safe to treat them as one continuous history. */
CREATE OR ALTER VIEW dw.vw_tcgcsv_source_check AS
SELECT o.finish,
       COUNT(*)                                                    AS prices_compared,
       AVG(ABS(o.price_usd - f.price_usd))                         AS avg_abs_diff_usd,
       CAST(100.0 * SUM(CASE WHEN o.price_usd = f.price_usd THEN 1 ELSE 0 END)
            / COUNT(*) AS DECIMAL(5,1))                            AS pct_exact_match,
       CAST(100.0 * SUM(CASE WHEN ABS(o.price_usd - f.price_usd) <= 0.05 * f.price_usd
                             THEN 1 ELSE 0 END)
            / COUNT(*) AS DECIMAL(5,1))                            AS pct_within_5pct
FROM stg.tcgcsv_overlap AS o
JOIN dw.dim_card AS c ON c.scryfall_id = o.scryfall_id
JOIN dw.fact_price AS f
     ON f.card_key = c.card_key
    AND f.finish   = o.finish
    AND f.source NOT IN ('mtgjson_archive', 'tcgcsv')
    AND o.price_date >= f.valid_from
    AND (f.valid_to IS NULL OR o.price_date <= f.valid_to)
GROUP BY o.finish;
GO

/* The study now spreads its dates over the long stretch (see 07_spike_study.sql) */
UPDATE dw.app_setting SET setting_value = 24
WHERE setting_name = 'study_max_dates' AND setting_value < 24;
GO
