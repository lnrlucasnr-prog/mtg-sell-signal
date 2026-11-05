# MTG Sell Signal

**When should I sell the Magic: The Gathering cards I'm not using?**

An automated price-analytics pipeline that tracks every paper Magic card daily, reconciles my collection against my decks, and flags each spare card as **Sell now**, **Sell soon**, **Watch** or **Hold**. The rules are backtested on over a million card observations across about five years of price history, and followed up to a year after each signal.

**[View the live dashboard on Tableau Public →](https://public.tableau.com/views/MTGDashboards/WhatShouldISell?:language=en-US&publish=yes&:sid=&:redirect=auth&:display_count=n&:origin=viz_share_link)**

`Python` · `SQL Server (T-SQL)` · `Tableau` · `Windows Task Scheduler` · free public data only

---

## Results

*As of November 2026. The study and backtest rerun weekly, so the dashboard always shows the current figures; the numbers here are rounded.*

The sell rules were backtested on about **1 million card observations**: every card worth $2 or more, on 33 past dates across three stretches of price history (late 2021, spring 2023, and continuous daily prices from February 2024). For each card, the test compared the signal the rules would have given on that date with what the price actually did afterwards.

**The sell signal lasts.** Cards flagged *Sell now* kept falling for months:

| Signal | After 1 month | After 3 months | After 6 months | After 1 year |
|---|---|---|---|---|
| **Sell now** (median change) | −6% | −14% | −20% | −19% |
| **Hold** (median change) | 0% | 0% | +2% | +3% |
| Sell now: share that fell 10%+ | 40% | 56% | 60% | 58% |
| Hold: share that fell 10%+ | 8% | 18% | 24% | 29% |

- **The rules held in every stretch of history.** In 2021, 2023 and 2024–2026 alike, *Sell now* cards were about 4–5 times as likely as *Hold* cards to lose 10%+ the next month.
- **Pre-order prices are the clearest sell.** Cards priced before their set's release fell a median **46%** the following month.
- **Rising spikes are a short window, not a hold.** Spikes that are still climbing usually keep rising for a few weeks, but the advantage is gone within about six months (the pattern in cards like Athreos, God of Passage). The backtest changed this rule's advice from *Hold* to **Sell soon: sell into the rise**.
- **Most spikes don't crash right away.** 80% of +25% spikes didn't fall 10% the next month. The risky ones have started cooling: 32–37% of those fell 10%+.
- **New-set cards rarely hold value.** Across 47 sets, cards worth $2+ kept about 63% of their early price within three months of release (the top 10 chases: about 69%). The chases held their value in only 5 of the 47 sets.
- **When Card Kingdom's buylist pays at or above market price, hold.** Only about 4% of those cards fell 10%+ the next month. The buylist price rises ahead of market demand.
- **"Hold" means no reason to sell yet, not a safe long-term bet.** A year later, about 40% of Hold cards were up 10%+ and 29% were down 10%+.

---|---|---|---|
| Oct 2021 – Jan 2022 | −3.5% | 32% | 9% |
| Feb – May 2023 | −7.0% | 42% | 10% |
| Jul 2026 – now | −10.2% | 51% | 6% |

- **The rules held in every season.** The signals ranked the same way each time (Sell now < Watch < Hold < Hold (rising)). "Sell now" cards were 3 to 8 times as likely as "Hold" cards to lose 10% or more.
- **Pre-order prices are the clearest sell.** Cards priced before their set's release fell a median **34%** in the following month.
- **Most price spikes don't crash.** 82% of +25% spikes did *not* fall 10% or more the following month. The risky spikes are the ones that have started cooling: 32–36% of those fell 10% or more.
- **New-set chase cards rarely hold value.** Across 11 sets, the 10 most valuable cards sat at about 70% of their early price within three months of release, and held their value in only 1 set.
- **When Card Kingdom's buylist pays at or above market price, hold.** Only 3% of those cards fell 10% or more. The buylist price is a leading indicator of demand.

*Numbers update weekly as the study reruns on new data; the dashboard shows the current figures.*

---

## How it works

```mermaid
flowchart LR
    scryfall["Scryfall: daily cards and prices"]
    buylist["MTGJSON: Card Kingdom buylist"]
    manabox["ManaBox: collection and decks"]
    archive["Archived MTGJSON: 2021 and 2023 seasons"]
    tcgcsv["TCGCSV: daily TCGplayer prices since Feb 2024"]
    etl["Python ETL"]
    warehouse[("SQL Server warehouse")]
    analysis["Metrics, spike study, sell rules, backtest"]
    csv["CSV export"]
    tableau["Tableau Public"]

    scryfall --> etl
    buylist --> etl
    manabox --> etl
    archive -. "one-time" .-> etl
    tcgcsv -. "one-time" .-> etl
    etl --> warehouse
    warehouse --> analysis
    analysis --> csv
    csv --> tableau
```

**Daily (Windows Task Scheduler):**
1. **`load_scryfall.py`** downloads Scryfall's bulk file of every printing, filters it to English paper cards, and loads cards, sets and prices.
2. **`load_buylist.py`** loads Card Kingdom's buylist (what a store will actually pay) from MTGJSON.
3. **`import_manabox.py`** imports my collection and deck lists from ManaBox exports synced through Google Drive.
4. **`refresh_analytics.py`** rebuilds the price metrics. Each week it also reruns the spike study and backtest so the rules learn from new history.
5. **`export_tableau.py`** writes the dashboard datasets to CSV, since Tableau Public can't connect to SQL Server.

Every step logs to one file and runs even if an earlier step fails, so one problem doesn't hide another. [`RUNBOOK.md`](RUNBOOK.md) covers operations, checks and recovery.

---

## Design decisions

- **Change-only price history.** Most card prices don't move on a given day, so `dw.fact_price` stores a new row only when a price changes (`valid_from` / `valid_to`, like a Type 2 slowly changing dimension). That keeps years of daily history for every printing small enough for a laptop.
- **No lookahead.** `dw.usp_build_card_metrics @as_of` rebuilds every metric using only prices known on that date. The study and backtest replay past dates through this same procedure.
- **One rules function for both live signals and backtest.** `dw.fn_sell_signal` is an inline table-valued function, so the dashboard's signals and the backtest can't drift apart.
- **Rules come from evidence, not guesses.** Spikes are classified by speed (sharp/gradual), momentum (still rising/cooling/flat) and breadth (did other printings move?), and compared against peer groups (set age × rarity × price tier). The backtest has changed two rules so far: "Card Kingdom pays at or above market" started as a sell signal, the data showed those cards *rose*, and it became a hold signal; rising spikes started as a hold, the long-horizon test showed the gain fades within months, and they became *Sell soon*.
- **Gaps stay gaps.** Archived MTGJSON files from the Wayback Machine add 90-day seasons from 2021 and 2023, and the TCGCSV archive adds continuous daily prices from February 2024. The gaps between them have no data, and none is invented. The study only uses dates with 30 days of real prices both before and after, inside one stretch of history.
- **Sources are checked before they're stitched together.** Each historical source is compared with the regular history on a day both cover (TCGCSV: about 1 cent average difference, 95–99% of prices within 5%).
- **The collection is the only source of truth for ownership.** Deck lists say what is needed; the collection says what is owned. Cards owned beyond what my decks need are the sell candidates.
- **Dashboard text is built in SQL.** The finding sentences on the dashboard are generated from the same results as the charts (`dw.vw_dashboard_findings`), so the text can never disagree with the numbers.

---

## Limitations

- **The backtest is in-sample.** The spike and peer statistics the rules use come from the same dates being tested, so results are somewhat optimistic. As daily history grows, newer dates can be tested against statistics from older ones.
- **Market price = TCGplayer market price** (via Scryfall, MTGJSON and TCGCSV). Real sale prices vary by condition and venue, and prices are not adjusted for inflation.
- **Observations overlap.** The same card appears on many dates, so the million observations are not a million independent cases. The Sell now vs. Hold gap is large enough that this doesn't change the conclusion.
- **Card Kingdom buylist history has a gap** from February 2024 to mid-2026 (TCGCSV has market prices only), so the "CK pays market or more" rule is tested on fewer dates than the others.
- **For the archived seasons, "other printings" is based on today's card list,** so reprints released later count slightly early. This only affects the spike breadth label.
- **The local-store estimate is a rule of thumb** (a share of market price); the Card Kingdom figure is a real buylist offer.

---

## Roadmap

- **Collection workbook:** whole-collection value, deck usage, and set-level views.
- **Pack-buy recommendation:** expected value of opening a pack versus buying the singles.
- **Buy-card recommendation:** when to buy the cards my decks still need, using the same price-pattern evidence.
- **Bulk breakout study:** which cheap cards tend to become valuable.
- **Out-of-sample backtest** once enough new daily history has built up.

---

## Running it yourself

Requirements: Windows, Python 3.10+, SQL Server (Express or Developer edition is fine) and the Microsoft ODBC Driver for SQL Server.

```
pip install -r requirements.txt
copy ETL\config.example.ini ETL\config.ini      (then fill in your server and export folder)
```

Run `sql/01` through `sql/12` in SSMS, then follow **Rebuilding from scratch** in [`RUNBOOK.md`](RUNBOOK.md).

## Repository layout

```
ETL/      Python loaders, analytics refresh, Tableau export
sql/      warehouse schema, procedures and views, run in numbered order
RUNBOOK.md  operations guide
run_daily_load.bat  daily pipeline (Task Scheduler entry point)
```

---

## Data sources and credits

- [Scryfall](https://scryfall.com/docs/api): card data, prices and images
- [MTGJSON](https://mtgjson.com): Card Kingdom buylist and historical prices
- [Internet Archive Wayback Machine](https://web.archive.org): archived MTGJSON price files
- [TCGCSV](https://tcgcsv.com): daily TCGplayer price archive since February 2024
- [ManaBox](https://manabox.app): collection and deck exports

*MTG Sell Signal is unofficial Fan Content permitted under the Wizards of the Coast Fan Content Policy. It is not approved or endorsed by Wizards. Portions of the materials used are property of Wizards of the Coast. © Wizards of the Coast LLC.*

*Not financial advice: card prices are volatile, and past patterns don't guarantee future moves.*
