<#
.SYNOPSIS
    Uninstall everything that install.ps1 put on the machine.

.DESCRIPTION
    Reverses the installer:
      - Unregisters the WorkIQ MCP server from Copilot CLI config
      - Uninstalls Copilot CLI (winget GitHub.Copilot) and scrubs any
        leftover portable-package directory + WinGet\Links shims
      - Uninstalls Azure CLI, GitHub CLI, Node.js LTS, Git (unless -Keep* flags)
      - Removes leftover npm global @github/copilot from earlier attempts
      - Removes the npm prefix from User PATH if we previously added it

    Self-elevates via UAC when not already running as admin so the MSI
    uninstalls actually succeed (pass -NoElevate to skip).

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

.PARAMETER NoElevate
    Do not attempt to relaunch elevated. Useful for CI or when you know admin
    is not needed. Without this flag, a non-admin run will re-launch itself
    via UAC so MSI uninstalls (Node.js, Git, gh, az) can actually proceed.

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
    [switch]$NoElevate,
    [switch]$NoWait
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$script:LogPath = Join-Path $env:TEMP ("copilot-cli-uninstaller-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { Start-Transcript -Path $script:LogPath -Force | Out-Null } catch { }

$script:Summary = [System.Collections.Generic.List[string]]::new()

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Info { param([string]$m) Write-Host "    $m" -ForegroundColor Gray }
function Write-Ok   { param([string]$m) Write-Host "[OK] $m" -ForegroundColor Green;    $script:Summary.Add("[OK]   $m") }
function Write-Skip { param([string]$m) Write-Host "[--] $m" -ForegroundColor DarkGray; $script:Summary.Add("[skip] $m") }
function Write-Warn2{ param([string]$m) Write-Host "[!!] $m" -ForegroundColor Yellow;   $script:Summary.Add("[warn] $m") }
function Write-Fail { param([string]$m) Write-Host "[XX] $m" -ForegroundColor Red;      $script:Summary.Add("[FAIL] $m") }

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Uninstall-WingetPackage {
    param([string]$Id, [string]$Friendly)
    $listed = winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String
    if ($listed -notmatch [regex]::Escape($Id)) {
        Write-Skip "$Friendly not installed (winget: $Id)"
        return
    }
    Write-Info "Uninstalling $Friendly ($Id)..."
    # Note: intentionally NOT using --disable-interactivity. Some packages
    # (Azure CLI MSI, Git MSI) require admin; blocking UAC causes silent
    # failures. We self-elevate in Main so UAC shouldn't pop again here.
    winget uninstall --id $Id --exact --silent --accept-source-agreements 2>&1 |
        ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    $code = $LASTEXITCODE

    # Re-check to confirm removal. winget sometimes returns 0 even when the
    # package is still registered (e.g., another installer scope owns it).
    $after = winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String
    if ($after -notmatch [regex]::Escape($Id)) {
        Write-Ok "$Friendly uninstalled"
    } elseif ($code -ne 0) {
        Write-Fail "$Friendly uninstall exited $code (still registered with winget)"
    } else {
        Write-Warn2 "$Friendly still registered after winget uninstall (may require admin or manual removal)"
    }
}

function Remove-CopilotPortableLeftovers {
    # GitHub.Copilot ships as a winget "portable" package. When uninstalled
    # via winget the package manifest is removed but the extracted directory
    # under %LOCALAPPDATA%\Microsoft\WinGet\Packages can be left behind,
    # along with a shim in %LOCALAPPDATA%\Microsoft\WinGet\Links that keeps
    # `copilot` resolvable on PATH. This makes a subsequent install.ps1
    # report "already present" even though winget has no record of it.
    $packagesRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    $linksDir     = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'

    if (Test-Path $packagesRoot) {
        $orphans = Get-ChildItem -Path $packagesRoot -Directory -Filter 'GitHub.Copilot_*' -ErrorAction SilentlyContinue
        foreach ($dir in $orphans) {
            try {
                Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
                Write-Ok "Removed leftover Copilot portable package: $($dir.FullName)"
            } catch {
                Write-Warn2 "Could not remove $($dir.FullName): $($_.Exception.Message)"
            }
        }
        if (-not $orphans) { Write-Skip 'No leftover GitHub.Copilot portable package directory' }
    } else {
        Write-Skip 'WinGet Packages directory not present'
    }

    if (Test-Path $linksDir) {
        $shims = Get-ChildItem -Path $linksDir -Filter 'copilot*' -ErrorAction SilentlyContinue
        foreach ($shim in $shims) {
            try {
                Remove-Item -LiteralPath $shim.FullName -Force -ErrorAction Stop
                Write-Ok "Removed WinGet Links shim: $($shim.Name)"
            } catch {
                Write-Warn2 "Could not remove $($shim.FullName): $($_.Exception.Message)"
            }
        }
        if (-not $shims) { Write-Skip 'No copilot shim in WinGet\Links' }
    }
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

# Self-elevate so MSI uninstalls (Git, Node.js, gh, az) actually succeed.
# When invoked via `irm ... | iex` the script has no $PSCommandPath, so
# we fall back to re-downloading from the same URL when elevation is needed.
if (-not (Test-IsAdmin) -and -not $NoElevate) {
    Write-Warn2 'Not running elevated. MSI uninstalls (Node.js, Git, gh, az) require admin.'
    Write-Info  'Relaunching elevated via UAC... (pass -NoElevate to skip)'

    # Forward the original switches so the elevated run matches user intent.
    $forwarded = @()
    if ($KeepNode)         { $forwarded += '-KeepNode' }
    if ($KeepGit)          { $forwarded += '-KeepGit' }
    if ($KeepGh)           { $forwarded += '-KeepGh' }
    if ($KeepAzure)        { $forwarded += '-KeepAzure' }
    if ($KeepWorkIQConfig) { $forwarded += '-KeepWorkIQConfig' }
    if ($NoWait)           { $forwarded += '-NoWait' }
    $forwarded += '-NoElevate'   # prevent infinite elevation loop

    try {
        if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
            $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $forwarded
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait
        } else {
            # Running via `irm | iex` — no file on disk. Stage to a temp .ps1
            # and re-invoke so the elevated host can `-File` it cleanly.
            $tempScript = Join-Path $env:TEMP ("copilot-cli-uninstaller-{0}.ps1" -f (Get-Date -Format 'yyyyMMddHHmmss'))
            $url = 'https://raw.githubusercontent.com/SpiffLab/copilot-cli-workiq-azure-installer/main/uninstall.ps1'
            Write-Info "Downloading uninstaller to $tempScript for elevated run..."
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tempScript
            $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$tempScript`"") + $forwarded
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait
        }
        Write-Host ''
        Write-Host 'Elevated uninstaller finished. See its window for details.' -ForegroundColor Green
        try { Stop-Transcript | Out-Null } catch { }
        return
    } catch {
        Write-Warn2 "Elevation failed or was cancelled: $($_.Exception.Message)"
        Write-Warn2 'Continuing in non-elevated mode; MSI uninstalls will likely fail.'
    }
}

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

Write-Step 'Copilot CLI portable leftovers'
Remove-CopilotPortableLeftovers

Write-Host "`n============================================" -ForegroundColor DarkGray
Write-Host 'Uninstall summary'                                -ForegroundColor White
Write-Host '============================================'    -ForegroundColor DarkGray
$script:Summary | ForEach-Object { Write-Host $_ }

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
