/* =============================================================================
   13_packs.sql  -  "Which pack should I open for my decks?"
   -----------------------------------------------------------------------------
   A just-for-fun view: for every card my Edit decks still need, which sets and
   packs contain it, and the chance of pulling something I want from each pack.
   (Buying singles is always the cheaper way to finish a deck; this is for when
   I want to open a pack anyway.)

   Source: MTGJSON's booster layouts (AllPrintings), loaded by ETL\load_boosters.py.
   For each set and pack type (Play Booster, Collector Booster, ...) MTGJSON lists:
     * pack configurations, each with a weight (how often that layout occurs)
     * for each configuration, how many cards come from each "sheet" (slot)
     * for each sheet, the cards on it and their weights (how often each appears)

   Odds, per pack:
     chance a sheet pick is a wanted card  p = (weight of wanted cards) / (sheet total weight)
     chance a configuration misses           = product over its sheets of (1 - p) ^ picks
     chance of at least one wanted card      = sum over configurations of
                                               (configuration share) * (1 - chance it misses)
   Picks are treated as independent draws, a close approximation for real packs.

   Pack kinds (dw.vw_pack_type): "Shelf pack" = Play / Draft / Set / Collector /
   Jumpstart boosters of regular sets; "Special product" = fixed or near-fixed
   contents (Secret Lair bonus cards, Signature Spellbooks, theme boosters, promos).

   Views (all read the CURRENT collection and Edit decks, so they update daily):
     dw.vw_pack_options        one row per set + pack type that has a wanted card
     dw.vw_pack_card_odds      one row per wanted card per pack it can come from
     dw.vw_pack_value          average total value of a whole pack (market and
                               Card Kingdom buylist), for every pack type
     dw.vw_wanted_card_sources every wanted card: which sets it was printed in and
                               whether any pack has it (or it is singles-only)

   Optional: dw.pack_price holds prices typed in by hand (what the shop charges),
   to show cost per wanted card. Leave it empty if you don't care.
============================================================================= */
USE mtg;
GO

/* Upgrade: pack type and sheet names can be long (e.g. Secret Lair bonus packs).
   Booster tables from the first version (VARCHAR(40)) are dropped and recreated;
   they only hold loaded data, refilled by ETL\load_boosters.py. */
IF COL_LENGTH('dw.booster_config', 'booster_type') < 150
BEGIN
    DROP TABLE IF EXISTS dw.booster_sheet_card, dw.booster_sheet, dw.booster_config_sheet,
                         dw.booster_config, dw.booster_set,
                         stg.booster_sheet_card, stg.booster_sheet, stg.booster_config_sheet,
                         stg.booster_config, stg.booster_set;
    IF NOT EXISTS (SELECT 1 FROM dw.pack_price) DROP TABLE IF EXISTS dw.pack_price;
END
GO

/* ---------- staging (filled by ETL\load_boosters.py) ---------- */
IF OBJECT_ID('stg.booster_set') IS NULL
CREATE TABLE stg.booster_set (
    set_code      VARCHAR(10)   NOT NULL,
    set_name      NVARCHAR(200) NOT NULL,
    release_date  DATE          NULL
);
IF OBJECT_ID('stg.booster_config') IS NULL
CREATE TABLE stg.booster_config (
    set_code            VARCHAR(10)   NOT NULL,
    booster_type        VARCHAR(150)   NOT NULL,
    booster_name        NVARCHAR(200) NULL,
    config_no           INT           NOT NULL,
    config_weight       BIGINT        NOT NULL,
    total_config_weight BIGINT        NOT NULL
);
IF OBJECT_ID('stg.booster_config_sheet') IS NULL
CREATE TABLE stg.booster_config_sheet (
    set_code      VARCHAR(10)  NOT NULL,
    booster_type  VARCHAR(150)  NOT NULL,
    config_no     INT          NOT NULL,
    sheet_name    VARCHAR(150)  NOT NULL,
    picks         INT          NOT NULL
);
IF OBJECT_ID('stg.booster_sheet') IS NULL
CREATE TABLE stg.booster_sheet (
    set_code      VARCHAR(10)  NOT NULL,
    booster_type  VARCHAR(150)  NOT NULL,
    sheet_name    VARCHAR(150)  NOT NULL,
    total_weight  BIGINT       NOT NULL,
    is_foil       BIT          NOT NULL
);
IF OBJECT_ID('stg.booster_sheet_card') IS NULL
CREATE TABLE stg.booster_sheet_card (
    set_code      VARCHAR(10)      NOT NULL,
    booster_type  VARCHAR(150)      NOT NULL,
    sheet_name    VARCHAR(150)      NOT NULL,
    mtgjson_uuid  UNIQUEIDENTIFIER NOT NULL,
    scryfall_id   UNIQUEIDENTIFIER NULL,     -- NULL = card from another set; mapped in SQL
    card_weight   BIGINT           NOT NULL
);
GO

/* ---------- warehouse copies ---------- */
IF OBJECT_ID('dw.booster_set') IS NULL
CREATE TABLE dw.booster_set (
    set_code      VARCHAR(10)   NOT NULL PRIMARY KEY,   -- MTGJSON code (upper case)
    set_name      NVARCHAR(200) NOT NULL,
    release_date  DATE          NULL,
    loaded_at     DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME()
);
IF OBJECT_ID('dw.booster_config') IS NULL
CREATE TABLE dw.booster_config (
    set_code            VARCHAR(10)   NOT NULL,
    booster_type        VARCHAR(150)   NOT NULL,
    booster_name        NVARCHAR(200) NULL,
    config_no           INT           NOT NULL,
    config_weight       BIGINT        NOT NULL,
    total_config_weight BIGINT        NOT NULL,
    CONSTRAINT pk_booster_config PRIMARY KEY (set_code, booster_type, config_no)
);
IF OBJECT_ID('dw.booster_config_sheet') IS NULL
CREATE TABLE dw.booster_config_sheet (
    set_code      VARCHAR(10)  NOT NULL,
    booster_type  VARCHAR(150)  NOT NULL,
    config_no     INT          NOT NULL,
    sheet_name    VARCHAR(150)  NOT NULL,
    picks         INT          NOT NULL,
    CONSTRAINT pk_booster_config_sheet PRIMARY KEY (set_code, booster_type, config_no, sheet_name)
);
IF OBJECT_ID('dw.booster_sheet') IS NULL
CREATE TABLE dw.booster_sheet (
    set_code      VARCHAR(10)  NOT NULL,
    booster_type  VARCHAR(150)  NOT NULL,
    sheet_name    VARCHAR(150)  NOT NULL,
    total_weight  BIGINT       NOT NULL,
    is_foil       BIT          NOT NULL,
    CONSTRAINT pk_booster_sheet PRIMARY KEY (set_code, booster_type, sheet_name)
);
IF OBJECT_ID('dw.booster_sheet_card') IS NULL
CREATE TABLE dw.booster_sheet_card (
    set_code      VARCHAR(10)      NOT NULL,
    booster_type  VARCHAR(150)      NOT NULL,
    sheet_name    VARCHAR(150)      NOT NULL,
    mtgjson_uuid  UNIQUEIDENTIFIER NOT NULL,
    card_key      INT              NULL,     -- NULL = printing not in dim_card (e.g. non-English)
    card_weight   BIGINT           NOT NULL,
    CONSTRAINT pk_booster_sheet_card PRIMARY KEY (set_code, booster_type, sheet_name, mtgjson_uuid)
) WITH (DATA_COMPRESSION = PAGE);
GO

/* Optional: what the shop charges, typed in by hand */
IF OBJECT_ID('dw.pack_price') IS NULL
CREATE TABLE dw.pack_price (
    set_code      VARCHAR(10)   NOT NULL,     -- MTGJSON code, e.g. 'DSK'
    booster_type  VARCHAR(150)   NOT NULL,     -- e.g. 'play', 'collector'
    price_usd     DECIMAL(8,2)  NOT NULL,
    updated_on    DATE          NOT NULL DEFAULT CAST(GETDATE() AS DATE),
    CONSTRAINT pk_pack_price PRIMARY KEY (set_code, booster_type)
);
GO

/* ---------- apply: replaces all booster data ---------- */
CREATE OR ALTER PROCEDURE dw.usp_apply_boosters
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM stg.booster_sheet_card)
        THROW 50030, 'Nothing staged; run ETL\load_boosters.py.', 1;

    BEGIN TRAN;
    DELETE FROM dw.booster_sheet_card;
    DELETE FROM dw.booster_sheet;
    DELETE FROM dw.booster_config_sheet;
    DELETE FROM dw.booster_config;
    DELETE FROM dw.booster_set;

    INSERT dw.booster_set (set_code, set_name, release_date)
    SELECT set_code, MAX(set_name), MAX(release_date) FROM stg.booster_set GROUP BY set_code;

    INSERT dw.booster_config (set_code, booster_type, booster_name, config_no, config_weight, total_config_weight)
    SELECT set_code, booster_type, booster_name, config_no, config_weight, total_config_weight
    FROM stg.booster_config;

    INSERT dw.booster_config_sheet (set_code, booster_type, config_no, sheet_name, picks)
    SELECT set_code, booster_type, config_no, sheet_name, SUM(picks)
    FROM stg.booster_config_sheet
    GROUP BY set_code, booster_type, config_no, sheet_name;

    INSERT dw.booster_sheet (set_code, booster_type, sheet_name, total_weight, is_foil)
    SELECT set_code, booster_type, sheet_name, MAX(total_weight), MAX(CAST(is_foil AS INT))
    FROM stg.booster_sheet
    GROUP BY set_code, booster_type, sheet_name;

    -- Map each card to a printing: its own set's Scryfall ID, or (for cards borrowed
    -- from other sets, e.g. bonus sheets) the MTGJSON -> Scryfall map
    INSERT dw.booster_sheet_card (set_code, booster_type, sheet_name, mtgjson_uuid, card_key, card_weight)
    SELECT s.set_code, s.booster_type, s.sheet_name, s.mtgjson_uuid,
           MAX(c.card_key), SUM(s.card_weight)
    FROM stg.booster_sheet_card AS s
    LEFT JOIN dw.map_mtgjson_scryfall AS m ON m.mtgjson_uuid = s.mtgjson_uuid
    LEFT JOIN dw.dim_card AS c ON c.scryfall_id = COALESCE(s.scryfall_id, m.scryfall_id)
    GROUP BY s.set_code, s.booster_type, s.sheet_name, s.mtgjson_uuid;
    COMMIT;

    SELECT (SELECT COUNT(*) FROM dw.booster_set)                                   AS sets,
           (SELECT COUNT(DISTINCT CONCAT(set_code, '|', booster_type))
            FROM dw.booster_config)                                                AS pack_types,
           COUNT(*)                                                                AS sheet_cards,
           SUM(CASE WHEN card_key IS NULL THEN 1 ELSE 0 END)                       AS unmapped_cards
    FROM dw.booster_sheet_card;
END
GO

/* ---------- wanted cards: Edit-deck cards I don't own enough of ----------
   Counted at the CARD level against ALL decks, the same way the collection views
   do it (dw.vw_card_demand): each deck name needs the larger of its Deck and Edit
   quantities, summed across decks, minus the copies I own. So copies already used
   in other decks are not available: own 2 Sol Rings, both in built decks, and an
   Edit deck wants one more -> 3 needed, 2 owned, 1 wanted. */
CREATE OR ALTER VIEW dw.vw_wanted_card AS
/* decks = the Edit decks that are actually short: their Edit list wants more copies
   than their own Deck list (fully owned) already has. Example: Witherbloom's Deck
   list has a Sol Ring and its Edit list wants 1 -> not short; Plagon has no Deck
   list with one -> short. If no Edit deck explains the shortage (e.g. two built
   decks sharing one copy), decks falls back to every Edit deck that wants the card.
   all_edit_decks (last column) always lists every Edit deck that includes it. */
WITH per_deck AS (
    SELECT d.deck_name, f.oracle_id,
           SUM(CASE WHEN d.list_type = 'Deck' THEN f.quantity END) AS deck_qty,
           SUM(CASE WHEN d.list_type = 'Edit' THEN f.quantity END) AS edit_qty
    FROM dw.fact_deck_card AS f
    JOIN dw.dim_deck AS d ON d.deck_key = f.deck_key
    WHERE d.is_active = 1
      AND f.oracle_id IS NOT NULL
      AND f.section NOT IN ('MAYBEBOARD', 'CONSIDERING', 'SIDEBOARD')
    GROUP BY d.deck_name, f.oracle_id
), edit_need AS (
    SELECT oracle_id, deck_name, edit_qty - ISNULL(deck_qty, 0) AS extra_needed
    FROM per_deck
    WHERE edit_qty IS NOT NULL
), agg AS (
    SELECT oracle_id,
           CAST(STRING_AGG(CASE WHEN extra_needed > 0 THEN CAST(deck_name AS NVARCHAR(MAX)) END, N', ')
                WITHIN GROUP (ORDER BY deck_name) AS NVARCHAR(MAX))                    AS short_decks,
           CAST(STRING_AGG(CAST(deck_name AS NVARCHAR(MAX)), N', ')
                WITHIN GROUP (ORDER BY deck_name) AS NVARCHAR(MAX))                    AS all_edit_decks
    FROM edit_need
    GROUP BY oracle_id
)
SELECT p.oracle_id,
       p.card_name,
       p.demand_now - p.owned_qty                     AS missing_qty,
       p.demand_now                                   AS needed_across_decks,
       p.owned_qty,
       COALESCE(a.short_decks, a.all_edit_decks)      AS decks,
       a.all_edit_decks
FROM dw.vw_card_position AS p
JOIN agg AS a ON a.oracle_id = p.oracle_id
WHERE p.demand_now > p.owned_qty
  AND p.is_basic_land = 0;
GO

/* Which pack types are ordinary shelf packs, and which are special products
   (Secret Lair bonus cards, Signature Spellbooks, theme boosters, bundle promos...)
   whose contents are fixed or nearly fixed. */
CREATE OR ALTER VIEW dw.vw_pack_type AS
SELECT c.set_code, c.booster_type,
       CASE WHEN c.booster_type IN ('play', 'draft', 'set', 'collector', 'jumpstart', 'default')
             AND s.set_type IN ('expansion', 'core', 'masters', 'draft_innovation', 'funny')
            THEN 'Shelf pack' ELSE 'Special product' END AS pack_kind
FROM (SELECT DISTINCT set_code, booster_type FROM dw.booster_config) AS c
LEFT JOIN dw.dim_set AS s ON s.set_code = LOWER(c.set_code);
GO

/* Average total value of everything in a pack (wanted or not), two ways:
     market    = TCGplayer market price of what you'd pull
     ck_cash   = what Card Kingdom's buylist would pay for it (cards CK doesn't buy = $0)
     ck_credit = the same as store credit (credit bonus from dw.dim_sell_channel)
   Foil slots are priced as foil (or etched), other slots as nonfoil (or foil when
   that's the only finish). share_unpriced = share of pulled cards with no market
   price (mostly tokens, art cards, non-English printings); they count as $0. */
CREATE OR ALTER VIEW dw.vw_pack_value AS
WITH card_val AS (
    SELECT sc.set_code, sc.booster_type, sc.sheet_name,
           SUM(sc.card_weight * ISNULL(mp.price_usd, 0))                        AS w_market,
           SUM(sc.card_weight * ISNULL(bl.price_usd, 0))                        AS w_ck_cash,
           SUM(CASE WHEN mp.price_usd IS NULL THEN sc.card_weight ELSE 0 END)   AS w_unpriced
    FROM dw.booster_sheet_card AS sc
    JOIN dw.booster_sheet AS sh
      ON sh.set_code = sc.set_code AND sh.booster_type = sc.booster_type AND sh.sheet_name = sc.sheet_name
    OUTER APPLY (SELECT TOP 1 f.price_usd
                 FROM dw.fact_price AS f
                 WHERE f.card_key = sc.card_key AND f.valid_to IS NULL
                 ORDER BY CASE WHEN sh.is_foil = 1
                               THEN CASE f.finish WHEN 'foil' THEN 1 WHEN 'etched' THEN 2 ELSE 3 END
                               ELSE CASE f.finish WHEN 'nonfoil' THEN 1 WHEN 'foil' THEN 2 ELSE 3 END
                          END) AS mp
    OUTER APPLY (SELECT TOP 1 b.price_usd
                 FROM dw.fact_buylist_price AS b
                 WHERE b.card_key = sc.card_key AND b.vendor = 'cardkingdom' AND b.valid_to IS NULL
                 ORDER BY CASE WHEN sh.is_foil = 1
                               THEN CASE b.finish WHEN 'foil' THEN 1 WHEN 'etched' THEN 2 ELSE 3 END
                               ELSE CASE b.finish WHEN 'nonfoil' THEN 1 WHEN 'foil' THEN 2 ELSE 3 END
                          END) AS bl
    GROUP BY sc.set_code, sc.booster_type, sc.sheet_name
), per_config AS (
    SELECT cfg.set_code, cfg.booster_type, cfg.config_no,
           CAST(cfg.config_weight AS FLOAT) / cfg.total_config_weight           AS config_share,
           SUM(cs.picks * CAST(v.w_market   AS FLOAT) / sh.total_weight)        AS market,
           SUM(cs.picks * CAST(v.w_ck_cash  AS FLOAT) / sh.total_weight)        AS ck_cash,
           SUM(cs.picks * CAST(v.w_unpriced AS FLOAT) / sh.total_weight)        AS unpriced_cards,
           SUM(cs.picks)                                                        AS cards
    FROM dw.booster_config AS cfg
    JOIN dw.booster_config_sheet AS cs
      ON cs.set_code = cfg.set_code AND cs.booster_type = cfg.booster_type AND cs.config_no = cfg.config_no
    JOIN dw.booster_sheet AS sh
      ON sh.set_code = cs.set_code AND sh.booster_type = cs.booster_type AND sh.sheet_name = cs.sheet_name
    JOIN card_val AS v
      ON v.set_code = cs.set_code AND v.booster_type = cs.booster_type AND v.sheet_name = cs.sheet_name
    GROUP BY cfg.set_code, cfg.booster_type, cfg.config_no, cfg.config_weight, cfg.total_config_weight
)
SELECT p.set_code, p.booster_type,
       CAST(SUM(p.config_share * p.market)  AS DECIMAL(12,2))                    AS pack_value_market_usd,
       CAST(SUM(p.config_share * p.ck_cash) AS DECIMAL(12,2))                    AS pack_value_ck_cash_usd,
       CAST(SUM(p.config_share * p.ck_cash) * (1 + ISNULL(MAX(cr.bonus), 0)) AS DECIMAL(12,2)) AS pack_value_ck_credit_usd,
       CAST(SUM(p.config_share * p.cards) AS DECIMAL(6,1))                       AS cards_per_pack,
       CAST(SUM(p.config_share * p.unpriced_cards) / NULLIF(SUM(p.config_share * p.cards), 0)
            AS DECIMAL(5,3))                                                     AS share_unpriced
FROM per_config AS p
OUTER APPLY (SELECT MAX(credit_bonus_pct) AS bonus FROM dw.dim_sell_channel
             WHERE buylist_vendor = 'cardkingdom' AND uses_buylist = 1) AS cr
GROUP BY p.set_code, p.booster_type;
GO

/* Wanted cards on each sheet, with the price of the exact printing you'd pull */
CREATE OR ALTER VIEW dw.vw_pack_sheet_hit AS
SELECT sc.set_code, sc.booster_type, sc.sheet_name, w.oracle_id,
       SUM(sc.card_weight)                                              AS wanted_weight,
       SUM(sc.card_weight * ISNULL(pr.price_usd, 0))                    AS weighted_value,
       MAX(c.image_url)                                                 AS image_url
FROM dw.booster_sheet_card AS sc
JOIN dw.booster_sheet AS sh
  ON sh.set_code = sc.set_code AND sh.booster_type = sc.booster_type AND sh.sheet_name = sc.sheet_name
JOIN dw.dim_card AS c ON c.card_key = sc.card_key
JOIN dw.vw_wanted_card AS w ON w.oracle_id = c.oracle_id
OUTER APPLY (SELECT TOP 1 f.price_usd
             FROM dw.fact_price AS f
             WHERE f.card_key = c.card_key AND f.valid_to IS NULL
               AND f.finish = CASE WHEN sh.is_foil = 1 THEN 'foil' ELSE 'nonfoil' END) AS pr
GROUP BY sc.set_code, sc.booster_type, sc.sheet_name, w.oracle_id;
GO

/* One row per wanted card per pack it can come from */
CREATE OR ALTER VIEW dw.vw_pack_card_odds AS
WITH per_config AS (
    SELECT h.set_code, h.booster_type, h.oracle_id, cs.config_no,
           CAST(cfg.config_weight AS FLOAT) / cfg.total_config_weight            AS config_share,
           SUM(cs.picks * LOG(CASE WHEN CAST(h.wanted_weight AS FLOAT) / sh.total_weight >= 1
                                   THEN 1e-12
                                   ELSE 1 - CAST(h.wanted_weight AS FLOAT) / sh.total_weight END)) AS log_miss,
           SUM(cs.picks * CAST(h.wanted_weight AS FLOAT) / sh.total_weight)       AS expected_copies
    FROM dw.vw_pack_sheet_hit AS h
    JOIN dw.booster_sheet AS sh
      ON sh.set_code = h.set_code AND sh.booster_type = h.booster_type AND sh.sheet_name = h.sheet_name
    JOIN dw.booster_config_sheet AS cs
      ON cs.set_code = h.set_code AND cs.booster_type = h.booster_type AND cs.sheet_name = h.sheet_name
    JOIN dw.booster_config AS cfg
      ON cfg.set_code = cs.set_code AND cfg.booster_type = cs.booster_type AND cfg.config_no = cs.config_no
    GROUP BY h.set_code, h.booster_type, h.oracle_id, cs.config_no, cfg.config_weight, cfg.total_config_weight
), per_card AS (
    SELECT set_code, booster_type, oracle_id,
           SUM(config_share * (1 - EXP(log_miss))) AS chance_per_pack,
           SUM(config_share * expected_copies)     AS expected_copies_per_pack
    FROM per_config
    GROUP BY set_code, booster_type, oracle_id
)
SELECT bs.set_name,
       LOWER(pc.set_code)                                          AS set_code,
       bs.release_date,
       pc.booster_type,
       ISNULL(bn.booster_name, pc.booster_type)                    AS booster_name,
       w.card_name,
       w.missing_qty,
       w.decks,
       CAST(pc.chance_per_pack AS DECIMAL(9,6))                    AS chance_per_pack,
       CAST(1 / NULLIF(pc.chance_per_pack, 0) AS DECIMAL(12,1))    AS one_in_n_packs,
       CAST(pc.expected_copies_per_pack AS DECIMAL(9,6))           AS expected_copies_per_pack,
       ch.cheapest_single_usd,
       img.image_url,
       pc.oracle_id,
       pt.pack_kind
FROM per_card AS pc
JOIN dw.booster_set AS bs ON bs.set_code = pc.set_code
JOIN dw.vw_pack_type AS pt ON pt.set_code = pc.set_code AND pt.booster_type = pc.booster_type
JOIN dw.vw_wanted_card AS w ON w.oracle_id = pc.oracle_id
OUTER APPLY (SELECT TOP 1 booster_name FROM dw.booster_config AS b
             WHERE b.set_code = pc.set_code AND b.booster_type = pc.booster_type) AS bn
OUTER APPLY (SELECT TOP 1 h.image_url FROM dw.vw_pack_sheet_hit AS h
             WHERE h.set_code = pc.set_code AND h.booster_type = pc.booster_type
               AND h.oracle_id = pc.oracle_id ORDER BY h.wanted_weight DESC) AS img
OUTER APPLY (SELECT MIN(f.price_usd) AS cheapest_single_usd
             FROM dw.dim_card AS c
             JOIN dw.fact_price AS f ON f.card_key = c.card_key AND f.valid_to IS NULL
             WHERE c.oracle_id = pc.oracle_id) AS ch;
GO

/* One row per set + pack type: chance of pulling ANY wanted card */
CREATE OR ALTER VIEW dw.vw_pack_options AS
WITH sheet_any AS (
    SELECT set_code, booster_type, sheet_name,
           SUM(wanted_weight)   AS wanted_weight,
           SUM(weighted_value)  AS weighted_value,
           COUNT(*)             AS wanted_cards
    FROM dw.vw_pack_sheet_hit
    GROUP BY set_code, booster_type, sheet_name
), per_config AS (
    SELECT a.set_code, a.booster_type, cs.config_no,
           CAST(cfg.config_weight AS FLOAT) / cfg.total_config_weight            AS config_share,
           SUM(cs.picks * LOG(CASE WHEN CAST(a.wanted_weight AS FLOAT) / sh.total_weight >= 1
                                   THEN 1e-12
                                   ELSE 1 - CAST(a.wanted_weight AS FLOAT) / sh.total_weight END)) AS log_miss,
           SUM(cs.picks * CAST(a.wanted_weight AS FLOAT) / sh.total_weight)       AS expected_wanted,
           SUM(cs.picks * CAST(a.weighted_value AS FLOAT) / sh.total_weight)      AS expected_value
    FROM sheet_any AS a
    JOIN dw.booster_sheet AS sh
      ON sh.set_code = a.set_code AND sh.booster_type = a.booster_type AND sh.sheet_name = a.sheet_name
    JOIN dw.booster_config_sheet AS cs
      ON cs.set_code = a.set_code AND cs.booster_type = a.booster_type AND cs.sheet_name = a.sheet_name
    JOIN dw.booster_config AS cfg
      ON cfg.set_code = cs.set_code AND cfg.booster_type = cs.booster_type AND cfg.config_no = cs.config_no
    GROUP BY a.set_code, a.booster_type, cs.config_no, cfg.config_weight, cfg.total_config_weight
), per_pack AS (
    SELECT set_code, booster_type,
           SUM(config_share * (1 - EXP(log_miss))) AS chance_any_wanted,
           SUM(config_share * expected_wanted)     AS expected_wanted_cards,
           SUM(config_share * expected_value)      AS expected_wanted_value
    FROM per_config
    GROUP BY set_code, booster_type
), cards AS (
    SELECT set_code, booster_type, oracle_id
    FROM dw.vw_pack_sheet_hit
    GROUP BY set_code, booster_type, oracle_id
), card_list AS (
    SELECT k.set_code, k.booster_type,
           COUNT(*)                                                             AS wanted_cards_available,
           CAST(STRING_AGG(CAST(w.card_name AS NVARCHAR(MAX)), N', ')
                WITHIN GROUP (ORDER BY w.card_name) AS NVARCHAR(MAX))           AS wanted_card_names
    FROM cards AS k
    JOIN dw.vw_wanted_card AS w ON w.oracle_id = k.oracle_id
    GROUP BY k.set_code, k.booster_type
)
SELECT bs.set_name,
       LOWER(p.set_code)                                               AS set_code,
       bs.release_date,
       p.booster_type,
       ISNULL(bn.booster_name, p.booster_type)                         AS booster_name,
       cl.wanted_cards_available,
       cl.wanted_card_names,
       CAST(p.chance_any_wanted AS DECIMAL(9,6))                       AS chance_any_wanted,
       CAST(1 / NULLIF(p.chance_any_wanted, 0) AS DECIMAL(12,1))       AS one_in_n_packs,
       CAST(p.expected_wanted_cards AS DECIMAL(9,6))                   AS expected_wanted_cards,
       CAST(p.expected_wanted_value AS DECIMAL(12,2))                  AS expected_wanted_value_usd,
       pp.price_usd                                                    AS pack_price_usd,
       CAST(pp.price_usd / NULLIF(p.chance_any_wanted, 0) AS DECIMAL(12,2)) AS est_cost_per_hit_usd,
       pt.pack_kind,
       pv.pack_value_market_usd,          -- whole pack, all cards (new columns at the END)
       pv.pack_value_ck_cash_usd,
       pv.pack_value_ck_credit_usd
FROM per_pack AS p
JOIN dw.booster_set AS bs ON bs.set_code = p.set_code
JOIN dw.vw_pack_type AS pt ON pt.set_code = p.set_code AND pt.booster_type = p.booster_type
JOIN card_list AS cl ON cl.set_code = p.set_code AND cl.booster_type = p.booster_type
LEFT JOIN dw.vw_pack_value AS pv ON pv.set_code = p.set_code AND pv.booster_type = p.booster_type
OUTER APPLY (SELECT TOP 1 booster_name FROM dw.booster_config AS b
             WHERE b.set_code = p.set_code AND b.booster_type = p.booster_type) AS bn
LEFT JOIN dw.pack_price AS pp ON pp.set_code = p.set_code AND pp.booster_type = p.booster_type;
GO

/* Every wanted card: where it was printed, and whether a shelf pack has it */
CREATE OR ALTER VIEW dw.vw_wanted_card_sources AS
SELECT w.card_name,
       w.missing_qty,
       w.decks,
       pr.printed_in_sets,
       pr.printings,
       pk.packs_with_card,                                   -- shelf packs only, newest first
       CASE WHEN pk.shelf_packs > 0  THEN 'In shelf packs'
            WHEN pk.other_packs > 0  THEN 'Special products only'
            ELSE 'Singles only' END                          AS availability,
       ch.cheapest_single_usd,
       w.oracle_id,
       pk.shelf_packs,
       pk.best_shelf_chance,
       -- new columns at the END: which pack those best odds come from, any year,
       -- and the best shelf pack released in the last 2 years (likely still on shelves)
       bp.best_shelf_pack,
       br.best_recent_pack,
       br.best_recent_chance,
       bp.best_shelf_image_url,      -- what the card looks like in those packs
       br.best_recent_image_url      -- (the version that turns up most often)
FROM dw.vw_wanted_card AS w
OUTER APPLY (SELECT COUNT(*) AS printings,
                    CAST(STRING_AGG(CAST(x.set_name AS NVARCHAR(MAX)), N', ')
                         WITHIN GROUP (ORDER BY x.release_date) AS NVARCHAR(MAX)) AS printed_in_sets
             FROM (SELECT DISTINCT s.set_name, s.release_date
                   FROM dw.dim_card AS c
                   JOIN dw.dim_set AS s ON s.set_code = c.set_code
                   WHERE c.oracle_id = w.oracle_id) AS x) AS pr
OUTER APPLY (SELECT SUM(CASE WHEN o.pack_kind = 'Shelf pack' THEN 1 ELSE 0 END)      AS shelf_packs,
                    SUM(CASE WHEN o.pack_kind <> 'Shelf pack' THEN 1 ELSE 0 END)     AS other_packs,
                    MAX(CASE WHEN o.pack_kind = 'Shelf pack' THEN o.chance_per_pack END) AS best_shelf_chance,
                    CAST(STRING_AGG(CASE WHEN o.pack_kind = 'Shelf pack'
                                         THEN CAST(CONCAT(o.set_name, N' (', o.booster_name, N')') AS NVARCHAR(MAX)) END,
                                    N'; ') WITHIN GROUP (ORDER BY o.release_date DESC) AS NVARCHAR(MAX)) AS packs_with_card
             FROM dw.vw_pack_card_odds AS o
             WHERE o.oracle_id = w.oracle_id) AS pk
OUTER APPLY (SELECT MIN(f.price_usd) AS cheapest_single_usd
             FROM dw.dim_card AS c
             JOIN dw.fact_price AS f ON f.card_key = c.card_key AND f.valid_to IS NULL
             WHERE c.oracle_id = w.oracle_id) AS ch
OUTER APPLY (SELECT TOP 1 CAST(CONCAT(o.set_name, N' (', o.booster_name, N')') AS NVARCHAR(400)) AS best_shelf_pack,
                    o.image_url AS best_shelf_image_url
             FROM dw.vw_pack_card_odds AS o
             WHERE o.oracle_id = w.oracle_id AND o.pack_kind = 'Shelf pack'
             ORDER BY o.chance_per_pack DESC, o.release_date DESC) AS bp
OUTER APPLY (SELECT TOP 1 CAST(CONCAT(o.set_name, N' (', o.booster_name, N')') AS NVARCHAR(400)) AS best_recent_pack,
                    o.chance_per_pack AS best_recent_chance,
                    o.image_url AS best_recent_image_url
             FROM dw.vw_pack_card_odds AS o
             WHERE o.oracle_id = w.oracle_id AND o.pack_kind = 'Shelf pack'
               AND o.release_date >= DATEADD(YEAR, -2, CAST(GETDATE() AS DATE))
             ORDER BY o.chance_per_pack DESC) AS br;
GO
