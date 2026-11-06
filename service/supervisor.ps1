[CmdletBinding()]
param(
    [ValidateRange(1, 120)][int]$RefreshMinutes = 10,
    [ValidateRange(1, 30)][int]$PollSeconds = 2,
    # Integrated GPU, NPU and top-consumer readings refresh on this slower
    # cadence. They are allowed to lag; the point is that they cost nothing.
    [ValidateRange(2, 600)][int]$DetailSeconds = 10,
    [ValidateRange(0, 31)][int]$GpuIndex = 0,
    [string]$RainmeterPath,
    [string]$NvidiaSmiPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$runtime = Join-Path $env:LOCALAPPDATA 'Utils\GpuMonitor'
$dataPath = Join-Path $runtime 'gpu.txt'
$integratedPath = Join-Path $runtime 'igpu.txt'
$npuPath = Join-Path $runtime 'npu.txt'
$residentPath = Join-Path $runtime 'processes.txt'
$modelPath = Join-Path $runtime 'models.txt'
$phasePath = Join-Path $runtime 'phase.txt'
$toolchainPath = Join-Path $runtime 'toolchain.txt'
$healthPath = Join-Path $runtime 'health.json'
$logPath = Join-Path $runtime 'supervisor.log'
$maxLogBytes = 1MB
$skinName = 'UtilsGpuMonitor'
$skinFile = 'UtilsGpuMonitor.ini'

New-Item -ItemType Directory -Path $runtime -Force | Out-Null

# Claim the duplicate guard before loading the module. Importing compiles the
# embedded C# for the PDH and WDDM interop, so a refused duplicate used to pay a
# few hundred milliseconds of compile just to discover it was not wanted -
# which is exactly what every launch during a restart loop was doing.
$created = $false
$mutex = New-Object Threading.Mutex($true, 'Local\UtilsGpuMonitorSupervisor', [ref]$created)
if (-not $created) { exit 0 }

Import-Module (Join-Path $root 'GpuMonitor.psm1') -Force

function Write-SupervisorLog {
    param([string]$Message)
    try {
        if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -ge $maxLogBytes) {
            Move-Item -LiteralPath $logPath -Destination ($logPath + '.1') -Force
        }
        Add-Content -LiteralPath $logPath -Encoding UTF8 -Value ('{0} {1}' -f ([DateTime]::UtcNow.ToString('o')), $Message)
    } catch { }
}

function Invoke-RainmeterBang {
    param([string[]]$BangArguments)
    try {
        Start-Process -FilePath $script:rainmeter -ArgumentList $BangArguments -WindowStyle Hidden | Out-Null
    } catch {
        Write-SupervisorLog ('Rainmeter bang failed: ' + $_.Exception.Message)
    }
}

# Returns 'active', 'inactive' or 'unknown'. The tri-state matters: the caller
# reactivates the skin on 'inactive', and a settings file we cannot read or
# parse is not evidence that the skin is down. Collapsing that case to $false -
# as a Test- returning a plain bool is forced to - fired a deactivate and an
# activate bang every 60 seconds, forever, on any machine whose Rainmeter.ini
# is unreadable. That is the same absence-of-evidence trap the watchdog
# documents and avoids.
#
# A missing Rainmeter.ini stays 'inactive' on purpose: Rainmeter has genuinely
# not activated anything yet, and the activate bang makes it write the file.
function Get-SkinActivationState {
    $settingsPath = Join-Path $env:APPDATA 'Rainmeter\Rainmeter.ini'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { return 'inactive' }
    try {
        $content = [IO.File]::ReadAllText($settingsPath)
    } catch {
        return 'unknown'
    }
    try {
        $section = [regex]::Match($content, '(?sim)^\[' + [regex]::Escape($skinName) + '\]\s*(.*?)(?=^\[|\z)')
        if ($section.Success) {
            $active = [regex]::Match($section.Groups[1].Value, '(?im)^\s*Active\s*=\s*(\d+)')
            if ($active.Success) {
                return $(if ([int]$active.Groups[1].Value -ge 1) { 'active' } else { 'inactive' })
            }
        }
    } catch {
        return 'unknown'
    }
    # Readable settings with no section, or a section with no Active key, is a
    # real answer: the skin is not loaded.
    return 'inactive'
}

function Select-Device {
    param([object[]]$Devices, [string]$Kind)
    $match = @($Devices | Where-Object { $_.kind -eq $Kind } | Select-Object -First 1)
    if ($match.Count -gt 0) { return $match[0] }
    return $null
}

$rainmeter = if ($RainmeterPath) { $RainmeterPath } else { Get-RainmeterExecutable }
$rainmeterRestarts = 0
$lastActivation = [DateTime]::MinValue
$lastSkinRefresh = [DateTime]::UtcNow
$lastRainmeterPid = $null
# A Rainmeter that cannot start - bad skin, missing ini, uninstalled underneath
# us - was respawned every two seconds for as long as the machine stayed up.
# Consecutive failed starts back off 2s, 4s, 8s ... to this cap.
$rainmeterFailures = 0
$rainmeterBackoffCapSeconds = 300
$nextRainmeterAttempt = [DateTime]::MinValue
$lastRainmeterStart = [DateTime]::MinValue
# A start only counts as good once it has survived this long. Clearing the
# backoff on mere presence would let a process that dies every three seconds
# reset the counter on every poll and never back off at all.
$rainmeterSettleSeconds = 30

# The accelerator query and the process table are shared state: the PDH query
# supplies rate counters relative to the previous collection, and the process
# table needs the previous CPU times to produce a percentage.
$sampler = $null
try {
    $sampler = New-AcceleratorSampler
} catch {
    Write-SupervisorLog ('Accelerator sampler unavailable: ' + $_.Exception.Message)
}
$processState = $null
$lastDetail = [DateTime]::MinValue
$integrated = New-AbsentAcceleratorSample -Kind 'igpu' -Message 'starting'
$npu = New-AbsentAcceleratorSample -Kind 'npu' -Message 'starting'
$processes = $null
$discreteDetail = $null
$toolchain = $null
$models = @()
$detailTick = $false
# Held between detail passes so the fast path can republish the last known
# answer instead of spawning nvidia-smi again to recompute it.
$lastVendorProcesses = @()
$lastVendorResident = ''
$claim = $null
# Point-in-time utilisation misreads a render as "8% the whole time"; the phase
# tracker accumulates time per phase so the panel can show duty cycle instead.
$phaseTracker = New-GpuPhaseTracker
$phaseReport = $null

Write-SupervisorLog "Supervisor started pid=$PID gpu=$GpuIndex poll=${PollSeconds}s detail=${DetailSeconds}s accelerators=$($null -ne $sampler)"

try {
    while ($true) {
        try {
            $rainmeterProcess = Get-Process -Name Rainmeter -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($rainmeterProcess) {
                $lastRainmeterPid = $rainmeterProcess.Id
                if ($rainmeterFailures -gt 0 -and
                    ([DateTime]::UtcNow - $lastRainmeterStart).TotalSeconds -ge $rainmeterSettleSeconds) {
                    if ($rainmeterFailures -ge 2) {
                        Write-SupervisorLog "Rainmeter stable pid=$($rainmeterProcess.Id); backoff cleared after $rainmeterFailures attempt(s)"
                    }
                    $rainmeterFailures = 0
                }
            }
            elseif ([DateTime]::UtcNow -ge $nextRainmeterAttempt) {
                # Arm the backoff before the spawn, not after: Start-Process
                # throws outright when the executable is gone, and an unarmed
                # backoff would retry that on every poll.
                $rainmeterFailures++
                $lastRainmeterStart = [DateTime]::UtcNow
                $backoffSeconds = [Math]::Min(
                    [Math]::Pow(2, [Math]::Min($rainmeterFailures, 8)), $rainmeterBackoffCapSeconds)
                $nextRainmeterAttempt = [DateTime]::UtcNow.AddSeconds($backoffSeconds)

                $rainmeterProcess = Start-Process -FilePath $rainmeter -PassThru
                $rainmeterRestarts++
                $lastRainmeterPid = $rainmeterProcess.Id
                Write-SupervisorLog "Rainmeter started pid=$($rainmeterProcess.Id) restart=$rainmeterRestarts attempt=$rainmeterFailures next_retry_after=${backoffSeconds}s"
                Start-Sleep -Seconds 2
                $lastActivation = [DateTime]::MinValue
            }

            # Periodic !Refresh. On 2026-09-19 the skin sat frozen for over an hour -- GPU tile at
            # 0% / 30,438 MB / "starting" while gpu.txt was updating every two seconds and the
            # UsageMonitor tiles on the same panel kept moving. WebParser's file:// fetch had
            # hung; a single !Refresh cleared it instantly. Nothing here can read the panel to
            # detect that, so the freeze is bounded instead: a refresh every RefreshMinutes is
            # invisible when nothing is wrong and caps a hang at that many minutes.
            if (([DateTime]::UtcNow - $lastSkinRefresh).TotalSeconds -ge ($RefreshMinutes * 60)) {
                Invoke-RainmeterBang @('!Refresh', ('"' + $skinName + '"'))
                $lastSkinRefresh = [DateTime]::UtcNow
            }

            if (([DateTime]::UtcNow - $lastActivation).TotalSeconds -ge 60) {
                if ((Get-SkinActivationState) -eq 'inactive') {
                    Invoke-RainmeterBang @('!ActivateConfig', ('"' + $skinName + '"'), ('"' + $skinFile + '"'))
                    Write-SupervisorLog 'Skin was inactive; reactivated'
                }
                $lastActivation = [DateTime]::UtcNow
            }

            $sample = Get-GpuSample -GpuIndex $GpuIndex -NvidiaSmiPath $NvidiaSmiPath

            $detailTick = ([DateTime]::UtcNow - $lastDetail).TotalSeconds -ge $DetailSeconds
            if ($detailTick) {
                $lastDetail = [DateTime]::UtcNow
                try {
                    $processes = Get-ProcessTelemetry -Previous $processState
                    $processState = $processes.state

                    $devices = @()
                    if ($sampler) {
                        $devices = @(Get-AcceleratorTelemetry -Sampler $sampler -ProcessNames $processes.names)
                    }

                    $found = Select-Device -Devices $devices -Kind 'igpu'
                    $integrated = if ($found) { $found } else {
                        New-AbsentAcceleratorSample -Kind 'igpu' -Message $(if ($sampler) { 'not present on this machine' } else { 'GPU performance counters unavailable' })
                    }
                    $found = Select-Device -Devices $devices -Kind 'npu'
                    $npu = if ($found) { $found } else {
                        New-AbsentAcceleratorSample -Kind 'npu' -Message $(if ($sampler) { 'not present on this machine' } else { 'GPU performance counters unavailable' })
                    }
                    $discreteDetail = Select-Device -Devices $devices -Kind 'dgpu'

                    Write-AtomicText -Path $integratedPath -Text (ConvertTo-GpuMonitorLine -Sample $integrated) -Encoding UTF8
                    Write-AtomicText -Path $npuPath -Text (ConvertTo-GpuMonitorLine -Sample $npu) -Encoding UTF8
                    Write-AtomicText -Path $residentPath -Encoding UTF8 -Text (ConvertTo-ResidentReport `
                        -DiscreteGpu $discreteDetail -IntegratedGpu $integrated -Npu $npu -Processes $processes)

                    # Which model sits on which device. Kept on the detail
                    # cadence, not the two-second poll: these are HTTP calls to
                    # three separate runtimes, and a model does not change
                    # identity between polls. Failures inside Get-ServedModels
                    # are already swallowed per-endpoint, so a down runtime
                    # costs an empty row rather than the whole detail pass.
                    $models = Get-ServedModels

                    # Drivers and SDKs do not change while the machine is up, so
                    # this is served from an hourly cache; the write is only
                    # here to keep the feed present for the skin.
                    $toolchain = Get-AcceleratorToolchain -NvidiaSmiPath $NvidiaSmiPath
                    Write-AtomicText -Path $toolchainPath -Encoding UTF8 -Text (ConvertTo-ToolchainReport -Toolchain $toolchain)

                    # A claim is a human declaring intent; it changes on the
                    # scale of minutes, so reading and parsing the file on every
                    # two-second poll bought nothing.
                    $claim = Get-GpuClaim
                } catch {
                    Write-SupervisorLog ('Detail sample failed: ' + $_.Exception.Message)
                }
            }

            # Without an NVIDIA driver the discrete card can still be read through
            # the WDDM counters. Fewer fields, but a real reading beats a zero.
            if ($sample.status -ne 'ok' -and $discreteDetail) {
                $sample = [pscustomobject][ordered]@{
                    timestamp_utc = [DateTime]::UtcNow.ToString('o')
                    status = 'limited'
                    name = $discreteDetail.name
                    utilization_percent = $discreteDetail.utilization_percent
                    temperature_c = ''
                    memory_used_mb = $discreteDetail.memory_used_mb
                    memory_total_mb = $discreteDetail.memory_total_mb
                    power_w = ''
                    power_limit_w = ''
                    # This branch runs precisely when there is no vendor tool to
                    # ask, so the WDDM attribution is the only attribution there
                    # is. Rebuilding the sample without it put the card back to
                    # a memory total with no owner - the gap this was meant to
                    # close - on exactly the machines that cannot close it later.
                    processes = @($discreteDetail.processes)
                    resident = (ConvertTo-SafeField $discreteDetail.resident)
                    error = 'no vendor tool; WDDM counters only'
                }
            }
            elseif ($discreteDetail) {
                # nvidia-smi gives temperature and power, which WDDM cannot, but
                # it cannot attribute per-process VRAM in WDDM mode - it reports
                # [N/A] for every process. The WDDM sample CAN attribute it, and
                # is already computed here for processes.txt.
                #
                # So the discrete card was the one device whose health.json entry
                # had a memory total and no owner, while igpu and npu both
                # published `processes` and `resident`. Consumers had to shell out
                # to nvidia-smi and got nothing. Carry the attribution across.
                Add-Member -InputObject $sample -NotePropertyName processes `
                    -NotePropertyValue @($discreteDetail.processes) -Force
                Add-Member -InputObject $sample -NotePropertyName resident `
                    -NotePropertyValue (ConvertTo-SafeField $discreteDetail.resident) -Force
            }
            elseif (-not $sample.resident) {
                # No WDDM counters on this machine, so nvidia-smi is the only
                # source of attribution. Ask it on the detail cadence only: it is
                # a second process spawn, and asking every poll doubled the cost
                # of the fast path to rediscover the same answer.
                if ($detailTick) {
                    $vendorProcesses = @(Get-GpuComputeProcesses -GpuIndex $GpuIndex -NvidiaSmiPath $NvidiaSmiPath)
                    $usedMb = 0.0
                    [void][double]::TryParse([string]$sample.memory_used_mb, [ref]$usedMb)
                    $lastVendorProcesses = $vendorProcesses
                    $lastVendorResident = if ($vendorProcesses.Count -gt 0) { Format-ResidentSummary -Rows $vendorProcesses }
                                          elseif ($usedMb -gt 512) { 'in use, not attributable (WDDM)' }
                                          else { 'idle' }
                }
                Add-Member -InputObject $sample -NotePropertyName processes `
                    -NotePropertyValue @($lastVendorProcesses) -Force
                Add-Member -InputObject $sample -NotePropertyName resident `
                    -NotePropertyValue (ConvertTo-SafeField $lastVendorResident) -Force
            }

            # Use the same finalized GPU sample as the hero card. With no WDDM
            # counters, the vendor sample can still report memory and owners.
            if ($detailTick) {
                Write-AtomicText -Path $modelPath -Encoding UTF8 -Text (ConvertTo-ModelReport `
                    -Models $models -DiscreteGpu $sample -IntegratedGpu $integrated -Npu $npu)
            }

            # Classify after the sample is final (WDDM merges included), so the
            # attribution the phase tracker sees is the one the panel shows.
            $null = Add-GpuPhaseSample -Tracker $phaseTracker -Sample $sample -Claim $claim
            $phaseReport = Get-GpuPhaseReport -Tracker $phaseTracker
            Write-AtomicText -Path $phasePath -Text (ConvertTo-PhaseReport -Report $phaseReport) -Encoding UTF8

            Write-AtomicText -Path $dataPath -Text (ConvertTo-GpuMonitorLine -Sample $sample) -Encoding UTF8
            Write-AtomicJson -Path $healthPath -Value ([ordered]@{
                contract = 'utils.gpu-monitor.health.v2'
                supervisor_pid = $PID
                updated_at = [DateTime]::UtcNow.ToString('o')
                poll_seconds = $PollSeconds
                detail_seconds = $DetailSeconds
                gpu_index = $GpuIndex
                gpu = $sample
                igpu = $integrated
                npu = $npu
                # Declared intent, not utilisation. On a one-GPU box a render, an
                # IDE assistant and a chat model all want the same card, and
                # "0% util" does not mean anyone is finished with it.
                claim = $claim
                # Time-weighted view of the window: duty cycle, phase seconds and
                # the full warning strings the phase.txt feed abbreviates.
                phase = $phaseReport
                top = [ordered]@{
                    sampled_at = $(if ($processes) { $processes.sampled_at } else { '' })
                    # @( ) not $( ): a subexpression unrolls an empty array to
                    # $null, which serializes as an object and then reads back as
                    # one phantom row. The first detail pass has no CPU deltas
                    # yet, so this list is legitimately empty.
                    memory = @(if ($processes) { $processes.memory } else { @() })
                    cpu = @(if ($processes) { $processes.cpu } else { @() })
                }
                # Named tenants per device. RESIDENT answers "which process",
                # which collides (two runtimes both ship llama-server) and goes
                # blank for anything inside WSL; this answers "which model".
                models = @($models)
                toolchain = $toolchain
                rainmeter = [ordered]@{
                    executable = $rainmeter
                    pid = $lastRainmeterPid
                    restarts = $rainmeterRestarts
                    # Non-zero means starts are failing and the respawn is
                    # backing off, which is otherwise only visible in the log.
                    consecutive_failures = $rainmeterFailures
                    skin = $skinName
                }
            })
        } catch {
            Write-SupervisorLog ('Loop error: ' + $_.Exception.Message)
        }
        Start-Sleep -Seconds $PollSeconds
    }
} finally {
    Write-SupervisorLog "Supervisor stopped pid=$PID"
    if ($sampler) {
        try { $sampler.Dispose() } catch { }
    }
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}
