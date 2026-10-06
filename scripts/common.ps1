# Shared helpers, dot-sourced by the other scripts:  . "$PSScriptRoot\common.ps1"

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path $PSScriptRoot -Parent
Set-Location $RepoRoot

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
    if ($LASTEXITCODE -ne 0) { throw "step failed ($LASTEXITCODE): $Title" }
}
