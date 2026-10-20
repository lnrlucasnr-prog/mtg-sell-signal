/* =============================================================================
   03_collection_decks.sql  -  ManaBox collection + deck lists
   -----------------------------------------------------------------------------
   Business rules
     * The ManaBox collection export is the ONLY source of truth for ownership.
       Proxies are excluded from owned quantities.
     * Deck lists come from text exports named by prefix:
         Deck: <name>  -> a list marked as fully built from the collection
         Edit: <name>  -> a target list (may be partly owned or not owned at all)
       A Deck and an Edit with the same name are the current build and its planned upgrade.
     * Ownership and demand are compared at the CARD level (oracle_id), not the
       printing: any printing of Sol Ring satisfies a Sol Ring slot.
     * Demand per card, summed across deck names:
         demand_now           = MAX(Deck qty, Edit qty)   keep what's in use AND what's wanted
         demand_after_upgrade = Edit qty if an Edit exists for that deck, else Deck qty
       Cards owned beyond demand_now are surplus; cards that become surplus only
       after the upgrade are "cut in planned upgrade".

   Each import fully refreshes the collection and deck tables (they are snapshots
   of ManaBox at export time). Safe to re-run this script.
============================================================================= */
USE mtg;
GO

-- Speeds up matching collection rows and deck lines by set + collector number.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_dim_card_set_number'
               AND object_id = OBJECT_ID('dw.dim_card'))
    CREATE INDEX ix_dim_card_set_number ON dw.dim_card(set_code, collector_number);
GO

/* -----------------------------------------------------------------------------
   STAGING (filled by ETL\import_manabox.py)
----------------------------------------------------------------------------- */
IF OBJECT_ID('stg.manabox_collection') IS NULL
CREATE TABLE stg.manabox_collection (
    binder_name        NVARCHAR(200)    NULL,
    binder_type        NVARCHAR(50)     NULL,
    card_name          NVARCHAR(300)    NOT NULL,
    set_code           NVARCHAR(10)     NULL,
    set_name           NVARCHAR(200)    NULL,
    collector_number   NVARCHAR(20)     NULL,
    finish             NVARCHAR(10)     NULL,     -- ManaBox: normal / foil / etched
    rarity             NVARCHAR(20)     NULL,
    quantity           INT              NOT NULL,
    manabox_id         INT              NULL,
    scryfall_id        UNIQUEIDENTIFIER NULL,
    purchase_price     DECIMAL(12,2)    NULL,
    is_misprint        BIT              NULL,
    is_altered         BIT              NULL,
    is_signed          BIT              NULL,
    card_condition     NVARCHAR(30)     NULL,
    card_language      NVARCHAR(10)     NULL,
    is_proxy           BIT              NULL,
    purchase_currency  NVARCHAR(5)      NULL,
    added_at           DATETIME2(0)     NULL,
    source_file        NVARCHAR(260)    NOT NULL,
    file_modified      DATETIME2(0)     NULL
);
GO

IF OBJECT_ID('stg.manabox_deck_line') IS NULL
CREATE TABLE stg.manabox_deck_line (
    source_file        NVARCHAR(260)    NOT NULL,
    list_type          VARCHAR(4)       NOT NULL,  -- Deck / Edit
    deck_name          NVARCHAR(200)    NOT NULL,
    section            NVARCHAR(50)     NOT NULL,  -- MAIN, COMMANDER, ...
    line_no            INT              NOT NULL,
    quantity           INT              NOT NULL,
    card_name          NVARCHAR(300)    NOT NULL,
    set_code           NVARCHAR(10)     NULL,
    collector_number   NVARCHAR(20)     NULL,
    finish             VARCHAR(8)       NULL,
    file_modified      DATETIME2(0)     NULL
);
GO

/* -----------------------------------------------------------------------------
   DW TABLES
----------------------------------------------------------------------------- */
IF OBJECT_ID('dw.fact_collection') IS NULL
CREATE TABLE dw.fact_collection (
    collection_row_id  INT IDENTITY(1,1) PRIMARY KEY,
    card_key           INT              NULL REFERENCES dw.dim_card(card_key),
    oracle_id          UNIQUEIDENTIFIER NULL,
    scryfall_id        UNIQUEIDENTIFIER NULL,     -- as exported by ManaBox
    card_name          NVARCHAR(300)    NOT NULL,
    set_code           NVARCHAR(10)     NULL,
    collector_number   NVARCHAR(20)     NULL,
    finish             VARCHAR(8)       NOT NULL, -- nonfoil / foil / etched (matches fact_price)
    quantity           INT              NOT NULL,
    binder_name        NVARCHAR(200)    NULL,
    binder_type        NVARCHAR(50)     NULL,
    card_condition     NVARCHAR(30)     NULL,
    card_language      NVARCHAR(10)     NULL,
    is_proxy           BIT              NOT NULL,
    purchase_price     DECIMAL(12,2)    NULL,
    added_at           DATETIME2(0)     NULL,
    match_method       VARCHAR(20)      NOT NULL, -- scryfall_id / set_number / name / unmatched
    import_date        DATE             NOT NULL
);
GO

IF OBJECT_ID('dw.dim_deck') IS NULL
CREATE TABLE dw.dim_deck (
    deck_key           INT IDENTITY(1,1) PRIMARY KEY,
    deck_name          NVARCHAR(200)    NOT NULL,
    list_type          VARCHAR(4)       NOT NULL CHECK (list_type IN ('Deck','Edit')),
    source_file        NVARCHAR(260)    NULL,
    file_modified      DATETIME2(0)     NULL,
    is_active          BIT              NOT NULL DEFAULT 1,  -- 0 = file no longer exported
    first_imported     DATE             NOT NULL,
    last_imported      DATE             NOT NULL,
    CONSTRAINT uq_dim_deck UNIQUE (deck_name, list_type)
);
GO

IF OBJECT_ID('dw.fact_deck_card') IS NULL
CREATE TABLE dw.fact_deck_card (
    deck_key           INT              NOT NULL REFERENCES dw.dim_deck(deck_key),
    line_no            INT              NOT NULL,
    oracle_id          UNIQUEIDENTIFIER NULL,     -- NULL = could not be matched
    card_key           INT              NULL,     -- the printing listed, when it matched
    card_name          NVARCHAR(300)    NOT NULL,
    section            NVARCHAR(50)     NOT NULL,
    quantity           INT              NOT NULL,
    match_method       VARCHAR(20)      NOT NULL,
    CONSTRAINT pk_fact_deck_card PRIMARY KEY (deck_key, line_no)
);
GO

IF OBJECT_ID('etl.import_log') IS NULL
CREATE TABLE etl.import_log (
    run_id               INT IDENTITY(1,1) PRIMARY KEY,
    import_date          DATE         NOT NULL,
    collection_rows      INT          NULL,
    collection_cards     INT          NULL,   -- total quantity
    collection_unmatched INT          NULL,
    deck_lists           INT          NULL,
    deck_lines           INT          NULL,
    deck_lines_unmatched INT          NULL,
    run_started          DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    run_finished         DATETIME2(0) NULL,
    status               VARCHAR(20)  NOT NULL DEFAULT 'running'
);
GO

/* -----------------------------------------------------------------------------
   LOAD PROCEDURE
----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dw.usp_load_manabox
    @import_date DATE
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @run_id INT;
    INSERT etl.import_log (import_date) VALUES (@import_date);
    SET @run_id = SCOPE_IDENTITY();

    BEGIN TRY
    BEGIN TRAN;

    /* 1. Collection: full refresh. Match by Scryfall ID, then set + collector
          number (covers non-English printings), then exact card name. */
    TRUNCATE TABLE dw.fact_collection;

    INSERT dw.fact_collection (card_key, oracle_id, scryfall_id, card_name, set_code,
        collector_number, finish, quantity, binder_name, binder_type, card_condition,
        card_language, is_proxy, purchase_price, added_at, match_method, import_date)
    SELECT
        COALESCE(m1.card_key, m2.card_key, m3.card_key),
        COALESCE(m1.oracle_id, m2.oracle_id, m3.oracle_id),
        s.scryfall_id, s.card_name, s.set_code, s.collector_number,
        CASE LOWER(s.finish) WHEN 'foil' THEN 'foil' WHEN 'etched' THEN 'etched' ELSE 'nonfoil' END,
        s.quantity, s.binder_name, s.binder_type, s.card_condition, s.card_language,
        ISNULL(s.is_proxy, 0), s.purchase_price, s.added_at,
        CASE WHEN m1.card_key IS NOT NULL THEN 'scryfall_id'
             WHEN m2.card_key IS NOT NULL THEN 'set_number'
             WHEN m3.card_key IS NOT NULL THEN 'name'
             ELSE 'unmatched' END,
        @import_date
    FROM stg.manabox_collection AS s
    LEFT JOIN dw.dim_card AS m1 ON m1.scryfall_id = s.scryfall_id
    OUTER APPLY (SELECT TOP 1 d.card_key, d.oracle_id FROM dw.dim_card AS d
                 WHERE m1.card_key IS NULL
                   AND d.set_code = s.set_code AND d.collector_number = s.collector_number) AS m2
    OUTER APPLY (SELECT TOP 1 d.card_key, d.oracle_id FROM dw.dim_card AS d
                 WHERE m1.card_key IS NULL AND m2.card_key IS NULL
                   AND d.card_name = s.card_name
                 ORDER BY d.card_key) AS m3;

    /* 2. Deck lists: keep stable keys, mark lists that are no longer exported as inactive */
    MERGE dw.dim_deck AS t
    USING (SELECT deck_name, list_type, MAX(source_file) AS source_file,
                  MAX(file_modified) AS file_modified
           FROM stg.manabox_deck_line GROUP BY deck_name, list_type) AS s
    ON t.deck_name = s.deck_name AND t.list_type = s.list_type
    WHEN MATCHED THEN UPDATE SET source_file = s.source_file, file_modified = s.file_modified,
                                 is_active = 1, last_imported = @import_date
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (deck_name, list_type, source_file, file_modified, is_active, first_imported, last_imported)
        VALUES (s.deck_name, s.list_type, s.source_file, s.file_modified, 1, @import_date, @import_date)
    WHEN NOT MATCHED BY SOURCE THEN UPDATE SET is_active = 0;

    /* 3. Deck cards: full refresh. Match by set + collector number, then exact
          name, then front-face name for double-faced cards ("Name // Back"). */
    DELETE FROM dw.fact_deck_card;

    INSERT dw.fact_deck_card (deck_key, line_no, oracle_id, card_key, card_name,
                              section, quantity, match_method)
    SELECT d.deck_key, s.line_no,
           COALESCE(m1.oracle_id, m2.oracle_id, m3.oracle_id),
           m1.card_key,
           s.card_name, s.section, s.quantity,
           CASE WHEN m1.oracle_id IS NOT NULL THEN 'set_number'
                WHEN m2.oracle_id IS NOT NULL THEN 'name'
                WHEN m3.oracle_id IS NOT NULL THEN 'front_face'
                ELSE 'unmatched' END
    FROM stg.manabox_deck_line AS s
    JOIN dw.dim_deck AS d ON d.deck_name = s.deck_name AND d.list_type = s.list_type
    OUTER APPLY (SELECT TOP 1 c.card_key, c.oracle_id FROM dw.dim_card AS c
                 WHERE c.set_code = s.set_code AND c.collector_number = s.collector_number) AS m1
    OUTER APPLY (SELECT TOP 1 c.oracle_id FROM dw.dim_card AS c
                 WHERE m1.oracle_id IS NULL AND c.card_name = s.card_name) AS m2
    OUTER APPLY (SELECT TOP 1 c.oracle_id FROM dw.dim_card AS c
                 WHERE m1.oracle_id IS NULL AND m2.oracle_id IS NULL
                   AND c.card_name LIKE s.card_name + N' // %') AS m3;

    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        UPDATE etl.import_log SET status = 'failed', run_finished = SYSDATETIME()
        WHERE run_id = @run_id;
        THROW;
    END CATCH;

    UPDATE etl.import_log
    SET collection_rows      = (SELECT COUNT(*) FROM dw.fact_collection),
        collection_cards     = (SELECT ISNULL(SUM(quantity), 0) FROM dw.fact_collection),
        collection_unmatched = (SELECT COUNT(*) FROM dw.fact_collection WHERE match_method = 'unmatched'),
        deck_lists           = (SELECT COUNT(*) FROM dw.dim_deck WHERE is_active = 1),
        deck_lines           = (SELECT COUNT(*) FROM dw.fact_deck_card),
        deck_lines_unmatched = (SELECT COUNT(*) FROM dw.fact_deck_card WHERE match_method = 'unmatched'),
        run_finished         = SYSDATETIME(),
        status               = 'success'
    WHERE run_id = @run_id;

    SELECT * FROM etl.import_log WHERE run_id = @run_id;
END
GO

/* -----------------------------------------------------------------------------
   VIEWS
----------------------------------------------------------------------------- */

-- One row per card (oracle_id): how many copies the decks need, now and after upgrades.
CREATE OR ALTER VIEW dw.vw_card_demand AS
WITH lines AS (
    SELECT d.deck_name, d.list_type, f.oracle_id, SUM(f.quantity) AS qty
    FROM dw.fact_deck_card AS f
    JOIN dw.dim_deck AS d ON d.deck_key = f.deck_key
    WHERE d.is_active = 1
      AND f.oracle_id IS NOT NULL
      AND f.section NOT IN ('MAYBEBOARD', 'CONSIDERING', 'SIDEBOARD')
    GROUP BY d.deck_name, d.list_type, f.oracle_id
), per_deck AS (
    SELECT deck_name, oracle_id,
           SUM(CASE WHEN list_type = 'Deck' THEN qty END) AS deck_qty,
           SUM(CASE WHEN list_type = 'Edit' THEN qty END) AS edit_qty
    FROM lines
    GROUP BY deck_name, oracle_id
), decks_with_edit AS (
    SELECT DISTINCT deck_name FROM dw.dim_deck WHERE is_active = 1 AND list_type = 'Edit'
)
SELECT p.oracle_id,
       SUM(ISNULL(p.deck_qty, 0))                                        AS committed_qty,
       SUM(GREATEST(ISNULL(p.deck_qty, 0), ISNULL(p.edit_qty, 0)))       AS demand_now,
       SUM(CASE WHEN e.deck_name IS NOT NULL THEN ISNULL(p.edit_qty, 0)
                ELSE ISNULL(p.deck_qty, 0) END)                          AS demand_after_upgrade,
       COUNT(p.deck_qty)                                                 AS in_deck_lists,
       COUNT(p.edit_qty)                                                 AS in_edit_lists
FROM per_deck AS p
LEFT JOIN decks_with_edit AS e ON e.deck_name = p.deck_name
GROUP BY p.oracle_id;
GO

-- One row per card: owned vs. needed, and the resulting surplus.
CREATE OR ALTER VIEW dw.vw_card_position AS
WITH owned AS (
    SELECT oracle_id, SUM(quantity) AS owned_qty
    FROM dw.fact_collection
    WHERE is_proxy = 0 AND oracle_id IS NOT NULL
    GROUP BY oracle_id
), card_info AS (
    SELECT oracle_id, MAX(card_name) AS card_name,
           MAX(CASE WHEN type_line LIKE N'Basic Land%' THEN 1 ELSE 0 END) AS is_basic_land
    FROM dw.dim_card
    WHERE oracle_id IN (SELECT oracle_id FROM owned UNION SELECT oracle_id FROM dw.vw_card_demand)
    GROUP BY oracle_id
)
SELECT COALESCE(o.oracle_id, d.oracle_id)                     AS oracle_id,
       i.card_name,
       ISNULL(i.is_basic_land, 0)                             AS is_basic_land,
       ISNULL(o.owned_qty, 0)                                 AS owned_qty,
       ISNULL(d.committed_qty, 0)                             AS committed_qty,
       ISNULL(d.demand_now, 0)                                AS demand_now,
       ISNULL(d.demand_after_upgrade, 0)                      AS demand_after_upgrade,
       ISNULL(d.in_deck_lists, 0)                             AS in_deck_lists,
       ISNULL(d.in_edit_lists, 0)                             AS in_edit_lists,
       ISNULL(o.owned_qty, 0) - ISNULL(d.demand_now, 0)           AS surplus_now,
       ISNULL(o.owned_qty, 0) - ISNULL(d.demand_after_upgrade, 0) AS surplus_after_upgrade
FROM owned AS o
FULL JOIN dw.vw_card_demand AS d ON d.oracle_id = o.oracle_id
LEFT JOIN card_info AS i ON i.oracle_id = COALESCE(o.oracle_id, d.oracle_id);
GO

-- Buy list: every card in an Edit list you don't own enough copies of,
-- priced at the cheapest current printing.
CREATE OR ALTER VIEW dw.vw_buy_list AS
SELECT d.deck_name,
       f.card_name,
       f.section,
       f.quantity                                              AS needed_qty,
       ISNULL(p.owned_qty, 0)                                  AS owned_qty,
       ISNULL(p.committed_qty, 0)                              AS used_in_built_decks,
       GREATEST(f.quantity - ISNULL(p.owned_qty, 0), 0)        AS missing_qty,
       cp.cheapest_usd,
       GREATEST(f.quantity - ISNULL(p.owned_qty, 0), 0) * cp.cheapest_usd AS est_cost_usd,
       f.match_method
FROM dw.fact_deck_card AS f
JOIN dw.dim_deck AS d ON d.deck_key = f.deck_key
LEFT JOIN dw.vw_card_position AS p ON p.oracle_id = f.oracle_id
OUTER APPLY (SELECT MIN(fp.price_usd) AS cheapest_usd
             FROM dw.dim_card AS c
             JOIN dw.fact_price AS fp ON fp.card_key = c.card_key AND fp.valid_to IS NULL
             WHERE c.oracle_id = f.oracle_id) AS cp
WHERE d.list_type = 'Edit' AND d.is_active = 1;
GO

-- Data-quality check: cards in "Deck:" lists (marked fully owned) that the
-- collection can't cover, or that couldn't be matched to a card at all.
CREATE OR ALTER VIEW dw.vw_deck_shortages AS
SELECT d.deck_name,
       f.card_name,
       f.quantity                       AS deck_qty,
       ISNULL(p.owned_qty, 0)           AS owned_qty,
       ISNULL(p.committed_qty, 0)       AS needed_across_built_decks,
       CASE WHEN f.oracle_id IS NULL THEN 'Card not matched'
            WHEN ISNULL(p.owned_qty, 0) = 0 THEN 'Not in collection'
            ELSE 'Shared across decks: not enough copies' END AS issue
FROM dw.fact_deck_card AS f
JOIN dw.dim_deck AS d ON d.deck_key = f.deck_key
LEFT JOIN dw.vw_card_position AS p ON p.oracle_id = f.oracle_id
WHERE d.list_type = 'Deck' AND d.is_active = 1
  AND f.section NOT IN ('MAYBEBOARD', 'CONSIDERING', 'SIDEBOARD')
  AND (f.oracle_id IS NULL OR ISNULL(p.owned_qty, 0) < ISNULL(p.committed_qty, 0));
GO

-- Sell candidates: owned printings of cards no deck needs (or that a planned
-- upgrade cuts), with today's price. Basic lands excluded.
CREATE OR ALTER VIEW dw.vw_sell_candidates AS
WITH by_binder AS (
    SELECT card_key, oracle_id, finish, binder_name,
           SUM(quantity) AS qty,
           SUM(purchase_price * quantity) AS cost
    FROM dw.fact_collection
    WHERE is_proxy = 0 AND card_key IS NOT NULL
    GROUP BY card_key, oracle_id, finish, binder_name
), holdings AS (
    SELECT card_key, oracle_id, finish,
           SUM(qty) AS qty,
           SUM(cost) / NULLIF(SUM(qty), 0) AS avg_purchase_price,
           STRING_AGG(binder_name, ', ') AS binders
    FROM by_binder
    GROUP BY card_key, oracle_id, finish
)
SELECT c.card_name,
       c.set_code,
       s.set_name,
       s.set_type,
       s.release_date,
       c.rarity,
       h.finish,
       h.qty                                   AS printing_qty,
       p.owned_qty                             AS card_owned_total,
       p.demand_now,
       p.demand_after_upgrade,
       CASE WHEN p.surplus_now > 0 THEN 'Not needed by any deck'
            ELSE 'Cut in planned upgrade' END  AS candidate_reason,
       LEAST(h.qty, CASE WHEN p.surplus_now > 0 THEN p.surplus_now
                         ELSE p.surplus_after_upgrade END) AS max_sellable_qty,
       fp.price_usd                            AS current_price_usd,
       fp.valid_from                           AS price_since,
       h.avg_purchase_price,
       fp.price_usd - h.avg_purchase_price     AS gain_per_copy_usd,
       h.binders,
       h.card_key,
       h.oracle_id
FROM holdings AS h
JOIN dw.vw_card_position AS p ON p.oracle_id = h.oracle_id
JOIN dw.dim_card AS c ON c.card_key = h.card_key
JOIN dw.dim_set  AS s ON s.set_code = c.set_code
LEFT JOIN dw.fact_price AS fp
       ON fp.card_key = h.card_key AND fp.finish = h.finish AND fp.valid_to IS NULL
WHERE p.is_basic_land = 0
  AND (p.surplus_now > 0 OR p.surplus_after_upgrade > 0);
GO

-- Everything that didn't match, for review after each import.
CREATE OR ALTER VIEW dw.vw_import_issues AS
SELECT 'collection' AS source, binder_name AS list_name, card_name, set_code,
       collector_number, quantity
FROM dw.fact_collection WHERE match_method = 'unmatched'
UNION ALL
SELECT 'deck', d.list_type + ': ' + d.deck_name, f.card_name, NULL, NULL, f.quantity
FROM dw.fact_deck_card AS f
JOIN dw.dim_deck AS d ON d.deck_key = f.deck_key
WHERE f.match_method = 'unmatched';
GO
