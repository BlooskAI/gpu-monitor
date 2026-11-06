$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot

function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

# Parse source only, not generated dist trees or local diagnostic captures.
$sourceFiles = @((Join-Path $root 'GpuMonitor.psm1'))
foreach ($directory in @('service', 'packaging', 'tests')) {
    $sourceFiles += @(Get-ChildItem (Join-Path $root $directory) -File | Where-Object Extension -in @('.ps1', '.psm1') | ForEach-Object FullName)
}
foreach ($file in $sourceFiles) {
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$parseErrors) | Out-Null
    Assert ($parseErrors.Count -eq 0) "Parse failure: $file : $parseErrors"
}
Import-Module (Join-Path $root 'GpuMonitor.psm1') -Force

$moduleAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'GpuMonitor.psm1'), [ref]$null, [ref]$null)
$defined = @($moduleAst.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
$exported = @((Get-Module GpuMonitor).ExportedFunctions.Keys)
foreach ($file in Get-ChildItem (Join-Path $root 'service') -Filter *.ps1) {
    $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
    $local = @($ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
    foreach ($call in $ast.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $call.GetCommandName()
        if ($name -in $defined -and $name -notin $local) { Assert ($name -in $exported) "Unexported service function: $name" }
    }
}

$now = [DateTime]::SpecifyKind([DateTime]'2026-10-06T12:00:00', [DateTimeKind]::Utc)
$sample = [pscustomobject]@{
    timestamp_utc = $now; status = 'ok'; utilization_percent = 90; memory_used_mb = 24000
    memory_total_mb = 32768; power_w = 300; processes = @()
}
$tracker = New-GpuPhaseTracker -AssumedIntervalSeconds 10
$null = Add-GpuPhaseSample $tracker $sample
$sample.timestamp_utc = $now.AddSeconds(10)
$sample.status = 'unavailable'
$null = Add-GpuPhaseSample $tracker $sample
$phases = Get-GpuPhaseReport $tracker
Assert ($phases.computing_seconds -eq 10 -and $phases.unknown_seconds -eq 10) 'An unavailable reading became useful work or idle.'
Assert ($phases.absent_seconds -eq 0 -and $phases.mean_utilization_percent -eq 90) 'Unknown time diluted utilization.'
Assert ($tracker.samples[1].timestamp_utc -eq $now.AddSeconds(10)) 'Typed UTC timestamp changed timezone.'

$unknown = New-GpuPhaseTracker
$null = Add-GpuPhaseSample $unknown ([pscustomobject]@{ status = 'limited'; timestamp_utc = $now; memory_used_mb = 20000 })
Assert ((ConvertTo-PhaseReport (Get-GpuPhaseReport $unknown)) -match 'telemetry unavailable') 'Missing load was treated as idle.'
$row = ConvertTo-ModelReport -Models @() -DiscreteGpu ([pscustomobject]@{ status = 'unavailable'; memory_used_mb = 0 })
Assert ($row.StartsWith('gpu|unavailable')) 'An unavailable device rendered as idle.'
$row = ConvertTo-ModelReport -Models @() -DiscreteGpu ([pscustomobject]@{ status = 'limited'; memory_used_mb = '' })
Assert ($row.StartsWith('gpu|unavailable')) 'Missing memory rendered as idle.'

# A worker can hold an unreported model below the old 2 GiB cutoff. Name the
# process as an owner, without inventing a model or hiding it as idle.
$workerGpu = [pscustomobject]@{
    status = 'ok'; memory_used_mb = 2206
    processes = @(
        [pscustomobject]@{ name = 'chrome'; pid = 300; memory_bytes = 500MB },
        [pscustomobject]@{ name = 'python'; pid = 12345; memory_bytes = 1200MB }
    )
}
foreach ($used in @(2206, 1200)) {
    $workerGpu.memory_used_mb = $used
    $row = ConvertTo-ModelReport -Models @() -DiscreteGpu $workerGpu
    Assert ($row.StartsWith('gpu|no model ID; python (12345)')) 'Unreported model lost its largest visible process owner.'
}
$knownModel = [pscustomobject]@{ device = 'gpu'; name = 'test-model'; detail = 'ready' }
Assert ((ConvertTo-ModelReport -Models @($knownModel) -DiscreteGpu $workerGpu).StartsWith('gpu|test-model (ready)')) 'Process fallback replaced a runtime model name.'
$workerGpu.processes = @()
$workerGpu.memory_used_mb = 9469
Assert ((ConvertTo-ModelReport -Models @() -DiscreteGpu $workerGpu).StartsWith('gpu|no model ID; memory in use')) 'Unattributed held memory was hidden.'
$workerGpu.memory_used_mb = 300
Assert ((ConvertTo-ModelReport -Models @() -DiscreteGpu $workerGpu).StartsWith('gpu|none reported')) 'Missing runtime reports were presented as proof of an empty GPU.'
$emptyNpu = [pscustomobject]@{
    status = 'ok'; memory_used_mb = 0
    processes = @([pscustomobject]@{ name = 'System'; pid = 4; memory_bytes = 8KB })
}
Assert ((ConvertTo-ModelReport -Models @() -Npu $emptyNpu) -match 'npu\|none reported') 'A rounded-zero device allocation displayed a system bookkeeping process as a missing model.'

# Exercise the public claim selection against synthetic files only. The legacy
# writer format stays unchanged, including extra fields and nullable timestamps.
$claimRoot = Join-Path ([IO.Path]::GetTempPath()) ('gpu-claim-contract-' + [guid]::NewGuid().ToString('N'))
$savedLocalData = $env:LOCALAPPDATA
$savedClaimPath = $env:GPUMONITOR_CLAIM_PATH
try {
    $env:LOCALAPPDATA = $claimRoot
    $env:GPUMONITOR_CLAIM_PATH = $null
    $legacy = Join-Path $claimRoot 'LocalAISettings/gpu-claim.json'
    $custom = Join-Path $claimRoot 'configured claim.json'
    $explicit = Join-Path $claimRoot 'explicit.json'
    Write-AtomicJson -Path $legacy -Value @{ state = 'held'; holder = 'legacy-worker'; note = 'ready'; claimed_at = '2026-11-05T12:00:00Z'; released_at = $null; future_field = 'ignored' }
    $legacyBefore = [IO.File]::ReadAllText($legacy)
    Assert ((Get-GpuClaim).holder -eq 'legacy-worker') 'Default claim location broke compatibility.'
    Write-AtomicJson -Path $custom -Value @{ state = 'released'; holder = 'public-worker'; next_for = 'next-worker'; released_at = '2026-11-05T12:01:00Z' }
    $env:GPUMONITOR_CLAIM_PATH = $custom
    $claim = Get-GpuClaim
    Assert ($claim.state -eq 'released' -and $claim.holder -eq 'public-worker' -and $claim.next_for -eq 'next-worker') 'Configured public claim lost its release or handoff fields.'
    Write-AtomicJson -Path $explicit -Value @{ state = 'held'; holder = 'explicit-worker' }
    Assert ((Get-GpuClaim -Path $explicit).holder -eq 'explicit-worker') 'Explicit claim path did not override the environment.'
    Assert ((Get-GpuClaim -Path (Join-Path $claimRoot 'missing-explicit.json')).state -eq 'none') 'Missing explicit claim fell back to another writer.'
    $env:GPUMONITOR_CLAIM_PATH = Join-Path $claimRoot 'missing-configured.json'
    Assert ((Get-GpuClaim).state -eq 'none') 'Missing configured claim fell back to a legacy owner.'
    $env:GPUMONITOR_CLAIM_PATH = $custom
    [IO.File]::WriteAllText($custom, '{malformed')
    Assert ((Get-GpuClaim).state -eq 'unreadable') 'Malformed configured claim was not labelled unreadable.'
    $env:GPUMONITOR_CLAIM_PATH = ' '
    Assert ((Get-GpuClaim).holder -eq 'legacy-worker') 'Blank configuration did not retain the compatibility default.'
    Assert ([IO.File]::ReadAllText($legacy) -eq $legacyBefore) 'Reading a claim modified the existing writer record.'
    $claimSchema = [IO.File]::ReadAllText((Join-Path $root 'contracts/gpu-claim.schema.json')) | ConvertFrom-Json
    Assert ($claimSchema.required -contains 'state') 'Public claim schema lost its state requirement.'
} finally {
    $env:LOCALAPPDATA = $savedLocalData
    $env:GPUMONITOR_CLAIM_PATH = $savedClaimPath
    $resolvedClaimRoot = [IO.Path]::GetFullPath($claimRoot)
    if ([IO.Path]::GetDirectoryName($resolvedClaimRoot) -ne [IO.Path]::GetTempPath().TrimEnd('\', '/')) { throw 'Unsafe claim fixture cleanup.' }
    Remove-Item -LiteralPath $resolvedClaimRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$culture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]'de-DE'
    Assert ((Get-SampleNumber ([pscustomobject]@{ value = '12.5' }) 'value') -eq 12.5) 'API decimals depend on Windows regional settings.'
    foreach ($bad in @('NaN', 'Infinity', '-Infinity', 'private-value', '')) {
        Assert ((Get-SampleNumber ([pscustomobject]@{ value = $bad }) 'value' -Default 42) -eq 42) 'Invalid number accepted.'
    }
} finally { [Threading.Thread]::CurrentThread.CurrentCulture = $culture }

# Sensitive sentinels must not survive in either export, even in unknown fields.
$secret = 'PRIVATE_SENTINEL_DO_NOT_EXPORT'
$sample.status = 'ok'
Add-Member -InputObject $sample -NotePropertyName name -NotePropertyValue $secret
Add-Member -InputObject $sample -NotePropertyName error -NotePropertyValue $secret
$sample.processes = @([pscustomobject]@{ name = $secret; pid = 987654; memory_bytes = 1GB })
$phases.warnings = @($secret)
$phases.summary = $secret
$health = [pscustomobject]@{
    contract = 'utils.gpu-monitor.health.v2'; updated_at = $now; poll_seconds = 2
    gpu = $sample; phase = $phases
    models = @([pscustomobject]@{ source = 'ollama'; name = $secret; detail = $secret })
    claim = @{ holder = $secret; note = $secret }; toolchain = @{ path = $secret }
    future_field = $secret; supervisor_pid = 987654
}
$report = New-GpuDiagnosticReport $health -Now $now.AddSeconds(2)
Assert ($report.freshness -eq 'fresh' -and $report.sample_age_seconds -eq 2) 'Typed timestamp freshness failed.'
Assert ($report.runtimes[0].reported_models -eq 1) 'Runtime model count lost.'
foreach ($text in @(($report | ConvertTo-Json -Depth 8), (ConvertTo-GpuDiagnosticText $report))) {
    Assert (-not $text.Contains($secret) -and -not $text.Contains('987654')) 'Private source data leaked into diagnostic export.'
}
Assert ((New-GpuDiagnosticReport $health -Now $now.AddSeconds(7)).freshness -eq 'stale') 'Stale snapshot reported fresh.'
Assert ((New-GpuDiagnosticReport $health -Now $now.AddSeconds(-30)).freshness -eq 'clock-skew') 'Future timestamp reported fresh.'
$health.updated_at = $now.ToString('o')
Assert ((New-GpuDiagnosticReport $health -Now $now).freshness -eq 'fresh') 'String timestamp freshness failed.'
$health.updated_at = $secret
Assert ((New-GpuDiagnosticReport $health -Now $now).freshness -eq 'unknown') 'Invalid timestamp reported fresh.'

$empty = New-GpuDiagnosticReport ([pscustomobject]@{}) -Now $now
Assert ($empty.devices[0].status -eq 'unavailable' -and $null -eq $empty.devices[0].utilization_percent) 'Missing GPU became a zero measurement.'
Assert ($null -eq $empty.phase.duty_cycle_percent -and $empty.runtimes.Count -eq 0) 'Missing history fabricated data.'
$badNumbers = [pscustomobject]@{ gpu = [pscustomobject]@{ status = 'ok'; utilization_percent = 120; memory_used_mb = -10; power_w = 'NaN' } }
$badReport = New-GpuDiagnosticReport $badNumbers -Now $now
Assert ($null -eq $badReport.devices[0].utilization_percent -and $null -eq $badReport.devices[0].memory_used_mb -and $null -eq $badReport.devices[0].power_w) 'Invalid metrics survived export.'

$capture = Join-Path $env:TEMP ('gpumonitor-offline-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $health.updated_at = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($capture, ($health | ConvertTo-Json -Depth 8))
    $snapshotText = & (Join-Path $root 'service/diagnose.ps1') -HealthPath $capture -Json
    Assert (-not $snapshotText.Contains($secret)) 'CLI leaked source strings.'
    $snapshot = $snapshotText | ConvertFrom-Json
    Assert ($snapshot.mode -eq 'snapshot' -and $snapshot.freshness -eq 'fresh') 'Saved snapshot CLI integration failed.'
    [IO.File]::WriteAllText($capture, '{"contract":"wrong"}')
    $rejected = $false
    try { & (Join-Path $root 'service/diagnose.ps1') -HealthPath $capture -Json | Out-Null } catch { $rejected = $true }
    Assert $rejected 'An unsupported snapshot contract was accepted.'
} finally { Remove-Item -LiteralPath $capture -ErrorAction SilentlyContinue }

# A deterministic replay proves the CLI works without devices or network probes.
$demo = & (Join-Path $root 'service/diagnose.ps1') -Demo -Json | ConvertFrom-Json
Assert ($demo.mode -eq 'demo-synthetic') 'Demo was not explicitly labelled synthetic.'
Assert ($demo.phase.computing_seconds -eq 120 -and $demo.phase.overhead_seconds -eq 40 -and $demo.phase.resident_idle_seconds -eq 140) 'Demo replay phase totals changed.'
Assert ($demo.phase.window_seconds -eq 300 -and $demo.phase.duty_cycle_percent -eq 40) 'Demo lost its time-weighted history.'
$demoText = & (Join-Path $root 'service/diagnose.ps1') -Demo
Assert ($demoText -match 'idle-held 140s' -and $demoText -match 'demo-synthetic') 'Text demo omitted key evidence.'

# Reproduce the disk overlap with measured font extents and the actual skin
# coordinates. Check typical and long values, not just one current free size.
$skinText = [IO.File]::ReadAllText((Join-Path $root 'skin/UtilsGpuMonitor.ini'))
function Get-SkinSection([string]$Name) {
    $match = [regex]::Match($skinText, '(?ms)^\[' + [regex]::Escape($Name) + '\]\r?\n(.*?)(?=^\[|\z)')
    Assert $match.Success "Missing skin section $Name"
    $fields = @{}
    foreach ($line in ($match.Groups[1].Value -split '\r?\n')) {
        if ($line -match '^([^;=]+)=(.*)$') { $fields[$Matches[1]] = $Matches[2] }
    }
    return $fields
}
Add-Type -AssemblyName System.Drawing
$bitmap = New-Object Drawing.Bitmap 1, 1
$graphics = [Drawing.Graphics]::FromImage($bitmap)
try {
    $bottom = 0.0
    foreach ($case in @(
        @{ Name = 'MeterDiskTitle'; Texts = @('DISK C:') },
        @{ Name = 'MeterDiskValue'; Texts = @('459.5 G FREE', '1023.9 G FREE', '999.9 T FREE', '0 B FREE') },
        @{ Name = 'MeterDiskQueue'; Texts = @('QUEUE ALL 0.0', 'QUEUE ALL 12345.6') }
    )) {
        $meter = Get-SkinSection $case.Name
        $font = New-Object Drawing.Font($meter.FontFace, [single]$meter.FontSize, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Point)
        try {
            $height = $font.GetHeight($graphics)
            Assert ([double]$meter.Y -ge $bottom) "$($case.Name) overlaps the preceding disk text."
            $fixedHeight = [double]$meter['H']
            if ($fixedHeight) { Assert ($fixedHeight -ge $height) "$($case.Name) clips text vertically." }
            foreach ($value in $case.Texts) {
                $width = $graphics.MeasureString($value, $font).Width
                Assert ($width -le 113) "$($case.Name) exceeds the disk column: $value"
            }
            $bottom = [double]$meter.Y + [Math]::Max($height, $fixedHeight)
        } finally { $font.Dispose() }
    }
    $bar = Get-SkinSection 'MeterDiskBar'
    Assert ([double]$bar.Y -ge $bottom) 'Disk activity bar overlaps queue text.'
    $card = Get-SkinSection 'MeterSystemCard'
    $cardHeight = [double]($card.Shape -split ',')[3]
    Assert (([double]$bar.Y + [double]$bar.H) -lt ([double]$card.Y + $cardHeight)) 'Disk activity bar extends beyond the card.'
} finally { $graphics.Dispose(); $bitmap.Dispose() }
Write-Host 'PASS offline: syntax, exports, missing data, model ownership, claim interface, disk text bounds, UTC, locale, privacy, freshness, and demo replay'
