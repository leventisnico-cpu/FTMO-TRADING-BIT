# Historical high-impact news events

`ff_high_impact_2020-01_2026-01.csv` feeds the backtest's news filter
(`ftmo-bot backtest --news-csv ...`; `scripts\research.ps1` picks it up by
default). Columns: `ts_utc,currency,impact,title`; `impact` is always `High`.

## Provenance

- Source: Forex Factory calendar as archived by the open-source scraper
  `ehsanrs2/forexfactory-scraper`, file `high_impact_events_calendar.csv`,
  repository commit `3fefefd14307df704629b4db85e23275c36c97e3` (2026-10-13).
  Forex Factory itself only publishes the current week as JSON, so a
  third-party archive is the only way to get 2020 onward.
- Transformation (2026-10-21): timestamps were ISO 8601 on a Europe/London
  clock with explicit `+00:00` / `+01:00` offsets; converted to UTC `Z`.
  Currency upper-cased, titles whitespace-normalised, exact duplicates
  dropped. 4,700 events, 2020-01-02 to 2026-01-30.
- Sanity checks passed: every US Non-Farm Payrolls release sits at 12:30 UTC
  (summer) or 13:30 UTC (winter), i.e. 08:30 New York; ISM at 15:00/14:00 UTC.

## Known limits (state them in any report that uses this file)

- Coverage ends 2026-01-30: the 2026 holdout runs with the news filter
  inactive from February on. Extend the file before the holdout run if a
  source appears (e.g. the per-15-minute commits of
  `QuarkFX/forex-economic-calendar`).
- 2020-2021 carry fewer events per month than 2023-2025. Part of that is how
  Forex Factory tagged impact at the time; part may be scraper gaps (12 weeks
  with zero USD high-impact events in 2020-2025, mostly holiday weeks).
  Missing events let the backtest take a few trades live would skip; it does
  not create trades.
- Only high-impact rows are included; medium-impact events are not filtered
  by the strategy by design (`config/strategy.yaml` `news.impact: High`).
