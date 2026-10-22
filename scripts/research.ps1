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
  Historical high-impact events CSV (ts_utc,currency,impact,title). Defaults
  to data\news\ff_high_impact_2020-01_2026-01.csv (see data\news\README.md).
  Pass "" to run without it; the report then warns that the filter is inactive.

.PARAMETER Source
  Tick provider: dukascopy (default, hourly .bi5 files) or histdata
  (HistData.com monthly zips; the fallback while datafeed.dukascopy.com is
  down). One provider per symbol folder: switching means deleting data\raw\<SYMBOL>.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\research.ps1
  powershell -ExecutionPolicy Bypass -File scripts\research.ps1 -Source histdata
#>
param(
    [string]$From = "2020-01-01",
    [string]$NewsCsv = "data\news\ff_high_impact_2020-01_2026-01.csv",
    [ValidateSet("dukascopy", "histdata")]
    [string]$Source = "dukascopy"
)
. "$PSScriptRoot\common.ps1"
Assert-Command uv "Run scripts\setup.ps1 first."
Repair-PythonEnv
$logFile = Join-Path $RepoRoot "state\logs\research.log"
Write-Host "Log: $logFile (every ftmo-bot step appends here)" -ForegroundColor DarkGray


Invoke-Step "Download $Source ticks from $From (resumable, ~2-4 GB on disk)" {
    uv run ftmo-bot download --from $From --source $Source
}
Invoke-Step "Resample ticks into 15m / 4H bars" { uv run ftmo-bot resample }
Invoke-Step "Data integrity checks (failing days are excluded)" { uv run ftmo-bot integrity }

$bt = @("run", "ftmo-bot", "backtest", "--split", "insample")
if ($NewsCsv) {
    if (-not (Test-Path $NewsCsv)) { throw "news CSV not found: $NewsCsv (pass -NewsCsv '' to run without it)" }
    $bt += @("--news-csv", $NewsCsv)
}
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
