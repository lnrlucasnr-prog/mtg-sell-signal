/* =============================================================================
   01_schema.sql  -  MTG database (sell-signal project)
   -----------------------------------------------------------------------------
   Creates the database, schemas, tables and the daily load procedure.

   Layers
     stg  : landing table, truncated and reloaded by Python every day
     dw   : dimensional model (dim_set, dim_card, fact_price)
     etl  : run log

   Price storage design (change-only / Type 2 style)
     Most card prices don't move day to day, so fact_price stores a new row only
     when a price changes. Each row is valid from valid_from until valid_to
     (NULL = current price). One row per printing + finish (nonfoil/foil/etched).
     A missing price in Scryfall means "no listings", not $0, so it never closes
     or overwrites a known price.

   Safe to re-run: every object is created only if it doesn't exist.
============================================================================= */

IF DB_ID('MTG') IS NULL
    CREATE DATABASE MTG;
GO
USE MTG;
GO

IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('dw')  IS NULL EXEC('CREATE SCHEMA dw');
IF SCHEMA_ID('etl') IS NULL EXEC('CREATE SCHEMA etl');
GO

/* -----------------------------------------------------------------------------
   STAGING: one row per Scryfall printing in today's file (already filtered by
   the Python loader to paper, non-digital, English, real game cards).
----------------------------------------------------------------------------- */
IF OBJECT_ID('stg.scryfall_card') IS NULL
CREATE TABLE stg.scryfall_card (
    scryfall_id        UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
    oracle_id          UNIQUEIDENTIFIER NULL,   -- same for every printing of a card
    card_name          NVARCHAR(300)    NOT NULL,
    set_code           NVARCHAR(10)     NOT NULL,
    set_name           NVARCHAR(200)    NOT NULL,
    set_type           NVARCHAR(50)     NULL,
    released_at        DATE             NULL,
    collector_number   NVARCHAR(20)     NOT NULL,
    rarity             NVARCHAR(20)     NULL,
    layout             NVARCHAR(40)     NULL,
    type_line          NVARCHAR(300)    NULL,
    mana_cost          NVARCHAR(150)    NULL,
    cmc                DECIMAL(10,1)     NULL,
    color_identity     NVARCHAR(20)     NULL,   -- e.g. 'B|G'
    finishes           NVARCHAR(60)     NULL,   -- e.g. 'nonfoil|foil'
    is_promo           BIT              NULL,
    is_reprint         BIT              NULL,
    edhrec_rank        INT              NULL,
    legal_commander    NVARCHAR(20)     NULL,
    price_usd          DECIMAL(12,2)    NULL,
    price_usd_foil     DECIMAL(12,2)    NULL,
    price_usd_etched   DECIMAL(12,2)    NULL,
    snapshot_date      DATE             NOT NULL,
    image_url          NVARCHAR(400)    NULL,
    loaded_at          DATETIME2(0)     NOT NULL DEFAULT SYSDATETIME()
);
GO

/* -----------------------------------------------------------------------------
   DIMENSIONS
----------------------------------------------------------------------------- */
IF OBJECT_ID('dw.dim_set') IS NULL
CREATE TABLE dw.dim_set (
    set_code       NVARCHAR(10)  NOT NULL PRIMARY KEY,
    set_name       NVARCHAR(200) NOT NULL,
    set_type       NVARCHAR(50)  NULL,      -- expansion, core, masters, commander...
    release_date   DATE          NULL,      -- earliest released_at seen in the set
    first_seen     DATE          NOT NULL,
    last_updated   DATE          NOT NULL
);
GO

IF OBJECT_ID('dw.dim_card') IS NULL
BEGIN
CREATE TABLE dw.dim_card (
    card_key           INT IDENTITY(1,1) PRIMARY KEY,   -- surrogate key
    scryfall_id        UNIQUEIDENTIFIER NOT NULL UNIQUE, -- one row per printing
    oracle_id          UNIQUEIDENTIFIER NULL,
    card_name          NVARCHAR(300)    NOT NULL,
    set_code           NVARCHAR(10)     NOT NULL REFERENCES dw.dim_set(set_code),
    collector_number   NVARCHAR(20)     NOT NULL,
    rarity             NVARCHAR(20)     NULL,
    layout             NVARCHAR(40)     NULL,
    type_line          NVARCHAR(300)    NULL,
    mana_cost          NVARCHAR(150)    NULL,
    cmc                DECIMAL(10,1)     NULL,
    color_identity     NVARCHAR(20)     NULL,
    finishes           NVARCHAR(60)     NULL,
    is_promo           BIT              NULL,
    is_reprint         BIT              NULL,
    edhrec_rank        INT              NULL,
    legal_commander    NVARCHAR(20)     NULL,
    first_seen         DATE             NOT NULL,
    last_updated       DATE             NOT NULL,
    image_url          NVARCHAR(400)    NULL      -- Scryfall card image (normal size)
);
CREATE INDEX ix_dim_card_oracle ON dw.dim_card(oracle_id);
CREATE INDEX ix_dim_card_name   ON dw.dim_card(card_name);
END
GO

/* -----------------------------------------------------------------------------
   FACT: change-only price history
----------------------------------------------------------------------------- */
IF OBJECT_ID('dw.fact_price') IS NULL
BEGIN
    CREATE TABLE dw.fact_price (
        card_key     INT           NOT NULL REFERENCES dw.dim_card(card_key),
        finish       VARCHAR(8)    NOT NULL
                     CHECK (finish IN ('nonfoil','foil','etched')),
        price_usd    DECIMAL(12,2) NOT NULL,
        valid_from   DATE          NOT NULL,
        valid_to     DATE          NULL,          -- NULL = current price
        source       VARCHAR(20)   NOT NULL DEFAULT 'scryfall',
        CONSTRAINT pk_fact_price PRIMARY KEY (card_key, finish, valid_from)
    ) WITH (DATA_COMPRESSION = PAGE);

    -- Guarantees at most one current price per printing + finish.
    CREATE UNIQUE INDEX ux_fact_price_current
        ON dw.fact_price(card_key, finish) WHERE valid_to IS NULL;
END
GO

/* -----------------------------------------------------------------------------
   ETL run log
----------------------------------------------------------------------------- */
IF OBJECT_ID('etl.load_log') IS NULL
CREATE TABLE etl.load_log (
    run_id            INT IDENTITY(1,1) PRIMARY KEY,
    snapshot_date     DATE         NOT NULL,
    rows_staged       INT          NULL,
    sets_inserted     INT          NULL,
    cards_inserted    INT          NULL,
    cards_updated     INT          NULL,
    prices_new        INT          NULL,   -- first price ever seen for a printing+finish
    prices_changed    INT          NULL,
    run_started       DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    run_finished      DATETIME2(0) NULL,
    status            VARCHAR(20)  NOT NULL DEFAULT 'running'
);
GO

/* Upgrade for databases created before card images were added */
IF COL_LENGTH('stg.scryfall_card', 'image_url') IS NULL
    ALTER TABLE stg.scryfall_card ADD image_url NVARCHAR(400) NULL;
IF COL_LENGTH('dw.dim_card', 'image_url') IS NULL
    ALTER TABLE dw.dim_card ADD image_url NVARCHAR(400) NULL;
GO

/* -----------------------------------------------------------------------------
   LOAD PROCEDURE: staging -> dw. Called by the Python loader after it fills stg.
----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dw.usp_load_snapshot
    @snapshot_date DATE
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- any error rolls back the whole load

    -- Change-only history must move forward in time; older dates need a backfill process.
    IF EXISTS (SELECT 1 FROM dw.fact_price WHERE valid_from > @snapshot_date)
        THROW 50001, 'Snapshot date is older than existing price history. Use a backfill process instead.', 1;

    DECLARE @run_id INT, @sets_ins INT, @cards_ins INT, @cards_upd INT,
            @prices_new INT, @prices_chg INT;
    DECLARE @card_actions TABLE (action NVARCHAR(10));
    DECLARE @set_actions  TABLE (action NVARCHAR(10));

    INSERT etl.load_log (snapshot_date, rows_staged)
    SELECT @snapshot_date, COUNT(*) FROM stg.scryfall_card;
    SET @run_id = SCOPE_IDENTITY();

    BEGIN TRY
    BEGIN TRAN;

    /* 1. Sets: insert new, update changed (Type 1) */
    MERGE dw.dim_set AS t
    USING (
        SELECT set_code,
               MAX(set_name)    AS set_name,
               MAX(set_type)    AS set_type,
               MIN(released_at) AS release_date
        FROM stg.scryfall_card
        GROUP BY set_code
    ) AS s
    ON t.set_code = s.set_code
    WHEN MATCHED AND EXISTS (SELECT s.set_name, s.set_type, s.release_date
                             EXCEPT
                             SELECT t.set_name, t.set_type, t.release_date)
        THEN UPDATE SET set_name = s.set_name, set_type = s.set_type,
                        release_date = s.release_date, last_updated = @snapshot_date
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (set_code, set_name, set_type, release_date, first_seen, last_updated)
             VALUES (s.set_code, s.set_name, s.set_type, s.release_date, @snapshot_date, @snapshot_date)
    OUTPUT $action INTO @set_actions;

    SELECT @sets_ins = COUNT(*) FROM @set_actions WHERE action = 'INSERT';

    /* 2. Cards: insert new printings, update changed attributes (Type 1).
          EXCEPT handles NULLs correctly, unlike <> comparisons. */
    MERGE dw.dim_card AS t
    USING stg.scryfall_card AS s
    ON t.scryfall_id = s.scryfall_id
    WHEN MATCHED AND EXISTS (
            SELECT s.oracle_id, s.card_name, s.set_code, s.collector_number, s.rarity,
                   s.layout, s.type_line, s.mana_cost, s.cmc, s.color_identity, s.finishes,
                   s.is_promo, s.is_reprint, s.edhrec_rank, s.legal_commander, s.image_url
            EXCEPT
            SELECT t.oracle_id, t.card_name, t.set_code, t.collector_number, t.rarity,
                   t.layout, t.type_line, t.mana_cost, t.cmc, t.color_identity, t.finishes,
                   t.is_promo, t.is_reprint, t.edhrec_rank, t.legal_commander, t.image_url)
        THEN UPDATE SET
            oracle_id = s.oracle_id, card_name = s.card_name, set_code = s.set_code,
            collector_number = s.collector_number, rarity = s.rarity, layout = s.layout,
            type_line = s.type_line, mana_cost = s.mana_cost, cmc = s.cmc,
            color_identity = s.color_identity, finishes = s.finishes, is_promo = s.is_promo,
            is_reprint = s.is_reprint, edhrec_rank = s.edhrec_rank,
            legal_commander = s.legal_commander, image_url = s.image_url,
            last_updated = @snapshot_date
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (scryfall_id, oracle_id, card_name, set_code, collector_number, rarity,
                     layout, type_line, mana_cost, cmc, color_identity, finishes, is_promo,
                     is_reprint, edhrec_rank, legal_commander, image_url, first_seen, last_updated)
             VALUES (s.scryfall_id, s.oracle_id, s.card_name, s.set_code, s.collector_number,
                     s.rarity, s.layout, s.type_line, s.mana_cost, s.cmc, s.color_identity,
                     s.finishes, s.is_promo, s.is_reprint, s.edhrec_rank, s.legal_commander,
                     s.image_url, @snapshot_date, @snapshot_date)
    OUTPUT $action INTO @card_actions;

    SELECT @cards_ins = SUM(CASE WHEN action = 'INSERT' THEN 1 ELSE 0 END),
           @cards_upd = SUM(CASE WHEN action = 'UPDATE' THEN 1 ELSE 0 END)
    FROM @card_actions;

    /* 3. Prices: unpivot the three finishes, keep only prices that are new or changed */
    SELECT c.card_key, v.finish, v.price_usd,
           cur.valid_from AS current_valid_from   -- NULL = first price ever seen
    INTO #changes
    FROM stg.scryfall_card AS s
    JOIN dw.dim_card AS c ON c.scryfall_id = s.scryfall_id
    CROSS APPLY (VALUES ('nonfoil', s.price_usd),
                        ('foil',    s.price_usd_foil),
                        ('etched',  s.price_usd_etched)) AS v(finish, price_usd)
    LEFT JOIN dw.fact_price AS cur
           ON cur.card_key = c.card_key
          AND cur.finish   = v.finish
          AND cur.valid_to IS NULL
    WHERE v.price_usd IS NOT NULL
      AND (cur.card_key IS NULL OR cur.price_usd <> v.price_usd);

    SELECT @prices_new = SUM(CASE WHEN current_valid_from IS NULL THEN 1 ELSE 0 END),
           @prices_chg = SUM(CASE WHEN current_valid_from IS NOT NULL THEN 1 ELSE 0 END)
    FROM #changes;

    -- 3a. Re-run on the same day: overwrite today's row instead of opening a new one
    UPDATE f
    SET    price_usd = ch.price_usd
    FROM   dw.fact_price AS f
    JOIN   #changes AS ch
           ON f.card_key = ch.card_key AND f.finish = ch.finish
    WHERE  f.valid_to IS NULL
      AND  f.valid_from = @snapshot_date;

    DELETE FROM #changes WHERE current_valid_from = @snapshot_date;

    -- 3b. Close the current row for prices that changed
    UPDATE f
    SET    valid_to = DATEADD(DAY, -1, @snapshot_date)
    FROM   dw.fact_price AS f
    JOIN   #changes AS ch
           ON f.card_key = ch.card_key AND f.finish = ch.finish
    WHERE  f.valid_to IS NULL;

    -- 3c. Open the new current rows
    INSERT dw.fact_price (card_key, finish, price_usd, valid_from, valid_to)
    SELECT card_key, finish, price_usd, @snapshot_date, NULL
    FROM   #changes;

    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        UPDATE etl.load_log
        SET status = 'failed', run_finished = SYSDATETIME()
        WHERE run_id = @run_id;
        THROW;   -- re-raise so the Python loader sees the error
    END CATCH;

    UPDATE etl.load_log
    SET sets_inserted  = ISNULL(@sets_ins, 0),
        cards_inserted = ISNULL(@cards_ins, 0),
        cards_updated  = ISNULL(@cards_upd, 0),
        prices_new     = ISNULL(@prices_new, 0),
        prices_changed = ISNULL(@prices_chg, 0),
        run_finished   = SYSDATETIME(),
        status         = 'success'
    WHERE run_id = @run_id;

    SELECT * FROM etl.load_log WHERE run_id = @run_id;
END
GO

/* -----------------------------------------------------------------------------
   Convenience view: current price of every printing + finish
----------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dw.vw_current_price AS
SELECT c.card_key, c.card_name, c.set_code, s.set_name, s.set_type, s.release_date,
       c.collector_number, c.rarity, f.finish, f.price_usd,
       f.valid_from AS price_since
FROM dw.fact_price AS f
JOIN dw.dim_card   AS c ON c.card_key = f.card_key
JOIN dw.dim_set    AS s ON s.set_code = c.set_code
WHERE f.valid_to IS NULL;
GO
