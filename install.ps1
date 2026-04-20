<#
.SYNOPSIS
    One-shot installer for GitHub Copilot CLI + WorkIQ MCP + Azure CLI on Windows.

.DESCRIPTION
    Installs (via winget, if missing) Node.js LTS, Git, GitHub CLI, and Azure CLI,
    then installs the Copilot CLI npm package, registers the WorkIQ MCP server,
    and runs interactive auth for GitHub and Azure.

    Designed to be invoked as a one-liner from PowerShell:

        irm https://raw.githubusercontent.com/<owner>/copilot-cli-workiq-azure-installer/main/install.ps1 | iex

    To pass parameters through `irm | iex`, use a scriptblock:

        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/<owner>/copilot-cli-workiq-azure-installer/main/install.ps1))) -SkipAuth

.PARAMETER SkipAuth
    Do not run `gh auth login` at the end.

.PARAMETER SkipWorkIQ
    Install tooling only; do not register the WorkIQ MCP server with Copilot CLI.

.PARAMETER SkipAzure
    Do not install Azure CLI.

.PARAMETER SkipNode
    Do not install Node.js LTS.

.PARAMETER SkipGit
    Do not install Git.

.PARAMETER SkipGh
    Do not install GitHub CLI (gh).

.PARAMETER SkipCopilot
    Do not install GitHub Copilot CLI (also forces -SkipWorkIQ since WorkIQ
    is registered via `copilot mcp add`).

.PARAMETER Yes
    Skip the interactive component picker at the start and install everything
    (respecting any -Skip* flags). Useful for CI / unattended runs.

.PARAMETER Force
    Continue past non-fatal errors where reasonable.

.PARAMETER NoWait
    Skip the final "Press Enter to close" pause. Useful for CI / unattended runs.
#>
[CmdletBinding()]
param(
    [switch]$SkipAuth,
    [switch]$SkipWorkIQ,
    [switch]$SkipAzure,
    [switch]$SkipNode,
    [switch]$SkipGit,
    [switch]$SkipGh,
    [switch]$SkipCopilot,
    [switch]$Yes,
    [switch]$Force,
    [switch]$NoWait
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Install manifest - tracks what the installer actually put on the machine
# so the uninstaller can skip components that were already present.
# ---------------------------------------------------------------------------

$script:ManifestDir  = Join-Path $env:LOCALAPPDATA 'copilot-cli-workiq-azure-installer'
$script:ManifestPath = Join-Path $script:ManifestDir 'manifest.json'
$script:Manifest = [ordered]@{
    version    = 1
    createdAt  = (Get-Date).ToString('o')
    components = [ordered]@{}
}

function Set-ManifestComponent {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][ValidateSet('installed','already-present','skipped-by-user','failed','registered','already-registered')][string]$State,
        [string]$Id
    )
    $entry = [ordered]@{ state = $State; at = (Get-Date).ToString('o') }
    if ($Id) { $entry.id = $Id }
    $script:Manifest.components[$Key] = $entry
}

function Save-Manifest {
    try {
        if (-not (Test-Path $script:ManifestDir)) {
            New-Item -ItemType Directory -Force -Path $script:ManifestDir | Out-Null
        }
        ($script:Manifest | ConvertTo-Json -Depth 10) | Set-Content -Path $script:ManifestPath -Encoding UTF8
        Write-Info "Install manifest written to $script:ManifestPath"
    } catch {
        Write-Warn2 "Could not write install manifest: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Transcript log (so the install output survives a closing terminal)
# ---------------------------------------------------------------------------

$script:LogPath = Join-Path $env:TEMP ("copilot-cli-installer-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { Start-Transcript -Path $script:LogPath -Force | Out-Null } catch { }

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

$script:Summary = [System.Collections.Generic.List[string]]::new()

function Write-Step   { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Info   { param([string]$m) Write-Host "    $m" -ForegroundColor Gray }
function Write-Ok     { param([string]$m) Write-Host "[OK] $m"   -ForegroundColor Green; $script:Summary.Add("[OK]   $m") }
function Write-Skip   { param([string]$m) Write-Host "[--] $m"   -ForegroundColor DarkGray; $script:Summary.Add("[skip] $m") }
function Write-Warn2  { param([string]$m) Write-Host "[!!] $m"   -ForegroundColor Yellow; $script:Summary.Add("[warn] $m") }
function Write-Fail   { param([string]$m) Write-Host "[XX] $m"   -ForegroundColor Red;    $script:Summary.Add("[FAIL] $m") }

# ---------------------------------------------------------------------------
# Environment helpers
# ---------------------------------------------------------------------------

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Resolve-NativeCommand {
    <#
    Resolves a command name to a path, preferring .cmd / .exe / .bat over .ps1.
    This avoids ExecutionPolicy issues: PowerShell's default command resolution
    picks up *.ps1 shims (e.g., npm.ps1, copilot.ps1) which fail on systems
    where unsigned PS scripts are blocked. Batch / executable shims bypass PS
    execution policy entirely.
    #>
    param([Parameter(Mandatory)][string]$Name)

    $preferredExts = @('.cmd', '.exe', '.bat', '.com')
    foreach ($ext in $preferredExts) {
        $candidate = Get-Command -Name "$Name$ext" -ErrorAction SilentlyContinue |
                     Where-Object { $_.CommandType -in 'Application','ExternalScript' } |
                     Select-Object -First 1
        if ($candidate) { return $candidate.Source }
    }
    # Fall back to whatever Get-Command finds (may be a .ps1 — caller should be aware).
    $fallback = Get-Command -Name $Name -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandType -eq 'Application' } |
                Select-Object -First 1
    if ($fallback) { return $fallback.Source }
    return $null
}

function Update-SessionPath {
    # Refresh PATH in the current session from Machine + User scopes so that
    # freshly-installed tools (winget, npm globals, etc.) become available
    # without requiring a new shell.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if ($machine) { $parts += $machine.Split(';') }
    if ($user)    { $parts += $user.Split(';') }
    # Preserve any paths added in-session that aren't in persisted env (e.g., npm prefix)
    $parts += ($env:Path -split ';')
    $env:Path = ($parts | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique) -join ';'
}

function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$File,
        [string[]]$Arguments = @(),
        [switch]$AllowFail
    )
    Write-Info "$File $($Arguments -join ' ')"
    & $File @Arguments
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFail) {
        throw "Command failed ($code): $File $($Arguments -join ' ')"
    }
    return $code
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

function Test-Preflight {
    Write-Step 'Pre-flight checks'

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw "PowerShell 5.1 or newer required (found $($PSVersionTable.PSVersion))."
    }
    Write-Ok "PowerShell $($PSVersionTable.PSVersion)"

    # On PS7+ $IsWindows is defined; on Windows PowerShell 5.1 it isn't. Guard
    # against strict-mode "variable not set" errors.
    $isWin = $true
    if (Test-Path variable:IsWindows) { $isWin = [bool](Get-Variable -Name IsWindows -ValueOnly) }
    if (-not $isWin) { throw 'This installer targets Windows only.' }

    if (-not (Test-CommandExists 'winget')) {
        throw @"
winget (Windows Package Manager) was not found on PATH.
winget ships with Windows 10 1809+ and Windows 11. Install or update
'App Installer' from the Microsoft Store, then re-run this installer.
"@
    }
    Write-Ok "winget $(winget --version)"
}

# ---------------------------------------------------------------------------
# winget install helper
# ---------------------------------------------------------------------------

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Friendly,
        [string]$ProbeCommand,
        [string]$ManifestKey   # component key for the install manifest
    )

    if ($ProbeCommand -and (Test-CommandExists $ProbeCommand)) {
        Write-Skip "$Friendly already present ($ProbeCommand on PATH)"
        if ($ManifestKey) { Set-ManifestComponent -Key $ManifestKey -State 'already-present' -Id $Id }
        return
    }

    # Secondary probe: ask winget if the package is already installed.
    $listed = winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String
    if ($listed -match [regex]::Escape($Id)) {
        Write-Skip "$Friendly already installed (winget: $Id)"
        if ($ManifestKey) { Set-ManifestComponent -Key $ManifestKey -State 'already-present' -Id $Id }
        Update-SessionPath
        return
    }

    Write-Info "Installing $Friendly ($Id) via winget..."
    $code = Invoke-External -File 'winget' -Arguments @(
        'install', '--id', $Id, '--exact',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    ) -AllowFail:$Force.IsPresent
    Update-SessionPath

    # winget occasionally returns non-zero exit codes (reboot-required, benign
    # post-install warnings, transient source errors) even when the package was
    # installed successfully. Re-verify by probing the binary, and check winget's
    # own installed list as a secondary signal.
    $verified = $false
    if ($ProbeCommand -and (Test-CommandExists $ProbeCommand)) { $verified = $true }
    if (-not $verified) {
        $listedAfter = winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String
        if ($listedAfter -match [regex]::Escape($Id)) { $verified = $true }
    }

    if ($code -eq 0 -or $verified) {
        if ($code -eq 0) {
            Write-Ok "$Friendly installed"
        } else {
            Write-Ok "$Friendly installed (winget exit $code, but binary verified on PATH)"
        }
        if ($ManifestKey) { Set-ManifestComponent -Key $ManifestKey -State 'installed' -Id $Id }
    } else {
        Write-Warn2 "$Friendly winget install exited $code"
        if ($ManifestKey) { Set-ManifestComponent -Key $ManifestKey -State 'failed' -Id $Id }
    }
}

# ---------------------------------------------------------------------------
# Copilot CLI (npm global)
# ---------------------------------------------------------------------------

function Install-CopilotCli {
    Write-Step 'GitHub Copilot CLI'

    # Already installed?
    $existing = Resolve-NativeCommand -Name 'copilot'
    if ($existing) {
        $ver = (& $existing --version 2>&1 | Select-Object -First 1)
        Write-Skip "Copilot CLI already present at $existing ($ver)"
        $script:CopilotPath = $existing
        Set-ManifestComponent -Key 'copilot' -State 'already-present' -Id 'GitHub.Copilot'
        return
    }

    # Install via the official winget package. It's a portable zip published
    # by GitHub, so no ExecutionPolicy or PATH surgery is needed.
    Install-WingetPackage -Id 'GitHub.Copilot' -Friendly 'GitHub Copilot CLI' -ProbeCommand 'copilot' -ManifestKey 'copilot'

    $copilotCmd = Resolve-NativeCommand -Name 'copilot'
    if (-not $copilotCmd) {
        # winget's portable packages register a links directory on PATH
        # (typically %LOCALAPPDATA%\Microsoft\WinGet\Links). Make sure we pick
        # it up in this session.
        $linksDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
        if ((Test-Path $linksDir) -and ($env:Path -notlike "*$linksDir*")) {
            $env:Path = "$linksDir;$env:Path"
        }
        $copilotCmd = Resolve-NativeCommand -Name 'copilot'
    }

    if ($copilotCmd) {
        $ver = (& $copilotCmd --version 2>&1 | Select-Object -First 1)
        Write-Ok "Copilot CLI installed at $copilotCmd ($ver)"
        $script:CopilotPath = $copilotCmd
    } else {
        Write-Warn2 'Copilot CLI installed but not visible on PATH in this session. Open a NEW PowerShell window, then run: copilot'
    }
}

# ---------------------------------------------------------------------------
# WorkIQ MCP registration
# ---------------------------------------------------------------------------

function Register-WorkIQMcp {
    Write-Step 'WorkIQ MCP server'

    if ($SkipWorkIQ) {
        Write-Skip 'WorkIQ registration skipped (-SkipWorkIQ)'
        Set-ManifestComponent -Key 'workiq' -State 'skipped-by-user'
        return
    }

    # Detect an existing 'workiq' MCP registration so we don't claim
    # ownership of something another installer / user added.
    $preExisting = $false
    $candidatePaths = @(
        (Join-Path $env:USERPROFILE '.copilot\mcp-config.json'),
        (Join-Path $env:USERPROFILE '.copilot\mcp.json')
    )
    foreach ($p in $candidatePaths) {
        if (-not (Test-Path $p)) { continue }
        try {
            $raw = Get-Content -Raw -Path $p
            if ($raw.Trim()) {
                $obj = $raw | ConvertFrom-Json
                if ($obj.PSObject.Properties.Name -contains 'mcpServers' -and $obj.mcpServers -and
                    ($obj.mcpServers.PSObject.Properties.Name -contains 'workiq')) {
                    $preExisting = $true; break
                }
            }
        } catch { }
    }

    $cliOk = $false
    # Prefer the resolved .cmd shim (set by Install-CopilotCli) to bypass
    # ExecutionPolicy issues with copilot.ps1.
    $copilotCmd = $null
    if (Test-Path variable:script:CopilotPath) { $copilotCmd = $script:CopilotPath }
    if (-not $copilotCmd) { $copilotCmd = Resolve-NativeCommand -Name 'copilot' }

    if ($copilotCmd) {
        try {
            Write-Info "$copilotCmd mcp add workiq -- npx -y @microsoft/workiq@latest mcp"
            & $copilotCmd mcp add workiq -- npx -y '@microsoft/workiq@latest' mcp 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            if ($LASTEXITCODE -eq 0) { $cliOk = $true }
            else { Write-Info "copilot mcp add exited $LASTEXITCODE; falling back to config file." }
        } catch {
            Write-Info "copilot mcp add did not succeed ($($_.Exception.Message)); falling back to config file."
        }
    } else {
        Write-Info 'copilot binary not resolvable in this session; using config-file fallback.'
    }

    if ($cliOk) {
        Write-Ok 'WorkIQ MCP server registered via `copilot mcp add`'
        Set-ManifestComponent -Key 'workiq' -State ($(if ($preExisting) { 'already-registered' } else { 'registered' }))
        return
    }

    # Fallback: write MCP server config directly.
    $candidatePaths = @(
        (Join-Path $env:USERPROFILE '.copilot\mcp-config.json'),
        (Join-Path $env:USERPROFILE '.copilot\mcp.json')
    )
    $configPath = $candidatePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $configPath) { $configPath = $candidatePaths[0] }

    $configDir = Split-Path -Parent $configPath
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Force -Path $configDir | Out-Null }

    $config = [ordered]@{}
    if (Test-Path $configPath) {
        try {
            $raw = Get-Content -Raw -Path $configPath
            if ($raw.Trim()) {
                $parsed = $raw | ConvertFrom-Json
                # ConvertFrom-Json returns PSCustomObject; convert to hashtable for mutation.
                $config = [ordered]@{}
                $parsed.PSObject.Properties | ForEach-Object { $config[$_.Name] = $_.Value }
            }
        } catch {
            Write-Warn2 "Could not parse existing $configPath; writing a fresh file."
            $config = [ordered]@{}
        }
    }

    if (-not $config.Contains('mcpServers')) { $config['mcpServers'] = [ordered]@{} }
    # mcpServers may be a PSCustomObject from parsed JSON; normalize to ordered hashtable.
    if ($config['mcpServers'] -isnot [System.Collections.IDictionary]) {
        $existing = $config['mcpServers']
        $normalized = [ordered]@{}
        if ($existing) {
            $existing.PSObject.Properties | ForEach-Object { $normalized[$_.Name] = $_.Value }
        }
        $config['mcpServers'] = $normalized
    }
    $config['mcpServers']['workiq'] = [ordered]@{
        command = 'npx'
        args    = @('-y', '@microsoft/workiq@latest', 'mcp')
        tools   = @('*')
    }

    ($config | ConvertTo-Json -Depth 10) | Set-Content -Path $configPath -Encoding UTF8
    Write-Ok "WorkIQ MCP server written to $configPath"
    Set-ManifestComponent -Key 'workiq' -State ($(if ($preExisting) { 'already-registered' } else { 'registered' }))
}

# ---------------------------------------------------------------------------
# Interactive auth
# ---------------------------------------------------------------------------

function Invoke-Auth {
    Write-Step 'Interactive authentication'

    if ($SkipAuth) {
        Write-Skip 'Auth skipped (-SkipAuth). Run `gh auth login` and `az login` yourself when ready.'
        return
    }

    # GitHub
    if (Test-CommandExists 'gh') {
        $alreadyLoggedIn = $false
        try {
            gh auth status *> $null
            if ($LASTEXITCODE -eq 0) { $alreadyLoggedIn = $true }
        } catch { }

        if ($alreadyLoggedIn) {
            Write-Skip 'gh already authenticated'
        } else {
            Write-Info 'Launching `gh auth login --web`...'
            try { Invoke-External -File 'gh' -Arguments @('auth', 'login', '--web') -AllowFail | Out-Null; Write-Ok 'gh authenticated' }
            catch { Write-Warn2 "gh auth login failed or was cancelled: $($_.Exception.Message)" }
        }
    } else {
        Write-Warn2 'gh not on PATH; skipping GitHub auth. Open a new shell and run `gh auth login`.'
    }

    # Azure CLI is installed but intentionally NOT signed in here. Users run
    # `az login` themselves when they're ready to deploy.
    Write-Skip 'az login skipped by design (run `az login` yourself when needed)'
}

# ---------------------------------------------------------------------------
# Interactive component picker
# ---------------------------------------------------------------------------

function Invoke-InstallPicker {
    $items = @(
        [pscustomobject]@{ Key='node';   Label='Node.js LTS (required by Copilot CLI / WorkIQ MCP)'; Probe='node'; SkipFlag='SkipNode';    CurrentSkip=$SkipNode }
        [pscustomobject]@{ Key='git';    Label='Git';                                                 Probe='git';  SkipFlag='SkipGit';     CurrentSkip=$SkipGit }
        [pscustomobject]@{ Key='gh';     Label='GitHub CLI (gh)';                                     Probe='gh';   SkipFlag='SkipGh';      CurrentSkip=$SkipGh }
        [pscustomobject]@{ Key='az';     Label='Azure CLI';                                           Probe='az';   SkipFlag='SkipAzure';   CurrentSkip=$SkipAzure }
        [pscustomobject]@{ Key='copilot';Label='GitHub Copilot CLI';                                  Probe='copilot'; SkipFlag='SkipCopilot'; CurrentSkip=$SkipCopilot }
        [pscustomobject]@{ Key='workiq'; Label='Register WorkIQ MCP server with Copilot CLI';         Probe=$null;  SkipFlag='SkipWorkIQ';  CurrentSkip=$SkipWorkIQ }
        [pscustomobject]@{ Key='auth';   Label='Run `gh auth login` at the end';                      Probe=$null;  SkipFlag='SkipAuth';    CurrentSkip=$SkipAuth }
    )

    # Default: install/enable unless the user already passed -Skip* for it.
    $state = @{}
    foreach ($it in $items) { $state[$it.Key] = -not $it.CurrentSkip }

    function Format-PresenceNote {
        param($item)
        if (-not $item.Probe) { return '' }
        $present = [bool](Get-Command -Name $item.Probe -ErrorAction SilentlyContinue)
        if ($present) { return ' (already present — will be skipped)' } else { return '' }
    }

    $done = $false
    while (-not $done) {
        Write-Host ''
        Write-Host 'The installer will set up the following:' -ForegroundColor White
        Write-Host '  [x] = will run   [ ] = will be skipped' -ForegroundColor DarkGray
        Write-Host ''
        for ($i = 0; $i -lt $items.Count; $i++) {
            $it = $items[$i]
            $mark = if ($state[$it.Key]) { 'x' } else { ' ' }
            $note = Format-PresenceNote $it
            $color = if ($note) { 'DarkGray' } else { 'White' }
            Write-Host ("  {0}. [{1}] {2}{3}" -f ($i + 1), $mark, $it.Label, $note) -ForegroundColor $color
        }
        Write-Host ''
        Write-Host '  [A] All   [N] None   [Enter] Proceed   [C] Cancel' -ForegroundColor Cyan
        $choice = Read-Host 'Toggle by number, or pick an action'
        if ($null -eq $choice) { $choice = '' }
        $choice = $choice.Trim()

        if ($choice -eq '') { $done = $true; break }
        switch -Regex ($choice) {
            '^[aA]$' { foreach ($it in $items) { $state[$it.Key] = $true } ; break }
            '^[nN]$' { foreach ($it in $items) { $state[$it.Key] = $false } ; break }
            '^[cC]$' { Write-Host 'Cancelled.' -ForegroundColor Yellow; exit 0 }
            '^\d+$' {
                $n = [int]$choice
                if ($n -ge 1 -and $n -le $items.Count) {
                    $k = $items[$n - 1].Key
                    $state[$k] = -not $state[$k]
                } else {
                    Write-Host "[!!] Out of range: $n" -ForegroundColor Yellow
                }
            }
            default { Write-Host "[!!] Unrecognized input: '$choice'" -ForegroundColor Yellow }
        }
    }

    return @{
        SkipNode    = -not $state['node']
        SkipGit     = -not $state['git']
        SkipGh      = -not $state['gh']
        SkipAzure   = -not $state['az']
        SkipCopilot = -not $state['copilot']
        SkipWorkIQ  = -not $state['workiq']
        SkipAuth    = -not $state['auth']
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Main {
    Write-Host ''
    Write-Host 'Copilot CLI + WorkIQ + Azure CLI installer' -ForegroundColor White
    Write-Host '------------------------------------------' -ForegroundColor DarkGray

    # Interactive component picker (skippable via -Yes or in non-console hosts).
    $interactive = (-not $Yes) -and ($Host.Name -eq 'ConsoleHost') -and [Environment]::UserInteractive
    if ($interactive) {
        try {
            $picked = Invoke-InstallPicker
            $script:SkipNode    = [bool]$picked.SkipNode
            $script:SkipGit     = [bool]$picked.SkipGit
            $script:SkipGh      = [bool]$picked.SkipGh
            $script:SkipAzure   = [bool]$picked.SkipAzure
            $script:SkipCopilot = [bool]$picked.SkipCopilot
            $script:SkipWorkIQ  = [bool]$picked.SkipWorkIQ
            $script:SkipAuth    = [bool]$picked.SkipAuth
            # Propagate into the param-scope variables the functions read.
            Set-Variable -Name SkipNode    -Scope 1 -Value $script:SkipNode
            Set-Variable -Name SkipGit     -Scope 1 -Value $script:SkipGit
            Set-Variable -Name SkipGh      -Scope 1 -Value $script:SkipGh
            Set-Variable -Name SkipAzure   -Scope 1 -Value $script:SkipAzure
            Set-Variable -Name SkipCopilot -Scope 1 -Value $script:SkipCopilot
            Set-Variable -Name SkipWorkIQ  -Scope 1 -Value $script:SkipWorkIQ
            Set-Variable -Name SkipAuth    -Scope 1 -Value $script:SkipAuth
        } catch {
            Write-Warn2 "Picker failed ($($_.Exception.Message)); continuing with current flags."
        }
    }

    # Skipping Copilot means WorkIQ cannot be registered via `copilot mcp add`.
    if ($SkipCopilot -and -not $SkipWorkIQ) {
        Write-Warn2 'SkipCopilot implies SkipWorkIQ (WorkIQ registers via the Copilot CLI). Skipping WorkIQ.'
        Set-Variable -Name SkipWorkIQ -Scope 1 -Value $true
    }

    Test-Preflight

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host '  UAC prompts may appear'                                     -ForegroundColor Yellow
    Write-Host '  Some MSI packages (Git, Azure CLI, GitHub CLI) trigger a'   -ForegroundColor Yellow
    Write-Host '  Windows UAC dialog during install. If the installer seems'  -ForegroundColor Yellow
    Write-Host '  to hang, check the taskbar - Windows sometimes puts the'    -ForegroundColor Yellow
    Write-Host '  UAC prompt behind other windows. Click "Yes" to continue.'  -ForegroundColor Yellow
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host ''

    Write-Step 'Prerequisites (winget)'
    if ($SkipNode) { Write-Skip 'Node.js LTS skipped (-SkipNode)'; Set-ManifestComponent -Key 'node' -State 'skipped-by-user' -Id 'OpenJS.NodeJS.LTS' }
    else { Install-WingetPackage -Id 'OpenJS.NodeJS.LTS' -Friendly 'Node.js LTS' -ProbeCommand 'node' -ManifestKey 'node' }
    if ($SkipGit)  { Write-Skip 'Git skipped (-SkipGit)'; Set-ManifestComponent -Key 'git' -State 'skipped-by-user' -Id 'Git.Git' }
    else { Install-WingetPackage -Id 'Git.Git'           -Friendly 'Git'          -ProbeCommand 'git'  -ManifestKey 'git' }
    if ($SkipGh)   { Write-Skip 'GitHub CLI skipped (-SkipGh)'; Set-ManifestComponent -Key 'gh' -State 'skipped-by-user' -Id 'GitHub.cli' }
    else { Install-WingetPackage -Id 'GitHub.cli'        -Friendly 'GitHub CLI'   -ProbeCommand 'gh'   -ManifestKey 'gh' }
    if ($SkipAzure) {
        Write-Skip 'Azure CLI skipped (-SkipAzure)'
        Set-ManifestComponent -Key 'az' -State 'skipped-by-user' -Id 'Microsoft.AzureCLI'
    } else {
        Install-WingetPackage -Id 'Microsoft.AzureCLI' -Friendly 'Azure CLI' -ProbeCommand 'az' -ManifestKey 'az'
    }

    if ($SkipCopilot) {
        Write-Skip 'GitHub Copilot CLI skipped (-SkipCopilot)'
        Set-ManifestComponent -Key 'copilot' -State 'skipped-by-user' -Id 'GitHub.Copilot'
    } else { Install-CopilotCli }

    Register-WorkIQMcp
    Invoke-Auth

    Save-Manifest

    # ---- Summary ----
    Write-Host "`n============================================" -ForegroundColor DarkGray
    Write-Host 'Install summary'                                  -ForegroundColor White
    Write-Host '============================================'    -ForegroundColor DarkGray
    $script:Summary | ForEach-Object { Write-Host $_ }

    Write-Host "`nNext steps:" -ForegroundColor White
    Write-Host '  1. Open a NEW PowerShell window (so PATH and npm globals are picked up).'
    Write-Host '  2. Run: copilot'
    Write-Host '  3. Ask: "What are my upcoming meetings this week?" (tests WorkIQ)'
    Write-Host ''
    Write-Host 'WorkIQ note: first-time access to tenant data requires admin consent.'
    Write-Host 'See: https://github.com/microsoft/work-iq-mcp#readme' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host "Transcript log: $script:LogPath" -ForegroundColor DarkCyan
    Write-Host ''
}

$script:ExitCode = 0
try {
    Main
} catch {
    Write-Host ''
    Write-Host "Installer failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host ''
    Write-Host "Transcript log: $script:LogPath" -ForegroundColor DarkCyan
    $script:ExitCode = 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }
}

# Keep the window open so the user can read the output. Only pause in an
# interactive console host; skip for CI / piped / -NoWait runs.
if (-not $NoWait -and $Host.Name -eq 'ConsoleHost' -and [Environment]::UserInteractive) {
    try {
        Write-Host ''
        Write-Host 'Press Enter to close this window...' -ForegroundColor Yellow
        [void](Read-Host)
    } catch { }
}

if ($script:ExitCode -ne 0) { exit $script:ExitCode }
