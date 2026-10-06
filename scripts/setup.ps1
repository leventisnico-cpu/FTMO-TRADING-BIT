<#
.SYNOPSIS
  One-time setup on Windows (your PC or the VPS): installs uv if missing,
  installs dependencies, runs the full test suite, and checks MetaTrader 5.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
#>
. "$PSScriptRoot\common.ps1"

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Host "Installing uv..." -ForegroundColor Cyan
    powershell -ExecutionPolicy Bypass -c "irm https://astral.sh/uv/install.ps1 | iex"
    $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
    Assert-Command uv "Open a new PowerShell window and re-run this script."
}
Assert-Command git "Install Git for Windows: https://git-scm.com/download/win"

Invoke-Step "Install Python 3.11 + dependencies (incl. MetaTrader5 package)" {
    uv sync --group dev --extra live
}
Invoke-Step "Lint" { uv run ruff check src tests }
Invoke-Step "Type check (strict)" { uv run mypy }
Invoke-Step "Test suite" { uv run pytest -q }

Invoke-Step "MetaTrader5 Python package" {
    uv run python -c "import MetaTrader5 as m; print('MetaTrader5', m.__version__)"
}

if (-not (Test-Path (Join-Path $RepoRoot ".env"))) {
    Copy-Item (Join-Path $RepoRoot ".env.example") (Join-Path $RepoRoot ".env")
    Write-Host ""
    Write-Host "Created .env from .env.example. Fill in your MT5 logins before going live." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Setup complete. Next: scripts\research.ps1 (download + in-sample backtest)." -ForegroundColor Green
