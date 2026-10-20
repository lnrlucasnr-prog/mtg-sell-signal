/* =============================================================================
   05_buylist.sql  -  Card Kingdom buylist prices (what CK will PAY for a card)
   -----------------------------------------------------------------------------
   Source: MTGJSON (paper -> cardkingdom -> buylist), loaded by ETL\load_buylist.py
     * Daily:    AllPricesToday file, one day of prices
     * Backfill: AllPrices file, ~90 days of history (run once at setup)

   Design: change-only history like dw.fact_price, kept in its own table so
   market prices and buylist prices never mix.

   Key difference from market prices: if a card is missing from today's
   buylist, Card Kingdom has stopped buying it, so its current row is closed.
   (A missing MARKET price only means no listings, so fact_price never does this.)

   Mox Boarding House drop-offs are sold to Card Kingdom's buylist.
   CK pays a 30% bonus for store credit (see dw.dim_sell_channel in a later script).
============================================================================= */
USE mtg;
GO

/* MTGJSON card uuid -> Scryfall printing, refreshed weekly by the loader */
IF OBJECT_ID('dw.map_mtgjson_scryfall') IS NULL
CREATE TABLE dw.map_mtgjson_scryfall (
    mtgjson_uuid   UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
    scryfall_id    UNIQUEIDENTIFIER NOT NULL,
    refreshed_at   DATETIME2(0)     NOT NULL DEFAULT SYSDATETIME()
);
GO

IF OBJECT_ID('stg.buylist_price') IS NULL
CREATE TABLE stg.buylist_price (
    scryfall_id    UNIQUEIDENTIFIER NOT NULL,
    finish         VARCHAR(8)       NOT NULL,
    price_date     DATE             NOT NULL,
    price_usd      DECIMAL(12,2)    NOT NULL
);
GO

IF OBJECT_ID('stg.buylist_backfill') IS NULL
CREATE TABLE stg.buylist_backfill (
    scryfall_id    UNIQUEIDENTIFIER NOT NULL,
    finish         VARCHAR(8)       NOT NULL,
    price_usd      DECIMAL(12,2)    NOT NULL,
    valid_from     DATE             NOT NULL,
    valid_to       DATE             NULL     -- NULL = still on the buylist at the end of the file
);
GO

IF OBJECT_ID('dw.fact_buylist_price') IS NULL
BEGIN
    CREATE TABLE dw.fact_buylist_price (
        card_key     INT           NOT NULL REFERENCES dw.dim_card(card_key),
        finish       VARCHAR(8)    NOT NULL CHECK (finish IN ('nonfoil','foil','etched')),
        vendor       VARCHAR(20)   NOT NULL DEFAULT 'cardkingdom',
        price_usd    DECIMAL(12,2) NOT NULL,       -- cash offer
        valid_from   DATE          NOT NULL,
        valid_to     DATE          NULL,           -- NULL = currently on the buylist
        source       VARCHAR(20)   NOT NULL,       -- mtgjson_backfill / mtgjson_daily
        CONSTRAINT pk_fact_buylist_price PRIMARY KEY (card_key, finish, vendor, valid_from)
    ) WITH (DATA_COMPRESSION = PAGE);

    CREATE UNIQUE INDEX ux_fact_buylist_current
        ON dw.fact_buylist_price(card_key, finish, vendor) WHERE valid_to IS NULL;
END
GO

IF OBJECT_ID('etl.buylist_log') IS NULL
CREATE TABLE etl.buylist_log (
    run_id          INT IDENTITY(1,1) PRIMARY KEY,
    run_type        VARCHAR(10)  NOT NULL,   -- daily / backfill
    snapshot_date   DATE         NULL,
    rows_staged     INT          NULL,
    prices_new      INT          NULL,
    prices_changed  INT          NULL,
    dropped_off     INT          NULL,
    run_at          DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
GO

/* -----------------------------------------------------------------------------
   Backfill: replaces all Card Kingdom history. Meant to run once, before the
   daily load starts; refuses if daily rows exist unless @force = 1.
----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dw.usp_apply_buylist_backfill
    @force BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @force = 0 AND EXISTS (SELECT 1 FROM dw.fact_buylist_price WHERE source = 'mtgjson_daily')
        THROW 50005, 'Daily buylist rows already exist; rerunning the backfill would remove them. Use @force = 1 to override.', 1;

    BEGIN TRAN;
    DELETE FROM dw.fact_buylist_price
    WHERE vendor = 'cardkingdom' AND source <> 'mtgjson_archive';   -- keep archived seasons (11_archive_prices.sql)

    INSERT dw.fact_buylist_price (card_key, finish, vendor, price_usd, valid_from, valid_to, source)
    SELECT c.card_key, b.finish, 'cardkingdom', b.price_usd, b.valid_from, b.valid_to, 'mtgjson_backfill'
    FROM stg.buylist_backfill AS b
    JOIN dw.dim_card AS c ON c.scryfall_id = b.scryfall_id
    WHERE b.valid_to IS NULL OR b.valid_from <= b.valid_to;
    COMMIT;

    INSERT etl.buylist_log (run_type, rows_staged, prices_new)
    SELECT 'backfill', (SELECT COUNT(*) FROM stg.buylist_backfill), COUNT(*)
    FROM dw.fact_buylist_price WHERE source = 'mtgjson_backfill';

    SELECT COUNT(*)                                   AS history_rows,
           SUM(CASE WHEN valid_to IS NULL THEN 1 ELSE 0 END) AS currently_on_buylist,
           MIN(valid_from)                            AS earliest_date
    FROM dw.fact_buylist_price WHERE vendor = 'cardkingdom';
END
GO

/* -----------------------------------------------------------------------------
   Daily load: change-only, plus closing rows for cards CK no longer buys.
----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dw.usp_load_buylist_snapshot
    @snapshot_date DATE
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- An empty file would otherwise look like "CK stopped buying everything".
    IF NOT EXISTS (SELECT 1 FROM stg.buylist_price)
        THROW 50003, 'Buylist staging is empty; nothing loaded.', 1;
    IF EXISTS (SELECT 1 FROM dw.fact_buylist_price WHERE vendor = 'cardkingdom'
               AND valid_from > @snapshot_date)
        THROW 50004, 'Snapshot date is older than existing buylist history.', 1;

    DECLARE @new INT, @chg INT, @off INT;

    SELECT c.card_key, s.finish, s.price_usd,
           cur.valid_from AS current_valid_from,
           cur.price_usd  AS current_price
    INTO #today
    FROM stg.buylist_price AS s
    JOIN dw.dim_card AS c ON c.scryfall_id = s.scryfall_id
    LEFT JOIN dw.fact_buylist_price AS cur
           ON cur.card_key = c.card_key AND cur.finish = s.finish
          AND cur.vendor = 'cardkingdom' AND cur.valid_to IS NULL
    WHERE s.price_date = @snapshot_date;

    SELECT @new = SUM(CASE WHEN current_valid_from IS NULL THEN 1 ELSE 0 END),
           @chg = SUM(CASE WHEN current_valid_from < @snapshot_date
                            AND current_price <> price_usd THEN 1 ELSE 0 END)
    FROM #today;

    BEGIN TRAN;

    -- 1. Same-day rerun: overwrite today's row in place
    UPDATE f SET price_usd = t.price_usd
    FROM dw.fact_buylist_price AS f
    JOIN #today AS t ON t.card_key = f.card_key AND t.finish = f.finish
    WHERE f.vendor = 'cardkingdom' AND f.valid_to IS NULL
      AND f.valid_from = @snapshot_date AND f.price_usd <> t.price_usd;

    -- 2. Price changed since an earlier day: close the old row...
    UPDATE f SET valid_to = DATEADD(DAY, -1, @snapshot_date)
    FROM dw.fact_buylist_price AS f
    JOIN #today AS t ON t.card_key = f.card_key AND t.finish = f.finish
    WHERE f.vendor = 'cardkingdom' AND f.valid_to IS NULL
      AND f.valid_from < @snapshot_date AND f.price_usd <> t.price_usd;

    -- ...and open new rows for changed prices and cards newly on the buylist
    INSERT dw.fact_buylist_price (card_key, finish, vendor, price_usd, valid_from, valid_to, source)
    SELECT card_key, finish, 'cardkingdom', price_usd, @snapshot_date, NULL, 'mtgjson_daily'
    FROM #today
    WHERE current_valid_from IS NULL
       OR (current_valid_from < @snapshot_date AND current_price <> price_usd);

    -- 3. No longer on the buylist: close the current row
    SELECT @off = COUNT(*)
    FROM dw.fact_buylist_price AS f
    WHERE f.vendor = 'cardkingdom' AND f.valid_to IS NULL
      AND NOT EXISTS (SELECT 1 FROM #today AS t WHERE t.card_key = f.card_key AND t.finish = f.finish);

    DELETE f FROM dw.fact_buylist_price AS f      -- added earlier today, gone on rerun
    WHERE f.vendor = 'cardkingdom' AND f.valid_to IS NULL AND f.valid_from = @snapshot_date
      AND NOT EXISTS (SELECT 1 FROM #today AS t WHERE t.card_key = f.card_key AND t.finish = f.finish);

    UPDATE f SET valid_to = DATEADD(DAY, -1, @snapshot_date)
    FROM dw.fact_buylist_price AS f
    WHERE f.vendor = 'cardkingdom' AND f.valid_to IS NULL AND f.valid_from < @snapshot_date
      AND NOT EXISTS (SELECT 1 FROM #today AS t WHERE t.card_key = f.card_key AND t.finish = f.finish);

    COMMIT;

    INSERT etl.buylist_log (run_type, snapshot_date, rows_staged, prices_new, prices_changed, dropped_off)
    VALUES ('daily', @snapshot_date, (SELECT COUNT(*) FROM stg.buylist_price),
            ISNULL(@new, 0), ISNULL(@chg, 0), ISNULL(@off, 0));

    SELECT TOP 1 * FROM etl.buylist_log ORDER BY run_id DESC;
END
GO

/* Current Card Kingdom offer for every printing + finish they're buying */
CREATE OR ALTER VIEW dw.vw_current_buylist AS
SELECT b.card_key, c.card_name, c.set_code, b.finish,
       b.price_usd           AS ck_cash_usd,
       b.price_usd * 1.30    AS ck_credit_usd,   -- CK's 30% store credit bonus
       b.valid_from          AS offer_since
FROM dw.fact_buylist_price AS b
JOIN dw.dim_card AS c ON c.card_key = b.card_key
WHERE b.vendor = 'cardkingdom' AND b.valid_to IS NULL;
GO
