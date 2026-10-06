# FTMO-TRADING-BIT

A rules-first FTMO 2-Step challenge bot, built to [`SPEC.md`](SPEC.md): an
Asian-range breakout strategy wrapped in a drawdown engine the strategy cannot
override. The drawdown engine is the product; the strategy is replaceable.

**Status: Phases 0–5 are built and tested on synthetic data. The gates (Phase 6)
have NOT been run on real data**, so nothing here says yet whether the strategy
is profitable. Don't pay a challenge fee until `reports/report.html` shows
every gate green on real ticks **and** the 60-day FTMO Free Trial passes.

## Layout

| Path | What |
|---|---|
| `SPEC.md` | The build spec: strategy, FTMO limits, go/no-go gates |
| `CLAUDE.md` | Module contracts that must never drift |
| `AGENT_PROMPT.md` | Kickoff prompt for a Claude Code session operating this repo |
| `config/` | `strategy.yaml` (one parameter set), `ftmo_2step.yaml` (limits, contract specs) |
| `src/ftmo_bot/risk/ftmo_rules.py` | Pure rules engine shared by backtest and live (100% branch coverage) |
| `src/ftmo_bot/{data,strategy,backtest,execution}` | Data pipeline, strategy, backtest and Monte Carlo, MT5 execution |
| `scripts/setup.ps1` | One-time Windows setup and checks |
| `scripts/research.ps1` | Download → bars → integrity → in-sample backtest → report |
| `scripts/run_live.ps1` | Starts and supervises the guard and the runner on the VPS |
| `.env.example` | Template for MT5 logins and alerts (copy to the git-ignored `.env`) |

## Windows quickstart (PowerShell)

Needs Git for Windows; `setup.ps1` installs `uv` and Python 3.11 if missing.

```powershell
git clone https://github.com/leventisnico-cpu/FTMO-TRADING-BIT.git
cd FTMO-TRADING-BIT

# 1. Install + run every test (and check the MetaTrader5 package)
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1

# 2. Research: ~2–4 GB of ticks since 2020 (resumable), in-sample backtest, report
powershell -ExecutionPolicy Bypass -File scripts\research.ps1
```

Stop after step 2 and review `reports\report.html`. The out-of-sample and
holdout runs are one-shot. The ledger (`reports\ledger.jsonl`) refuses OOS
before in-sample, refuses a second OOS with the same parameters, and lets the
holdout run only once. Commit the ledger.

```powershell
# 3. Only after reviewing in-sample, with parameters unchanged
uv run ftmo-bot backtest --split oos
uv run ftmo-bot backtest --split holdout
uv run ftmo-bot montecarlo --split oos
uv run pytest --cov=ftmo_bot --cov-branch --cov-report=json:coverage.json
uv run ftmo-bot report --coverage-json coverage.json
```

## Live: FTMO Free Trial first, on a Windows VPS in Europe

1. Install **two** MT5 terminals in separate folders (e.g. `C:\MT5-Guard`,
   `C:\MT5-Runner`). The guard and the runner each log in on their own.
2. `copy .env.example .env` and fill in both logins and terminal paths.
3. Start it:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run_live.ps1 -Mode paper
```

`paper` mode refuses any non-demo account. The guard flattens everything
at a 2.5% daily or 6% overall loss. If the guard stops, the runner refuses to
open trades.

## Known risks to check before trusting any result

- **The stop cap may starve the strategy of trades.** SPEC step 4 skips any
  breakout whose range-based stop is wider than 1.5 × ATR(14, 15m). Asian
  ranges are often wider than that, so the ≥ 500-trade OOS gate may fail. If
  it does, the SPEC says to try a different strategy family, not to loosen the cap.
- **Historical news.** Forex Factory publishes only the current week. Without
  a historical events CSV (`--news-csv`), the backtest's news filter does
  nothing and the report warns about it.
- **Values marked VERIFY** in `config/ftmo_2step.yaml` (NAS100 contract size
  and symbol name, metal and index commissions, typical spreads, server
  timezone, challenge fee) must be checked on the FTMO demo before the gates mean anything.
- **Overall-loss modelling.** Overall loss depends on the challenge start date.
  The continuous backtest enforces daily limits tick by tick, and `ftmo_sim`
  replays the 6% and 10% overall limits for every rolling start date.
