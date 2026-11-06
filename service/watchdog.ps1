[CmdletBinding()]
param(
    [ValidateRange(10, 300)][int]$MaxHeartbeatAgeSeconds = 20
)

# ConvertFrom-Json returns ISO-8601 timestamps as [DateTime] under PowerShell 7 (Kind=Utc) and as
# [string] under Windows PowerShell 5.1. Re-parsing a DateTime's ToString() drops the zone and
# treats the UTC clock value as local time, which reported the heartbeat as -25,000 s old
# (seven hours in the future) under pwsh while looking correct under 5.1. Accept either form.
function ConvertTo-UtcDateTime {
    param([Parameter(Mandatory)] $Value)
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        return $Value.ToUniversalTime()
    }
    return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}

$ErrorActionPreference = 'Stop'
$taskName = 'Utils-GpuMonitor'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'GpuMonitor.psm1') -Force

$runtime = Join-Path $env:LOCALAPPDATA 'Utils\GpuMonitor'
$healthPath = Join-Path $runtime 'health.json'
$watchdogHealthPath = Join-Path $runtime 'watchdog-health.json'
$logPath = Join-Path $runtime 'watchdog.log'
$maxLogBytes = 512KB
New-Item -ItemType Directory -Path $runtime -Force | Out-Null

function Write-WatchdogLog {
    param([string]$Message)
    try {
        if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -ge $maxLogBytes) {
            Move-Item -LiteralPath $logPath -Destination ($logPath + '.1') -Force
        }
        Add-Content -LiteralPath $logPath -Encoding UTF8 -Value ('{0} {1}' -f ([DateTime]::UtcNow.ToString('o')), $Message)
    } catch { }
}

$checkedAt = [DateTime]::UtcNow
$mainState = 'missing'
$heartbeatAge = $null
$heartbeatFresh = $false
$action = 'none'
$errorMessage = ''

try {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    $mainState = [string]$task.State
    $needsRestart = $task.State -ne 'Running'
    $heartbeatFresh = $false

    if (Test-Path -LiteralPath $healthPath) {
        try {
            $health = Get-Content -Raw -Encoding UTF8 -LiteralPath $healthPath | ConvertFrom-Json
            $heartbeatAge = ($checkedAt - (ConvertTo-UtcDateTime $health.updated_at)).TotalSeconds
            $heartbeatFresh = $heartbeatAge -le $MaxHeartbeatAgeSeconds
            if (-not $heartbeatFresh) {
                $warmingUp = $taskInfo -and (($checkedAt - $taskInfo.LastRunTime.ToUniversalTime()).TotalSeconds -lt $MaxHeartbeatAgeSeconds)
                if (-not $warmingUp) { $needsRestart = $true }
            }
        } catch {
            $needsRestart = $true
            $errorMessage = 'Invalid main heartbeat: ' + $_.Exception.Message
        }
    } elseif ($taskInfo -and (($checkedAt - $taskInfo.LastRunTime.ToUniversalTime()).TotalSeconds -ge $MaxHeartbeatAgeSeconds)) {
        $needsRestart = $true
    }

    # A fresh heartbeat is proof the supervisor is alive and sampling, and it
    # overrides the task state.
    #
    # The supervisor routinely outlives the launcher Task Scheduler tracks:
    # stopping the task does not reliably kill PowerShell running under the
    # windowless wscript host, so the task falls back to 'Ready' while a healthy
    # supervisor keeps running. Treating that as failure restarted the monitor
    # every single minute - the replacement then exited on the duplicate-guard
    # mutex, so the damage was invisible and the loop ran indefinitely, burning a
    # task stop, two process spawns and a module compile a minute, forever.
    #
    # Only ever suppress a restart on positive evidence of life, never on the
    # absence of evidence of death.
    if ($heartbeatFresh -and -not $errorMessage) { $needsRestart = $false }

    if ($needsRestart) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $action = 'restarted'
        Write-WatchdogLog "Restarted main task state=$mainState heartbeat_age=$heartbeatAge"
    }
} catch {
    $errorMessage = $_.Exception.Message
    Write-WatchdogLog ('Watchdog failure: ' + $errorMessage)
}

$receipt = [ordered]@{
    contract = 'utils.gpu-monitor.watchdog.v1'
    checked_at = $checkedAt.ToString('o')
    main_task = $taskName
    main_state = $mainState
    heartbeat_age_seconds = $heartbeatAge
    heartbeat_fresh = $heartbeatFresh
    action = $action
    error = $errorMessage
}
Write-AtomicJson -Path $watchdogHealthPath -Value $receipt

if ($errorMessage -and $action -ne 'restarted') { throw $errorMessage }
