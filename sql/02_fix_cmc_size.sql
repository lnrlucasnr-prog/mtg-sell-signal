/* One-time fix for databases created with the first version of 01_schema.sql:
   widen cmc (mana value) so joke cards like Gleemax (mana value 1,000,000) fit.
   01_schema.sql now creates this size directly, so new setups don't need this. */
USE mtg;
GO
ALTER TABLE stg.scryfall_card ALTER COLUMN cmc DECIMAL(10,1) NULL;
ALTER TABLE dw.dim_card       ALTER COLUMN cmc DECIMAL(10,1) NULL;
GO
