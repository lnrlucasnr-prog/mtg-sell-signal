/* =============================================================================
   11_archive_prices.sql  -  older price history from archived MTGJSON files
   -----------------------------------------------------------------------------
   ETL\load_archive.py reads AllPrices files saved from the Wayback Machine
   (data\raw\archive\), compresses them to change-only rows and stages them
   here. dw.usp_apply_archive_prices then swaps them into the warehouse:

     dw.fact_price           TCGplayer retail (market) prices, source = 'mtgjson_archive'
     dw.fact_buylist_price   Card Kingdom buylist,             source = 'mtgjson_archive'
     dw.price_window         one row per archive file: the dates it covers
                             (created in 07_spike_study.sql, which uses it)

   Rules
     * Rerunnable: every run replaces ALL archive rows with what is staged.
     * Archive rows must end before the regular history starts, and archive
       windows must not overlap each other; the procedure refuses otherwise.
     * The years between windows stay empty. Nothing is interpolated.

   Run order for an existing database: 05 (updated), 07, 09, 10, then this file.
   Then: python ETL\load_archive.py, then python ETL\refresh_analytics.py --study
============================================================================= */
USE mtg;
GO

IF OBJECT_ID('stg.archive_price') IS NULL
CREATE TABLE stg.archive_price (
    file_name     NVARCHAR(200)    NOT NULL,
    kind          VARCHAR(8)       NOT NULL,   -- market / buylist
    scryfall_id   UNIQUEIDENTIFIER NOT NULL,
    finish        VARCHAR(8)       NOT NULL,
    price_usd     DECIMAL(12,2)    NOT NULL,
    valid_from    DATE             NOT NULL,
    valid_to      DATE             NOT NULL
);
GO

IF OBJECT_ID('stg.archive_window') IS NULL
CREATE TABLE stg.archive_window (
    file_name        NVARCHAR(200) NOT NULL PRIMARY KEY,
    first_date       DATE          NOT NULL,
    last_date        DATE          NOT NULL,
    cards_matched    INT           NOT NULL,
    cards_unmatched  INT           NOT NULL
);
GO

CREATE OR ALTER PROCEDURE dw.usp_apply_archive_prices
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @cutoff    DATE = (SELECT MIN(valid_from) FROM dw.fact_price
                               WHERE source <> 'mtgjson_archive'),
            @bl_cutoff DATE = (SELECT MIN(valid_from) FROM dw.fact_buylist_price
                               WHERE source <> 'mtgjson_archive');
    SET @bl_cutoff = ISNULL(@bl_cutoff, '9999-12-31');

    IF @cutoff IS NULL
        THROW 50010, 'No regular price history yet; run the daily load first.', 1;
    IF NOT EXISTS (SELECT 1 FROM stg.archive_window)
        THROW 50011, 'Nothing staged; run ETL\load_archive.py.', 1;
    IF EXISTS (SELECT 1 FROM stg.archive_window AS a
               JOIN stg.archive_window AS b
                 ON a.file_name < b.file_name
                AND a.first_date <= b.last_date AND b.first_date <= a.last_date)
        THROW 50012, 'Two archive files cover overlapping dates; keep only one of them in data\raw\archive.', 1;
    IF EXISTS (SELECT 1 FROM stg.archive_window WHERE last_date >= @cutoff)
        THROW 50013, 'An archive file reaches into the regular price history.', 1;

    BEGIN TRAN;

    DELETE FROM dw.fact_price         WHERE source = 'mtgjson_archive';
    DELETE FROM dw.fact_buylist_price WHERE source = 'mtgjson_archive';
    DELETE FROM dw.price_window;

    INSERT dw.fact_price (card_key, finish, price_usd, valid_from, valid_to, source)
    SELECT c.card_key, a.finish, a.price_usd, a.valid_from, a.valid_to, 'mtgjson_archive'
    FROM stg.archive_price AS a
    JOIN dw.dim_card AS c ON c.scryfall_id = a.scryfall_id
    WHERE a.kind = 'market'
      AND a.valid_to < @cutoff
      AND a.valid_from <= a.valid_to;

    INSERT dw.fact_buylist_price (card_key, finish, vendor, price_usd, valid_from, valid_to, source)
    SELECT c.card_key, a.finish, 'cardkingdom', a.price_usd, a.valid_from, a.valid_to, 'mtgjson_archive'
    FROM stg.archive_price AS a
    JOIN dw.dim_card AS c ON c.scryfall_id = a.scryfall_id
    WHERE a.kind = 'buylist'
      AND a.valid_to < @bl_cutoff
      AND a.valid_from <= a.valid_to;

    INSERT dw.price_window (file_name, first_date, last_date, cards_matched, cards_unmatched,
                            market_rows, buylist_rows)
    SELECT w.file_name, w.first_date, w.last_date, w.cards_matched, w.cards_unmatched,
           (SELECT COUNT(*) FROM dw.fact_price AS f
            WHERE f.source = 'mtgjson_archive' AND f.valid_from BETWEEN w.first_date AND w.last_date),
           (SELECT COUNT(*) FROM dw.fact_buylist_price AS b
            WHERE b.source = 'mtgjson_archive' AND b.valid_from BETWEEN w.first_date AND w.last_date)
    FROM stg.archive_window AS w;

    COMMIT;

    SELECT v.period_name AS window_name, v.first_date, v.last_date,
           DATEDIFF(DAY, v.first_date, v.last_date) + 1 AS days,
           p.market_rows, p.buylist_rows
    FROM dw.price_window AS p
    JOIN dw.vw_price_window AS v ON v.first_date = p.first_date AND v.period_type = 'Archive'
    ORDER BY p.first_date;
END
GO

/* Check: archive rows per window and finish (run after loading) */
-- SELECT v.period_name, f.finish, COUNT(*) AS price_rows, COUNT(DISTINCT f.card_key) AS printings
-- FROM dw.fact_price AS f
-- JOIN dw.vw_price_window AS v ON f.valid_from BETWEEN v.first_date AND v.last_date
-- WHERE f.source = 'mtgjson_archive'
-- GROUP BY v.period_name, v.first_date, f.finish
-- ORDER BY v.first_date, f.finish;
