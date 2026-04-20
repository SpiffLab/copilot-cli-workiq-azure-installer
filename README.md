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
   - **GitHub Copilot CLI** (`GitHub.Copilot`) — the official portable-zip package from GitHub.
   - **Node.js LTS** — runtime for the WorkIQ MCP server (`npx -y @microsoft/workiq`).
   - **Git** — required for most Copilot CLI workflows.
   - **GitHub CLI (`gh`)** — used for authenticating your GitHub account so Copilot CLI can talk to GitHub. Also handy for creating repos, PRs, issues from the terminal.
   - **Azure CLI (`az`)** — for building and managing Azure resources.
3. Register the WorkIQ MCP server with Copilot CLI.
4. Run `gh auth login --web` interactively so Copilot CLI can talk to GitHub. (`az login` is intentionally **not** run — sign in when you're ready to deploy.)
5. Print a summary and next steps.

Anything already present is skipped — re-running is safe.

## Passing flags through the one-liner

Because `irm | iex` doesn't support script parameters, wrap it in a scriptblock:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/SpiffLab/copilot-cli-workiq-azure-installer/main/install.ps1))) -SkipAuth
```

### Flags

| Flag           | Effect                                                              |
| -------------- | ------------------------------------------------------------------- |
| `-SkipAuth`    | Don't run `gh auth login` at the end.                               |
| `-SkipWorkIQ`  | Install tooling only; don't register the WorkIQ MCP server.         |
| `-SkipAzure`   | Don't install Azure CLI.                                            |
| `-Force`       | Continue past non-fatal errors where reasonable.                    |
| `-NoWait`      | Skip the final "Press Enter to close" pause.                        |

## Uninstall

To remove everything this script installed:

```powershell
irm https://raw.githubusercontent.com/SpiffLab/copilot-cli-workiq-azure-installer/main/uninstall.ps1 | iex
```

The uninstaller:

- Removes the `workiq` entry from your Copilot CLI MCP config.
- Uninstalls (via winget) Copilot CLI, Azure CLI, GitHub CLI, Node.js LTS,
  and Git.
- Cleans up any leftover `@github/copilot` from older npm-based install
  attempts and removes `%APPDATA%\npm` from your User PATH if it was added.

Flags to keep specific tools (useful for install/uninstall round-tripping
during development):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/SpiffLab/copilot-cli-workiq-azure-installer/main/uninstall.ps1))) -KeepGit -KeepNode -KeepGh
```

| Flag                 | Effect                                                      |
| -------------------- | ----------------------------------------------------------- |
| `-KeepNode`          | Don't uninstall Node.js LTS.                                |
| `-KeepGit`           | Don't uninstall Git.                                        |
| `-KeepGh`            | Don't uninstall GitHub CLI.                                 |
| `-KeepAzure`         | Don't uninstall Azure CLI.                                  |
| `-KeepWorkIQConfig`  | Don't remove the WorkIQ entry from the MCP config.          |
| `-NoWait`            | Skip the final "Press Enter to close" pause.                |

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
- **`copilot` command not found in a new terminal.** winget installs the
  `GitHub.Copilot` portable package with a shim under
  `%LOCALAPPDATA%\Microsoft\WinGet\Links`, which winget adds to User PATH
  automatically. If it doesn't show up, open a new PowerShell window. If
  still missing, verify the install: `winget list --id GitHub.Copilot`.
- **PowerShell ExecutionPolicy / "running scripts is disabled on this system".**
  The `irm | iex` entry point is immune (code runs in memory, not from a
  `.ps1` file). All tools installed by this script (`GitHub.Copilot`, `gh`,
  `az`, `npx`) are `.exe` / `.cmd` / `.bat` binaries, so they run fine under
  the default `Restricted` and `AllSigned` execution policies. You do **not**
  need `Set-ExecutionPolicy`.
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

- `winget` packages: `GitHub.Copilot` (Copilot CLI), `OpenJS.NodeJS.LTS`,
  `Git.Git`, `GitHub.cli`, `Microsoft.AzureCLI` (only if missing).
- Copilot CLI MCP configuration: a `workiq` server entry, added either via
  `copilot mcp add` or by writing to `%USERPROFILE%\.copilot\mcp-config.json`.
- Interactive sign-in tokens stored by `gh` and `az` in their usual locations.

No files in this repo are copied to your machine.

## License

MIT — see [LICENSE](./LICENSE).
