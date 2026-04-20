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

.PARAMETER KeepCopilot
    Do not uninstall GitHub Copilot CLI (and skip scrubbing its portable
    leftovers under %LOCALAPPDATA%\Microsoft\WinGet\Packages / Links).

.PARAMETER KeepWorkIQConfig
    Do not remove the WorkIQ entry from the Copilot CLI MCP config.

.PARAMETER NoElevate
    Do not attempt to relaunch elevated. Useful for CI or when you know admin
    is not needed. Without this flag, a non-admin run will re-launch itself
    via UAC so MSI uninstalls (Node.js, Git, gh, az) can actually proceed.

.PARAMETER Yes
    Skip the interactive component picker and remove everything (respecting
    any -Keep* flags). Useful for CI / unattended runs.

.PARAMETER NoWait
    Skip the "Press Enter to close" pause at the end.
#>
[CmdletBinding()]
param(
    [switch]$KeepNode,
    [switch]$KeepGit,
    [switch]$KeepGh,
    [switch]$KeepAzure,
    [switch]$KeepCopilot,
    [switch]$KeepWorkIQConfig,
    [switch]$NoElevate,
    [switch]$Yes,
    [switch]$NoWait
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$script:LogPath = Join-Path $env:TEMP ("copilot-cli-uninstaller-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { Start-Transcript -Path $script:LogPath -Force | Out-Null } catch { }

# ---------------------------------------------------------------------------
# Install manifest (written by install.ps1). Tells us which components the
# installer actually put on the machine vs. which were already present so
# we don't remove tools the user installed themselves before.
# ---------------------------------------------------------------------------

$script:ManifestDir  = Join-Path $env:LOCALAPPDATA 'copilot-cli-workiq-azure-installer'
$script:ManifestPath = Join-Path $script:ManifestDir 'manifest.json'
$script:Manifest     = $null   # hashtable of component -> @{state; id; at}

function Get-ManifestState {
    param([Parameter(Mandatory)][string]$Key)
    if (-not $script:Manifest) { return $null }
    if (-not $script:Manifest.ContainsKey($Key)) { return $null }
    return $script:Manifest[$Key].state
}

function Remove-ManifestComponent {
    param([Parameter(Mandatory)][string]$Key)
    if (-not $script:Manifest) { return }
    if ($script:Manifest.ContainsKey($Key)) { $script:Manifest.Remove($Key) }
}

function Load-Manifest {
    if (-not (Test-Path $script:ManifestPath)) { return }
    try {
        $raw = Get-Content -Raw -Path $script:ManifestPath -ErrorAction Stop
        if (-not $raw.Trim()) { return }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $components = [ordered]@{}
        if ($obj.PSObject.Properties.Name -contains 'components' -and $obj.components) {
            $obj.components.PSObject.Properties | ForEach-Object {
                $v = $_.Value
                $entry = @{}
                $v.PSObject.Properties | ForEach-Object { $entry[$_.Name] = $_.Value }
                $components[$_.Name] = $entry
            }
        }
        $script:Manifest = $components
        Write-Info "Loaded install manifest: $script:ManifestPath"
    } catch {
        Write-Warn2 "Could not parse install manifest ($script:ManifestPath): $($_.Exception.Message)"
    }
}

function Save-Manifest {
    # Called at the end to persist / delete the manifest based on what's left.
    try {
        if (-not $script:Manifest -or $script:Manifest.Count -eq 0) {
            if (Test-Path $script:ManifestPath) {
                Remove-Item -LiteralPath $script:ManifestPath -Force -ErrorAction SilentlyContinue
                # Clean up empty dir too.
                if ((Test-Path $script:ManifestDir) -and -not (Get-ChildItem $script:ManifestDir -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item -LiteralPath $script:ManifestDir -Force -ErrorAction SilentlyContinue
                }
                Write-Info "Removed install manifest (all tracked components gone)"
            }
            return
        }
        if (-not (Test-Path $script:ManifestDir)) {
            New-Item -ItemType Directory -Force -Path $script:ManifestDir | Out-Null
        }
        $out = [ordered]@{
            version    = 1
            updatedAt  = (Get-Date).ToString('o')
            components = $script:Manifest
        }
        ($out | ConvertTo-Json -Depth 10) | Set-Content -Path $script:ManifestPath -Encoding UTF8
    } catch {
        Write-Warn2 "Could not update install manifest: $($_.Exception.Message)"
    }
}

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

# Run winget quietly with a clean animated progress bar instead of letting
# winget's spinner + UTF-8 progress chars pollute the console.
function Invoke-WingetQuiet {
    param(
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $logDir  = Join-Path $env:TEMP 'copilot-cli-workiq-azure-installer'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $stamp   = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $stdout  = Join-Path $logDir "winget-$stamp.out.log"
    $stderr  = Join-Path $logDir "winget-$stamp.err.log"

    $proc = Start-Process -FilePath 'winget' -ArgumentList $Arguments `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError  $stderr

    $start  = Get-Date
    $frames = @('|','/','-','\')
    $i = 0
    try {
        while (-not $proc.HasExited) {
            $elapsed = [int]((Get-Date) - $start).TotalSeconds
            $status  = "{0}  elapsed {1:00}:{2:00}" -f $frames[$i % $frames.Length], [math]::Floor($elapsed/60), ($elapsed % 60)
            $hint = ''
            if (Test-Path $stdout) {
                $lastLine = Get-Content -LiteralPath $stdout -Tail 1 -ErrorAction SilentlyContinue
                if ($lastLine) { $hint = ($lastLine -replace '[\u2580-\u259F\u2500-\u257F]', '').Trim() }
            }
            if ($hint) { $status = "$status  -  $hint" }
            Write-Progress -Activity $Activity -Status $status -PercentComplete -1
            Start-Sleep -Milliseconds 250
            $i++
        }
    } finally {
        Write-Progress -Activity $Activity -Completed
    }

    return [pscustomobject]@{
        ExitCode  = $proc.ExitCode
        StdoutLog = $stdout
        StderrLog = $stderr
    }
}

function Uninstall-WingetPackage {
    param(
        [string]$Id,
        [string]$Friendly,
        [string]$LeftoverHint,    # optional message when winget has no record (e.g., Copilot portable files)
        [string]$ManifestKey       # remove this manifest component on successful uninstall
    )
    $listed = winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String
    if ($listed -notmatch [regex]::Escape($Id)) {
        if ($LeftoverHint) {
            Write-Skip "$Friendly not registered with winget - $LeftoverHint"
        } else {
            Write-Skip "$Friendly not installed (winget: $Id)"
        }
        if ($ManifestKey) { Remove-ManifestComponent -Key $ManifestKey }
        return
    }
    Write-Info "Uninstalling $Friendly ($Id)..."
    # Note: intentionally NOT using --disable-interactivity. Some packages
    # (Azure CLI MSI, Git MSI) require admin; blocking UAC causes silent
    # failures. We self-elevate in Main so UAC shouldn't pop again here.
    $result = Invoke-WingetQuiet -Activity "Uninstalling $Friendly" -Arguments @(
        'uninstall', '--id', $Id, '--exact', '--silent', '--accept-source-agreements'
    )
    $code = $result.ExitCode

    # Re-check to confirm removal. winget sometimes returns 0 even when the
    # package is still registered (e.g., another installer scope owns it).
    $after = winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String
    if ($after -notmatch [regex]::Escape($Id)) {
        Write-Ok "$Friendly uninstalled"
        if ($ManifestKey) { Remove-ManifestComponent -Key $ManifestKey }
    } elseif ($code -ne 0) {
        Write-Fail "$Friendly uninstall exited $code (still registered with winget)"
        Write-Fail "See log: $($result.StdoutLog)"
        try {
            $tail = Get-Content -LiteralPath $result.StdoutLog -Tail 8 -ErrorAction SilentlyContinue
            if ($tail) { $tail | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray } }
        } catch { }
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
                Remove-ManifestComponent -Key 'workiq'
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

function Invoke-ComponentPicker {
    # Interactive checklist. Defaults reflect current flags + detected state.
    # Returns a hashtable of Keep* booleans.
    $haveWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)

    function Test-WingetInstalled {
        param([string]$Id)
        if (-not $haveWinget) { return $false }
        $listed = winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String
        return ($listed -match [regex]::Escape($Id))
    }

    $workiqCfg = @(
        (Join-Path $env:USERPROFILE '.copilot\mcp-config.json'),
        (Join-Path $env:USERPROFILE '.copilot\mcp.json')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    $copilotLeftover = Test-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages')
    $copilotLeftover = $copilotLeftover -and ((Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Directory -Filter 'GitHub.Copilot_*' -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)

    $items = @(
        [pscustomobject]@{ Key='workiq'; Label='WorkIQ MCP server registration';     Detected=[bool]$workiqCfg;                        KeepFlag='KeepWorkIQConfig'; CurrentKeep=$KeepWorkIQConfig }
        [pscustomobject]@{ Key='copilot';Label='GitHub Copilot CLI (winget + leftovers)'; Detected=((Test-WingetInstalled 'GitHub.Copilot') -or $copilotLeftover); KeepFlag='KeepCopilot';     CurrentKeep=$KeepCopilot }
        [pscustomobject]@{ Key='az';     Label='Azure CLI';                           Detected=(Test-WingetInstalled 'Microsoft.AzureCLI'); KeepFlag='KeepAzure';       CurrentKeep=$KeepAzure }
        [pscustomobject]@{ Key='gh';     Label='GitHub CLI (gh)';                     Detected=(Test-WingetInstalled 'GitHub.cli');        KeepFlag='KeepGh';          CurrentKeep=$KeepGh }
        [pscustomobject]@{ Key='node';   Label='Node.js LTS';                         Detected=(Test-WingetInstalled 'OpenJS.NodeJS.LTS'); KeepFlag='KeepNode';        CurrentKeep=$KeepNode }
        [pscustomobject]@{ Key='git';    Label='Git';                                 Detected=(Test-WingetInstalled 'Git.Git');           KeepFlag='KeepGit';         CurrentKeep=$KeepGit }
    )

    # Default state rules (highest priority first):
    #   1. If manifest says "already-present" or "already-registered": default KEEP
    #      (the user had it before we ran; we should NOT remove it).
    #   2. If user passed -Keep* for this item: KEEP.
    #   3. Else if detected on the machine: REMOVE.
    #   4. Else: do nothing (not detected).
    $state = @{}
    $manifestHeld = @{}   # keys we're defaulting to KEEP due to manifest history
    foreach ($it in $items) {
        $manifestState = Get-ManifestState -Key $it.Key
        if ($manifestState -in @('already-present','already-registered')) {
            $state[$it.Key] = $false
            $manifestHeld[$it.Key] = $manifestState
        } else {
            $state[$it.Key] = ($it.Detected -and -not $it.CurrentKeep)
        }
    }

    $done = $false
    while (-not $done) {
        Write-Host ''
        Write-Host 'Select components to remove:' -ForegroundColor White
        Write-Host '  [x] = will be removed   [ ] = will be kept   (dim = not detected)' -ForegroundColor DarkGray
        if ($manifestHeld.Count -gt 0) {
            Write-Host '  (*) = was present before our installer ran; defaulted to KEEP' -ForegroundColor DarkGray
        }
        Write-Host ''
        for ($i = 0; $i -lt $items.Count; $i++) {
            $it = $items[$i]
            $mark = if ($state[$it.Key]) { 'x' } else { ' ' }
            $color = if ($it.Detected) { 'White' } else { 'DarkGray' }
            $suffix = ''
            if ($manifestHeld.ContainsKey($it.Key)) { $suffix = ' (*)  pre-existing' ; $color = 'DarkYellow' }
            elseif (-not $it.Detected) { $suffix = ' (not detected)' }
            Write-Host ("  {0}. [{1}] {2}{3}" -f ($i + 1), $mark, $it.Label, $suffix) -ForegroundColor $color
        }
        Write-Host ''
        Write-Host '  [A] All detected   [N] None   [Enter] Proceed   [C] Cancel' -ForegroundColor Cyan
        $choice = Read-Host 'Toggle by number, or pick an action'
        if ($null -eq $choice) { $choice = '' }
        $choice = $choice.Trim()

        if ($choice -eq '' ) { $done = $true; break }
        switch -Regex ($choice) {
            '^[aA]$' {
                # "All" respects manifest: pre-existing items stay off unless
                # the user explicitly toggles them by number.
                foreach ($it in $items) {
                    if ($manifestHeld.ContainsKey($it.Key)) { continue }
                    if ($it.Detected) { $state[$it.Key] = $true }
                }
                break
            }
            '^[nN]$' { foreach ($it in $items) { $state[$it.Key] = $false } ; break }
            '^[cC]$' { Write-Host 'Cancelled.' -ForegroundColor Yellow; exit 0 }
            '^\d+$'  {
                $n = [int]$choice
                if ($n -ge 1 -and $n -le $items.Count) {
                    $k = $items[$n - 1].Key
                    if ($manifestHeld.ContainsKey($k) -and -not $state[$k]) {
                        Write-Host "    WARNING: '$($items[$n-1].Label)' was already on this machine before our installer ran." -ForegroundColor Yellow
                        Write-Host "    Toggling it ON will uninstall software the user had previously." -ForegroundColor Yellow
                    }
                    $state[$k] = -not $state[$k]
                } else {
                    Write-Warn2 "Out of range: $n"
                }
            }
            default  { Write-Warn2 "Unrecognized input: '$choice'" }
        }
    }

    # Translate picker state back into Keep* flags.
    $result = @{
        KeepWorkIQConfig = -not $state['workiq']
        KeepCopilot      = -not $state['copilot']
        KeepAzure        = -not $state['az']
        KeepGh           = -not $state['gh']
        KeepNode         = -not $state['node']
        KeepGit          = -not $state['git']
    }
    return $result
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Copilot CLI + WorkIQ + Azure CLI uninstaller' -ForegroundColor White
Write-Host '--------------------------------------------' -ForegroundColor DarkGray

# Load install manifest (written by install.ps1). Presence of a component
# with state 'already-present' or 'already-registered' means the user had
# it before our installer ran, so the uninstaller will default to KEEPing
# it even if it is currently detected on the machine.
Load-Manifest

# Interactive component picker. Runs before elevation so the user's choices
# can be forwarded into the elevated child as -Keep* flags. Skipped when
# -Yes is passed or when not running in an interactive console host.
$interactive = (-not $Yes) -and ($Host.Name -eq 'ConsoleHost') -and [Environment]::UserInteractive
if ($interactive) {
    try {
        $picked = Invoke-ComponentPicker
        $KeepWorkIQConfig = [bool]$picked.KeepWorkIQConfig
        $KeepCopilot      = [bool]$picked.KeepCopilot
        $KeepAzure        = [bool]$picked.KeepAzure
        $KeepGh           = [bool]$picked.KeepGh
        $KeepNode         = [bool]$picked.KeepNode
        $KeepGit          = [bool]$picked.KeepGit
    } catch {
        Write-Warn2 "Picker failed ($($_.Exception.Message)); falling back to default behaviour."
    }
}

# Self-elevate so MSI uninstalls (Git, Node.js, gh, az) actually succeed.
# When invoked via `irm ... | iex` the script has no $PSCommandPath, so
# we fall back to re-downloading from the same URL when elevation is needed.
if (-not (Test-IsAdmin) -and -not $NoElevate) {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host '  UAC prompt incoming'                                         -ForegroundColor Yellow
    Write-Host '  A Windows UAC dialog is about to open asking for admin'     -ForegroundColor Yellow
    Write-Host '  permission. If you do not see it, check the taskbar -'      -ForegroundColor Yellow
    Write-Host '  Windows sometimes puts it behind other windows.'            -ForegroundColor Yellow
    Write-Host '  Click "Yes" to continue. MSI uninstalls (Node, Git, gh,'    -ForegroundColor Yellow
    Write-Host '  az) require admin rights to run.'                           -ForegroundColor Yellow
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host ''
    Write-Info 'Relaunching elevated via UAC... (pass -NoElevate to skip)'

    # Forward the original switches so the elevated run matches user intent.
    $forwarded = @('-Yes')   # picker already ran pre-elevation; don't re-prompt
    if ($KeepNode)         { $forwarded += '-KeepNode' }
    if ($KeepGit)          { $forwarded += '-KeepGit' }
    if ($KeepGh)           { $forwarded += '-KeepGh' }
    if ($KeepAzure)        { $forwarded += '-KeepAzure' }
    if ($KeepCopilot)      { $forwarded += '-KeepCopilot' }
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
    if ($KeepCopilot) {
        Write-Skip 'GitHub Copilot CLI kept (-KeepCopilot)'
    } else {
        $copilotPackagesRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
        $copilotHasLeftovers = $false
        if (Test-Path $copilotPackagesRoot) {
            $copilotHasLeftovers = [bool](Get-ChildItem -Path $copilotPackagesRoot -Directory -Filter 'GitHub.Copilot_*' -ErrorAction SilentlyContinue | Select-Object -First 1)
        }
        $hint = if ($copilotHasLeftovers) { 'leftover portable files detected, will scrub in next step' } else { $null }
        Uninstall-WingetPackage -Id 'GitHub.Copilot' -Friendly 'GitHub Copilot CLI' -LeftoverHint $hint -ManifestKey 'copilot'
    }
    if ($KeepAzure)   { Write-Skip 'Azure CLI kept (-KeepAzure)' }     else { Uninstall-WingetPackage -Id 'Microsoft.AzureCLI'  -Friendly 'Azure CLI'  -ManifestKey 'az' }
    if ($KeepGh)      { Write-Skip 'GitHub CLI kept (-KeepGh)' }        else { Uninstall-WingetPackage -Id 'GitHub.cli'         -Friendly 'GitHub CLI' -ManifestKey 'gh' }
    if ($KeepNode)    { Write-Skip 'Node.js LTS kept (-KeepNode)' }     else { Uninstall-WingetPackage -Id 'OpenJS.NodeJS.LTS'  -Friendly 'Node.js LTS' -ManifestKey 'node' }
    if ($KeepGit)     { Write-Skip 'Git kept (-KeepGit)' }              else { Uninstall-WingetPackage -Id 'Git.Git'            -Friendly 'Git'         -ManifestKey 'git' }
}

Write-Step 'Copilot CLI portable leftovers'
if ($KeepCopilot) { Write-Skip 'Copilot leftovers kept (-KeepCopilot)' }
else { Remove-CopilotPortableLeftovers }

# Persist remaining manifest entries (or delete the file if nothing is left).
Save-Manifest

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
