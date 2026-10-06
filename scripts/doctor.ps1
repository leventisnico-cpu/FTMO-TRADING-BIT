<#
.SYNOPSIS
  Read-only health check of this machine for FTMO-TRADING-BIT. Prints one
  PASS / WARN / FAIL line per check, then a summary to paste back for help.

.DESCRIPTION
  Changes nothing and places no orders. It attaches to an MT5 terminal that is
  already running and logged in only to read account info. It never prints
  passwords or tokens: only whether they are set.

.PARAMETER SkipTests
  Skip the test suite (it takes about a minute).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1
#>
param([switch]$SkipTests)

. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = "Continue"
$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param([string]$Status, [string]$Check, [string]$Detail)
    $results.Add([pscustomobject]@{ Status = $Status; Check = $Check; Detail = $Detail })
    $color = @{ PASS = "Green"; WARN = "Yellow"; FAIL = "Red" }[$Status]
    Write-Host ("[{0}] {1}: {2}" -f $Status, $Check, $Detail) -ForegroundColor $color
}

function Test-Tool {
    param([string]$Name, [string[]]$VersionArgs, [string]$Hint)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) { Add-Result FAIL $Name "not on PATH. $Hint"; return $false }
    $v = (& $Name @VersionArgs 2>&1 | Select-Object -First 1) -as [string]
    Add-Result PASS $Name $v.Trim()
    return $true
}

Write-Host "FTMO-TRADING-BIT doctor  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "Repo: $RepoRoot"
Write-Host ""

# --- System -----------------------------------------------------------------
$os = [System.Environment]::OSVersion.VersionString
$arch = if ([System.Environment]::Is64BitOperatingSystem) { "64-bit" } else { "32-bit" }
Add-Result ($(if ($IsWindows -or $env:OS -eq "Windows_NT") { "PASS" } else { "WARN" })) "OS" "$os $arch (live trading needs Windows; research runs anywhere)"
Add-Result PASS "PowerShell" $PSVersionTable.PSVersion.ToString()
$policy = Get-ExecutionPolicy
Add-Result ($(if ($policy -in "Restricted", "AllSigned") { "WARN" } else { "PASS" })) "Execution policy" "$policy (run scripts with: powershell -ExecutionPolicy Bypass -File ...)"
$drive = (Get-Item $RepoRoot).PSDrive
if ($drive -and $drive.Free) {
    $freeGb = [math]::Round($drive.Free / 1GB, 1)
    Add-Result ($(if ($freeGb -ge 8) { "PASS" } elseif ($freeGb -ge 4) { "WARN" } else { "FAIL" })) "Disk space" "$freeGb GB free (data needs about 2-4 GB)"
}

# --- Tools ------------------------------------------------------------------
$hasGit = Test-Tool git @("--version") "Install Git for Windows: https://git-scm.com/download/win"
$hasUv = Test-Tool uv @("--version") "Run scripts\setup.ps1 (it installs uv)."
if ($hasGit) {
    $branch = (git rev-parse --abbrev-ref HEAD 2>$null)
    $dirty = (git status --porcelain 2>$null | Measure-Object).Count
    $env:GIT_TERMINAL_PROMPT = "0"  # never hang on a credential prompt
    git fetch -q origin 2>$null
    $behind = (git rev-list --count "HEAD..origin/main" 2>$null)
    $st = if ($behind -and [int]$behind -gt 0) { "WARN" } else { "PASS" }
    Add-Result $st "Git checkout" "branch $branch, $dirty uncommitted file(s), $behind commit(s) behind origin/main"
}

# --- Python environment -------------------------------------------------------
if ($hasUv) {
    $py = (uv run --frozen python -c "import sys; print(sys.version.split()[0])" 2>&1 | Select-Object -Last 1)
    if ($LASTEXITCODE -eq 0 -and "$py" -match "^3\.11") { Add-Result PASS "Python env" "Python $py" }
    else { Add-Result FAIL "Python env" "$py  -> run scripts\setup.ps1 (reinstalls Python automatically)" }

    $imp = (uv run --frozen python -c "import ftmo_bot, numpy, pandas, pyarrow, yaml; print('ok')" 2>&1 | Select-Object -Last 1)
    Add-Result ($(if ("$imp" -eq "ok") { "PASS" } else { "FAIL" })) "Bot packages" "$imp"

    $mt5v = (uv run --frozen python -c "import MetaTrader5 as m; print(m.__version__)" 2>&1 | Select-Object -Last 1)
    if ($LASTEXITCODE -eq 0) { Add-Result PASS "MetaTrader5 package" "version $mt5v" }
    else { Add-Result FAIL "MetaTrader5 package" "not installed -> uv sync --group dev --extra live" }

    # --- MT5 terminal (read-only) ------------------------------------------
    $probe = @'
import json, MetaTrader5 as m
out = {"init": bool(m.initialize())}
if not out["init"]:
    out["error"] = str(m.last_error())
else:
    t = m.terminal_info(); a = m.account_info()
    out["terminal"] = {"path": t.path, "connected": bool(t.connected), "algo_trading": bool(t.trade_allowed)} if t else None
    out["account"] = {"login": a.login, "server": a.server, "demo": a.trade_mode == m.ACCOUNT_TRADE_MODE_DEMO,
                      "balance": a.balance, "equity": a.equity, "currency": a.currency} if a else None
    syms = {}
    for s in ("EURUSD", "GBPUSD", "XAUUSD", "US100.cash"):
        i = m.symbol_info(s)
        syms[s] = None if i is None else {"contract_size": i.trade_contract_size, "digits": i.digits,
                                           "volume_min": i.volume_min, "volume_step": i.volume_step}
    out["symbols"] = syms
    tick = m.symbol_info_tick("EURUSD")
    out["eurusd_tick_time"] = int(tick.time) if tick else None
    m.shutdown()
print(json.dumps(out))
'@
    $probeFile = Join-Path $env:TEMP "ftmo_mt5_probe.py"
    Set-Content -Path $probeFile -Value $probe -Encoding UTF8
    $raw = (uv run --frozen python $probeFile 2>&1 | Select-Object -Last 1)
    Remove-Item $probeFile -ErrorAction SilentlyContinue
    try { $mt5 = $raw | ConvertFrom-Json } catch { $mt5 = $null }
    if ($null -eq $mt5) {
        Add-Result FAIL "MT5 terminal" "probe failed: $raw"
    } elseif (-not $mt5.init) {
        Add-Result FAIL "MT5 terminal" "cannot attach ($($mt5.error)). Open MT5 and log in to your FTMO account."
    } else {
        $t = $mt5.terminal
        Add-Result ($(if ($t.connected) { "PASS" } else { "FAIL" })) "MT5 terminal" "$($t.path), connected=$($t.connected)"
        Add-Result ($(if ($t.algo_trading) { "PASS" } else { "WARN" })) "MT5 Algo Trading" $(if ($t.algo_trading) { "enabled" } else { "disabled: press the 'Algo Trading' button in MT5 before going live" })
        $a = $mt5.account
        if ($a) {
            Add-Result ($(if ($a.demo) { "PASS" } else { "WARN" })) "MT5 account" ("login {0} on {1}, {2}, balance {3} {4}" -f $a.login, $a.server, $(if ($a.demo) { "DEMO" } else { "NOT DEMO" }), $a.balance, $a.currency)
        } else { Add-Result FAIL "MT5 account" "not logged in" }
        foreach ($p in $mt5.symbols.PSObject.Properties) {
            if ($null -eq $p.Value) { Add-Result WARN "Symbol $($p.Name)" "not found on this server (check mt5_symbol in config\ftmo_2step.yaml)" }
            else { Add-Result PASS "Symbol $($p.Name)" ("contract size {0}, min lot {1}, step {2}" -f $p.Value.contract_size, $p.Value.volume_min, $p.Value.volume_step) }
        }
        if ($mt5.eurusd_tick_time) {
            # MT5 stamps ticks in server time; the gap vs UTC is the server offset.
            $offsetH = [math]::Round(($mt5.eurusd_tick_time - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) / 3600, 1)
            Add-Result PASS "MT5 server time" "server clock is UTC$(if ($offsetH -ge 0) { '+' })$offsetH h (markets open). Check this matches mt5.server_timezone in config\ftmo_2step.yaml"
        }
    }
}

# --- Network (data sources) -----------------------------------------------------
foreach ($u in @(
        @{ Name = "Dukascopy ticks"; Url = "https://datafeed.dukascopy.com/datafeed/EURUSD/2024/00/02/10h_ticks.bi5" },
        @{ Name = "Forex Factory news"; Url = "https://nfs.faireconomy.media/ff_calendar_thisweek.json" })) {
    try {
        $r = Invoke-WebRequest -Uri $u.Url -Method Get -UseBasicParsing -TimeoutSec 20
        Add-Result PASS $u.Name "HTTP $($r.StatusCode), $($r.RawContentLength) bytes"
    } catch {
        Add-Result FAIL $u.Name "unreachable: $($_.Exception.Message)"
    }
}

# --- Config and secrets (never printed) ---------------------------------------------
$envFile = Join-Path $RepoRoot ".env"
if (Test-Path $envFile) {
    Import-DotEnv
    $need = "MT5_GUARD_LOGIN", "MT5_GUARD_PASSWORD", "MT5_GUARD_SERVER", "MT5_GUARD_PATH",
            "MT5_LOGIN", "MT5_PASSWORD", "MT5_SERVER", "MT5_PATH"
    $missing = @($need | Where-Object { -not (Test-Path "Env:$_") })
    Add-Result ($(if ($missing.Count) { "WARN" } else { "PASS" })) ".env" $(if ($missing.Count) { "missing: $($missing -join ', ') (needed only for live)" } else { "all MT5 settings present" })
    foreach ($k in "MT5_GUARD_PATH", "MT5_PATH") {
        $v = [Environment]::GetEnvironmentVariable($k)
        if ($v) { Add-Result ($(if (Test-Path $v) { "PASS" } else { "FAIL" })) $k $(if (Test-Path $v) { "found" } else { "no file at $v" }) }
    }
    if ($env:MT5_GUARD_PATH -and $env:MT5_GUARD_PATH -eq $env:MT5_PATH) {
        Add-Result FAIL "MT5 installs" "guard and runner point at the same terminal; install a second copy"
    }
    $tg = [bool]($env:TELEGRAM_BOT_TOKEN -and $env:TELEGRAM_CHAT_ID)
    Add-Result ($(if ($tg) { "PASS" } else { "WARN" })) "Telegram alerts" $(if ($tg) { "configured" } else { "not configured (optional, recommended)" })
} else {
    Add-Result WARN ".env" "not created yet: copy .env.example .env (needed only for live)"
}

# --- State and research progress -------------------------------------------
$halt = Join-Path $RepoRoot "state\HALT"
if (Test-Path $halt) { Add-Result WARN "state\HALT" "present: the runner will refuse to start. Contents: $(Get-Content $halt -Raw)" }
$ledger = Join-Path $RepoRoot "reports\ledger.jsonl"
if (Test-Path $ledger) {
    $runs = Get-Content $ledger | ForEach-Object { ($_ | ConvertFrom-Json).split }
    Add-Result PASS "Backtest ledger" "runs so far: $($runs -join ', ')"
} else {
    Add-Result WARN "Backtest ledger" "no backtest run yet (next: scripts\research.ps1)"
}
foreach ($s in "EURUSD", "GBPUSD", "NAS100", "XAUUSD") {
    $dir = Join-Path $RepoRoot "data\raw\$s"
    $n = if (Test-Path $dir) { (Get-ChildItem $dir -Filter *.parquet | Measure-Object).Count } else { 0 }
    Add-Result ($(if ($n -gt 1000) { "PASS" } else { "WARN" })) "Tick data $s" "$n day files"
}

# --- Test suite ---------------------------------------------------------------
if ($hasUv -and -not $SkipTests) {
    $out = (uv run --frozen pytest -q 2>&1 | Select-Object -Last 1)
    Add-Result ($(if ($LASTEXITCODE -eq 0) { "PASS" } else { "FAIL" })) "Test suite" "$out"
}

# --- Summary ------------------------------------------------------------------
$fails = @($results | Where-Object Status -eq "FAIL").Count
$warns = @($results | Where-Object Status -eq "WARN").Count
Write-Host ""
Write-Host ("Summary: {0} PASS, {1} WARN, {2} FAIL" -f @($results | Where-Object Status -eq "PASS").Count, $warns, $fails) `
    -ForegroundColor $(if ($fails) { "Red" } elseif ($warns) { "Yellow" } else { "Green" })
Write-Host "Copy everything above and paste it to Claude for a diagnosis."
exit $(if ($fails) { 1 } else { 0 })
