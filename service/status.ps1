[CmdletBinding()]
param()

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

$taskName = 'Utils-GpuMonitor'
$watchdogTaskName = 'Utils-GpuMonitor-Watchdog'
$runtime = Join-Path $env:LOCALAPPDATA 'Utils\GpuMonitor'
$healthPath = Join-Path $runtime 'health.json'
$watchdogHealthPath = Join-Path $runtime 'watchdog-health.json'
$dataPath = Join-Path $runtime 'gpu.txt'
$healthy = $true

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $task) {
    Write-Host 'Task       : MISSING'
    $healthy = $false
} else {
    $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    Write-Host "Task       : $($task.State)"
    if ($info) {
        Write-Host "Last run   : $($info.LastRunTime)"
        Write-Host "Last result: $($info.LastTaskResult)"
    }
    if ($task.State -ne 'Running') { $healthy = $false }
}

$watchdogTask = Get-ScheduledTask -TaskName $watchdogTaskName -ErrorAction SilentlyContinue
if (-not $watchdogTask) {
    Write-Host 'Watchdog   : MISSING'
    $healthy = $false
} else {
    $watchdogInfo = Get-ScheduledTaskInfo -TaskName $watchdogTaskName -ErrorAction SilentlyContinue
    $watchdogResult = if ($watchdogInfo) { $watchdogInfo.LastTaskResult } else { 'unknown' }
    Write-Host "Watchdog   : $($watchdogTask.State) / last result $watchdogResult"
    if ($watchdogTask.State -notin @('Ready', 'Running')) { $healthy = $false }
}

$rainmeter = Get-Process -Name Rainmeter -ErrorAction SilentlyContinue | Select-Object -First 1
if ($rainmeter) {
    Write-Host "Rainmeter  : RUNNING pid=$($rainmeter.Id)"
} else {
    Write-Host 'Rainmeter  : STOPPED'
    $healthy = $false
}

if (Test-Path -LiteralPath $watchdogHealthPath) {
    try {
        $watchdogHealth = Get-Content -Raw -Encoding UTF8 -LiteralPath $watchdogHealthPath | ConvertFrom-Json
        $watchdogAge = [DateTime]::UtcNow - (ConvertTo-UtcDateTime $watchdogHealth.checked_at)
        Write-Host ('Watch check : {0:N1}s old / {1}' -f $watchdogAge.TotalSeconds, $watchdogHealth.action)
        if ($watchdogAge.TotalSeconds -gt 130 -or $watchdogHealth.error) { $healthy = $false }
    } catch {
        Write-Host "Watch check : INVALID ($($_.Exception.Message))"
        $healthy = $false
    }
} else {
    Write-Host 'Watch check : PENDING'
}

if (Test-Path -LiteralPath $healthPath) {
    try {
        $health = Get-Content -Raw -Encoding UTF8 -LiteralPath $healthPath | ConvertFrom-Json
        $age = [DateTime]::UtcNow - (ConvertTo-UtcDateTime $health.updated_at)
        Write-Host ('Heartbeat  : {0:N1}s old' -f $age.TotalSeconds)
        Write-Host "GPU        : $($health.gpu.status) / $($health.gpu.name) / $($health.gpu.utilization_percent)% / $($health.gpu.temperature_c) C"

        # The integrated GPU and NPU are optional hardware. Absent is a correct
        # answer on a machine that has neither, so it must not fail the check.
        foreach ($accelerator in @(
            @{ Label = 'iGPU       '; Value = $(if ($health.PSObject.Properties.Name -contains 'igpu') { $health.igpu } else { $null }) },
            @{ Label = 'NPU        '; Value = $(if ($health.PSObject.Properties.Name -contains 'npu') { $health.npu } else { $null }) }
        )) {
            $device = $accelerator.Value
            if (-not $device) { Write-Host "$($accelerator.Label): NOT REPORTED"; continue }
            if ($device.status -eq 'absent') {
                Write-Host "$($accelerator.Label): absent / $($device.error)"
            } else {
                Write-Host "$($accelerator.Label): $($device.status) / $($device.name) / $($device.utilization_percent)% / $($device.error)"
                if ($device.resident) { Write-Host "             resident: $($device.resident)" }
            }
        }

        if ($health.PSObject.Properties.Name -contains 'top' -and $health.top) {
            # A null or absent list still yields one pipeline item, so filter to
            # real rows before formatting rather than printing a phantom entry.
            $memory = @($health.top.memory | Where-Object { $_ -and $_.name } | ForEach-Object { '{0} {1:N1}G' -f $_.name, ($_.memory_bytes / 1GB) })
            $cpu = @($health.top.cpu | Where-Object { $_ -and $_.name } | ForEach-Object { '{0} {1}%' -f $_.name, $_.utilization_percent })
            if ($memory.Count -gt 0) { Write-Host ("Top RAM    : " + ($memory -join '   ')) }
            if ($cpu.Count -gt 0) { Write-Host ("Top CPU    : " + ($cpu -join '   ')) }
        }

        if ($age.TotalSeconds -gt 10 -or $health.gpu.status -notin @('ok', 'limited')) { $healthy = $false }
    } catch {
        Write-Host "Heartbeat  : INVALID ($($_.Exception.Message))"
        $healthy = $false
    }
} else {
    Write-Host 'Heartbeat  : MISSING'
    $healthy = $false
}

Write-Host "Data       : $dataPath"
Write-Host "Health     : $healthPath"
Write-Host "Watchdog   : $watchdogHealthPath"
Write-Host "Overall    : $(if ($healthy) { 'HEALTHY' } else { 'UNHEALTHY' })"
if (-not $healthy) { exit 1 }
