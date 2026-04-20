<#
.SYNOPSIS
    Publish this repo to GitHub under your account.

.EXAMPLE
    .\publish.ps1 -Owner yourname

.EXAMPLE
    .\publish.ps1 -Owner yourname -Private
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Owner,
    [string]$Repo = 'copilot-cli-workiq-azure-installer',
    [switch]$Private
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) not found. Install with: winget install --id GitHub.cli -e"
}

# Ensure gh is authenticated
gh auth status 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'gh not authenticated. Launching gh auth login --web...' -ForegroundColor Cyan
    gh auth login --web
    if ($LASTEXITCODE -ne 0) { throw 'gh auth login failed.' }
}

# Swap the <owner> placeholder in README.md for the real owner
$readme = Join-Path $PSScriptRoot 'README.md'
(Get-Content -Raw $readme) -replace '<owner>', $Owner | Set-Content -NoNewline $readme
if ((git status --porcelain) -match 'README\.md') {
    git add README.md
    git -c user.email="$Owner@users.noreply.github.com" -c user.name="$Owner" `
        commit -q -m "Set README one-liner owner to $Owner

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
}

$visibility = if ($Private) { '--private' } else { '--public' }
Write-Host "Creating $Owner/$Repo ($visibility) on GitHub..." -ForegroundColor Cyan
gh repo create "$Owner/$Repo" $visibility --source=. --remote=origin --push
if ($LASTEXITCODE -ne 0) { throw 'gh repo create failed.' }

Write-Host ''
Write-Host "Published: https://github.com/$Owner/$Repo" -ForegroundColor Green
Write-Host 'One-liner to share:' -ForegroundColor White
Write-Host "  irm https://raw.githubusercontent.com/$Owner/$Repo/main/install.ps1 | iex"
