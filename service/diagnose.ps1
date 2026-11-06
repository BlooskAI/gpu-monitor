[CmdletBinding(DefaultParameterSetName = 'Live')]
param(
    [Parameter(ParameterSetName = 'Demo', Mandatory)][switch]$Demo,
    [Parameter(ParameterSetName = 'Live')][string]$HealthPath,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'GpuMonitor.psm1') -Force

if ($Demo) {
    # Synthetic measurements exercise the same phase tracker as the live panel.
    # No device, runtime, installed monitor, or network access is required.
    $tracker = New-GpuPhaseTracker -AssumedIntervalSeconds 10
    $start = [DateTime]::UtcNow.AddSeconds(-290)
    foreach ($index in 0..29) {
        $util = if ($index -lt 4) { 8 } elseif ($index -lt 16) { 96 } else { 0 }
        $used = if ($index -lt 4) { 4000 * ($index + 1) } else { 24000 }
        $sample = [pscustomobject]@{
            timestamp_utc = $start.AddSeconds(10 * $index).ToString('o')
            status = 'ok'
            utilization_percent = $util
            memory_used_mb = $used
            memory_total_mb = 32768
            power_w = $(if ($util -gt 50) { 350 } else { 45 })
            processes = @()
        }
        $null = Add-GpuPhaseSample -Tracker $tracker -Sample $sample
    }
    $health = [pscustomobject]@{
        contract = 'utils.gpu-monitor.health.v2'
        updated_at = [DateTime]::UtcNow.ToString('o')
        poll_seconds = 2
        gpu = $sample
        igpu = [pscustomobject]@{ status = 'absent' }
        npu = [pscustomobject]@{ status = 'absent' }
        phase = Get-GpuPhaseReport -Tracker $tracker
        models = @([pscustomobject]@{ device = 'gpu'; source = 'ollama'; name = 'synthetic-model' })
    }
} else {
    if (-not $HealthPath) {
        if (-not $env:LOCALAPPDATA) { throw 'Pass -HealthPath to a Windows health.json, or use -Demo.' }
        $HealthPath = Join-Path $env:LOCALAPPDATA 'Utils\GpuMonitor\health.json'
    }
    if (-not (Test-Path -LiteralPath $HealthPath -PathType Leaf)) {
        throw 'No health snapshot found. Start GPU Monitor, pass -HealthPath, or try -Demo.'
    }
    $health = Get-Content -LiteralPath $HealthPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ((Get-RuntimeProperty $health 'contract') -ne 'utils.gpu-monitor.health.v2') {
        throw 'Expected a Windows utils.gpu-monitor.health.v2 snapshot.'
    }
}

$report = New-GpuDiagnosticReport -Health $health -Demo:$Demo
if ($Json) { $report | ConvertTo-Json -Depth 8 }
else { ConvertTo-GpuDiagnosticText -Report $report }
