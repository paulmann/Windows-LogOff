#Requires -Version 7.0

<#
.SYNOPSIS
    Forces logoff of a target Windows user's sessions and terminates remaining processes.

.DESCRIPTION
    Windows administrative utility for PowerShell 7+.
    The script enumerates user sessions via quser/query user, safely logs off matched
    sessions, waits for a configurable delay, then optionally terminates any remaining
    processes owned by the target user.

    Safe operational design:
    - Supports -WhatIf and -Confirm (preference variables cascade automatically)
    - Returns structured result objects (pipeline-friendly)
    - Skips the current controller session by default
    - Requires administrative elevation
    - Detailed verbose diagnostics throughout

.PARAMETER UserName
    Target username without domain prefix.

.PARAMETER UserContext
    Optional computer or domain prefix used for stricter process owner matching.
    Examples: MYPC, CONTOSO. Default: current computer name ($env:COMPUTERNAME).

.PARAMETER SkipLogoff
    Skips the session logoff stage entirely.

.PARAMETER SkipProcessTermination
    Skips the residual process termination stage.

.PARAMETER AllowCurrentSession
    Allows logoff of the current controlling session if it belongs to the target user.
    Use with caution — will terminate your own PowerShell session.

.PARAMETER PostLogoffDelaySeconds
    Seconds to wait between session logoff and residual process sweep.
    Default: 3.

.PARAMETER Help
    Displays full built-in help and exits without performing any actions.

.EXAMPLE
    .\logoff.ps1 -UserName md -Verbose
    Logs off all sessions for user 'md', then terminates residual processes.

.EXAMPLE
    .\logoff.ps1 -UserName md -WhatIf
    Simulates all actions without making any changes.

.EXAMPLE
    .\logoff.ps1 -UserName md -SkipProcessTermination -Verbose
    Logs off sessions only; skips residual process termination.

.EXAMPLE
    .\logoff.ps1 -UserName md -AllowCurrentSession -Confirm:$false -Verbose
    Forcefully logs off all sessions including current, no confirmation prompt.

.EXAMPLE
    .\logoff.ps1 -UserName md | Select-Object -ExpandProperty Summary
    Runs cleanup and shows only the summary object.

.EXAMPLE
    .\logoff.ps1 -UserName md | ConvertTo-Json -Depth 5
    Exports full structured result as JSON for logging or automation.

.EXAMPLE
    Get-Help .\logoff.ps1 -Full
    Displays this complete built-in help.

.OUTPUTS
    PSCustomObject with properties:
    - Summary : counts and timing metadata
    - Details : per-action result records

.NOTES
    Author  : Mikhail Deynekin
    Site    : https://Deynekin.com
    Email   : Mikhail@Deynekin.com
    Version : 4.2.0

    Requirements:
    - PowerShell 7.0 or later
    - Windows OS
    - Administrative (elevated) privileges

    Notes:
    - quser/query user output format is locale-sensitive.
      Tested on en-US and ru-RU Windows 11 / Windows Server 2022.
    - Get-Process -IncludeUserName requires elevation.
      Some system-protected processes may still resist termination.
    - -WhatIf and -Confirm are standard PowerShell common parameters
      and cascade automatically; do not pass them explicitly via hashtable.

.LINK
    https://github.com/Deynekin
.LINK
    https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/logoff
.LINK
    https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0, HelpMessage = 'Target user name without domain prefix')]
    [ValidateLength(1, 64)]
    [ValidatePattern('^[\w.\-]+$')]
    [string]$UserName,

    [Parameter(HelpMessage = 'Computer or domain prefix for strict process owner matching')]
    [ValidatePattern('^[\w.\-]+$')]
    [string]$UserContext = $env:COMPUTERNAME,

    [Parameter(HelpMessage = 'Skip the session logoff stage')]
    [switch]$SkipLogoff,

    [Parameter(HelpMessage = 'Skip the residual process termination stage')]
    [switch]$SkipProcessTermination,

    [Parameter(HelpMessage = 'Allow logoff of the current controller session if it belongs to the target user')]
    [switch]$AllowCurrentSession,

    [Parameter(HelpMessage = 'Seconds to wait between session logoff and process sweep (0-120)')]
    [ValidateRange(0, 120)]
    [int]$PostLogoffDelaySeconds = 3,

    [Parameter(HelpMessage = 'Display full help and exit')]
    [Alias('?', 'H')]
    [switch]$Help
)

# ─────────────────────────────────────────────────────────────────────────────
# Show help when -Help flag present OR when UserName was not supplied
# ─────────────────────────────────────────────────────────────────────────────
if ($Help.IsPresent -or [string]::IsNullOrWhiteSpace($UserName)) {
    Get-Help $PSCommandPath -Full
    return
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal function — force-logoff implementation
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-WindowsUserForceLogoff {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [ValidateLength(1, 64)]
        [ValidatePattern('^[\w.\-]+$')]
        [string]$UserName,

        [ValidatePattern('^[\w.\-]+$')]
        [string]$UserContext = $env:COMPUTERNAME,

        [switch]$SkipLogoff,
        [switch]$SkipProcessTermination,
        [switch]$AllowCurrentSession,

        [ValidateRange(0, 120)]
        [int]$PostLogoffDelaySeconds = 3
    )

    begin {
        if (-not $IsWindows) {
            throw [System.PlatformNotSupportedException]::new(
                'This function supports Windows only.'
            )
        }

        # Elevation check
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Elevation required. Run PowerShell 7 as Administrator.'
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $results   = [System.Collections.Generic.List[pscustomobject]]::new()
	$sessionStageFailed = $false

        # ── Helper: build a typed result record ───────────────────────────────
        function script:New-OperationResult {
            [OutputType([pscustomobject])]
            param(
                [Parameter(Mandatory)] [string]$Stage,
                [Parameter(Mandatory)] [string]$Target,
                [Parameter(Mandatory)]
                [ValidateSet('Success','Failed','Skipped','WhatIf','Info','Error')]
                [string]$Status,
                [string]   $Message,
                [Nullable[int]] $SessionId   = $null,
                [Nullable[int]] $ProcessId   = $null,
                [string]   $ProcessName = '',
                [int]      $ExitCode    = -1
            )
            [pscustomobject]@{
                ComputerName = $env:COMPUTERNAME
                UserName     = $UserName
                Stage        = $Stage
                Target       = $Target
                Status       = $Status
                SessionId    = $SessionId
                ProcessId    = $ProcessId
                ProcessName  = $ProcessName
                ExitCode     = $ExitCode
                Message      = $Message
                TimestampUtc = [datetime]::UtcNow.ToString('o')
            }
        }

        # ── Helper: get SessionId of the current PS process via CIM ───────────
        function script:Get-CurrentSessionId {
            try {
                $cim = Get-CimInstance Win32_Process `
                       -Filter "ProcessId = $PID" -ErrorAction Stop
                return [int]$cim.SessionId
            }
            catch {
                Write-Verbose "Cannot resolve current SessionId: $($_.Exception.Message)"
                return $null
            }
        }

        # ── Helper: parse quser output, return sessions matching TargetUser ───
        function script:Get-UserSessions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TargetUser
    )

    [string[]]$raw = @()

    try {
        $raw = @(& quser 2>$null)

        if (-not $raw -or $raw.Count -eq 0) {
            $raw = @(& query.exe user 2>$null)
        }
    }
    catch {
        Write-Verbose "Failed to execute quser/query user: $($_.Exception.Message)"
        return @()
    }

    if (-not $raw -or $raw.Count -lt 2) {
        Write-Verbose 'No session data returned by quser/query user.'
        return @()
    }

    $sessions = foreach ($line in ($raw | Select-Object -Skip 1)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $work = ($line -replace '^\s*>', '').Trim()
        if ([string]::IsNullOrWhiteSpace($work)) {
            continue
        }

        $userMatch = [regex]::Match($work, '^(?<User>\S+)')
        if (-not $userMatch.Success) {
            continue
        }

        $sessionIdMatch = [regex]::Match($work, '(?<!\S)(?<Id>\d+)(?!\S)')
        if (-not $sessionIdMatch.Success) {
            continue
        }

        $stateMatch = [regex]::Match(
            $work,
            '\b(?<State>Active|Disc|Disconnected|Idle|Listen|Down|Conn)\b',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        $parsedUser = $userMatch.Groups['User'].Value
        $sessionId  = [int]$sessionIdMatch.Groups['Id'].Value
        $state      = if ($stateMatch.Success) { $stateMatch.Groups['State'].Value } else { 'Unknown' }

        [pscustomobject]@{
            UserName    = $parsedUser
            SessionName = ''
            SessionId   = $sessionId
            State       = $state
            RawLine     = $line
        }
    }

    @($sessions | Where-Object { $_.UserName -ieq $TargetUser })
}

        # ── Helper: find processes owned by target user ───────────────────────
        function script:Get-UserProcesses {
            param(
                [Parameter(Mandatory)][string]$TargetUserName,
                [Parameter(Mandatory)][string]$TargetContext
            )

            $strict = "$TargetContext\$TargetUserName"
            $suffix = "\$TargetUserName"

            @(Get-Process -IncludeUserName -ErrorAction SilentlyContinue |
                Where-Object {
                    $null -ne $_.UserName -and (
                        $_.UserName -ieq $strict -or
                        $_.UserName.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)
                    )
                })
        }

        $currentSessionId = script:Get-CurrentSessionId

        Write-Verbose (
            "BEGIN | User='{0}' Context='{1}' ControllerSession={2} SkipLogoff={3} SkipKill={4}" -f
            $UserName, $UserContext, $currentSessionId, $SkipLogoff, $SkipProcessTermination
        )
    }

    process {

        # ── Stage 1: Session Logoff ───────────────────────────────────────────
        if (-not $SkipLogoff) {
            try {
                $sessions = script:Get-UserSessions -TargetUser $UserName

                if ($sessions.Count -eq 0) {
                    $results.Add((script:New-OperationResult -Stage 'SessionDiscovery' `
                        -Target $UserName -Status 'Info' `
                        -Message "No active sessions found for '$UserName'."))
                    Write-Verbose "No active sessions found for '$UserName'."
                }
                else {
                    Write-Verbose "Found $($sessions.Count) session(s) for '$UserName'."

                    foreach ($session in $sessions) {
                        # Guard: skip current controlling session unless explicitly allowed
                        if (-not $AllowCurrentSession -and
                            $null -ne $currentSessionId -and
                            $session.SessionId -eq $currentSessionId)
                        {
                            $msg = "Skipped current controller session ID $($session.SessionId) (safety guard). Use -AllowCurrentSession to override."
                            Write-Warning $msg
                            $results.Add((script:New-OperationResult -Stage 'Logoff' `
                                -Target $session.UserName -Status 'Skipped' `
                                -Message $msg -SessionId $session.SessionId))
                            continue
                        }

                        $action = "Logoff session ID $($session.SessionId) " +
                                  "[$($session.SessionName), state=$($session.State)] " +
                                  "for user '$($session.UserName)'"

                        if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, $action)) {
                            Write-Verbose "Executing: logoff $($session.SessionId) /SERVER:localhost"
                            & logoff $session.SessionId /SERVER:localhost 2>$null
                            $code = $LASTEXITCODE

                            if ($code -eq 0) {
                                $results.Add((script:New-OperationResult -Stage 'Logoff' `
                                    -Target $session.UserName -Status 'Success' `
                                    -Message 'Session logoff completed.' `
                                    -SessionId $session.SessionId -ExitCode $code))
                                Write-Verbose "Session $($session.SessionId) logged off successfully."
                            }
                            else {
                                $results.Add((script:New-OperationResult -Stage 'Logoff' `
                                    -Target $session.UserName -Status 'Failed' `
                                    -Message "logoff exited with code $code." `
                                    -SessionId $session.SessionId -ExitCode $code))
                                Write-Warning "logoff session $($session.SessionId) failed. Exit code: $code"
                            }
                        }
                        else {
                            $results.Add((script:New-OperationResult -Stage 'Logoff' `
                                -Target $session.UserName -Status 'WhatIf' `
                                -Message 'Logoff skipped (-WhatIf / -Confirm declined).' `
                                -SessionId $session.SessionId))
                        }
                    }
                }
            }
catch {
    $sessionStageFailed = $true
    $msg = "Session logoff stage failed: $($_.Exception.Message)"
    $results.Add((script:New-OperationResult -Stage 'Logoff' `
        -Target $UserName -Status 'Error' -Message $msg))
    Write-Error $msg
}

            if ($PostLogoffDelaySeconds -gt 0) {
                Write-Verbose "Waiting ${PostLogoffDelaySeconds}s before residual process sweep."
                Start-Sleep -Seconds $PostLogoffDelaySeconds
            }
        }
        else {
            $results.Add((script:New-OperationResult -Stage 'Logoff' `
                -Target $UserName -Status 'Skipped' `
                -Message 'Session logoff skipped by -SkipLogoff.'))
            Write-Verbose 'Logoff stage skipped (-SkipLogoff).'
        }

        # ── Stage 2: Residual Process Termination ─────────────────────────────
        if ($sessionStageFailed) {
    $results.Add((script:New-OperationResult -Stage 'Terminate' `
        -Target $UserName -Status 'Skipped' `
        -Message 'Process termination skipped because the session logoff stage failed.'))
    Write-Verbose 'Process termination skipped because the session logoff stage failed.'
}
elseif (-not $SkipProcessTermination) {
            try {
                $processes = script:Get-UserProcesses `
                    -TargetUserName $UserName -TargetContext $UserContext

                if ($processes.Count -eq 0) {
                    $results.Add((script:New-OperationResult -Stage 'ProcessDiscovery' `
                        -Target $UserName -Status 'Info' `
                        -Message "No residual processes found for '$UserName'."))
                    Write-Verbose "No residual processes found for '$UserName'."
                }
                else {
                    Write-Verbose "Found $($processes.Count) process(es) for '$UserName'. Terminating..."

                    foreach ($proc in $processes) {
                        # Guard: never kill the current PS host process
                        if ($proc.Id -eq $PID) {
                            $msg = "Skipped current PowerShell host process (PID $PID) for safety."
                            Write-Warning $msg
                            $results.Add((script:New-OperationResult -Stage 'Terminate' `
                                -Target $proc.UserName -Status 'Skipped' `
                                -Message $msg -ProcessId $proc.Id -ProcessName $proc.ProcessName))
                            continue
                        }

                        $action = "Terminate PID $($proc.Id) [$($proc.ProcessName)] owned by '$($proc.UserName)'"

                        if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, $action)) {
                            try {
                                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                                $results.Add((script:New-OperationResult -Stage 'Terminate' `
                                    -Target $proc.UserName -Status 'Success' `
                                    -Message 'Process terminated.' `
                                    -ProcessId $proc.Id -ProcessName $proc.ProcessName))
                                Write-Verbose "Terminated PID $($proc.Id) [$($proc.ProcessName)]."
                            }
                            catch [System.ComponentModel.Win32Exception] {
                                # Access Denied — system-protected process
                                $results.Add((script:New-OperationResult -Stage 'Terminate' `
                                    -Target $proc.UserName -Status 'Failed' `
                                    -Message "Access denied: $($_.Exception.Message)" `
                                    -ProcessId $proc.Id -ProcessName $proc.ProcessName))
                                Write-Warning "Access denied — PID $($proc.Id) [$($proc.ProcessName)]: $($_.Exception.Message)"
                            }
                            catch {
                                $results.Add((script:New-OperationResult -Stage 'Terminate' `
                                    -Target $proc.UserName -Status 'Failed' `
                                    -Message $_.Exception.Message `
                                    -ProcessId $proc.Id -ProcessName $proc.ProcessName))
                                Write-Warning "Failed to terminate PID $($proc.Id) [$($proc.ProcessName)]: $($_.Exception.Message)"
                            }
                        }
                        else {
                            $results.Add((script:New-OperationResult -Stage 'Terminate' `
                                -Target $proc.UserName -Status 'WhatIf' `
                                -Message 'Termination skipped (-WhatIf / -Confirm declined).' `
                                -ProcessId $proc.Id -ProcessName $proc.ProcessName))
                        }
                    }
                }
            }
            catch {
                $msg = "Process termination stage failed: $($_.Exception.Message)"
                $results.Add((script:New-OperationResult -Stage 'Terminate' `
                    -Target $UserName -Status 'Error' -Message $msg))
                Write-Error $msg
            }
        }
        else {
            $results.Add((script:New-OperationResult -Stage 'Terminate' `
                -Target $UserName -Status 'Skipped' `
                -Message 'Process termination skipped by -SkipProcessTermination.'))
            Write-Verbose 'Process termination stage skipped (-SkipProcessTermination).'
        }
    }

    end {
        $stopwatch.Stop()

        $summary = [pscustomobject]@{
            ComputerName   = $env:COMPUTERNAME
            UserName       = $UserName
            DurationMs     = $stopwatch.ElapsedMilliseconds
            TotalRecords   = $results.Count
            SuccessCount   = @($results | Where-Object Status -eq 'Success').Count
            FailedCount    = @($results | Where-Object Status -eq 'Failed').Count
            SkippedCount   = @($results | Where-Object Status -in 'Skipped','WhatIf').Count
            ErrorCount     = @($results | Where-Object Status -eq 'Error').Count
            GeneratedAtUtc = [datetime]::UtcNow.ToString('o')
        }

        Write-Verbose (
            "END | Duration={0}ms Success={1} Failed={2} Skipped={3} Error={4}" -f
            $summary.DurationMs,
            $summary.SuccessCount,
            $summary.FailedCount,
            $summary.SkippedCount,
            $summary.ErrorCount
        )

        [pscustomobject]@{
            Summary = $summary
            Details = @($results)
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry point — forward script params to internal function.
# NOTE: -WhatIf, -Verbose, -Confirm are NOT passed explicitly via hashtable.
#       PowerShell cascades $WhatIfPreference, $VerbosePreference,
#       $ConfirmPreference automatically to all called functions.
# ─────────────────────────────────────────────────────────────────────────────
$invokeParams = @{
    UserName               = $UserName
    UserContext            = $UserContext
    SkipLogoff             = $SkipLogoff.IsPresent
    SkipProcessTermination = $SkipProcessTermination.IsPresent
    AllowCurrentSession    = $AllowCurrentSession.IsPresent
    PostLogoffDelaySeconds = $PostLogoffDelaySeconds
}

Invoke-WindowsUserForceLogoff @invokeParams
