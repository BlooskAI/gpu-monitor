[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$taskName = 'Utils-GpuMonitor'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $task) {
    throw "Scheduled task '$taskName' is not installed. Run install.ps1 first."
}

Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

# Stopping the task does not reliably terminate PowerShell running under the
# windowless wscript launcher. A surviving supervisor keeps the duplicate-guard
# mutex, so the freshly started instance exits immediately and this script
# reported success while the old code kept running - a restart that restarted
# nothing. install.ps1 already had to solve this; so does restarting.
try {
    Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*UtilsGpuMonitor\service\supervisor.ps1*' } |
        ForEach-Object {
            Write-Host "Stopping surviving supervisor pid=$($_.ProcessId)"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
} catch {
    Write-Verbose "Could not inspect supervisor command lines: $($_.Exception.Message)"
}

Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 6
& (Join-Path $PSScriptRoot 'status.ps1')

