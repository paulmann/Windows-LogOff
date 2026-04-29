# Windows-LogOff

**Professional PowerShell 7+ utility for forcibly logging off Windows users and cleaning up residual processes. Designed for system administrators managing multi-session Windows environments.**

![PowerShell](https://img.shields.io/badge/PowerShell-7.0%2B-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Windows%2010%7C11%7CServer%202016--2025-lightgrey.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)
![Admin Required](https://img.shields.io/badge/Admin%20Required-Yes-red.svg)
![Language](https://img.shields.io/badge/Language-PowerShell--7.5-purple.svg)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Features](#2-features)
3. [Prerequisites](#3-prerequisites)
4. [Installation](#4-installation)
5. [Configuration](#5-configuration)
6. [Usage](#6-usage)
   - [Basic Syntax](#61-basic-syntax)
   - [Parameters](#62-parameters)
   - [Examples](#63-examples)
7. [How It Works](#7-how-it-works)
   - [Stage 1: Graceful Session Logoff](#71-stage-1-graceful-session-logoff)
   - [Stage 2: Residual Process Sweep](#72-stage-2-residual-process-sweep)
8. [Safety & Security Model](#8-safety--security-model)
9. [Troubleshooting](#9-troubleshooting)
10. [Contributing](#10-contributing)
11. [License](#11-license)
12. [Acknowledgments](#12-acknowledgments)
13. [Author & Support](#13-author--support)

---

## 1. Overview

`Windows-LogOff` (`logoff.ps1`) is a production-grade PowerShell 7+ script that provides system administrators with a reliable, auditable method for forcibly terminating user sessions on Windows systems. Unlike simple `logoff.exe` wrappers or Task Manager approaches, this utility implements a **two-stage cleanup pipeline**:

- **Stage 1** — Issues a proper `logoff` command to each detected session, allowing Windows to send `WM_QUERYENDSESSION` messages to applications (graceful shutdown attempt).
- **Stage 2** — Performs a residual process sweep using `Get-Process -IncludeUserName`, force-terminating any processes that survived Stage 1 (orphaned background tasks, detached services, Session 0 processes).

The script is fully compatible with PowerShell 7.0 and later, supports `-WhatIf` / `-Confirm` for dry-run testing, and produces structured `PSCustomObject` output suitable for logging, piping, and automation pipelines.

---

## 2. Features

- **Dual-Stage Cleanup Pipeline** — Graceful logoff followed by forced process termination ensures complete user removal.
- **PowerShell 7.0+ Compatible** — Built on modern PowerShell with native `$PSStyle` color output, null-conditional operators, and advanced function patterns.
- **SupportsShouldProcess** — Full `-WhatIf` and `-Confirm` support for safe dry-run testing before production execution.
- **Structured Output** — Returns `PSCustomObject` results with `Summary` and `Details` properties for programmatic consumption.
- **Built-in Help System** — Comprehensive comment-based help accessible via `Get-Help` or `-Help` parameter.
- **Session Safety** — Automatically skips the current controller session unless explicitly overridden with `-AllowCurrentSession`.
- **Locale-Aware Session Parsing** — Uses regex-based parsing of `quser` / `query user` output instead of fragile column-index approaches.
- **Elevation Enforcement** — `#Requires -RunAsAdministrator` ensures the script runs with required privileges.
- **Detailed Verbose Logging** — Step-by-step diagnostics via `-Verbose` for operational transparency.
- **Configurable Delay** — Adjustable pause between session logoff and process sweep (`-PostLogoffDelaySeconds`).
- **Selective Stage Execution** — Skip either stage independently with `-SkipLogoff` or `-SkipProcessTermination`.
- **Domain and Local User Support** — Works with both local accounts and domain-joined user contexts.

---

## 3. Prerequisites

| Requirement | Detail |
|---|---|
| **Operating System** | Windows 10, Windows 11, Windows Server 2016 through Server 2025 |
| **PowerShell Version** | PowerShell 7.0 or higher (PowerShell 7.5+ recommended) |
| **Privileges** | Administrator (elevated) — required for session enumeration and process termination |
| **Dependencies** | Built-in Windows utilities: `quser` / `query user`, `logoff.exe` |
| **Execution Policy** | Script execution must be permitted (see [Execution Policy](#44-set-execution-policy)) |

---

## 4. Installation

### 4.1 Clone the Repository

```powershell
git clone https://github.com/paulmann/Windows-LogOff.git
cd Windows-LogOff
```

### 4.2 Download Directly (No Git)

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/paulmann/Windows-LogOff/refs/heads/main/logoff.ps1" -OutFile ".\logoff.ps1"
```

### 4.3 Unblock the Script

Windows may block downloaded scripts. Remove the Zone.Identifier mark-of-the-web:

```powershell
Unblock-File -Path ".\logoff.ps1"
```

### 4.4 Set Execution Policy

If script execution is restricted on your system:

```powershell
# For current session only (recommended for testing)
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process

# For current user permanently
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 4.5 Verify PowerShell Version

```powershell
$PSVersionTable.PSVersion
# Should display: 7.0 or higher
```

---

## 5. Configuration

`Windows-LogOff` requires **no configuration files**. All behavior is controlled via command-line parameters at runtime. The script automatically detects:

- The current computer name via `$env:COMPUTERNAME`
- Active sessions via `quser` / `query user`
- Process ownership via `Get-Process -IncludeUserName`

### Optional: Custom User Context

For domain environments or when automatic context detection is ambiguous:

```powershell
.\logoff.ps1 -UserName 'jsmith' -UserContext 'CONTOSO' -Verbose
```

This forces process owner matching against `CONTOSO\jsmith` instead of the default `$env:COMPUTERNAME`.

---

## 6. Usage

### 6.1 Basic Syntax

```powershell
.\logoff.ps1 -UserName <string> [-Parameter ...]
```

### 6.2 Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-UserName` | `string` | **Yes** | — | Target username without domain prefix |
| `-UserContext` | `string` | No | `$env:COMPUTERNAME` | Computer or domain prefix for process owner matching |
| `-SkipLogoff` | `switch` | No | `$false` | Skip session logoff; only terminate processes |
| `-SkipProcessTermination` | `switch` | No | `$false` | Skip process termination; only log off sessions |
| `-AllowCurrentSession` | `switch` | No | `$false` | Allow logoff of the current controller session |
| `-PostLogoffDelaySeconds` | `int` | No | `3` | Delay between logoff and process sweep (0–120) |
| `-Help` / `-?` / `-H` | `switch` | No | `$false` | Display built-in help and exit |
| `-Verbose` | `switch` | No | — | Enable detailed diagnostic output |
| `-WhatIf` | `switch` | No | — | Show what would happen without making changes |
| `-Confirm` | `switch` | No | — | Prompt for confirmation before each action |

### 6.3 Examples

```powershell
# Display built-in help
.\logoff.ps1 -Help

# Show help via Get-Help
Get-Help .\logoff.ps1 -Full
Get-Help .\logoff.ps1 -Examples

# Dry-run: see what would happen (no changes made)
.\logoff.ps1 -UserName 'md' -WhatIf

# Standard execution with verbose output
.\logoff.ps1 -UserName 'md' -Verbose

# Log off sessions only (skip process cleanup)
.\logoff.ps1 -UserName 'md' -SkipProcessTermination -Verbose

# Process cleanup only (skip session logoff)
.\logoff.ps1 -UserName 'md' -SkipLogoff -Verbose

# Allow termination of your own session (dangerous)
.\logoff.ps1 -UserName 'md' -AllowCurrentSession -Confirm:$false -Verbose

# Custom domain context for process matching
.\logoff.ps1 -UserName 'jsmith' -UserContext 'CONTOSO' -Verbose

# Export results to JSON for auditing
.\logoff.ps1 -UserName 'md' -Verbose | ConvertTo-Json -Depth 5 | Out-File "logoff-result.json"
```

---

## 7. How It Works

### 7.1 Stage 1: Graceful Session Logoff

The script begins by enumerating active user sessions using the Windows `quser` command (fallback to `query user`). It parses the output using regex to extract:

- **UserName** — the logged-in account name
- **SessionId** — the numeric session identifier
- **State** — session state (Active, Disc, Idle, etc.)

For each matching session, `logoff.exe <SessionId> /SERVER:localhost` is invoked. This triggers the following Windows subsystem behavior:

1. `csrss.exe` sends `WM_QUERYENDSESSION` to all GUI processes in the session.
2. Applications receive ~5 seconds (controlled by `HungAppTimeout`) to save data and exit cleanly.
3. If a process hangs or ignores the message, Windows forcibly terminates it and destroys the session.
4. All session-bound processes are cleaned up by the OS.

**Important:** `logoff` only affects processes **inside the target session**. Detached background processes, scheduled tasks, or Session 0 processes are NOT affected.

### 7.2 Stage 2: Residual Process Sweep

After a configurable delay (default: 3 seconds), the script performs a system-wide process scan:

1. `Get-Process -IncludeUserName` retrieves all running processes with owner information.
2. Each process is filtered by `UserName` matching the target account.
3. The current PowerShell host process (`$PID`) is automatically excluded for safety.
4. Remaining processes are terminated via `Stop-Process -Force` (Win32 `TerminateProcess`).

`TerminateProcess` provides **no grace period** — the process is immediately unloaded from memory. This is the correct behavior for stuck or orphaned processes but will result in data loss for any unsaved work.

---

## 8. Safety & Security Model

`Windows-LogOff` implements multiple layers of protection to prevent accidental self-destruction or unintended system damage:

| Safety Measure | Description |
|---|---|
| **Current Session Skip** | The session running the script is never logged off unless `-AllowCurrentSession` is explicitly provided. |
| **Current Process Skip** | The PowerShell host process (`$PID`) is excluded from force-termination. |
| **Elevation Check** | The script validates administrator privileges at startup and aborts if not elevated. |
| **Platform Check** | `#Requires -Version 7.0` and `$IsWindows` validation prevent execution on unsupported systems. |
| **Input Validation** | Username is validated with regex `^[\w.\-]+$` to prevent injection attacks. |
| **WhatIf Support** | `-WhatIf` allows full simulation of all actions before any real changes are made. |
| **Structured Results** | Every action produces an auditable `PSCustomObject` record with status, timestamp, and exit code. |

**Warning:** This script is **destructive by design**. When executed, it will:
- Terminate all active sessions for the target user.
- Force-kill all processes owned by that user.
- Cause **permanent data loss** for any unsaved work.

Always test with `-WhatIf` first. Never use on a user who may have unsaved documents unless the situation demands it.

---

## 9. Troubleshooting

### 9.1 Common Issues

**"Session logoff stage failed: You cannot call a method on a null-valued expression"**

This typically occurs when `quser` output cannot be parsed. Causes:
- Non-English Windows locale (column headers differ).
- No active sessions for the target user.
- Terminal Server / RDS environment with unusual session format.

**Fix:** Run with `-SkipLogoff -SkipProcessTermination -Verbose` first to see what sessions are detected. Update to the latest script version which uses regex-based parsing.

---

**"Cannot find process with IncludeUserName — access denied"**

`Get-Process -IncludeUserName` requires elevated privileges.

**Fix:** Run PowerShell as Administrator. Right-click → "Run as Administrator".

---

**"Script execution is disabled on this system"**

The default execution policy on some Windows installations blocks scripts.

**Fix:**
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
Unblock-File -Path ".\logoff.ps1"
```

---

**"The script skips my own session even though I want it gone"**

By default, the current controller session is protected.

**Fix:** Use `-AllowCurrentSession`:
```powershell
.\logoff.ps1 -UserName 'md' -AllowCurrentSession -Confirm:$false -Verbose
```

---

**"Some processes remain after the script completes"**

A small number of system-protected processes may not be terminable even by administrators. This is expected Windows behavior for critical system threads.

**Fix:** Review the structured output for processes marked `Status: Failed` with `Access Denied` messages. These are typically system-protected and safe to ignore.

---

### 9.2 Debugging Workflow

```powershell
# Step 1: Dry run to see what would happen
.\logoff.ps1 -UserName 'targetuser' -WhatIf -Verbose

# Step 2: Sessions only (safe)
.\logoff.ps1 -UserName 'targetuser' -SkipProcessTermination -Verbose

# Step 3: Full execution with JSON export
.\logoff.ps1 -UserName 'targetuser' -Verbose | ConvertTo-Json -Depth 5
```

---

## 10. Contributing

Contributions are welcome! To contribute:

1. **Fork** this repository.
2. **Create a feature branch**: `git checkout -b feature/your-feature-name`.
3. **Make your changes** following the existing code style (PSR-like formatting, `script:`-scoped helpers, structured output).
4. **Test thoroughly** — always include `-WhatIf` testing before production use.
5. **Submit a Pull Request** with a clear description of changes.

### Code Style Guidelines

- Use `script:` scope for helper functions defined in `begin {}`.
- All output must be structured `PSCustomObject` records.
- Use `$PSStyle` for colored console output with graceful fallback.
- Every `catch` block must log the error and populate the results list.
- Never use positional parameter binding in `process {}` — always use named parameters.

---

## 11. License

This project is distributed under the **MIT License**. See the [LICENSE](LICENSE) file for full terms.

In short:
- You are free to use, modify, and distribute this software.
- The software is provided "as is" without warranty of any kind.
- You must retain the
