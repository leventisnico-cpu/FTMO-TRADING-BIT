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
