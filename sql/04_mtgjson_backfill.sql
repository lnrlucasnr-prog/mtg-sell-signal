/* =============================================================================
   04_mtgjson_backfill.sql  -  one-time (rerunnable) 90-day price backfill
   -----------------------------------------------------------------------------
   MTGJSON's AllPrices file holds ~90 days of daily TCGplayer prices. The
   Python script ETL\backfill_mtgjson.py compresses each card's history into
   change-only rows (same design as the daily load) and stages them here.

   Rules
     * Backfill rows are tagged source = 'mtgjson' and only cover dates BEFORE
       the first Scryfall snapshot (the "cutoff"), so the two sources never overlap.
     * Rerunning deletes and reloads the mtgjson rows only; Scryfall rows are untouched.
     * For the cutoff day itself, MTGJSON prices are staged separately and compared
       with Scryfall (dw.vw_backfill_source_check) to validate that the sources agree.
============================================================================= */
USE mtg;
GO

IF OBJECT_ID('stg.price_backfill') IS NULL
CREATE TABLE stg.price_backfill (
    scryfall_id   UNIQUEIDENTIFIER NOT NULL,
    finish        VARCHAR(8)       NOT NULL,
    price_usd     DECIMAL(12,2)    NOT NULL,
    valid_from    DATE             NOT NULL,
    valid_to      DATE             NOT NULL
);
GO

IF OBJECT_ID('stg.price_overlap') IS NULL
CREATE TABLE stg.price_overlap (
    scryfall_id   UNIQUEIDENTIFIER NOT NULL,
    finish        VARCHAR(8)       NOT NULL,
    price_date    DATE             NOT NULL,
    price_usd     DECIMAL(12,2)    NOT NULL
);
GO

CREATE OR ALTER PROCEDURE dw.usp_apply_price_backfill
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @cutoff DATE = (SELECT MIN(valid_from) FROM dw.fact_price WHERE source = 'scryfall');
    IF @cutoff IS NULL
        THROW 50002, 'No Scryfall prices loaded yet; run the daily load first.', 1;

    BEGIN TRAN;

    DELETE FROM dw.fact_price WHERE source = 'mtgjson';

    INSERT dw.fact_price (card_key, finish, price_usd, valid_from, valid_to, source)
    SELECT c.card_key, b.finish, b.price_usd, b.valid_from, b.valid_to, 'mtgjson'
    FROM stg.price_backfill AS b
    JOIN dw.dim_card AS c ON c.scryfall_id = b.scryfall_id
    WHERE b.valid_to < @cutoff
      AND b.valid_from <= b.valid_to;

    COMMIT;

    SELECT @cutoff                                   AS cutoff_date,
           COUNT(*)                                  AS backfill_rows,
           COUNT(DISTINCT CONCAT(card_key, finish))  AS price_series,
           MIN(valid_from)                           AS earliest_date
    FROM dw.fact_price
    WHERE source = 'mtgjson';
END
GO

/* Do MTGJSON and Scryfall agree on the day both have a price?
   If they mostly match, stitching them into one history is valid. */
CREATE OR ALTER VIEW dw.vw_backfill_source_check AS
SELECT o.finish,
       COUNT(*)                                                    AS prices_compared,
       AVG(ABS(o.price_usd - f.price_usd))                         AS avg_abs_diff_usd,
       CAST(100.0 * SUM(CASE WHEN o.price_usd = f.price_usd THEN 1 ELSE 0 END)
            / COUNT(*) AS DECIMAL(5,1))                            AS pct_exact_match,
       CAST(100.0 * SUM(CASE WHEN ABS(o.price_usd - f.price_usd) <= 0.05 * f.price_usd
                             THEN 1 ELSE 0 END)
            / COUNT(*) AS DECIMAL(5,1))                            AS pct_within_5pct
FROM stg.price_overlap AS o
JOIN dw.dim_card AS c ON c.scryfall_id = o.scryfall_id
JOIN dw.fact_price AS f
     ON f.card_key = c.card_key
    AND f.finish   = o.finish
    AND f.source   = 'scryfall'
    AND o.price_date >= f.valid_from
    AND (f.valid_to IS NULL OR o.price_date <= f.valid_to)
GROUP BY o.finish;
GO
