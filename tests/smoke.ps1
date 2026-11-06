$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$scripts = Get-ChildItem -LiteralPath $root -Filter *.ps1 -Recurse
foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        throw "PowerShell parse failure in $($script.FullName): $($errors[0].Message)"
    }
}

Import-Module (Join-Path $root 'GpuMonitor.psm1') -Force

# Every module function the service scripts call must be exported.
#
# A helper that is defined but not exported resolves fine inside the module and
# fails only in the caller - so the supervisor kept running on already-loaded
# code and the break appeared at the next restart, hours later, as a loop error
# every two seconds with a frozen panel. Catch it here instead.
$moduleAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'GpuMonitor.psm1'), [ref]$null, [ref]$null)
$defined = @($moduleAst.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    ForEach-Object { $_.Name })
$exported = @((Get-Module GpuMonitor).ExportedFunctions.Keys)

foreach ($service in (Get-ChildItem -LiteralPath (Join-Path $root 'service') -Filter *.ps1)) {
    $serviceAst = [Management.Automation.Language.Parser]::ParseFile($service.FullName, [ref]$null, [ref]$null)
    # Functions the script defines itself are not module calls.
    $local = @($serviceAst.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { $_.Name })
    $called = @($serviceAst.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($name in $called) {
        if ($local -contains $name) { continue }
        if ($defined -notcontains $name) { continue }
        if ($exported -notcontains $name) {
            throw "$($service.Name) calls $name, which GpuMonitor.psm1 defines but does not export."
        }
    }
}
Write-Host ("Exports    : {0} functions, all service call sites resolve" -f $exported.Count)

$rainmeter = Get-RainmeterExecutable
if (-not (Test-Path -LiteralPath $rainmeter)) { throw 'Rainmeter discovery returned a missing path.' }

$sample = Get-GpuSample
$line = ConvertTo-GpuMonitorLine -Sample $sample
$parts = @($line -split '\|', -1)
if ($parts.Count -ne 10) { throw "Telemetry contract has $($parts.Count) fields; expected 10." }
if ($sample.status -ne 'ok') { throw "Live NVIDIA sample failed: $($sample.error)" }

# The fast poll path must spawn nvidia-smi once. Per-process attribution needs a
# second spawn, so it is opt-in; wiring it into the default call doubled the cost
# of the one thing that runs every couple of seconds, and on a WDDM machine it
# returned nothing usable anyway.
$plain = (Measure-Command { $null = Get-GpuSample }).TotalMilliseconds
$withProcesses = (Measure-Command { $null = Get-GpuSample -IncludeProcesses }).TotalMilliseconds
if ($withProcesses -lt $plain * 1.4) {
    throw ("Get-GpuSample costs the same with and without -IncludeProcesses ({0:N0}ms vs {1:N0}ms); " -f $plain, $withProcesses) +
          'the default path is probably still querying compute apps on every poll.'
}
if (@((Get-GpuSample).processes).Count -ne 0) {
    throw 'Get-GpuSample attributed processes without -IncludeProcesses; the fast path pays for a second nvidia-smi spawn.'
}
Write-Host ("Poll cost  : {0:N0}ms plain / {1:N0}ms with -IncludeProcesses" -f $plain, $withProcesses)

# A claim is read from another repo's file and must never throw, whatever it
# holds - including absent, empty, or missing fields a future writer drops.
$claim = Get-GpuClaim
if ($claim.PSObject.Properties.Name -notcontains 'summary') { throw 'Get-GpuClaim did not return a summary.' }
$claimProbe = Join-Path $env:TEMP ('gpu-claim-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    foreach ($case in @('', '{}', '{"state":"held"}', 'not json at all')) {
        [IO.File]::WriteAllText($claimProbe, $case)
        $probe = Get-GpuClaim -Path $claimProbe
        if (-not $probe.summary) { throw "Get-GpuClaim returned no summary for input '$case'." }
    }
    Write-Host ("Claim      : {0}" -f $claim.summary)
} finally {
    Remove-Item -LiteralPath $claimProbe -Force -ErrorAction SilentlyContinue
}

$temporary = Join-Path $env:TEMP ('gpu-monitor-smoke-' + [guid]::NewGuid().ToString('N') + '.txt')
try {
    Write-AtomicText -Path $temporary -Text $line
    $written = (Get-Content -Raw -Encoding UTF8 -LiteralPath $temporary).Trim()
    if ($written -ne $line) { throw 'Atomic telemetry write changed the data contract.' }
} finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Integrated GPU, NPU and resident-process readings.
#
# The devices themselves are optional hardware, so absence is a pass. What must
# hold everywhere is that every device produces a well-formed ten-field line and
# that a machine which does have the hardware actually reports it.
# ---------------------------------------------------------------------------

$inventory = @(Get-AcceleratorInventory -Force)
$kinds = @($inventory | ForEach-Object { $_.kind })
Write-Host ("Adapters   : " + $(if ($inventory.Count -gt 0) {
    (@($inventory | ForEach-Object { '{0}={1}' -f $_.kind, $_.name }) -join ' / ')
} else { 'none enumerated' }))

$sampler = New-AcceleratorSampler
try {
    $processes = Get-ProcessTelemetry
    if (-not $processes.names -or $processes.names.Count -eq 0) { throw 'Process enumeration returned no processes.' }
    Start-Sleep -Seconds 2
    $processes = Get-ProcessTelemetry -Previous $processes.state
    if ($processes.memory.Count -eq 0) { throw 'Top memory consumers came back empty.' }

    $devices = @()
    if ($sampler) { $devices = @(Get-AcceleratorTelemetry -Sampler $sampler -ProcessNames $processes.names) }
    elseif ($inventory.Count -gt 0) { throw 'Adapters were enumerated but the GPU counter query could not be opened.' }

    foreach ($kind in @('igpu', 'npu')) {
        $device = @($devices | Where-Object { $_.kind -eq $kind } | Select-Object -First 1)
        $device = if ($device.Count -gt 0) { $device[0] } else { New-AbsentAcceleratorSample -Kind $kind }

        $deviceLine = ConvertTo-GpuMonitorLine -Sample $device
        $deviceParts = @($deviceLine -split '\|', -1)
        if ($deviceParts.Count -ne 10) { throw "$kind line has $($deviceParts.Count) fields; expected 10." }
        if ($deviceParts[1] -notin @('ok', 'limited', 'unavailable', 'absent')) {
            throw "$kind reported unknown status '$($deviceParts[1])'."
        }
        if ($device.status -eq 'ok') {
            $utilization = [double]$device.utilization_percent
            if ($utilization -lt 0 -or $utilization -gt 100) { throw "$kind utilization $utilization is outside 0-100." }
        }
        # A device the adapter enumeration found must not then be reported missing.
        if (($kinds -contains $kind) -and $device.status -eq 'absent') {
            throw "$kind was enumerated as present but produced no telemetry."
        }
        Write-Host ("{0,-11}: {1} / {2} / {3}%" -f $kind, $device.status, $device.name, $device.utilization_percent)
    }

    $report = ConvertTo-ResidentReport `
        -DiscreteGpu (@($devices | Where-Object { $_.kind -eq 'dgpu' } | Select-Object -First 1) | Select-Object -First 1) `
        -IntegratedGpu (@($devices | Where-Object { $_.kind -eq 'igpu' } | Select-Object -First 1) | Select-Object -First 1) `
        -Npu (@($devices | Where-Object { $_.kind -eq 'npu' } | Select-Object -First 1) | Select-Object -First 1) `
        -Processes $processes
    $reportLines = @($report -split '\r?\n')
    if ($reportLines.Count -ne 5) { throw "Resident report has $($reportLines.Count) lines; expected 5." }
    foreach ($index in 0..4) {
        $expected = @('gpu', 'igpu', 'npu', 'ram', 'cpu')[$index]
        if ($reportLines[$index] -notmatch ('^' + $expected + '\|.+$')) {
            throw "Resident report line $($index + 1) is not a populated '$expected' row: $($reportLines[$index])"
        }
    }
    Write-Host ("Resident   : " + ($reportLines -join ' | '))

    # Toolchain is cached hourly and must still produce a complete feed. A
    # device that is present has to report at least one usable runtime,
    # otherwise the detector silently claims working hardware is unusable.
    $toolchain = Get-AcceleratorToolchain -Force
    $toolchainLines = @((ConvertTo-ToolchainReport -Toolchain $toolchain) -split '\r?\n')
    if ($toolchainLines.Count -ne 5) { throw "Toolchain report has $($toolchainLines.Count) lines; expected 5." }
    foreach ($index in 0..4) {
        $expected = @('gpu', 'igpu', 'npu', 'wsl', 'gaps')[$index]
        if ($toolchainLines[$index] -notmatch ('^' + $expected + '\|.+$')) {
            throw "Toolchain line $($index + 1) is not a populated '$expected' row: $($toolchainLines[$index])"
        }
    }
    foreach ($device in @($toolchain.devices | Where-Object { $_.present })) {
        if (@($device.runtimes).Count -eq 0) { throw "$($device.kind) is present but no compute runtime was detected." }
    }

    # Anything found on the WSL side must be reported as living there, never as
    # a gap: a Windows-only view of a split stack calls working build tooling
    # missing, which is accurate about Windows and wrong about the machine.
    $wslState = Get-WslToolchain
    if ($wslState.available) {
        if ($wslState.nvcc -and ($toolchain.gaps -join ' ') -match '(?i)nvcc') {
            throw "nvcc exists in WSL at $($wslState.nvcc) but is still reported as a gap."
        }
        if ($wslState.cudnn -and ($toolchain.gaps -join ' ') -match '(?i)cudnn') {
            throw "cuDNN exists in WSL at $($wslState.cudnn) but is still reported as a gap."
        }
        Write-Host ("WSL        : {0} / CUDA {1} / nvcc {2} / cuDNN {3}" -f `
            $wslState.distro, $(if ($wslState.cuda) { $wslState.cuda } else { 'none' }),
            $(if ($wslState.nvcc) { 'yes' } else { 'no' }), $(if ($wslState.cudnn) { 'yes' } else { 'no' }))
    } else {
        Write-Host ("WSL        : {0}" -f $wslState.reason)
    }

    # Every gap must say why it matters, or the card is just a word list.
    foreach ($gap in @($toolchain.gaps)) {
        if ($gap -notmatch '\s-\s') { throw "Gap '$gap' carries no annotation explaining why it matters." }
    }
    Write-Host ("Toolchain  : " + ($toolchainLines -join ' | '))

    # GAPS must not contradict the device lines. Reporting an SDK as missing
    # while a device is credited with it is how OpenVINO showed as a gap on a
    # machine that had it: detection only looked system-wide and never at the
    # virtual environments the SDK was actually installed into.
    # Compare the structured lists, not the rendered text. A gap is only a
    # contradiction when it names the same runtime a device is credited with -
    # "CUDA toolkit (nvcc)" alongside "CUDA 13.2" is correct, because the
    # runtime ships with the driver and the compiler does not.
    $gapText = ($toolchainLines | Where-Object { $_ -like 'gaps|*' }) -replace '^gaps\|', ''
    $creditedRuntimes = @($toolchain.devices | Where-Object { $_.present } | ForEach-Object { $_.runtimes })
    foreach ($gap in @($toolchain.gaps)) {
        foreach ($runtime in $creditedRuntimes) {
            if ($runtime -eq $gap -or $runtime -like ($gap + ' *')) {
                throw "Toolchain contradicts itself: '$gap' is a gap while a device is credited with '$runtime'."
            }
        }
    }

    # Every rendered line must fit its column, or the panel silently truncates
    # the item that was added last - which is how OpenVINO ended up displayed as
    # "OpenVIN..." the moment it was detected correctly.
    Add-Type -AssemblyName System.Drawing
    $measureBitmap = New-Object System.Drawing.Bitmap 1, 1
    $measureGraphics = [System.Drawing.Graphics]::FromImage($measureBitmap)
    $measureFont = New-Object System.Drawing.Font('Segoe UI Variable Text', 7, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
    try {
        foreach ($line in ($toolchainLines + $reportLines)) {
            $value = ($line -split '\|', 2)[1]
            if (-not $value) { continue }
            $width = [int]$measureGraphics.MeasureString($value, $measureFont).Width
            if ($width -gt 222) {
                throw ("Toolchain/resident value is {0}px wide but the column is 222px, so it renders truncated: '{1}'" -f $width, $value)
            }
        }
    } finally {
        $measureFont.Dispose(); $measureGraphics.Dispose(); $measureBitmap.Dispose()
    }

    $openvino = Get-OpenVinoRuntime
    if ($openvino.present) {
        if ($gapText -match 'OpenVINO\b(?!\s+NPU)') { throw "OpenVINO was detected ($($openvino.source)) but is still reported as a gap." }
        Write-Host ("OpenVINO   : {0} via {1} (npu plugin={2}, gpu plugin={3})" -f `
            $(if ($openvino.version) { $openvino.version } else { 'present' }), $openvino.source, $openvino.npu, $openvino.gpu)
    } else {
        Write-Host ("OpenVINO   : not installed (searched {0} python environments)" -f @(Get-SitePackagesRoot).Count)
    }

    # Regression: the first detail pass has no CPU deltas yet, so that list is
    # legitimately empty. A $( ) subexpression unrolls an empty array to $null,
    # which serializes as an object and reads back as one phantom row, because
    # piping $null still yields a single pipeline item.
    $empty = @()
    $payload = [ordered]@{ top = [ordered]@{ memory = @(if ($true) { $empty }); cpu = @(if ($true) { $empty }) } }
    $restored = ($payload | ConvertTo-Json -Depth 8) | ConvertFrom-Json
    foreach ($scope in @('memory', 'cpu')) {
        if ($null -eq $restored.top.$scope) { throw "Empty top.$scope serialized to null instead of an empty list." }
        $rows = @($restored.top.$scope | Where-Object { $_ -and $_.name })
        if ($rows.Count -ne 0) { throw "Empty top.$scope rendered $($rows.Count) phantom row(s)." }
    }
} finally {
    if ($sampler) { $sampler.Dispose() }
}

$skin = Join-Path $root 'skin\UtilsGpuMonitor.ini'
$skinText = Get-Content -Raw -Encoding UTF8 -LiteralPath $skin
foreach ($required in @(
    'MeasureGpuRaw', 'MeasureGpuUtil', 'MeterGpuGraph', 'MeterStatus', 'MeterSystemCard',
    'MeasureIgpuRaw', 'MeasureIgpuUtil', 'MeterIgpuBar',
    'MeasureNpuRaw', 'MeasureNpuUtil', 'MeterNpuBar',
    'MeasureResidentRaw', 'MeterResidentGpuValue', 'MeterResidentRamValue', 'MeterResidentCpuValue',
    'MeasureToolchainRaw', 'MeterToolchainGpuValue', 'MeterToolchainNpuValue',
    'MeasureToolchainWsl', 'MeterToolchainWslValue', 'MeterToolchainGapsValue',
    'MeasurePhaseRaw', 'MeasurePhaseText', 'MeasurePhaseWarn', 'MeterGpuPhase',
    'MeasureModelRaw', 'MeterModelGpuValue', 'MeterModelIgpuValue', 'MeterModelNpuValue', 'MeterModelCpuValue'
)) {
    if ($skinText -notmatch ('\[' + [regex]::Escape($required) + '\]')) { throw "Skin is missing [$required]." }
}
foreach ($variable in @('IgpuFile', 'NpuFile', 'ProcessFile', 'ToolchainFile', 'PhaseFile', 'ModelFile')) {
    if ($skinText -notmatch ('#' + [regex]::Escape($variable) + '#')) { throw "Skin never reads #$variable#." }
}

# Vertical layout. Every card is placed with absolute Y coordinates, so adding a
# card means moving everything beneath it by hand - which is how the MODELS card
# landed on top of the CRASH-SAFE / RIGHT-CLICK TO RESTART footer. Recompute the
# spans instead of trusting them.
$cardSpans = @{}
$sectionName = $null
$sectionY = $null
foreach ($skinLine in ($skinText -split '\r?\n')) {
    if ($skinLine -match '^\[(.+)\]') { $sectionName = $Matches[1]; $sectionY = $null; continue }
    if ($skinLine -match '^Y=(\d+)') { $sectionY = [int]$Matches[1]; continue }
    if ($skinLine -match '^Shape=Rectangle \d+,\d+,[^,]+,(\d+)' -and $sectionName -like 'Meter*Card' -and $null -ne $sectionY) {
        $cardSpans[$sectionName] = @{ Top = $sectionY; Bottom = $sectionY + [int]$Matches[1] }
    }
}
if ($cardSpans.Count -lt 6) { throw "Skin layout check found only $($cardSpans.Count) cards; the parse is stale." }
foreach ($a in $cardSpans.Keys) {
    foreach ($b in $cardSpans.Keys) {
        if ($a -ge $b) { continue }
        # The two half-width cards legitimately share a row.
        if (@('MeterIgpuCard', 'MeterNpuCard') -contains $a -and @('MeterIgpuCard', 'MeterNpuCard') -contains $b) { continue }
        if ($cardSpans[$a].Top -lt $cardSpans[$b].Bottom -and $cardSpans[$b].Top -lt $cardSpans[$a].Bottom) {
            throw "Skin cards overlap: $a ($($cardSpans[$a].Top)-$($cardSpans[$a].Bottom)) and $b ($($cardSpans[$b].Top)-$($cardSpans[$b].Bottom))."
        }
    }
}
$lastCardBottom = ($cardSpans.Values | ForEach-Object { $_.Bottom } | Measure-Object -Maximum).Maximum
$footerY = [int][regex]::Match($skinText, '(?ms)^\[MeterFooter\].*?^Y=(\d+)').Groups[1].Value
$skinHeight = [int][regex]::Match($skinText, '(?m)^H=(\d+)').Groups[1].Value
if ($footerY -le $lastCardBottom) {
    throw "Skin footer sits at Y=$footerY, on top of a card that ends at $lastCardBottom."
}
if ($skinHeight -lt $footerY + 14) {
    throw "Skin is $skinHeight px tall but the footer at Y=$footerY needs $($footerY + 14)."
}

# The installer is what defines those variables; a skin that reads a path the
# installer never writes would silently render an empty card.
$installText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'service\install.ps1')
foreach ($variable in @('IgpuFile', 'NpuFile', 'ProcessFile', 'ToolchainFile', 'PhaseFile', 'ModelFile')) {
    if ($installText -notmatch ($variable + '=\{0\}')) { throw "install.ps1 does not publish $variable in Paths.inc." }
}

# ---------------------------------------------------------------------------
# Version consistency.
#
# The version is written as a literal in several places across PowerShell, zsh,
# XML and a UTF-16 ini. Nothing reads it from anything else, so a partial bump
# is silent: build-app.sh copies Info.plist verbatim, so a stale plist ships an
# app bundle labelled with the previous version containing current code.
#
# Checked rather than centralised on purpose. Threading one source through four
# file formats means every build script rewrites files at build time, including
# a plist and a UTF-16 ini, on a platform this test cannot run. A check costs
# nothing and fails loudly on the exact file that was missed.
# ---------------------------------------------------------------------------

$installSource = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'service\install.ps1')
$canonical = [regex]::Match($installSource, "(?m)^\s*version\s*=\s*'([\d.]+)'").Groups[1].Value
if (-not $canonical) { throw 'install.ps1 no longer declares a manifest version to check the repo against.' }
$compact = $canonical -replace '\.', ''
$majorMinor = ($canonical -split '\.')[0..1] -join '.'

$versionChecks = @(
    @{ File = 'service\install.ps1';               Pattern = "(?m)^\s*version\s*=\s*'([\d.]+)'";                                  Expected = $canonical },
    @{ File = 'service\install.ps1';               Pattern = "DisplayVersion\s+-Value\s+'([\d.]+)'";                              Expected = $canonical },
    @{ File = 'packaging\build-windows.ps1';       Pattern = "\`$Version\s*=\s*'([\d.]+)'";                                        Expected = $canonical },
    @{ File = 'packaging\build-macos-source.ps1';  Pattern = "\`$Version\s*=\s*'([\d.]+)'";                                        Expected = $canonical },
    @{ File = 'packaging\build-public-source.ps1'; Pattern = "\`$Version\s*=\s*'([\d.]+)'";                                        Expected = $canonical },
    @{ File = 'service\update.ps1';               Pattern = "else\s*\{\s*'([\d.]+)'\s*\}";                                        Expected = $canonical },
    @{ File = 'macos\scripts\build-release.sh';    Pattern = 'VERSION="\$\{1:-([\d.]+)\}"';                                        Expected = $canonical },
    @{ File = 'macos\Resources\Info.plist';        Pattern = '<key>CFBundleShortVersionString</key><string>([\d.]+)</string>';     Expected = $canonical },
    @{ File = 'macos\Resources\Info.plist';        Pattern = '<key>CFBundleVersion</key><string>(\d+)</string>';                   Expected = $compact },
    @{ File = 'skin\UtilsGpuMonitor.ini';          Pattern = '(?m)^Version=([\d.]+)\s*$';                                          Expected = $majorMinor }
)

foreach ($check in $versionChecks) {
    $path = Join-Path $root $check.File
    if (-not (Test-Path -LiteralPath $path)) { throw "Version check target is missing: $($check.File)" }
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
    $found = [regex]::Match($text, $check.Pattern)
    if (-not $found.Success) { throw "Could not find a version declaration in $($check.File) - the check pattern is stale." }
    if ($found.Groups[1].Value -ne $check.Expected) {
        throw ("Version drift: {0} declares {1}, expected {2} (canonical {3} from install.ps1)." -f `
            $check.File, $found.Groups[1].Value, $check.Expected, $canonical)
    }
}
Write-Host ("Version    : {0} consistent across {1} declarations" -f $canonical, $versionChecks.Count)

$schema = Join-Path $root 'contracts\telemetry.schema.json'
try { Get-Content -Raw -Encoding UTF8 -LiteralPath $schema | ConvertFrom-Json | Out-Null }
catch { throw "Telemetry schema is invalid JSON: $($_.Exception.Message)" }

$macFiles = @(
    'macos\Package.swift',
    'macos\Resources\Info.plist',
    'macos\Sources\GpuMonitor\main.swift',
    'macos\scripts\build-app.sh',
    'macos\scripts\install.sh',
    'macos\scripts\uninstall.sh'
)
foreach ($relative in $macFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf)) {
        throw "macOS distribution is missing $relative"
    }
}
$package = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'macos\Package.swift')
foreach ($framework in @('AppKit', 'CoreGraphics', 'SwiftUI', 'Metal')) {
    if ($package -notmatch ('linkedFramework\("' + $framework + '"\)')) {
        throw "macOS package is missing the $framework framework link."
    }
}
$plistText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'macos\Resources\Info.plist')
if ($plistText -notmatch '<string>com\.utils\.gpumonitor</string>') {
    throw 'macOS bundle identifier is missing or unexpected.'
}
try { [xml]$plistText | Out-Null }
catch { throw "macOS Info.plist is not well-formed XML: $($_.Exception.Message)" }

# --- phase tracking -----------------------------------------------------------
# Replays the render that was misread as "8% the whole time" on 2026-08-08: a Wan
# 2.2 S2V job that loaded a 19.6 GB GGUF, sampled at 90-100% and 575 W, then left
# 28.3 GB resident at 0% with the GPU claim still held. A naive mean reports single
# digits for that; the phase report has to say "saturated while working, then held
# idle" - otherwise this module is no better than the reading it replaced.
function New-FakeSample {
    param(
        [Parameter(Mandatory)][DateTime]$Stamp,
        [double]$Util, [double]$UsedMb, [double]$PowerW,
        [object[]]$Processes = @()
    )
    [pscustomobject][ordered]@{
        timestamp_utc = $Stamp.ToString('o')
        status = 'ok'
        utilization_percent = $Util
        memory_used_mb = $UsedMb
        power_w = $PowerW
        processes = $Processes
    }
}

$tracker = New-GpuPhaseTracker -WasteWarnSeconds 30 -AssumedIntervalSeconds 5
$claimHeld = [pscustomobject]@{ state = 'held'; holder = 'comfyui' }
$t0 = [DateTime]::UtcNow.AddMinutes(-5)
$step = 0

# Load: memory climbing hard, GPU barely engaged. This is the stretch that makes a
# point sample read 0-8% while real work is happening.
foreach ($mb in 1200, 6000, 12000, 19000, 25000) {
    $null = Add-GpuPhaseSample -Tracker $tracker -Claim $claimHeld `
        -Sample (New-FakeSample -Stamp $t0.AddSeconds(5 * $step++) -Util 3 -UsedMb $mb -PowerW 120)
}
# Sampling: saturated.
foreach ($i in 1..12) {
    $null = Add-GpuPhaseSample -Tracker $tracker -Claim $claimHeld `
        -Sample (New-FakeSample -Stamp $t0.AddSeconds(5 * $step++) -Util 97 -UsedMb 31800 -PowerW 575)
}
# Finished, and nobody released: memory held, zero work, claim still held.
foreach ($i in 1..12) {
    $null = Add-GpuPhaseSample -Tracker $tracker -Claim $claimHeld `
        -Sample (New-FakeSample -Stamp $t0.AddSeconds(5 * $step++) -Util 0 -UsedMb 28300 -PowerW 45)
}

$report = Get-GpuPhaseReport -Tracker $tracker

if ($report.computing_seconds -le 0) { throw 'phase report credited no time to computing' }
if ($report.resident_idle_seconds -le 0) { throw 'phase report credited no time to resident-idle' }
if ($report.overhead_seconds -le 0) { throw 'phase report credited no time to overhead (model load)' }
if ($report.peak_utilization_percent -lt 90) { throw 'phase report lost the saturated peak' }
# The core claim: duty cycle shows the work where a mean hides it.
if ($report.duty_cycle_percent -lt 30) {
    throw "duty cycle $($report.duty_cycle_percent)% understates a job saturated for 60s"
}
if ($report.mean_utilization_percent -ge $report.duty_cycle_percent) {
    throw 'mean utilisation should sit below duty cycle here - that gap is the whole point'
}
# Both warnings this session actually needed.
if (-not ($report.warnings -match 'held at idle')) { throw 'no warning for idle-but-resident memory' }
if (-not ($report.warnings -match 'claim leak')) { throw 'no warning for the leaked GPU claim' }

# Unattributed VRAM: 9.4 GB used and nothing the driver could name - exactly what
# nvidia-smi reports from inside WSL, where Windows host processes are invisible.
$blind = New-GpuPhaseTracker -UnattributedWarnMb 1024
$null = Add-GpuPhaseSample -Tracker $blind -Sample (New-FakeSample -Stamp ([DateTime]::UtcNow) `
    -Util 0 -UsedMb 9469 -PowerW 48)
$blindReport = Get-GpuPhaseReport -Tracker $blind
if ($blindReport.max_unattributed_mb -lt 9000) { throw 'unattributed VRAM was not measured' }
if (-not ($blindReport.warnings -match 'not attributable')) {
    throw 'no warning for VRAM belonging to no visible process'
}

# A quiet card must stay quiet: no phantom warnings when nothing is loaded.
$quiet = New-GpuPhaseTracker
$null = Add-GpuPhaseSample -Tracker $quiet -Sample (New-FakeSample -Stamp ([DateTime]::UtcNow) `
    -Util 0 -UsedMb 300 -PowerW 20)
if (@((Get-GpuPhaseReport -Tracker $quiet).warnings).Count -ne 0) {
    throw 'an idle, empty GPU should raise no warnings'
}

# The rendered phase feed: exactly two prefixed lines, and the display line has
# to fit the hero card's 264px column in every shape - quiet, working, warning.
Add-Type -AssemblyName System.Drawing
$phaseBitmap = New-Object System.Drawing.Bitmap 1, 1
$phaseGraphics = [System.Drawing.Graphics]::FromImage($phaseBitmap)
$phaseFont = New-Object System.Drawing.Font('Segoe UI Variable Text', 7, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
try {
    foreach ($case in @($null, $report, $blindReport, (Get-GpuPhaseReport -Tracker $quiet))) {
        $phaseLines = @((ConvertTo-PhaseReport -Report $case) -split '\r?\n')
        if ($phaseLines.Count -ne 2) { throw "Phase report rendered $($phaseLines.Count) lines; expected 2." }
        if ($phaseLines[0] -notmatch '^phase\|.+$') { throw "Phase line is not a populated 'phase' row: $($phaseLines[0])" }
        if ($phaseLines[1] -notmatch '^warn\|.+$') { throw "Phase line is not a populated 'warn' row: $($phaseLines[1])" }
        $phaseValue = ($phaseLines[0] -split '\|', 2)[1]
        $phaseWidth = [int]$phaseGraphics.MeasureString($phaseValue, $phaseFont).Width
        if ($phaseWidth -gt 264) {
            throw ("Phase display line is {0}px wide but the hero column is 264px: '{1}'" -f $phaseWidth, $phaseValue)
        }
    }
} finally {
    $phaseFont.Dispose(); $phaseGraphics.Dispose(); $phaseBitmap.Dispose()
}
# A warning must take the display line - a held-idle card matters more than a
# duty figure - and the warn field must let the skin recolour without parsing.
$warnLines = @((ConvertTo-PhaseReport -Report $report) -split '\r?\n')
if ($warnLines[1] -eq 'warn|none') { throw 'A report with warnings rendered warn|none.' }
if (($warnLines[0] -split '\|', 2)[1] -notmatch 'held at idle') { throw 'An active warning did not take the phase display line.' }
if (((ConvertTo-PhaseReport -Report (Get-GpuPhaseReport -Tracker $quiet)) -split '\r?\n')[1] -ne 'warn|none') {
    throw 'A quiet card must render warn|none.'
}

# --- model feed ---------------------------------------------------------------
# MODELS answers "which model is on which device" straight from the runtimes.
# The shapes that must hold: four prefixed rows in a fixed order; held memory
# without a model ID never reads "idle"; and a realistic Ollama tag must not
# overflow the 222px column - a single quantised 32B name nearly fills it alone.
$modelRows = @(
    [pscustomobject]@{ device = 'gpu'; name = 'qwen2.5-coder:32b-instruct-q4_K_M'; detail = '19.6G ctx 32768'; source = 'ollama' },
    [pscustomobject]@{ device = 'gpu'; name = 'wan2.2-s2v-14b'; detail = 'ready'; source = 'llama-swap' },
    [pscustomobject]@{ device = 'igpu'; name = 'bge-small-en-v1.5'; detail = 'embeddings 384d'; source = 'openvino' },
    [pscustomobject]@{ device = 'cpu'; name = 'phi-3-mini'; detail = ''; source = 'ollama' }
)
$heldGpu = [pscustomobject]@{ status = 'ok'; memory_used_mb = '9469' }
$quietGpu = [pscustomobject]@{ status = 'ok'; memory_used_mb = '612' }
$absentNpu = [pscustomobject]@{ status = 'absent' }
$ownerGpu = [pscustomobject]@{
    status = 'ok'; memory_used_mb = '2206'
    processes = @([pscustomobject]@{ name = 'WWWWWWWWWWWWWWWWWWWW'; pid = 2147483647; memory_bytes = 1200MB })
}

$modelBitmap = New-Object System.Drawing.Bitmap 1, 1
$modelGraphics = [System.Drawing.Graphics]::FromImage($modelBitmap)
$modelFont = New-Object System.Drawing.Font('Segoe UI Variable Text', 7, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
try {
    foreach ($case in @(
        @{ Models = $modelRows; Gpu = $heldGpu; Igpu = $quietGpu; Npu = $absentNpu },
        @{ Models = @();        Gpu = $heldGpu; Igpu = $quietGpu; Npu = $absentNpu },
        @{ Models = @();        Gpu = $ownerGpu; Igpu = $quietGpu; Npu = $absentNpu },
        @{ Models = $null;      Gpu = $null;    Igpu = $null;     Npu = $null }
    )) {
        $modelLines = @((ConvertTo-ModelReport -Models $case.Models -DiscreteGpu $case.Gpu -IntegratedGpu $case.Igpu -Npu $case.Npu) -split '\r?\n')
        if ($modelLines.Count -ne 4) { throw "Model report has $($modelLines.Count) lines; expected 4." }
        foreach ($index in 0..3) {
            $expected = @('gpu', 'igpu', 'npu', 'cpu')[$index]
            if ($modelLines[$index] -notmatch ('^' + $expected + '\|.+$')) {
                throw "Model report line $($index + 1) is not a populated '$expected' row: $($modelLines[$index])"
            }
        }
        foreach ($line in $modelLines) {
            $value = ($line -split '\|', 2)[1]
            $width = [int]$modelGraphics.MeasureString($value, $modelFont).Width
            if ($width -gt 222) {
                throw ("Model value is {0}px wide but the column is 222px, so it renders truncated: '{1}'" -f $width, $value)
            }
        }
    }
} finally {
    $modelFont.Dispose(); $modelGraphics.Dispose(); $modelBitmap.Dispose()
}

# Held memory with no runtime claiming it is a tenant, not idle - printing
# "idle" over 9.4 GB of resident VRAM is the exact lie the card exists to avoid.
$unnamed = @((ConvertTo-ModelReport -Models @() -DiscreteGpu $heldGpu -IntegratedGpu $quietGpu -Npu $absentNpu) -split '\r?\n')
if ($unnamed[0] -ne 'gpu|no model ID; memory in use') { throw "9.4G of unclaimed VRAM lost its missing attribution status: $($unnamed[0])" }
if ($unnamed[1] -ne 'igpu|none reported') { throw "An unclaimed device did not read none reported: $($unnamed[1])" }
if ($unnamed[2] -ne 'npu|not present') { throw "An absent device did not read not present: $($unnamed[2])" }
Write-Host ("Models     : " + ((@((ConvertTo-ModelReport -Models $modelRows -DiscreteGpu $heldGpu -IntegratedGpu $quietGpu -Npu $absentNpu) -split '\r?\n')) -join ' | '))

Write-Host "PASS phases $($report.summary)"
Write-Host "PASS Rainmeter=$rainmeter GPU=$($sample.name) util=$($sample.utilization_percent)% temp=$($sample.temperature_c)C"
