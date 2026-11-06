[CmdletBinding()]
param([switch]$PurgeRuntime)

$ErrorActionPreference = 'Stop'
$taskNames = @('Utils-GpuMonitor-Watchdog', 'Utils-GpuMonitor')
$sourceOrInstallRoot = Split-Path -Parent $PSScriptRoot
$module = Join-Path $sourceOrInstallRoot 'GpuMonitor.psm1'
Import-Module $module -Force
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\UtilsGpuMonitor'

foreach ($taskName in $taskNames) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
}

# Stopping the task does not reliably terminate PowerShell running under the
# windowless wscript launcher, and a surviving supervisor keeps the mutex and
# blocks the next install. Kill any remaining supervisor/watchdog processes.
try {
    Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object { $_.CommandLine -and ($_.CommandLine -like '*UtilsGpuMonitor\service\supervisor.ps1*' -or $_.CommandLine -like '*UtilsGpuMonitor\service\watchdog.ps1*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { }

try {
    $rainmeter = Get-RainmeterExecutable
    Start-Process -FilePath $rainmeter -ArgumentList @('!DeactivateConfig', '"UtilsGpuMonitor"') -WindowStyle Hidden | Out-Null
} catch { }

$skinTarget = Join-Path (Get-RainmeterSkinPath) 'UtilsGpuMonitor'
if (Test-Path -LiteralPath $skinTarget) { Remove-Item -LiteralPath $skinTarget -Recurse -Force }

if ($PurgeRuntime) {
    $runtime = Join-Path $env:LOCALAPPDATA 'Utils\GpuMonitor'
    if (Test-Path -LiteralPath $runtime) { Remove-Item -LiteralPath $runtime -Recurse -Force }
}

$programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\GPU Monitor'
if (Test-Path -LiteralPath $programs) { Remove-Item -LiteralPath $programs -Recurse -Force }
Remove-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\UtilsGpuMonitor' -Recurse -Force -ErrorAction SilentlyContinue

$resolvedExpected = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\UtilsGpuMonitor')).TrimEnd('\')
$resolvedTarget = [IO.Path]::GetFullPath($installRoot).TrimEnd('\')
if ($resolvedTarget -eq $resolvedExpected -and (Test-Path -LiteralPath $resolvedTarget)) {
    Remove-Item -LiteralPath $resolvedTarget -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'GPU Monitor task and installed skin removed. Repository source was retained.'
