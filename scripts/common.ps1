# Shared helpers, dot-sourced by the other scripts:  . "$PSScriptRoot\common.ps1"

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path $PSScriptRoot -Parent
Set-Location $RepoRoot

# uv's installer puts uv.exe in ~\.local\bin but only shells opened afterwards
# see it on PATH; pick it up here so scripts work in the same window.
if ($env:USERPROFILE -and -not (Get-Command uv -ErrorAction SilentlyContinue)) {
    $uvHome = Join-Path $env:USERPROFILE ".local\bin"
    if (Test-Path (Join-Path $uvHome "uv.exe")) { $env:Path = "$uvHome;$env:Path" }
}

function Import-DotEnv {
    <#
      Loads KEY=VALUE lines from .env (git-ignored) into this process's
      environment. Variables already set in the environment win, so a VPS can
      use real environment variables instead of a file.
    #>
    param([string]$Path = (Join-Path $RepoRoot ".env"))
    if (-not (Test-Path $Path)) { return }
    foreach ($line in Get-Content $Path) {
        $t = $line.Trim()
        if ($t -eq "" -or $t.StartsWith("#")) { continue }
        $i = $t.IndexOf("=")
        if ($i -lt 1) { continue }
        $key = $t.Substring(0, $i).Trim()
        $val = $t.Substring($i + 1).Trim().Trim('"').Trim("'")
        if (-not (Test-Path "Env:$key") -and $val -ne "") {
            Set-Item -Path "Env:$key" -Value $val
        }
    }
}

function Assert-Command {
    param([string]$Name, [string]$Hint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name not found on PATH. $Hint"
    }
}

function Test-PythonEnv {
    # True when the project's Python runs. `uv run` also creates .venv if missing.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"  # PS 5.1 turns redirected stderr into errors
    try {
        $script:PythonProbe = (uv run --frozen python -c "import sys; print(sys.version.split()[0])" 2>&1 |
            ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } } |
            Where-Object { $_ -and $_ -ne "System.Management.Automation.RemoteException" }) -join "`n  "
        return ($LASTEXITCODE -eq 0)
    } finally { $ErrorActionPreference = $prev }
}

function Repair-PythonEnv {
    <#
      Makes sure the project's Python interpreter exists. If it is gone (most
      often Windows Security quarantined python.exe), reinstalls Python 3.11,
      rebuilds .venv and reinstalls every package. Throws if that fails.
    #>
    if (Test-PythonEnv) {
        Write-Host "Python OK ($script:PythonProbe)" -ForegroundColor Green
        return
    }
    Write-Host ""
    Write-Host "Python environment is broken:" -ForegroundColor Yellow
    Write-Host "  $script:PythonProbe" -ForegroundColor Yellow
    Write-Host "Usually Windows Security quarantined python.exe. Reinstalling..." -ForegroundColor Yellow
    Invoke-Step "Reinstall Python 3.11" { uv python install 3.11 --reinstall }
    $venv = Join-Path $RepoRoot ".venv"
    if (Test-Path $venv) { Remove-Item $venv -Recurse -Force }
    Invoke-Step "Rebuild .venv and reinstall packages" { uv sync --group dev --extra live }
    if (-not (Test-PythonEnv)) {
        throw ("Python still broken after reinstall: $script:PythonProbe`n" +
            "Windows Security is probably deleting it again. Check Protection history; " +
            "if python.exe under AppData\Roaming\uv\python is listed with a generic " +
            "detection, choose Allow, or add that folder under Exclusions, then re-run.")
    }
    Write-Host "Python repaired ($script:PythonProbe)" -ForegroundColor Green
}

function Invoke-Step {
    # Runs a native command and stops the script if it fails.
    param([string]$Title, [scriptblock]$Block)
    Write-Host ""
    Write-Host "==> $Title" -ForegroundColor Cyan
    & $Block
    if ($LASTEXITCODE -eq -1073739514) {
        # 0xC0000906 STATUS_VIRUS_INFECTED: antivirus killed the process.
        throw ("step '$Title' was stopped by Windows Security (0xC0000906, a virus/threat " +
            "block). This is not a failing test. Open Windows Security > Virus & threat " +
            "protection > Protection history to see which file it flagged, then see " +
            "README.md 'Windows Security blocked a step'.")
    }
    if ($LASTEXITCODE -ne 0) { throw "step failed ($LASTEXITCODE): $Title" }
}
