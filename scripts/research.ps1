<#
.SYNOPSIS
  Phase 4 research run: download ticks, build bars, check data integrity,
  run the IN-SAMPLE backtest + Monte Carlo, and open the report.

.DESCRIPTION
  Safe to re-run: downloads resume where they stopped. It never runs the
  out-of-sample or holdout splits - those are one-shot (see README.md, step 3) and
  the ledger refuses a second attempt.

.PARAMETER From
  First day to download (default 2020-01-01).

.PARAMETER NewsCsv
  Optional historical high-impact events CSV (ts_utc,currency,impact,title).
  Without it the backtest's news filter is inactive and the report warns.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\research.ps1
#>
param(
    [string]$From = "2020-01-01",
    [string]$NewsCsv = ""
)
. "$PSScriptRoot\common.ps1"
Assert-Command uv "Run scripts\setup.ps1 first."
Repair-PythonEnv

Invoke-Step "Download Dukascopy ticks from $From (resumable, ~2-4 GB)" {
    uv run ftmo-bot download --from $From
}
Invoke-Step "Resample ticks into 15m / 4H bars" { uv run ftmo-bot resample }
Invoke-Step "Data integrity checks (failing days are excluded)" { uv run ftmo-bot integrity }

$bt = @("run", "ftmo-bot", "backtest", "--split", "insample")
if ($NewsCsv) { $bt += @("--news-csv", $NewsCsv) }
Invoke-Step "In-sample backtest 2020-2023" { uv @bt }
Invoke-Step "Monte Carlo on in-sample trades (10,000 stressed paths)" {
    uv run ftmo-bot montecarlo --split insample
}
Invoke-Step "Coverage for the rules-engine gate" {
    uv run pytest -q --cov=ftmo_bot --cov-branch --cov-report=json:coverage.json
}
Invoke-Step "Rebuild report" { uv run ftmo-bot report --coverage-json coverage.json }

$report = Join-Path $RepoRoot "reports\report.html"
Write-Host ""
Write-Host "Report: $report" -ForegroundColor Green
Write-Host "Review it before any OOS run. Commit reports\ledger.jsonl and reports\*\summary.json." -ForegroundColor Yellow
Start-Process $report
