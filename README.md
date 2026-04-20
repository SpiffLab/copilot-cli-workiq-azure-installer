# Copilot CLI + WorkIQ + Azure CLI Installer

A single PowerShell one-liner that sets up a Windows machine with everything
needed to use [GitHub Copilot CLI](https://github.com/github/copilot-cli) with
the [Microsoft WorkIQ](https://github.com/microsoft/work-iq-mcp) MCP server
and the [Azure CLI](https://learn.microsoft.com/cli/azure/).

## Quick start

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/SpiffLab/copilot-cli-workiq-azure-installer/main/install.ps1 | iex
```

That's it. The script will:

1. Check pre-reqs (Windows, PowerShell 5.1+, `winget`).
2. Install anything missing via `winget`:
   - **Node.js LTS** — runtime for Copilot CLI and the WorkIQ MCP server (`npx`).
   - **Git** — required for most Copilot CLI workflows.
   - **GitHub CLI (`gh`)** — used for authenticating your GitHub account so Copilot CLI can talk to GitHub. Also handy for creating repos, PRs, issues from the terminal.
   - **Azure CLI (`az`)** — for building and managing Azure resources.
3. Install Copilot CLI: `npm install -g @github/copilot`.
4. Register the WorkIQ MCP server with Copilot CLI.
5. Run `gh auth login --web` and `az login` interactively.
6. Print a summary and next steps.

Anything already present is skipped — re-running is safe.

## Passing flags through the one-liner

Because `irm | iex` doesn't support script parameters, wrap it in a scriptblock:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/SpiffLab/copilot-cli-workiq-azure-installer/main/install.ps1))) -SkipAuth
```

### Flags

| Flag           | Effect                                                              |
| -------------- | ------------------------------------------------------------------- |
| `-SkipAuth`    | Don't run `gh auth login` or `az login` at the end.                 |
| `-SkipWorkIQ`  | Install tooling only; don't register the WorkIQ MCP server.         |
| `-SkipAzure`   | Don't install Azure CLI and don't run `az login`.                   |
| `-Force`       | Continue past non-fatal errors where reasonable.                    |

## After install

Open a **new** PowerShell window (so updated `PATH` is picked up), then:

```powershell
copilot
```

Try: *"What are my upcoming meetings this week?"* — that exercises WorkIQ.

## Troubleshooting

- **The terminal closed before I could read the output.** Every run writes a
  full transcript to `%TEMP%\copilot-cli-installer-YYYYMMDD-HHMMSS.log`. Open
  it with: `notepad "$env:TEMP\copilot-cli-installer-*.log"` (grabs the
  newest). The script also pauses at the end of every interactive run with
  "Press Enter to close" — if that didn't happen, the host probably wasn't a
  normal PowerShell console (e.g., `cmd /c powershell -Command ...`
  auto-closes).
- **`copilot` command not found in a new terminal.** The npm global bin
  directory (usually `%APPDATA%\npm`) must be on `PATH`. The installer now
  adds it to your **User** `PATH` persistently, so **closing and reopening**
  your terminal should pick it up. If it still doesn't:
  ```powershell
  $prefix = (npm config get prefix)
  [Environment]::SetEnvironmentVariable('Path', "$([Environment]::GetEnvironmentVariable('Path','User'));$prefix", 'User')
  # then open a NEW PowerShell window
  ```
  Verify with: `Get-Command copilot` and `Test-Path (Join-Path (npm config get prefix) 'copilot.cmd')`.
- **PowerShell ExecutionPolicy / "running scripts is disabled on this system".**
  The `irm | iex` entry point is immune (code runs in memory, not from a
  `.ps1` file). The installer also explicitly invokes `.cmd` / `.exe` shims
  for `npm` and `copilot` so it works under the default `Restricted` and
  `AllSigned` policies without any changes. You do **not** need
  `Set-ExecutionPolicy`.
- **`winget` not found.** Update "App Installer" from the Microsoft Store
  (Windows 10 1809+ and Windows 11 ship with winget).
- **Execution policy errors.** `irm | iex` runs in-memory and usually isn't
  blocked, but if needed:
  `Set-ExecutionPolicy -Scope Process Bypass -Force` before running.
- **Corporate proxy / blocked winget.** If your org blocks winget, install
  Node LTS, Git, GitHub CLI, and Azure CLI manually, then re-run the installer
  — it will detect the existing tools and skip to Copilot CLI / WorkIQ setup.
- **`copilot` not found after install.** Open a new PowerShell window. Global
  npm packages aren't on `PATH` until a new shell starts.
- **WorkIQ "admin consent required".** First-time access to Microsoft 365
  tenant data requires tenant-admin consent. See the
  [WorkIQ README](https://github.com/microsoft/work-iq-mcp) for the admin
  consent URL and enablement guide.

## What gets changed on your machine

- `winget` packages: `OpenJS.NodeJS.LTS`, `Git.Git`, `GitHub.cli`,
  `Microsoft.AzureCLI` (only if missing).
- npm global package: `@github/copilot`.
- Copilot CLI MCP configuration: a `workiq` server entry, added either via
  `copilot mcp add` or by writing to `%USERPROFILE%\.copilot\mcp-config.json`.
- Interactive sign-in tokens stored by `gh` and `az` in their usual locations.

No files in this repo are copied to your machine.

## License

MIT — see [LICENSE](./LICENSE).
