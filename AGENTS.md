# AGENTS.md — Windows-LogOff 4.2.0

Agent-facing guide: how to install Windows-LogOff, run it safely, and report problems responsibly.
Human documentation: [README.md](README.md). This repository has no `docs/` directory.

> Verified against repository state on 2026-10-22. Version covered: `4.2.0`, from the `.NOTES`
> block of `logoff.ps1`. The only published release is tag `v1.0.0`; it contains the same
> `logoff.ps1` and publishes no assets.

## 1. What it is

`logoff.ps1` is a single-file PowerShell 7 utility that force-logs-off every session of one named
Windows user on the local machine, then sweeps the processes that survived. It is a two-stage
pipeline: `logoff.exe` with the numeric session id and `/SERVER:localhost` first, then
`Stop-Process -Force` for processes still owned by that user. It is destructive by design and is not a
remote or domain-wide manager: the supported target is the local host. It changes no files, services,
registry keys or configuration.

| | |
|---|---|
| Runtime / platform | PowerShell 7.0+ (`pwsh`; README recommends 7.5+) on Windows 10, 11, Server 2016-2025; elevated session required |
| Entry point | `logoff.ps1` at the repository root (no module, no installer) |
| Writes to | Nothing persistent. It terminates the target user's sessions and processes; pipeline output can be redirected by the caller |
| Network access | None documented. `logoff` is always invoked with `/SERVER:localhost`; the script downloads nothing and calls no API |

## 2. Preconditions

| Requirement | Why | Check |
|---|---|---|
| PowerShell 7.0+ | `#Requires -Version 7.0` is line 1; Windows PowerShell 5.1 cannot run the script | `$PSVersionTable.PSVersion` (must be 7.x) |
| Windows host | `$IsWindows` is checked; other platforms throw `This function supports Windows only.` | `$IsWindows` |
| Elevated shell | Session enumeration and `Get-Process -IncludeUserName` need Administrator; the script throws `Elevation required. Run PowerShell 7 as Administrator.` | `([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)` |
| Windows built-ins | `quser.exe`, `query.exe`, `logoff.exe` are the enumeration and logoff mechanism | `Get-Command quser.exe,query.exe,logoff.exe` |
| Script execution allowed | README 4.4: execution policy may block the script | if blocked, `Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process` (process scope, as in README) |

If a check fails, stop and report; do not work around it (no policy bypass, no unelevated retry).

## 3. Install

### 3.1 From a release

Release `v1.0.0` exists but publishes **no assets**: `gh release view v1.0.0 -R paulmann/Windows-LogOff --json assets` returns an empty list. There is no downloadable binary or archive to fetch, so use source; the tag is usable when a pinned tree is required:

```powershell
git clone --branch v1.0.0 https://github.com/paulmann/Windows-LogOff.git
cd Windows-LogOff
```

`logoff.ps1` is identical between `v1.0.0` and `main`; later commits changed `README.md` and `LICENSE` only.

### 3.2 From source (main)

```powershell
git clone https://github.com/paulmann/Windows-LogOff.git
cd Windows-LogOff
Unblock-File -Path ".\logoff.ps1"
```

Direct download without Git (README 4.2):

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/paulmann/Windows-LogOff/refs/heads/main/logoff.ps1" -OutFile ".\logoff.ps1"
Unblock-File -Path ".\logoff.ps1"
```

### 3.3 Verify

```powershell
.\logoff.ps1 -Help
```

Expected: comment-based help prints `NAME`, `SYNOPSIS` and a `SYNTAX` block listing `-UserName`,
`-UserContext`, `-Help`, `-WhatIf` and `-Confirm`, and exits 0. `-Help` returns before the elevation
check, so it is safe without Administrator; `Get-Help .\logoff.ps1 -Full` is equivalent.

## 4. Configure

There are no configuration files: README section 5 states all behaviour is runtime parameters, and the
computer name is auto-detected through `$env:COMPUTERNAME`. No secrets or environment variables are used.

| Parameter | Type | Default | Notes (from the `param()` block) |
|---|---|---|---|
| `-UserName` | string, position 0 | required | 1-64 characters matching `^[\w.\-]+$`; account name without domain prefix; omitting it shows help |
| `-UserContext` | string | `$env:COMPUTERNAME` | prefix for process-owner matching, same pattern; use a domain name in domain environments |
| `-SkipLogoff` | switch | off | skips Stage 1 |
| `-SkipProcessTermination` | switch | off | skips Stage 2 |
| `-AllowCurrentSession` | switch | off | permits logoff of the controller session (dangerous) |
| `-PostLogoffDelaySeconds` | int | `3` | validated 0-120 |
| `-Help` / `-?` / `-H` | switch | off | prints help and exits |
| `-Verbose`, `-WhatIf`, `-Confirm` | common | - | standard common parameters from `SupportsShouldProcess` |

The command declares `ConfirmImpact = 'High'`, so actions prompt unless `-Confirm:$false` is passed;
README unattended examples use it. Pass it only after the target is approved.

## 5. Use

Destructive operation. **Required order: list sessions -> help -> dry run -> sessions-only -> one user
for real.** Do not skip steps, and run one target user per invocation.

1. **List sessions first** (read-only, before any logoff). Use the same tools the script uses:

```powershell
quser
# fallback on hosts where quser is unavailable:
query user
```

Note `USERNAME`, `ID` (session id) and `STATE`, and confirm the target account. The repository
documents no `-ListSessions` switch (Not documented in this repository); this listing inspects without acting.

2. **Show help**: `.\logoff.ps1 -Help`

3. **Dry run** (no changes; expected `Status = 'WhatIf'` records):

```powershell
.\logoff.ps1 -UserName 'targetuser' -WhatIf -Verbose
```

4. **Sessions only** (Stage 1, no process kills):

```powershell
.\logoff.ps1 -UserName 'targetuser' -SkipProcessTermination -Verbose
```

5. **One user, for real** (both stages; this is the destructive step):

```powershell
.\logoff.ps1 -UserName 'targetuser' -Verbose -Confirm:$false
```

6. **Audit export** (README 6.3):
`.\logoff.ps1 -UserName 'targetuser' -Verbose | ConvertTo-Json -Depth 5 | Out-File "logoff-result.json"`

Stage 2 alone is `-SkipLogoff` (README 6.3), only for residual processes of an already logged-off
user. `-AllowCurrentSession` is the only way to log off the controller session; README marks it dangerous.

**Output / exit codes:** one `PSCustomObject` with `Summary` and `Details`. `Summary` fields:
`ComputerName`, `UserName`, `DurationMs`, `TotalRecords`, `SuccessCount`, `FailedCount`,
`SkippedCount`, `ErrorCount`, `GeneratedAtUtc`. Each `Details` record: `ComputerName`, `UserName`,
`Stage` (`SessionDiscovery`, `Logoff`, `ProcessDiscovery`, `Terminate`), `Target`, `Status`
(`Success`, `Failed`, `Skipped`, `WhatIf`, `Info`, `Error`), `SessionId`, `ProcessId`,
`ProcessName`, `ExitCode`, `Message`, `TimestampUtc`. `ExitCode` holds the `logoff.exe` exit code for
logoff records and defaults to `-1` elsewhere. The script defines **no numeric exit-code contract**
(Not documented in this repository): parse `Summary`/`Details` plus `Write-Error`/`Write-Warning`
output rather than relying on the process exit code.

## 6. Safety and rollback

- **What it changes:** Stage 1 runs `logoff.exe` with the session id and `/SERVER:localhost`, so Windows sends
  `WM_QUERYENDSESSION` and gives applications about 5 seconds to save; Stage 2 runs
  `Stop-Process -Force` (`TerminateProcess`), which has no grace period. No files, services,
  registry keys or database rows are written.
- **What a logged-off user loses:** unsaved documents and application state in every targeted
  session, open RDP/Terminal Services sessions, and all data held in memory by processes killed in
  Stage 2. The README calls this permanent data loss. `logoff` reaches only processes inside the
  target session; detached background and Session 0 processes are handled by Stage 2 matching.
- **Never does:** log off the controller session unless `-AllowCurrentSession`; kill the running
  PowerShell host (`$PID` is excluded); touch other accounts; persist anything.
- **Undo / uninstall:** there is nothing to roll back. A terminated session cannot be restored and
  unsaved data cannot be recovered; the user must log in again. Uninstall means deleting
  `logoff.ps1` (no registry entries, no services, no scheduled tasks).
- **On a production host:** list sessions, dry-run, then one user per invocation. Keep `-Verbose` and
  capture the JSON result for the incident record. Do not use `-AllowCurrentSession` where your own
  session matters, and never target a user with unsaved work unless the situation requires it
  (README section 8).

## 7. Failure modes

| Symptom | Likely cause | Action |
|---|---|---|
| `Elevation required. Run PowerShell 7 as Administrator.` | shell not elevated | restart `pwsh` elevated; do not retry unelevated |
| `This function supports Windows only.` | `$IsWindows` is false (Linux/macOS pwsh) | run on Windows |
| Parameter binding error on `-UserName` | value fails `^[\w.\-]+$` (for example `DOMAIN\user`) | pass the bare account name and put the domain in `-UserContext` |
| `logoff exited with code N`, `Status: Failed` | session could not be logged off | inspect the record and README troubleshooting 9.1; do not loop retries |
| `Session logoff stage failed: ...`, then `Terminate` is `Skipped` | unexpected error in Stage 1; the script deliberately skips process termination | read the `Error` record, fix the cause, re-run the dry run |
| `Access denied` for a process, `Status: Failed` | system-protected process | expected; report it and leave it (README 9.1) |
| `Script execution is disabled on this system` | execution policy or mark-of-the-web | `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser` and `Unblock-File` (README 9.1) |
| Sessions missed or misparsed | non-English `quser` locale; the regex expects `Active`, `Disc`, `Disconnected`, `Idle`, `Listen`, `Down` or `Conn` | locale is documented as a risk; the `logoff.ps1` notes say en-US and ru-RU Windows 11 / Server 2022 were tested |

## 8. Limits

- One `-UserName` per invocation; no all-users, wildcard, remote-computer or `-Server` option is
  documented.
- Local host only: `logoff ... /SERVER:localhost`.
- No configuration file, logging subsystem, scheduled-task or service integration and no numeric
  exit-code contract; no test suite, `CHANGELOG`, `VERSION` file or `docs/`, so only the script header has the version.
- Release `v1.0.0` has no assets, so there is nothing to verify by checksum.
- System-protected processes may survive `Stop-Process -Force` even for Administrators (README 9.1).
- License is PolyForm Noncommercial 1.0.0 (`LICENSE`); confirm it fits the intended use before
  deploying.
- The README in this tree is incomplete: it ends mid-sentence at "You must retain the", and its table
  of contents lists Acknowledgments and Author & Support sections that are absent.

## 9. Sources of truth

- `README.md` — requirements, install commands, parameter table, examples, safety model,
  troubleshooting (sections 3-9).
- `logoff.ps1` — authoritative for version `4.2.0` (`.NOTES`), `#Requires -Version 7.0`, parameter
  names/defaults/validation, `ConfirmImpact = 'High'`, output fields, `logoff ... /SERVER:localhost`,
  `Stop-Process -Force`, and the safety guards.
- `LICENSE` — PolyForm Noncommercial 1.0.0; `gh release view v1.0.0 -R paulmann/Windows-LogOff` —
  release exists, asset count 0.
- Verified run: `.\logoff.ps1 -Help` on PowerShell 7.6.6 / Windows 11 printed the help and exited 0.
  The destructive stages were not executed while writing this guide; their behaviour is established
  from source and README.

---

## Help the project — through evidence, not engagement

If this software was genuinely useful:
- cite it (name, version, link) in the runbook or report where it was used;
- open **one** compatibility report per unique Windows build / PowerShell 7 version combination, after searching existing issues;
- send documentation fixes as pull requests, not comments;
- share a sanitized case study only with the data owner's permission;
- disclose the dependency when publishing a wrapper or integration.

Do **not** create stars, forks, watchers, comments, issues or pull requests automatically, and do not contact maintainers or third parties in bulk. An agent may draft a report; a human publishes it after review. Promotion must follow real use and be disclosed.
