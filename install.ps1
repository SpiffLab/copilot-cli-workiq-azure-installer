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
    Do not run `gh auth login` or `az login` at the end.

.PARAMETER SkipWorkIQ
    Install tooling only; do not register the WorkIQ MCP server with Copilot CLI.

.PARAMETER SkipAzure
    Do not install Azure CLI or run `az login`.

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
    [switch]$Force,
    [switch]$NoWait
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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
        [string]$ProbeCommand
    )

    if ($ProbeCommand -and (Test-CommandExists $ProbeCommand)) {
        Write-Skip "$Friendly already present ($ProbeCommand on PATH)"
        return
    }

    # Secondary probe: ask winget if the package is already installed.
    $listed = winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String
    if ($listed -match [regex]::Escape($Id)) {
        Write-Skip "$Friendly already installed (winget: $Id)"
        Update-SessionPath
        return
    }

    Write-Info "Installing $Friendly ($Id) via winget..."
    $null = Invoke-External -File 'winget' -Arguments @(
        'install', '--id', $Id, '--exact',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    ) -AllowFail:$Force.IsPresent
    Update-SessionPath
    Write-Ok "$Friendly installed"
}

# ---------------------------------------------------------------------------
# Copilot CLI (npm global)
# ---------------------------------------------------------------------------

function Install-CopilotCli {
    Write-Step 'GitHub Copilot CLI'

    # Resolve npm to its .cmd / .exe form to bypass PowerShell ExecutionPolicy
    # (PS would otherwise pick up npm.ps1 and fail on restricted systems).
    $npmCmd = Resolve-NativeCommand -Name 'npm'
    if (-not $npmCmd) {
        # Try common install paths directly.
        foreach ($p in @(
            "$env:ProgramFiles\nodejs\npm.cmd",
            "${env:ProgramFiles(x86)}\nodejs\npm.cmd",
            "$env:APPDATA\npm\npm.cmd"
        )) { if (Test-Path $p) { $npmCmd = $p; break } }
    }
    if (-not $npmCmd) {
        throw "npm.cmd not found after installing Node.js. Open a new terminal and re-run, or install Node LTS manually."
    }
    Write-Info "Using npm: $npmCmd"

    # Check for existing copilot shim (prefer .cmd to avoid ExecutionPolicy issues).
    $copilotCmd = Resolve-NativeCommand -Name 'copilot'
    if ($copilotCmd) {
        $ver = (& $copilotCmd --version 2>&1 | Select-Object -First 1)
        Write-Skip "Copilot CLI already present at $copilotCmd ($ver)"
        return
    }

    Write-Info 'npm install -g @github/copilot'
    $npmOut = & $npmCmd install -g '@github/copilot' 2>&1
    $npmExit = $LASTEXITCODE
    $npmOut | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($npmExit -ne 0) {
        Write-Fail "npm install -g @github/copilot failed (exit $npmExit). See log: $script:LogPath"
        if (-not $Force) { throw "Copilot CLI install failed." }
        return
    }

    # Resolve npm global prefix (again via .cmd, not .ps1).
    $npmPrefix = $null
    try { $npmPrefix = (& $npmCmd config get prefix 2>$null | Select-Object -First 1).Trim() } catch { }

    if ($npmPrefix -and (Test-Path $npmPrefix)) {
        if ($env:Path -notlike "*$npmPrefix*") { $env:Path = "$npmPrefix;$env:Path" }

        # Persist to User PATH so new shells see it.
        try {
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            if (-not $userPath) { $userPath = '' }
            $segments = $userPath.Split(';') | Where-Object { $_ }
            if ($segments -notcontains $npmPrefix) {
                $newUserPath = if ($userPath) { "$userPath;$npmPrefix" } else { $npmPrefix }
                [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
                Write-Info "Added $npmPrefix to User PATH (takes effect in new terminals)."
            }
        } catch {
            Write-Warn2 "Could not persist npm prefix to User PATH: $($_.Exception.Message)"
        }
    }

    # Locate the produced shim, preferring .cmd (works under any ExecutionPolicy).
    $copilotShim = $null
    if ($npmPrefix) {
        foreach ($name in 'copilot.cmd','copilot.exe','copilot.bat') {
            $candidate = Join-Path $npmPrefix $name
            if (Test-Path $candidate) { $copilotShim = $candidate; break }
        }
    }

    if ($copilotShim) {
        $ver = (& $copilotShim --version 2>&1 | Select-Object -First 1)
        Write-Ok "Copilot CLI installed at $copilotShim ($ver)"
        $script:CopilotPath = $copilotShim
        if (-not (Resolve-NativeCommand -Name 'copilot')) {
            Write-Warn2 'Not visible on PATH in THIS session (persisted for new terminals). Open a NEW PowerShell window, then run: copilot'
        }
    } else {
        Write-Fail "npm reported success but 'copilot.cmd' shim not found under $npmPrefix. See log: $script:LogPath"
        if (-not $Force) { throw "Copilot CLI install did not produce a usable binary." }
    }
}

# ---------------------------------------------------------------------------
# WorkIQ MCP registration
# ---------------------------------------------------------------------------

function Register-WorkIQMcp {
    Write-Step 'WorkIQ MCP server'

    if ($SkipWorkIQ) {
        Write-Skip 'WorkIQ registration skipped (-SkipWorkIQ)'
        return
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

    # Azure
    if ($SkipAzure) {
        Write-Skip 'Azure auth skipped (-SkipAzure)'
    } elseif (Test-CommandExists 'az') {
        $azSignedIn = $false
        try {
            az account show *> $null
            if ($LASTEXITCODE -eq 0) { $azSignedIn = $true }
        } catch { }

        if ($azSignedIn) {
            Write-Skip 'az already signed in'
        } else {
            Write-Info 'Launching `az login`...'
            try { Invoke-External -File 'az' -Arguments @('login') -AllowFail | Out-Null; Write-Ok 'az signed in' }
            catch { Write-Warn2 "az login failed or was cancelled: $($_.Exception.Message)" }
        }
    } else {
        Write-Warn2 'az not on PATH; skipping Azure auth. Open a new shell and run `az login`.'
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Main {
    Write-Host ''
    Write-Host 'Copilot CLI + WorkIQ + Azure CLI installer' -ForegroundColor White
    Write-Host '------------------------------------------' -ForegroundColor DarkGray

    Test-Preflight

    Write-Step 'Prerequisites (winget)'
    Install-WingetPackage -Id 'OpenJS.NodeJS.LTS' -Friendly 'Node.js LTS' -ProbeCommand 'node'
    Install-WingetPackage -Id 'Git.Git'           -Friendly 'Git'          -ProbeCommand 'git'
    Install-WingetPackage -Id 'GitHub.cli'        -Friendly 'GitHub CLI'   -ProbeCommand 'gh'
    if (-not $SkipAzure) {
        Install-WingetPackage -Id 'Microsoft.AzureCLI' -Friendly 'Azure CLI' -ProbeCommand 'az'
    } else {
        Write-Skip 'Azure CLI skipped (-SkipAzure)'
    }

    Install-CopilotCli
    Register-WorkIQMcp
    Invoke-Auth

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
