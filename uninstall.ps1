<#
.SYNOPSIS
    Uninstall everything that install.ps1 put on the machine.

.DESCRIPTION
    Reverses the installer:
      - Unregisters the WorkIQ MCP server from Copilot CLI config
      - Uninstalls Copilot CLI (winget GitHub.Copilot)
      - Uninstalls Azure CLI, GitHub CLI, Node.js LTS, Git (unless -Keep* flags)
      - Removes leftover npm global @github/copilot from earlier attempts
      - Removes the npm prefix from User PATH if we previously added it

    One-liner:
        irm https://raw.githubusercontent.com/SpiffLab/copilot-cli-workiq-azure-installer/main/uninstall.ps1 | iex

    With flags:
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/SpiffLab/copilot-cli-workiq-azure-installer/main/uninstall.ps1))) -KeepGit -KeepNode

.PARAMETER KeepNode
    Do not uninstall Node.js LTS.

.PARAMETER KeepGit
    Do not uninstall Git.

.PARAMETER KeepGh
    Do not uninstall GitHub CLI (gh).

.PARAMETER KeepAzure
    Do not uninstall Azure CLI (az).

.PARAMETER KeepWorkIQConfig
    Do not remove the WorkIQ entry from the Copilot CLI MCP config.

.PARAMETER NoWait
    Skip the "Press Enter to close" pause at the end.
#>
[CmdletBinding()]
param(
    [switch]$KeepNode,
    [switch]$KeepGit,
    [switch]$KeepGh,
    [switch]$KeepAzure,
    [switch]$KeepWorkIQConfig,
    [switch]$NoWait
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$script:LogPath = Join-Path $env:TEMP ("copilot-cli-uninstaller-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { Start-Transcript -Path $script:LogPath -Force | Out-Null } catch { }

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Info { param([string]$m) Write-Host "    $m" -ForegroundColor Gray }
function Write-Ok   { param([string]$m) Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Skip { param([string]$m) Write-Host "[--] $m" -ForegroundColor DarkGray }
function Write-Warn2{ param([string]$m) Write-Host "[!!] $m" -ForegroundColor Yellow }

function Uninstall-WingetPackage {
    param([string]$Id, [string]$Friendly)
    $listed = winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String
    if ($listed -notmatch [regex]::Escape($Id)) {
        Write-Skip "$Friendly not installed (winget: $Id)"
        return
    }
    Write-Info "Uninstalling $Friendly ($Id)..."
    winget uninstall --id $Id --exact --silent --accept-source-agreements --disable-interactivity 2>&1 |
        ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -eq 0) { Write-Ok "$Friendly uninstalled" }
    else { Write-Warn2 "$Friendly uninstall exited $LASTEXITCODE" }
}

function Remove-WorkIQMcpConfig {
    $candidatePaths = @(
        (Join-Path $env:USERPROFILE '.copilot\mcp-config.json'),
        (Join-Path $env:USERPROFILE '.copilot\mcp.json')
    )
    $found = $false
    foreach ($p in $candidatePaths) {
        if (-not (Test-Path $p)) { continue }
        $found = $true
        try {
            $raw = Get-Content -Raw -Path $p
            if (-not $raw.Trim()) { Write-Skip "Empty config: $p"; continue }
            $obj = $raw | ConvertFrom-Json
            $changed = $false
            if ($obj.PSObject.Properties.Name -contains 'mcpServers' -and $obj.mcpServers) {
                if ($obj.mcpServers.PSObject.Properties.Name -contains 'workiq') {
                    $obj.mcpServers.PSObject.Properties.Remove('workiq')
                    $changed = $true
                }
            }
            if ($changed) {
                ($obj | ConvertTo-Json -Depth 10) | Set-Content -Path $p -Encoding UTF8
                Write-Ok "Removed 'workiq' from $p"
            } else {
                Write-Skip "No 'workiq' entry in $p"
            }
        } catch {
            Write-Warn2 "Could not edit $p ($($_.Exception.Message))"
        }
    }
    if (-not $found) { Write-Skip 'No Copilot MCP config file found' }
}

function Remove-NpmCopilotLeftover {
    # In case a previous installer version used npm-global @github/copilot.
    $npmCandidates = @(
        "$env:ProgramFiles\nodejs\npm.cmd",
        "${env:ProgramFiles(x86)}\nodejs\npm.cmd",
        "$env:APPDATA\npm\npm.cmd"
    ) | Where-Object { Test-Path $_ }
    $npmCandidates = @($npmCandidates)  # force array so [0] is the full path, not the first character

    if ($npmCandidates.Count -gt 0) {
        $npmCmd = $npmCandidates[0]
        Write-Info "Running: $npmCmd uninstall -g @github/copilot"
        & $npmCmd uninstall -g '@github/copilot' 2>&1 |
            ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    } else {
        Write-Skip 'npm not found; cannot uninstall npm-global @github/copilot (may not exist).'
    }

    # Best-effort file cleanup for copilot.* shims in %APPDATA%\npm.
    $npmPrefixShims = Join-Path $env:APPDATA 'npm\copilot*'
    $found = Get-ChildItem $npmPrefixShims -ErrorAction SilentlyContinue
    if ($found) {
        $found | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Ok "Removed leftover shims from $env:APPDATA\npm"
    }
}

function Remove-NpmPrefixFromUserPath {
    $npmPrefix = Join-Path $env:APPDATA 'npm'
    try {
        $user = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (-not $user) { return }
        $segments = $user.Split(';') | Where-Object { $_ -and $_ -ne $npmPrefix }
        $newUser = $segments -join ';'
        if ($newUser -ne $user) {
            [Environment]::SetEnvironmentVariable('Path', $newUser, 'User')
            Write-Ok "Removed $npmPrefix from User PATH (takes effect in new terminals)"
        } else {
            Write-Skip "$npmPrefix not in User PATH"
        }
    } catch {
        Write-Warn2 "Could not edit User PATH: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Copilot CLI + WorkIQ + Azure CLI uninstaller' -ForegroundColor White
Write-Host '--------------------------------------------' -ForegroundColor DarkGray

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Warn2 'winget not found; package uninstalls will be skipped.'
}

Write-Step 'WorkIQ MCP registration'
if ($KeepWorkIQConfig) { Write-Skip 'Kept (-KeepWorkIQConfig)' }
else { Remove-WorkIQMcpConfig }

Write-Step 'Leftover npm-global @github/copilot (from earlier installer versions)'
Remove-NpmCopilotLeftover
Remove-NpmPrefixFromUserPath

Write-Step 'winget uninstalls'
if (Get-Command winget -ErrorAction SilentlyContinue) {
    Uninstall-WingetPackage -Id 'GitHub.Copilot'     -Friendly 'GitHub Copilot CLI'
    if ($KeepAzure)   { Write-Skip 'Azure CLI kept (-KeepAzure)' }     else { Uninstall-WingetPackage -Id 'Microsoft.AzureCLI'  -Friendly 'Azure CLI' }
    if ($KeepGh)      { Write-Skip 'GitHub CLI kept (-KeepGh)' }        else { Uninstall-WingetPackage -Id 'GitHub.cli'         -Friendly 'GitHub CLI' }
    if ($KeepNode)    { Write-Skip 'Node.js LTS kept (-KeepNode)' }     else { Uninstall-WingetPackage -Id 'OpenJS.NodeJS.LTS'  -Friendly 'Node.js LTS' }
    if ($KeepGit)     { Write-Skip 'Git kept (-KeepGit)' }              else { Uninstall-WingetPackage -Id 'Git.Git'            -Friendly 'Git' }
}

Write-Host ''
Write-Host "Transcript log: $script:LogPath" -ForegroundColor DarkCyan
Write-Host 'Uninstall complete. Open a new terminal to pick up PATH changes.' -ForegroundColor Green
Write-Host ''

try { Stop-Transcript | Out-Null } catch { }

if (-not $NoWait -and $Host.Name -eq 'ConsoleHost' -and [Environment]::UserInteractive) {
    try {
        Write-Host 'Press Enter to close this window...' -ForegroundColor Yellow
        [void](Read-Host)
    } catch { }
}
