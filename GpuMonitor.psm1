Set-StrictMode -Version Latest

# Cached across calls: adapter topology and machine memory limits change rarely,
# and the point of this module is to be cheap enough to poll from a supervisor.
$script:AcceleratorInventory = $null
$script:AcceleratorInventoryStamp = [DateTime]::MinValue
$script:AcceleratorMemoryLimits = $null

function Get-RainmeterExecutable {
    [CmdletBinding()]
    param()

    $candidates = @(
        (Join-Path $env:ProgramFiles 'Rainmeter\Rainmeter.exe'),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Rainmeter\Rainmeter.exe' }),
        (Join-Path $env:LOCALAPPDATA 'Rainmeter\Rainmeter.exe')
    ) | Where-Object { $_ }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $command = Get-Command Rainmeter.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw 'Rainmeter.exe was not found. Install Rainmeter before installing GPU Monitor.'
}

function Get-RainmeterSkinPath {
    [CmdletBinding()]
    param(
        [string]$SettingsPath = (Join-Path $env:APPDATA 'Rainmeter\Rainmeter.ini')
    )

    if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
        $content = [IO.File]::ReadAllText($SettingsPath)
        $match = [regex]::Match($content, '(?im)^\s*SkinPath\s*=\s*(.+?)\s*$')
        if ($match.Success) {
            $configured = [Environment]::ExpandEnvironmentVariables($match.Groups[1].Value.Trim())
            if ($configured) { return $configured.TrimEnd('\') }
        }
    }

    $oneDrive = if ($env:OneDrive) { Join-Path $env:OneDrive 'Documents\Rainmeter\Skins' } else { $null }
    if ($oneDrive -and (Test-Path -LiteralPath $oneDrive)) { return $oneDrive }
    return (Join-Path $env:USERPROFILE 'Documents\Rainmeter\Skins')
}

function Resolve-NvidiaSmi {
    [CmdletBinding()]
    param([string]$Path)

    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $Path).Path
    }
    $command = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $systemPath = Join-Path $env:WINDIR 'System32\nvidia-smi.exe'
    if (Test-Path -LiteralPath $systemPath) { return $systemPath }
    throw 'nvidia-smi.exe was not found.'
}

function ConvertTo-SafeField {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Replace('|', '/').Replace("`r", ' ').Replace("`n", ' ').Trim()
}

function New-UnavailableGpuSample {
    param([string]$Message)
    [pscustomobject][ordered]@{
        timestamp_utc = [DateTime]::UtcNow.ToString('o')
        status = 'unavailable'
        name = 'NVIDIA GPU unavailable'
        utilization_percent = '0'
        temperature_c = '0'
        memory_used_mb = '0'
        memory_total_mb = '0'
        power_w = '0'
        power_limit_w = '0'
        processes = @()
        resident = ''
        error = (ConvertTo-SafeField $Message)
    }
}

function Get-GpuComputeProcesses {
    <#
    .SYNOPSIS
        Which processes hold memory on the discrete GPU, with PIDs.
    .DESCRIPTION
        The integrated GPU and NPU samples already carried `processes` and
        `resident`; the discrete card did not, so it was the one device whose
        memory had a total but no owner.

        That gap cost real time downstream: a consumer saw 8.8 GB attributed to
        llama-server while no such process existed any more, and had no PID to
        test liveness against. A name and a size cannot be checked; a PID can.
    #>
    param([ValidateRange(0, 31)][int]$GpuIndex = 0, [string]$NvidiaSmiPath)

    try {
        $smi = Resolve-NvidiaSmi -Path $NvidiaSmiPath
        $rows = @(& $smi "--id=$GpuIndex" '--query-compute-apps=pid,used_gpu_memory,process_name' '--format=csv,noheader,nounits' 2>$null)
        if ($LASTEXITCODE -ne 0) { return @() }
        $out = foreach ($row in $rows) {
            $text = ([string]$row).Trim()
            if (-not $text -or $text.StartsWith('[')) { continue }
            $parts = @($text -split '\s*,\s*')
            if ($parts.Count -lt 3) { continue }
            $mib = 0
            # In WDDM mode the driver reports used_gpu_memory as [N/A] for every
            # process, and nvidia-smi additionally lists graphics contexts. Both
            # mean "no usable attribution", so drop the row instead of emitting
            # a zero: publishing 23 desktop apps at 0 bytes, with a resident line
            # reading "RtkUWP 0%  Notepad 0%", is noise wearing the shape of data
            # and is worse than the empty list this device had before.
            if (-not [int]::TryParse($parts[1], [ref]$mib)) { continue }
            if ($mib -le 0) { continue }
            [pscustomobject][ordered]@{
                pid = [int]$parts[0]
                name = (ConvertTo-SafeField ([IO.Path]::GetFileNameWithoutExtension($parts[2])))
                utilization_percent = 0
                memory_bytes = [int64]$mib * 1MB
            }
        }
        # Empty here is a truthful "this driver mode cannot attribute", which the
        # WDDM performance-counter path used for igpu/npu could still answer.
        return @($out | Sort-Object -Property memory_bytes -Descending)
    } catch {
        return @()
    }
}

function Get-GpuClaim {
    <#
    .SYNOPSIS
        Who has declared they are using the GPU, and whether they are done.
    .DESCRIPTION
        Utilisation says the card is busy; it cannot say whether a human is
        mid-task. On a single-GPU box where a video render, an IDE assistant and
        a chat model all want the same card, "is it free yet" is a question about
        intent, not about percent-used.

        Any worker can publish the optional JSON record documented in
        docs/gpu-claims.md and contracts/gpu-claim.schema.json. This function
        only reads it. A released record can retain handoff information.
        Explicit -Path takes precedence over GPUMONITOR_CLAIM_PATH, then the
        legacy location is used for compatibility with existing writers.
    #>
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = $env:GPUMONITOR_CLAIM_PATH }
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Join-Path $env:LOCALAPPDATA 'LocalAISettings\gpu-claim.json' }
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject][ordered]@{ state = 'none'; holder = ''; note = ''; summary = 'unclaimed' }
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        return [pscustomobject][ordered]@{ state = 'unreadable'; holder = ''; note = ''; summary = 'claim unreadable' }
    }
    # Set-StrictMode -Version Latest is active module-wide, so reading a property
    # a producer did not emit is a terminating error, not $null. The claim file
    # is written by another application and can gain fields; read defensively
    # or a future writer silently breaks the monitor.
    function Get-Field([object]$Object, [string]$Name) {
        if ($null -eq $Object) { return '' }
        $prop = $Object.PSObject.Properties[$Name]
        if (-not $prop) { return '' }
        return (ConvertTo-SafeField $prop.Value)
    }

    $state = Get-Field $raw 'state'
    $holder = Get-Field $raw 'holder'
    $note = Get-Field $raw 'note'
    $nextFor = Get-Field $raw 'next_for'
    if ($state -eq 'held') {
        $summary = 'HELD by ' + $holder
        if ($note) { $summary += ' - ' + $note }
        $summary += '  (not released)'
    } elseif ($state -eq 'released') {
        $summary = 'free'
        if ($holder) { $summary += ' - last ' + $holder }
        if ($nextFor) { $summary += ', handed to ' + $nextFor }
    } else {
        $summary = 'unclaimed'
    }
    [pscustomobject][ordered]@{
        state = $state
        holder = $holder
        note = $note
        claimed_at = Get-Field $raw 'claimed_at'
        released_at = Get-Field $raw 'released_at'
        next_for = $nextFor
        summary = ConvertTo-SafeField $summary
    }
}

function Get-GpuSample {
    [CmdletBinding()]
    param(
        [ValidateRange(0, 31)][int]$GpuIndex = 0,
        [string]$NvidiaSmiPath,
        # Per-process attribution costs a second nvidia-smi spawn, which doubles
        # the cost of the only call on the fast poll path. Callers that sample
        # every couple of seconds must leave this off and attribute on their own
        # slower cadence; see the supervisor.
        [switch]$IncludeProcesses
    )

    try {
        $smi = Resolve-NvidiaSmi -Path $NvidiaSmiPath
        $query = 'name,utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw,power.limit'
        $lines = @(& $smi "--id=$GpuIndex" "--query-gpu=$query" '--format=csv,noheader,nounits' 2>$null)
        if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) {
            return New-UnavailableGpuSample "nvidia-smi returned exit code $LASTEXITCODE"
        }

        $parts = @(([string]$lines[0]) -split '\s*,\s*')
        if ($parts.Count -lt 7) {
            return New-UnavailableGpuSample 'nvidia-smi returned an incomplete telemetry row'
        }

        $procs = @()
        if ($IncludeProcesses) { $procs = @(Get-GpuComputeProcesses -GpuIndex $GpuIndex -NvidiaSmiPath $NvidiaSmiPath) }

        # Format-ResidentSummary calls an empty list "idle", which is right for a
        # quiet device and badly wrong here: WDDM cannot attribute per-process
        # VRAM, so an empty list beside 31 GB in use would read as "nothing is on
        # the card" while the card is nearly full. Distinguish the two.
        $usedMb = 0.0
        [void][double]::TryParse($parts[3], [ref]$usedMb)
        if ($procs.Count -gt 0) {
            $residentText = Format-ResidentSummary -Rows $procs
        } elseif (-not $IncludeProcesses) {
            # Not asked for. Saying "idle" here would be a claim this call never
            # tested, so say nothing and let the caller fill it in.
            $residentText = ''
        } elseif ($usedMb -gt 512) {
            $residentText = 'in use, not attributable (WDDM)'
        } else {
            $residentText = 'idle'
        }
        return [pscustomobject][ordered]@{
            timestamp_utc = [DateTime]::UtcNow.ToString('o')
            status = 'ok'
            name = ConvertTo-SafeField $parts[0]
            utilization_percent = ConvertTo-SafeField $parts[1]
            temperature_c = ConvertTo-SafeField $parts[2]
            memory_used_mb = ConvertTo-SafeField $parts[3]
            memory_total_mb = ConvertTo-SafeField $parts[4]
            power_w = ConvertTo-SafeField $parts[5]
            power_limit_w = ConvertTo-SafeField $parts[6]
            # Same two fields the igpu/npu samples already publish, so every
            # device now answers "who is on it" in the same shape.
            processes = $procs
            resident = (ConvertTo-SafeField $residentText)
            error = ''
        }
    } catch {
        return New-UnavailableGpuSample $_.Exception.Message
    }
}

function ConvertTo-GpuMonitorLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Sample)

    $fields = @(
        $Sample.timestamp_utc,
        $Sample.status,
        $Sample.name,
        $Sample.utilization_percent,
        $Sample.temperature_c,
        $Sample.memory_used_mb,
        $Sample.memory_total_mb,
        $Sample.power_w,
        $Sample.power_limit_w,
        $Sample.error
    ) | ForEach-Object { ConvertTo-SafeField $_ }
    return ($fields -join '|')
}

$script:AtomicMoveSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class UtilsAtomicFile
{
    private const uint MOVEFILE_REPLACE_EXISTING = 0x00000001;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool MoveFileExW(string existingFileName, string newFileName, uint flags);

    // Atomic rename-over. Unlike ReplaceFile, this never unlinks the destination
    // first, so a concurrent reader always resolves the name to one whole file.
    // Works whether or not the destination already exists.
    public static void ReplaceAtomic(string source, string destination)
    {
        if (!MoveFileExW(source, destination, MOVEFILE_REPLACE_EXISTING))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@

# Compiled on first use rather than at import. The supervisor claims its
# duplicate-guard mutex before importing precisely to avoid paying compile cost
# in a launch that is about to exit, and the watchdog imports this module once a
# minute only to write a JSON receipt; neither should pay for interop it has not
# reached yet.
function Initialize-AtomicMove {
    if (-not ('UtilsAtomicFile' -as [type])) {
        Add-Type -TypeDefinition $script:AtomicMoveSource -ErrorAction Stop
    }
}

function Write-AtomicText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [ValidateSet('UTF8', 'ASCII')][string]$Encoding = 'UTF8'
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = Join-Path $directory ('.{0}.{1}.{2}.tmp' -f ([IO.Path]::GetFileName($Path)), $PID, [guid]::NewGuid().ToString('N'))
    try {
        $encoder = if ($Encoding -eq 'ASCII') { [Text.Encoding]::ASCII } else { New-Object Text.UTF8Encoding($false) }
        [IO.File]::WriteAllText($temporary, $Text + [Environment]::NewLine, $encoder)
        # Move-Item -Force is delete-then-rename on Windows, so it never was the
        # atomic swap this function's name promises. It leaves a window in which
        # $Path does not exist, and it fails outright with "Cannot create a file
        # when that file already exists" whenever a reader or an AV scan holds
        # the destination. Both were live: the supervisor lost a whole poll's
        # worth of writes on every collision, and the watchdog caught health.json
        # missing mid-swap and restarted the monitor on the strength of it.
        #
        # [IO.File]::Replace is not the fix - ReplaceFile also deletes before it
        # renames, and a reader polling this feed still catches it absent. Only
        # MoveFileEx with MOVEFILE_REPLACE_EXISTING is a true atomic rename-over:
        # the name resolves to the old file or the new one at every instant.
        # File.Move(src, dst, overwrite) wraps exactly that, but the overload is
        # .NET Core only and the service runs on Windows PowerShell 5.1, so the
        # call is made directly. It also covers the create case, which is why
        # there is no Test-Path branch here to race against.
        Initialize-AtomicMove
        for ($attempt = 1; ; $attempt++) {
            try {
                [UtilsAtomicFile]::ReplaceAtomic($temporary, $Path)
                break
            } catch {
                # ERROR_ACCESS_DENIED here is a reader holding the destination:
                # File.ReadAllText opens with FileShare.Read, which withholds
                # FILE_SHARE_DELETE and so blocks a rename-over for as long as
                # the read lasts. Reads of these feeds are microseconds, so the
                # collision clears almost immediately - but it has to be waited
                # out rather than surfaced, because the caller's alternative is
                # dropping the poll, which is the failure this function exists
                # to prevent. Bounded at roughly a third of a second: still well
                # inside the fast-path cadence, and a genuine fault (bad path,
                # missing directory, read-only file) still escapes on the last
                # attempt instead of looping.
                if ($attempt -ge 8) { throw }
                Start-Sleep -Milliseconds ([Math]::Min([Math]::Pow(2, $attempt), 100))
            }
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Write-AtomicJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value
    )
    Write-AtomicText -Path $Path -Text ($Value | ConvertTo-Json -Depth 8) -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Integrated GPU and NPU support
#
# Everything below is deliberately allocation-light and poll-light. Adapter
# topology comes from the WDDM kernel-mode thunk (the only interface that
# enumerates compute-only devices such as an NPU), and live numbers come from a
# long-lived PDH query. A PDH collect costs single-digit milliseconds, so the
# supervisor can sample on a slow cadence without a process spawn or a WMI call.
# ---------------------------------------------------------------------------

$script:AcceleratorNativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace UtilsGpuMonitor.Native {

public sealed class CounterValue {
    public string Name;
    public double Value;
}

// A persistent PDH query. Rate counters such as GPU engine utilization are
// differences between two collections, so holding the query open makes the
// reported value the average over the caller's own polling interval and costs
// one cheap collect per sample instead of Get-Counter's built-in sleep.
public sealed class PdhSampler : IDisposable {
    const uint PDH_FMT_DOUBLE = 0x00000200;
    const uint PDH_FMT_NOCAP100 = 0x00008000;
    const uint PDH_MORE_DATA = 0x800007D2;
    const uint PDH_CSTATUS_VALID_DATA = 0x00000000;
    const uint PDH_CSTATUS_NEW_DATA = 0x00000001;

    [StructLayout(LayoutKind.Sequential)]
    struct PDH_FMT_COUNTERVALUE_DOUBLE { public uint CStatus; public double doubleValue; }

    [StructLayout(LayoutKind.Sequential)]
    struct PDH_FMT_COUNTERVALUE_ITEM_W { public IntPtr szName; public PDH_FMT_COUNTERVALUE_DOUBLE FmtValue; }

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    static extern uint PdhOpenQueryW(string dataSource, IntPtr userData, out IntPtr query);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    static extern uint PdhAddEnglishCounterW(IntPtr query, string path, IntPtr userData, out IntPtr counter);
    [DllImport("pdh.dll")]
    static extern uint PdhCollectQueryData(IntPtr query);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    static extern uint PdhGetFormattedCounterArrayW(IntPtr counter, uint format, ref uint bufferSize, out uint itemCount, IntPtr buffer);
    [DllImport("pdh.dll")]
    static extern uint PdhCloseQuery(IntPtr query);

    IntPtr query = IntPtr.Zero;
    readonly Dictionary<string, IntPtr> counters = new Dictionary<string, IntPtr>();

    public PdhSampler() {
        uint rc = PdhOpenQueryW(null, IntPtr.Zero, out query);
        if (rc != 0) throw new InvalidOperationException("PdhOpenQuery failed with 0x" + rc.ToString("X8"));
    }

    // Wildcard instance paths are expanded by PDH at collection time, so
    // processes that start after the counter was added still show up.
    public bool Add(string key, string path) {
        IntPtr counter;
        if (PdhAddEnglishCounterW(query, path, IntPtr.Zero, out counter) != 0) return false;
        counters[key] = counter;
        return true;
    }

    public bool Has(string key) { return counters.ContainsKey(key); }

    public bool Collect() { return PdhCollectQueryData(query) == 0; }

    public CounterValue[] Read(string key) {
        IntPtr counter;
        if (!counters.TryGetValue(key, out counter)) return new CounterValue[0];
        uint size = 0, count = 0;
        uint rc = PdhGetFormattedCounterArrayW(counter, PDH_FMT_DOUBLE | PDH_FMT_NOCAP100, ref size, out count, IntPtr.Zero);
        if (rc != PDH_MORE_DATA || size == 0) return new CounterValue[0];
        IntPtr buffer = Marshal.AllocHGlobal((int)size);
        try {
            if (PdhGetFormattedCounterArrayW(counter, PDH_FMT_DOUBLE | PDH_FMT_NOCAP100, ref size, out count, buffer) != 0) {
                return new CounterValue[0];
            }
            int stride = Marshal.SizeOf(typeof(PDH_FMT_COUNTERVALUE_ITEM_W));
            var results = new List<CounterValue>((int)count);
            for (int i = 0; i < count; i++) {
                IntPtr item = new IntPtr(buffer.ToInt64() + (long)i * stride);
                var value = (PDH_FMT_COUNTERVALUE_ITEM_W)Marshal.PtrToStructure(item, typeof(PDH_FMT_COUNTERVALUE_ITEM_W));
                if (value.FmtValue.CStatus != PDH_CSTATUS_VALID_DATA && value.FmtValue.CStatus != PDH_CSTATUS_NEW_DATA) continue;
                var result = new CounterValue();
                result.Name = value.szName == IntPtr.Zero ? "" : Marshal.PtrToStringUni(value.szName);
                result.Value = value.FmtValue.doubleValue;
                results.Add(result);
            }
            return results.ToArray();
        } finally {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public void Dispose() {
        if (query != IntPtr.Zero) { PdhCloseQuery(query); query = IntPtr.Zero; }
        counters.Clear();
    }
}

public sealed class Adapter {
    public string Luid;
    public string Name;
    public uint Flags;
}

public static class AdapterEnum {
    [StructLayout(LayoutKind.Sequential)]
    struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    struct D3DKMT_ADAPTERINFO {
        public uint hAdapter;
        public LUID AdapterLuid;
        public uint NumOfSources;
        public uint bPrecisePresentRegionsPreferred;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct D3DKMT_ENUMADAPTERS2 { public uint NumAdapters; public IntPtr pAdapters; }

    // Filter is a 64-bit bitfield: bit 0 includes compute-only adapters (an NPU
    // is compute-only and is invisible to every other enumeration path).
    [StructLayout(LayoutKind.Sequential)]
    struct D3DKMT_ENUMADAPTERS3 { public ulong Filter; public uint NumAdapters; public IntPtr pAdapters; }

    [StructLayout(LayoutKind.Sequential)]
    struct D3DKMT_QUERYADAPTERINFO {
        public uint hAdapter;
        public int Type;
        public IntPtr pPrivateDriverData;
        public uint PrivateDriverDataSize;
    }

    [DllImport("gdi32.dll")] static extern int D3DKMTEnumAdapters2(ref D3DKMT_ENUMADAPTERS2 p);
    [DllImport("gdi32.dll")] static extern int D3DKMTEnumAdapters3(ref D3DKMT_ENUMADAPTERS3 p);
    [DllImport("gdi32.dll")] static extern int D3DKMTQueryAdapterInfo(ref D3DKMT_QUERYADAPTERINFO p);

    public const uint FlagRenderSupported = 1u << 0;
    public const uint FlagDisplaySupported = 1u << 1;
    public const uint FlagSoftwareDevice = 1u << 2;
    public const uint FlagHybridDiscrete = 1u << 4;
    public const uint FlagHybridIntegrated = 1u << 5;
    public const uint FlagComputeOnly = 1u << 11;

    public static Adapter[] Enumerate() {
        Adapter[] adapters = EnumerateModern();
        if (adapters.Length > 0) return adapters;
        return EnumerateLegacy();
    }

    // Windows 11 / late Windows 10. NumAdapters is an in/out capacity, and the
    // call reports no required size for a null buffer, so start generous.
    static Adapter[] EnumerateModern() {
        int capacity = 64;
        int stride = Marshal.SizeOf(typeof(D3DKMT_ADAPTERINFO));
        IntPtr buffer = Marshal.AllocHGlobal(stride * capacity);
        try {
            var enumeration = new D3DKMT_ENUMADAPTERS3();
            enumeration.Filter = 1;
            enumeration.NumAdapters = (uint)capacity;
            enumeration.pAdapters = buffer;
            if (D3DKMTEnumAdapters3(ref enumeration) != 0) return new Adapter[0];
            return Describe(buffer, stride, enumeration.NumAdapters);
        } catch (EntryPointNotFoundException) {
            return new Adapter[0];
        } finally {
            Marshal.FreeHGlobal(buffer);
        }
    }

    // Older Windows: display adapters only, which is the honest limit there.
    static Adapter[] EnumerateLegacy() {
        var probe = new D3DKMT_ENUMADAPTERS2();
        probe.NumAdapters = 0;
        probe.pAdapters = IntPtr.Zero;
        if (D3DKMTEnumAdapters2(ref probe) != 0 || probe.NumAdapters == 0) return new Adapter[0];

        int stride = Marshal.SizeOf(typeof(D3DKMT_ADAPTERINFO));
        IntPtr buffer = Marshal.AllocHGlobal(stride * (int)probe.NumAdapters);
        try {
            probe.pAdapters = buffer;
            if (D3DKMTEnumAdapters2(ref probe) != 0) return new Adapter[0];
            return Describe(buffer, stride, probe.NumAdapters);
        } finally {
            Marshal.FreeHGlobal(buffer);
        }
    }

    static Adapter[] Describe(IntPtr buffer, int stride, uint count) {
        var results = new List<Adapter>((int)count);
        for (int i = 0; i < count; i++) {
            IntPtr item = new IntPtr(buffer.ToInt64() + (long)i * stride);
            var info = (D3DKMT_ADAPTERINFO)Marshal.PtrToStructure(item, typeof(D3DKMT_ADAPTERINFO));
            var adapter = new Adapter();
            adapter.Luid = string.Format("0x{0:x8}_0x{1:x8}", info.AdapterLuid.HighPart, info.AdapterLuid.LowPart);
            adapter.Name = QueryName(info.hAdapter);
            adapter.Flags = QueryFlags(info.hAdapter);
            results.Add(adapter);
        }
        return results.ToArray();
    }

    // KMTQAITYPE_ADAPTERREGISTRYINFO: four MAX_PATH wide strings, the first of
    // which is the adapter description. Compute-only devices often leave it empty.
    static string QueryName(uint hAdapter) {
        int size = 260 * 2 * 4;
        IntPtr data = Marshal.AllocHGlobal(size);
        try {
            var request = new D3DKMT_QUERYADAPTERINFO();
            request.hAdapter = hAdapter;
            request.Type = 8;
            request.pPrivateDriverData = data;
            request.PrivateDriverDataSize = (uint)size;
            if (D3DKMTQueryAdapterInfo(ref request) != 0) return "";
            string name = Marshal.PtrToStringUni(data);
            return name == null ? "" : name.Trim();
        } finally {
            Marshal.FreeHGlobal(data);
        }
    }

    // KMTQAITYPE_ADAPTERTYPE: D3DKMT_ADAPTERTYPE bitfield.
    static uint QueryFlags(uint hAdapter) {
        IntPtr data = Marshal.AllocHGlobal(4);
        try {
            Marshal.WriteInt32(data, 0);
            var request = new D3DKMT_QUERYADAPTERINFO();
            request.hAdapter = hAdapter;
            request.Type = 15;
            request.pPrivateDriverData = data;
            request.PrivateDriverDataSize = 4;
            if (D3DKMTQueryAdapterInfo(ref request) != 0) return 0;
            return (uint)Marshal.ReadInt32(data);
        } finally {
            Marshal.FreeHGlobal(data);
        }
    }
}

}
'@

function Initialize-AcceleratorNative {
    [CmdletBinding()]
    param()

    if ('UtilsGpuMonitor.Native.AdapterEnum' -as [type]) { return $true }
    try {
        Add-Type -TypeDefinition $script:AcceleratorNativeSource -ErrorAction Stop
        return $true
    } catch {
        Write-Verbose ('Accelerator support unavailable: ' + $_.Exception.Message)
        return $false
    }
}

function Get-AcceleratorMemoryLimit {
    [CmdletBinding()]
    param()

    if ($script:AcceleratorMemoryLimits) { return $script:AcceleratorMemoryLimits }

    $physical = 0L
    try { $physical = [int64](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory } catch { }

    # Windows exposes half of system memory to a WDDM adapter as shared memory,
    # which is the whole budget for an integrated GPU or an NPU.
    $script:AcceleratorMemoryLimits = [pscustomobject]@{
        physical_bytes = $physical
        shared_limit_bytes = [int64]($physical / 2)
    }
    return $script:AcceleratorMemoryLimits
}

function Get-AcceleratorDisplayName {
    param([string]$Name, [string]$Kind)

    if ($Name) { return $Name }
    if ($Kind -eq 'npu') {
        # The WDDM description of a compute-only device is usually blank; Plug
        # and Play still knows it as, for example, "Intel(R) AI Boost".
        try {
            $device = @(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='ComputeAccelerator'" -ErrorAction Stop |
                Where-Object { $_.Name } | Select-Object -First 1)
            if ($device.Count -gt 0) { return [string]$device[0].Name }
        } catch { }
        return 'Neural processor'
    }
    return 'Graphics adapter'
}

function Get-AcceleratorInventory {
    <#
    .SYNOPSIS
        Enumerates WDDM adapters and classifies each as a discrete GPU, an
        integrated GPU or an NPU. Absent classes simply do not appear.
    #>
    [CmdletBinding()]
    param(
        [switch]$Force,
        [ValidateRange(1, 3600)][int]$CacheSeconds = 300
    )

    if (-not $Force -and $script:AcceleratorInventory -and
        ([DateTime]::UtcNow - $script:AcceleratorInventoryStamp).TotalSeconds -lt $CacheSeconds) {
        return $script:AcceleratorInventory
    }

    $inventory = @()
    if (Initialize-AcceleratorNative) {
        try {
            $adapters = @([UtilsGpuMonitor.Native.AdapterEnum]::Enumerate())
            $renderers = @($adapters | Where-Object {
                ($_.Flags -band [UtilsGpuMonitor.Native.AdapterEnum]::FlagSoftwareDevice) -eq 0 -and
                ($_.Flags -band [UtilsGpuMonitor.Native.AdapterEnum]::FlagRenderSupported) -ne 0
            })

            foreach ($adapter in $renderers) {
                $flags = [uint32]$adapter.Flags
                $kind = if (($flags -band [UtilsGpuMonitor.Native.AdapterEnum]::FlagComputeOnly) -ne 0) { 'npu' }
                        elseif (($flags -band [UtilsGpuMonitor.Native.AdapterEnum]::FlagHybridIntegrated) -ne 0) { 'igpu' }
                        elseif (($flags -band [UtilsGpuMonitor.Native.AdapterEnum]::FlagHybridDiscrete) -ne 0) { 'dgpu' }
                        elseif ($adapter.Name -match '(?i)\b(UHD|Iris|Vega)\b.*Graphics|Radeon\(TM\) Graphics|Radeon Graphics$') { 'igpu' }
                        else { 'dgpu' }

                $inventory += [pscustomobject][ordered]@{
                    luid = ([string]$adapter.Luid).ToLowerInvariant()
                    name = ConvertTo-SafeField (Get-AcceleratorDisplayName -Name $adapter.Name -Kind $kind)
                    kind = $kind
                    flags = $flags
                }
            }

            # A machine with exactly one graphics adapter has no hybrid pairing to
            # read, so trust the single adapter rather than a name heuristic.
            $graphics = @($inventory | Where-Object { $_.kind -ne 'npu' })
            if ($graphics.Count -eq 1) { $graphics[0].kind = 'dgpu' }
        } catch {
            Write-Verbose ('Adapter enumeration failed: ' + $_.Exception.Message)
        }
    }

    $script:AcceleratorInventory = @($inventory)
    $script:AcceleratorInventoryStamp = [DateTime]::UtcNow
    return $script:AcceleratorInventory
}

function New-AcceleratorSampler {
    <#
    .SYNOPSIS
        Opens the long-lived PDH query used for every accelerator reading.
        Returns $null when the GPU counter sets are not present.
    #>
    [CmdletBinding()]
    param()

    if (-not (Initialize-AcceleratorNative)) { return $null }
    try {
        $sampler = New-Object UtilsGpuMonitor.Native.PdhSampler
    } catch {
        Write-Verbose ('PDH query could not be opened: ' + $_.Exception.Message)
        return $null
    }

    $added = $sampler.Add('engine', '\GPU Engine(*)\Utilization Percentage')
    $null = $sampler.Add('adapter_dedicated', '\GPU Adapter Memory(*)\Dedicated Usage')
    $null = $sampler.Add('adapter_shared', '\GPU Adapter Memory(*)\Shared Usage')
    $null = $sampler.Add('process_memory', '\GPU Process Memory(*)\Total Committed')
    if (-not $added) {
        $sampler.Dispose()
        return $null
    }

    # Rate counters need a baseline collection before they can report anything.
    $null = $sampler.Collect()
    return $sampler
}

function Format-CompactSize {
    param([AllowNull()][object]$Bytes)

    $value = 0.0
    if ($null -ne $Bytes) { $value = [double]$Bytes }
    if ($value -le 0) { return '0' }
    if ($value -ge 1GB) { return ('{0:0.0}G' -f ($value / 1GB)) }
    if ($value -ge 1MB) { return ('{0:0}M' -f ($value / 1MB)) }
    return ('{0:0}K' -f ($value / 1KB))
}

function Format-ResidentSummary {
    <#
    .SYNOPSIS
        Renders "who is on this device" as one short display line.
    .DESCRIPTION
        Entries are ranked, so when they do not all fit the line drops whole
        trailing entries rather than letting the skin clip mid-glyph. A budget
        in characters keeps this free; the smoke test measures the real rendered
        width and fails if the budget is ever too generous.
    #>
    param([AllowNull()][object[]]$Rows, [int]$Take = 3, [int]$MaxLength = 42)

    $items = @($Rows | Select-Object -First $Take | ForEach-Object {
        if ($_.memory_bytes -gt 0) { '{0} {1}' -f $_.name, (Format-CompactSize $_.memory_bytes) }
        else { '{0} {1:0.#}%' -f $_.name, $_.utilization_percent }
    })
    if ($items.Count -eq 0) { return 'idle' }

    $separator = '   '
    $line = ''
    foreach ($item in $items) {
        $candidate = if ($line) { $line + $separator + $item } else { $item }
        if ($candidate.Length -gt $MaxLength -and $line) { break }
        $line = $candidate
    }
    # A single entry longer than the budget still has to be shown; it is the
    # largest consumer, and naming it partially beats naming nothing.
    return $line
}

function Get-AcceleratorTelemetry {
    <#
    .SYNOPSIS
        One cheap sample of every present accelerator: utilization, memory, the
        busiest engine and the processes resident on the device.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Sampler,
        [object[]]$Inventory,
        [hashtable]$ProcessNames,
        [ValidateRange(1, 10)][int]$Top = 3
    )

    $timestamp = [DateTime]::UtcNow.ToString('o')
    if (-not $PSBoundParameters.ContainsKey('Inventory')) { $Inventory = Get-AcceleratorInventory }
    if (-not $ProcessNames) { $ProcessNames = @{} }

    $devices = @()
    if ($null -eq $Sampler) { return $devices }
    if (-not $Sampler.Collect()) { return $devices }

    $instance = [regex]::new('^pid_(\d+)_luid_(0x[0-9a-f]+_0x[0-9a-f]+)_phys_\d+_eng_\d+_engtype_(.+)$', 'IgnoreCase')
    $adapterInstance = [regex]::new('^luid_(0x[0-9a-f]+_0x[0-9a-f]+)_phys_\d+$', 'IgnoreCase')
    $processInstance = [regex]::new('^pid_(\d+)_luid_(0x[0-9a-f]+_0x[0-9a-f]+)_phys_\d+$', 'IgnoreCase')

    $engineRows = @()
    foreach ($counter in $Sampler.Read('engine')) {
        $match = $instance.Match($counter.Name)
        if (-not $match.Success) { continue }
        if ($counter.Value -le 0) { continue }
        $engineRows += [pscustomobject]@{
            pid = [int]$match.Groups[1].Value
            luid = $match.Groups[2].Value.ToLowerInvariant()
            engine = $match.Groups[3].Value
            value = [double]$counter.Value
        }
    }

    $memoryByLuid = @{}
    foreach ($key in @('adapter_dedicated', 'adapter_shared')) {
        foreach ($counter in $Sampler.Read($key)) {
            $match = $adapterInstance.Match($counter.Name)
            if (-not $match.Success) { continue }
            $luid = $match.Groups[1].Value.ToLowerInvariant()
            if (-not $memoryByLuid.ContainsKey($luid)) { $memoryByLuid[$luid] = 0.0 }
            $memoryByLuid[$luid] += [double]$counter.Value
        }
    }

    $processMemory = @{}
    foreach ($counter in $Sampler.Read('process_memory')) {
        $match = $processInstance.Match($counter.Name)
        if (-not $match.Success -or $counter.Value -le 0) { continue }
        $key = '{0}|{1}' -f $match.Groups[2].Value.ToLowerInvariant(), $match.Groups[1].Value
        if (-not $processMemory.ContainsKey($key)) { $processMemory[$key] = 0.0 }
        $processMemory[$key] += [double]$counter.Value
    }

    $limits = Get-AcceleratorMemoryLimit

    foreach ($adapter in $Inventory) {
        $rows = @($engineRows | Where-Object { $_.luid -eq $adapter.luid })

        # Windows reports utilization per process per engine. The device-level
        # number is the busiest engine type, not the sum, which is what Task
        # Manager shows and the only reading that stays inside 0-100.
        $utilization = 0.0
        $busiestEngine = ''
        foreach ($group in ($rows | Group-Object engine)) {
            $sum = [double](($group.Group | Measure-Object value -Sum).Sum)
            if ($sum -gt $utilization) { $utilization = $sum; $busiestEngine = $group.Name }
        }
        $utilization = [Math]::Round([Math]::Min([Math]::Max($utilization, 0), 100), 1)

        $memoryUsed = 0.0
        if ($memoryByLuid.ContainsKey($adapter.luid)) { $memoryUsed = [double]$memoryByLuid[$adapter.luid] }

        $processes = @()
        $seen = @{}
        foreach ($row in $rows) { $seen[$row.pid] = $true }
        foreach ($key in $processMemory.Keys) {
            $parts = $key -split '\|'
            if ($parts[0] -eq $adapter.luid) { $seen[[int]$parts[1]] = $true }
        }
        foreach ($processId in $seen.Keys) {
            $share = @($rows | Where-Object { $_.pid -eq $processId })
            $processUtilization = 0.0
            foreach ($group in ($share | Group-Object engine)) {
                $sum = [double](($group.Group | Measure-Object value -Sum).Sum)
                if ($sum -gt $processUtilization) { $processUtilization = $sum }
            }
            $memoryKey = '{0}|{1}' -f $adapter.luid, $processId
            $processes += [pscustomobject][ordered]@{
                pid = $processId
                name = ConvertTo-SafeField $(if ($ProcessNames.ContainsKey($processId)) { $ProcessNames[$processId] } else { "pid $processId" })
                utilization_percent = [Math]::Round([Math]::Min($processUtilization, 100), 1)
                memory_bytes = [int64]$(if ($processMemory.ContainsKey($memoryKey)) { $processMemory[$memoryKey] } else { 0 })
            }
        }
        $processes = @($processes |
            Sort-Object -Property @{ Expression = 'memory_bytes'; Descending = $true }, @{ Expression = 'utilization_percent'; Descending = $true } |
            Select-Object -First $Top)

        # Only a discrete GPU has a memory budget of its own; integrated devices
        # borrow from system memory, so report the shared budget rather than a
        # fabricated total.
        $memoryTotal = if ($adapter.kind -eq 'dgpu') { 0 } else { [int64]$limits.shared_limit_bytes }

        $detail = if ($busiestEngine) { '{0} {1:0}%' -f $busiestEngine, $utilization } else { 'idle' }

        $devices += [pscustomobject][ordered]@{
            timestamp_utc = $timestamp
            status = 'ok'
            kind = $adapter.kind
            luid = $adapter.luid
            name = $adapter.name
            utilization_percent = ('{0:0.#}' -f $utilization)
            temperature_c = ''
            memory_used_mb = $(if ($memoryUsed -gt 0) { '{0:0}' -f ($memoryUsed / 1MB) } else { '0' })
            memory_total_mb = $(if ($memoryTotal -gt 0) { '{0:0}' -f ($memoryTotal / 1MB) } else { '' })
            power_w = ''
            power_limit_w = ''
            error = $detail
            engine = $busiestEngine
            processes = $processes
            resident = ConvertTo-SafeField (Format-ResidentSummary -Rows $processes -Take $Top)
        }
    }

    return $devices
}

function New-AbsentAcceleratorSample {
    param(
        [Parameter(Mandatory)][ValidateSet('dgpu', 'igpu', 'npu')][string]$Kind,
        [string]$Message = 'not present on this machine'
    )

    $label = switch ($Kind) {
        'igpu' { 'Integrated GPU' }
        'npu'  { 'NPU' }
        default { 'GPU' }
    }
    [pscustomobject][ordered]@{
        timestamp_utc = [DateTime]::UtcNow.ToString('o')
        status = 'absent'
        kind = $Kind
        luid = ''
        name = "$label not detected"
        utilization_percent = '0'
        temperature_c = ''
        memory_used_mb = '0'
        memory_total_mb = ''
        power_w = ''
        power_limit_w = ''
        error = (ConvertTo-SafeField $Message)
        engine = ''
        processes = @()
        resident = ''
    }
}

function Get-ProcessTelemetry {
    <#
    .SYNOPSIS
        Top memory and CPU consumers, plus the pid-to-name map the accelerator
        readings need. One Get-Process call serves all three.
    .DESCRIPTION
        CPU percentage is derived from the change in processor time since the
        previous call, so the first call after start reports memory only.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][hashtable]$Previous,
        [ValidateRange(1, 10)][int]$Top = 3
    )

    $now = [DateTime]::UtcNow
    $names = @{}
    $cpuTime = @{}
    $memory = @()
    $processorCount = [Math]::Max([Environment]::ProcessorCount, 1)

    foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
        try {
            $names[$process.Id] = $process.ProcessName
            $memory += [pscustomobject][ordered]@{
                pid = $process.Id
                name = $process.ProcessName
                memory_bytes = [int64]$process.WorkingSet64
                utilization_percent = 0.0
            }
            $total = $process.TotalProcessorTime
            if ($null -ne $total) { $cpuTime[$process.Id] = $total.TotalSeconds }
        } catch {
            # A process that exits mid-enumeration is not an error worth logging.
        }
    }

    $cpu = @()
    if ($Previous -and $Previous.ContainsKey('cpu_time') -and $Previous.ContainsKey('sampled_at')) {
        $elapsed = ($now - [DateTime]$Previous['sampled_at']).TotalSeconds
        if ($elapsed -gt 0.5) {
            $previousCpu = [hashtable]$Previous['cpu_time']
            foreach ($processId in $cpuTime.Keys) {
                if (-not $previousCpu.ContainsKey($processId)) { continue }
                $delta = [double]$cpuTime[$processId] - [double]$previousCpu[$processId]
                if ($delta -le 0) { continue }
                $percent = [Math]::Round(($delta / $elapsed / $processorCount) * 100, 1)
                if ($percent -le 0) { continue }
                $cpu += [pscustomobject][ordered]@{
                    pid = $processId
                    name = $(if ($names.ContainsKey($processId)) { $names[$processId] } else { "pid $processId" })
                    memory_bytes = [int64]0
                    utilization_percent = [Math]::Min($percent, 100)
                }
            }
        }
    }

    return [pscustomobject][ordered]@{
        sampled_at = $now.ToString('o')
        names = $names
        memory = @($memory | Sort-Object memory_bytes -Descending | Select-Object -First $Top)
        cpu = @($cpu | Sort-Object utilization_percent -Descending | Select-Object -First $Top)
        state = @{ cpu_time = $cpuTime; sampled_at = $now }
    }
}

$script:AcceleratorToolchain = $null
$script:AcceleratorToolchainStamp = [DateTime]::MinValue

function Test-RegisteredRuntime {
    <#
    .SYNOPSIS
        True when a driver-registered runtime is both declared and present.
    .DESCRIPTION
        A registry entry left behind by an uninstalled driver still names a path,
        so the file has to exist before the runtime counts as usable. LoaderName
        is the system-wide loader the runtime is reached through; without it the
        vendor library cannot be loaded either.
    #>
    param(
        [AllowNull()][object]$Properties,
        [Parameter(Mandatory)][string]$ValueName,
        [string]$LoaderName
    )

    if (-not $Properties) { return $false }
    if ($Properties.PSObject.Properties.Name -notcontains $ValueName) { return $false }
    $path = @($Properties.$ValueName) | Select-Object -First 1
    if (-not $path) { return $false }
    # Driver-written values are padded and can carry trailing NULs, which
    # Test-Path rejects outright as illegal path characters.
    $path = ([string]$path).Trim([char]0, ' ', "`t", "`r", "`n")
    if (-not $path) { return $false }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    if ($LoaderName) {
        $loader = Join-Path $env:WINDIR "System32\$LoaderName"
        if (-not (Test-Path -LiteralPath $loader -PathType Leaf)) { return $false }
    }
    return $true
}

function Get-DriverRegistryEntry {
    <#
    .SYNOPSIS
        Finds the driver key for an adapter by its description.
    .DESCRIPTION
        Keys survive the hardware: this machine still lists an AMD Radeon entry
        for a card that is not installed. Callers pass names taken from the live
        adapter inventory, so a stale key is never matched.
    #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$ClassGuid)

    $root = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$ClassGuid"
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    foreach ($key in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        if (-not $properties) { continue }
        if ($properties.PSObject.Properties.Name -notcontains 'DriverDesc') { continue }
        if ([string]$properties.DriverDesc -eq $Name) { return $properties }
    }
    return $null
}

function Format-DriverVersion {
    param([AllowNull()][string]$Version)
    if (-not $Version) { return '' }
    $parts = @($Version -split '\.')
    # Windows pads vendor versions into a four-part number; the trailing two
    # parts are the version the vendor actually publishes.
    if ($parts.Count -eq 4) { return ($parts[2] + '.' + $parts[3]) }
    return $Version
}

function Get-NvidiaRuntimeVersion {
    <#
    .SYNOPSIS
        Driver and CUDA version from a single nvidia-smi call.
    .DESCRIPTION
        Called only when the toolchain cache expires, not on the sampling path.
        CUDA version is not available from --query-gpu, so this uses the XML
        report; a failure degrades to the version-less labels.
    #>
    param([string]$NvidiaSmiPath)

    try {
        $smi = Resolve-NvidiaSmi -Path $NvidiaSmiPath
        $raw = (& $smi '-q' '-x' 2>$null) -join [Environment]::NewLine
        if (-not $raw) { return $null }

        # nvidia-smi declares an external DTD that is not shipped beside the
        # output, so the default resolving reader fails on the DOCTYPE.
        $settings = New-Object Xml.XmlReaderSettings
        $settings.DtdProcessing = [Xml.DtdProcessing]::Ignore
        $settings.XmlResolver = $null
        $reader = [Xml.XmlReader]::Create((New-Object IO.StringReader($raw)), $settings)
        try {
            $xml = New-Object Xml.XmlDocument
            $xml.Load($reader)
        } finally {
            $reader.Close()
        }

        $root = $xml.DocumentElement
        $driver = $root.SelectSingleNode('driver_version')
        $cuda = $root.SelectSingleNode('cuda_version')
        return [pscustomobject]@{
            driver = ConvertTo-SafeField $(if ($driver) { $driver.InnerText } else { '' })
            cuda = ConvertTo-SafeField $(if ($cuda) { $cuda.InnerText } else { '' })
        }
    } catch {
        Write-Verbose ('nvidia-smi toolchain query failed: ' + $_.Exception.Message)
        return $null
    }
}

$script:SitePackagesRoots = $null

function Get-SitePackagesRoot {
    <#
    .SYNOPSIS
        Python environments on this machine, found without walking the disk.
    .DESCRIPTION
        Accelerator SDKs are now normally pip-installed into a virtual
        environment rather than installed system-wide, so looking only in
        System32, a vendor environment variable and Program Files reports a
        working toolchain as missing.

        Each pattern is a wildcard path, not a recursive search: every wildcard
        segment costs one directory listing, so the whole set resolves in
        fractions of a second where an -Recurse scan of the profile took minutes.
    #>
    [CmdletBinding()]
    param([switch]$Force)

    if (-not $Force -and $null -ne $script:SitePackagesRoots) { return $script:SitePackagesRoots }

    $patterns = @(
        (Join-Path $env:LOCALAPPDATA '*\*\Lib\site-packages'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\*\Lib\site-packages'),
        (Join-Path $env:APPDATA 'Python\Python*\site-packages'),
        (Join-Path $env:USERPROFILE '.venvs\*\Lib\site-packages'),
        (Join-Path $env:USERPROFILE '*\.venv\Lib\site-packages'),
        (Join-Path $env:USERPROFILE 'miniconda3\envs\*\Lib\site-packages'),
        (Join-Path $env:USERPROFILE 'anaconda3\envs\*\Lib\site-packages'),
        (Join-Path $env:SystemDrive '\Python*\Lib\site-packages')
    )

    $roots = @()
    foreach ($pattern in $patterns) {
        $roots += @(Get-Item -Path $pattern -ErrorAction SilentlyContinue |
            Where-Object { $_.PSIsContainer } | ForEach-Object { $_.FullName })
    }
    $script:SitePackagesRoots = @($roots | Sort-Object -Unique)
    return $script:SitePackagesRoots
}

function Find-SitePackagePayload {
    <#
    .SYNOPSIS
        First matching file under any discovered site-packages directory.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RelativePattern)

    foreach ($root in (Get-SitePackagesRoot)) {
        $hit = @(Get-Item -Path (Join-Path $root $RelativePattern) -ErrorAction SilentlyContinue) |
            Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function Get-OpenVinoRuntime {
    <#
    .SYNOPSIS
        Whether OpenVINO is usable, which devices it can drive, and its version.
    .DESCRIPTION
        The device plugins are the part that matters: OpenVINO without
        openvino_intel_npu_plugin.dll cannot target the NPU, which is the main
        reason to have it on a machine with one.
    #>
    [CmdletBinding()]
    param()

    $system32 = Join-Path $env:WINDIR 'System32'
    $result = [pscustomobject][ordered]@{
        present = $false; version = ''; npu = $false; gpu = $false; source = ''
    }

    $libraryDirectory = ''
    if (Test-Path -LiteralPath (Join-Path $system32 'openvino.dll') -PathType Leaf) {
        $libraryDirectory = $system32
        $result.source = 'system'
    }
    if (-not $libraryDirectory) {
        foreach ($scope in @('Machine', 'User')) {
            $root = [Environment]::GetEnvironmentVariable('INTEL_OPENVINO_DIR', $scope)
            if ($root -and (Test-Path -LiteralPath $root)) {
                $libraryDirectory = $root
                $result.source = 'INTEL_OPENVINO_DIR'
                break
            }
        }
    }
    if (-not $libraryDirectory) {
        $installed = @(Get-Item (Join-Path $env:ProgramFiles 'Intel\openvino*') -ErrorAction SilentlyContinue) |
            Select-Object -First 1
        if ($installed) { $libraryDirectory = $installed.FullName; $result.source = 'Program Files' }
    }
    if (-not $libraryDirectory) {
        $payload = Find-SitePackagePayload -RelativePattern 'openvino\libs\openvino.dll'
        if ($payload) {
            $libraryDirectory = Split-Path -Parent $payload.FullName
            $result.source = 'pip'
            $sitePackages = Split-Path -Parent (Split-Path -Parent $libraryDirectory)
            $info = @(Get-ChildItem -LiteralPath $sitePackages -Directory -Filter 'openvino-*.dist-info' -ErrorAction SilentlyContinue) |
                Select-Object -First 1
            if ($info) {
                $result.version = ($info.Name -replace '^openvino-', '' -replace '\.dist-info$', '')
            }
        }
    }
    if (-not $libraryDirectory) { return $result }

    $result.present = $true
    # A system or archive install keeps its plugins in a runtime subdirectory;
    # a wheel keeps them beside the core library.
    foreach ($candidate in @($libraryDirectory,
                             (Join-Path $libraryDirectory 'runtime\bin\intel64\Release'),
                             (Join-Path $libraryDirectory 'runtime\bin\intel64'))) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        if (Test-Path -LiteralPath (Join-Path $candidate 'openvino_intel_npu_plugin.dll') -PathType Leaf) { $result.npu = $true }
        if (Test-Path -LiteralPath (Join-Path $candidate 'openvino_intel_gpu_plugin.dll') -PathType Leaf) { $result.gpu = $true }
        if ($result.npu -or $result.gpu) { break }
    }
    return $result
}

$script:WslToolchain = $null
$script:WslToolchainCachePath = Join-Path $env:LOCALAPPDATA 'Utils\GpuMonitor\wsl-toolchain.json'

function Get-WslToolchain {
    <#
    .SYNOPSIS
        CUDA build tooling on the WSL side of this machine.
    .DESCRIPTION
        A Windows-only search reports a working toolchain as missing whenever
        the work actually happens in WSL, which is the normal arrangement: nvcc
        is build-only and cuDNN ships inside PyTorch wheels per virtual
        environment, so neither ever appears on the Windows side.

        Deliberately skipped when no distribution is already running. Starting a
        virtual machine to draw a panel row would cost seconds and spin up a VM
        the user did not ask for; an idle WSL simply reports "not running".
    #>
    [CmdletBinding()]
    param([switch]$Force, [ValidateRange(60, 86400)][int]$CacheSeconds = 3600)

    if (-not $Force -and $script:WslToolchain -and
        ([DateTime]::UtcNow - $script:WslToolchain.checked_at).TotalSeconds -lt $CacheSeconds) {
        return $script:WslToolchain
    }

    $result = [pscustomobject][ordered]@{
        checked_at = [DateTime]::UtcNow
        available = $false
        reason = ''
        distro = ''
        cuda = ''
        nvcc = ''
        cudnn = ''
    }

    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) {
        $result.reason = 'WSL not installed'
        $script:WslToolchain = $result
        return $result
    }

    try {
        # -l output is UTF-16; reading it as text leaves NUL bytes between the
        # characters, which turns every name into an unmatchable string.
        $running = @(& $wsl.Source '-l' '--running' '-q' 2>$null |
            ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
        if ($running.Count -eq 0) {
            # An idle WSL is the common state on a box where builds happen there,
            # and starting a VM to draw a panel row is not an option. A toolchain
            # found on an earlier probe did not vanish because the VM went to
            # sleep, so fall back to the last successful probe instead of
            # flipping nvcc and cuDNN back into gaps for the rest of the day.
            $cached = $null
            try {
                if (Test-Path -LiteralPath $script:WslToolchainCachePath -PathType Leaf) {
                    $cached = Get-Content -LiteralPath $script:WslToolchainCachePath -Raw -ErrorAction Stop | ConvertFrom-Json
                }
            } catch { $cached = $null }
            $probedAt = [DateTime]::MinValue
            if ($cached -and $cached.PSObject.Properties['probed_at']) {
                [void][DateTime]::TryParse([string]$cached.probed_at, [ref]$probedAt)
            }
            # A week is far longer than any toolchain-change cadence but short
            # enough that an uninstalled WSL stops being reported eventually.
            if ($cached -and ([DateTime]::UtcNow - $probedAt.ToUniversalTime()).TotalDays -le 7) {
                foreach ($field in @('distro', 'cuda', 'nvcc', 'cudnn')) {
                    $prop = $cached.PSObject.Properties[$field]
                    if ($prop) { $result.$field = ConvertTo-SafeField $prop.Value }
                }
                $result.available = $true
                $result.reason = 'idle; cached probe'
            } else {
                $result.reason = 'no distribution running'
            }
            $script:WslToolchain = $result
            return $result
        }
        $result.distro = $running[0]

        # Nested quoting through wsl.exe mangles the script; base64 makes the
        # payload alphanumeric so it survives both shells untouched.
        $probe = @'
N=$(command -v nvcc 2>/dev/null)
[ -z "$N" ] && N=$(ls -d /usr/local/cuda*/bin/nvcc 2>/dev/null | sort -r | head -1)
V=""
[ -n "$N" ] && V=$("$N" --version 2>/dev/null | sed -n 's/.*release \([0-9.]*\).*/\1/p')
C=$(find "$HOME" -maxdepth 7 -type d -path '*nvidia/cudnn' -print -quit 2>/dev/null)
echo "nvcc=$N"
echo "cuda=$V"
echo "cudnn=$C"
'@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($probe))
        foreach ($line in @(& $wsl.Source '-e' 'bash' '-c' "echo $encoded | base64 -d | bash" 2>$null)) {
            $text = ($line -replace "`0", '').Trim()
            if ($text -match '^nvcc=(.*)$') { $result.nvcc = ConvertTo-SafeField $Matches[1] }
            elseif ($text -match '^cuda=(.*)$') { $result.cuda = ConvertTo-SafeField $Matches[1] }
            elseif ($text -match '^cudnn=(.*)$') { $result.cudnn = ConvertTo-SafeField $Matches[1] }
        }
        $result.available = $true

        # Persist the successful probe so the next run - or the next supervisor
        # process - can answer while WSL is idle without starting the VM.
        try {
            Write-AtomicJson -Path $script:WslToolchainCachePath -Value ([ordered]@{
                contract = 'utils.gpu-monitor.wsl-toolchain.v1'
                probed_at = [DateTime]::UtcNow.ToString('o')
                distro = $result.distro
                cuda = $result.cuda
                nvcc = $result.nvcc
                cudnn = $result.cudnn
            })
        } catch { }
    } catch {
        $result.reason = ConvertTo-SafeField $_.Exception.Message
    }

    $script:WslToolchain = $result
    return $result
}

function Get-AcceleratorToolchain {
    <#
    .SYNOPSIS
        What each present accelerator can actually be programmed with, and the
        notable pieces that are missing.
    .DESCRIPTION
        Reads the per-adapter driver registrations rather than probing SDKs, so
        the answer is authoritative and costs no process spawn. The result is
        cached because none of it changes without a driver or SDK install.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Inventory,
        [string]$NvidiaSmiPath,
        [switch]$Force,
        [ValidateRange(60, 86400)][int]$CacheSeconds = 3600
    )

    if (-not $Force -and $script:AcceleratorToolchain -and
        ([DateTime]::UtcNow - $script:AcceleratorToolchainStamp).TotalSeconds -lt $CacheSeconds) {
        return $script:AcceleratorToolchain
    }
    if (-not $PSBoundParameters.ContainsKey('Inventory')) { $Inventory = Get-AcceleratorInventory }
    # Re-resolve Python environments whenever the toolchain is re-detected, so a
    # newly created venv is picked up on the same schedule as everything else.
    $null = Get-SitePackagesRoot -Force

    $displayClass = '{4d36e968-e325-11ce-bfc1-08002be10318}'
    $computeClass = '{f01a9d53-3ff6-48d2-9f97-c8a7004be10c}'
    $system32 = Join-Path $env:WINDIR 'System32'
    function Test-System32 { param([string]$Name) Test-Path -LiteralPath (Join-Path $system32 $Name) -PathType Leaf }

    $devices = @()
    $gaps = @()
    # Things absent from Windows but present where they are actually used. They
    # are reported, not counted as gaps: nvcc is build-only and cuDNN ships
    # per-venv, so neither belongs on the Windows side of a split stack.
    $elsewhere = @()
    $wsl = Get-WslToolchain
    $hasNvidia = $false
    $hasIntelCompute = $false

    foreach ($kind in @('dgpu', 'igpu', 'npu')) {
        $adapter = @($Inventory | Where-Object { $_.kind -eq $kind } | Select-Object -First 1)
        if ($adapter.Count -eq 0) {
            $devices += [pscustomobject][ordered]@{ kind = $kind; driver = ''; runtimes = @(); present = $false }
            continue
        }
        $adapter = $adapter[0]
        $class = if ($kind -eq 'npu') { $computeClass } else { $displayClass }
        $properties = Get-DriverRegistryEntry -Name $adapter.name -ClassGuid $class
        $driver = if ($properties -and $properties.PSObject.Properties.Name -contains 'DriverVersion') {
            Format-DriverVersion ([string]$properties.DriverVersion)
        } else { '' }

        $runtimes = @()
        if ($kind -eq 'npu') {
            if (Test-RegisteredRuntime -Properties $properties -ValueName 'LevelZeroDriverPath' -LoaderName 'ze_loader.dll') { $runtimes += 'Level Zero' }
            if (Test-System32 'DirectML.dll') { $runtimes += 'DirectML' }
            if ((Test-System32 'Windows.AI.MachineLearning.dll') -and (Test-System32 'onnxruntime.dll')) { $runtimes += 'WinML' }
        } else {
            if ($adapter.name -match '(?i)nvidia') {
                $hasNvidia = $true
                if (Test-System32 'nvcuda.dll') { $runtimes += 'CUDA' }
            }
            if (Test-RegisteredRuntime -Properties $properties -ValueName 'LevelZeroDriverPath' -LoaderName 'ze_loader.dll') { $runtimes += 'Level Zero' }
            if (Test-RegisteredRuntime -Properties $properties -ValueName 'OpenCLDriverName' -LoaderName 'OpenCL.dll') { $runtimes += 'OpenCL' }
            if (Test-RegisteredRuntime -Properties $properties -ValueName 'VulkanDriverName' -LoaderName 'vulkan-1.dll') { $runtimes += 'Vulkan' }
        }
        if ($adapter.name -match '(?i)intel') { $hasIntelCompute = $true }

        $devices += [pscustomobject][ordered]@{
            kind = $kind
            name = $adapter.name
            driver = $driver
            runtimes = @($runtimes)
            present = $true
        }
    }

    # Version the CUDA label once the device list confirms an NVIDIA card.
    if ($hasNvidia) {
        $nvidia = Get-NvidiaRuntimeVersion -NvidiaSmiPath $NvidiaSmiPath
        foreach ($device in $devices) {
            if ($device.kind -ne 'dgpu' -or -not $device.present) { continue }
            if ($nvidia -and $nvidia.driver) { $device.driver = $nvidia.driver }
            if ($nvidia -and $nvidia.cuda) {
                $device.runtimes = @($device.runtimes | ForEach-Object { if ($_ -eq 'CUDA') { 'CUDA ' + $nvidia.cuda } else { $_ } })
            }
        }

        # The CUDA runtime ships with the display driver; the toolkit and cuDNN
        # do not, and their absence is what stops a machine from building or
        # running most deep-learning code.
        $cudaPath = @('Machine', 'User') | ForEach-Object { [Environment]::GetEnvironmentVariable('CUDA_PATH', $_) } | Where-Object { $_ } | Select-Object -First 1
        $toolkitKey = 'HKLM:\SOFTWARE\NVIDIA Corporation\GPU Computing Toolkit\CUDA'
        $hasToolkit = ($cudaPath -and (Test-Path -LiteralPath $cudaPath)) -or (Test-Path -LiteralPath $toolkitKey)
        # Name the compiler, not "CUDA toolkit". The card already shows "CUDA
        # 13.2" from the driver's runtime, so a bare "CUDA toolkit" gap beside it
        # reads as a contradiction rather than as "no nvcc to build with".
        if (-not $hasToolkit) {
            # Terse on purpose: the WSL row above already names the path and
            # version, so this only has to say why it is not a gap.
            if ($wsl.nvcc) { $elsewhere += 'nvcc: WSL, build-only' }
            else { $gaps += 'nvcc - no CUDA builds' }
        }

        $cudnn = $false
        foreach ($directory in @($(if ($cudaPath) { Join-Path $cudaPath 'bin' }), $system32) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) {
            if (@(Get-ChildItem -LiteralPath $directory -Filter 'cudnn64*.dll' -ErrorAction SilentlyContinue).Count -gt 0) { $cudnn = $true; break }
        }
        # A CUDA-enabled torch or a pip nvidia-cudnn wheel ships cuDNN inside the
        # environment. That is a working cuDNN, so reporting it missing because
        # it is not in System32 would be the same mistake as with OpenVINO.
        if (-not $cudnn) {
            foreach ($pattern in @('torch\lib\cudnn*.dll', 'nvidia\cudnn\bin\cudnn*.dll')) {
                if (Find-SitePackagePayload -RelativePattern $pattern) { $cudnn = $true; break }
            }
        }
        if (-not $cudnn) {
            if ($wsl.cudnn) { $elsewhere += 'cuDNN: per-venv' }
            else { $gaps += 'cuDNN - DL needs it' }
        }
    }

    if ($hasIntelCompute) {
        $openvino = Get-OpenVinoRuntime
        if (-not $openvino.present) {
            $gaps += 'OpenVINO - for iGPU/NPU'
        } else {
            # Credit it to the devices it can actually drive. OpenVINO is the
            # practical way to run anything on the NPU, so a bare "installed"
            # says less than which plugins came with it.
            $label = 'OpenVINO'
            if ($openvino.version) { $label += ' ' + ($openvino.version -replace '^(\d+\.\d+).*$', '$1') }
            foreach ($device in $devices) {
                if (-not $device.present) { continue }
                if ($device.kind -eq 'npu' -and $openvino.npu) { $device.runtimes = @($device.runtimes) + $label }
                if ($device.kind -eq 'igpu' -and $openvino.gpu) { $device.runtimes = @($device.runtimes) + $label }
            }
            if (-not $openvino.npu -and ($Inventory | Where-Object { $_.kind -eq 'npu' })) {
                $gaps += 'OpenVINO NPU plugin - NPU unusable'
            }
        }
    }

    $script:AcceleratorToolchain = [pscustomobject][ordered]@{
        detected_at = [DateTime]::UtcNow.ToString('o')
        devices = @($devices)
        gaps = @($gaps)
        elsewhere = @($elsewhere)
        wsl = $wsl
    }
    $script:AcceleratorToolchainStamp = [DateTime]::UtcNow
    return $script:AcceleratorToolchain
}

function ConvertTo-ToolchainReport {
    <#
    .SYNOPSIS
        Renders the toolchain feed: one line per device plus a gap line.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$Toolchain)

    function Format-Device {
        param([AllowNull()][object]$Device)
        if (-not $Device -or -not $Device.present) { return 'not present' }
        # Runtimes only. The card exists to answer "what can this device run",
        # and the driver version was consuming ~50px of a 222px column - enough
        # to push OpenVINO off the end of the line it was added to. The version
        # is still published in health.json for anyone who needs it.
        if (@($Device.runtimes).Count -eq 0) { return 'no compute runtime' }
        return (@($Device.runtimes) -join '  ')
    }

    $lines = @()
    foreach ($kind in @('dgpu', 'igpu', 'npu')) {
        # @( ) around the if: assigning a single-element result from a
        # subexpression unrolls it, and then .Count does not exist.
        $device = @(if ($Toolchain) { $Toolchain.devices | Where-Object { $_.kind -eq $kind } | Select-Object -First 1 })
        $label = if ($kind -eq 'dgpu') { 'gpu' } else { $kind }
        $lines += ($label + '|' + (ConvertTo-SafeField (Format-Device $(if ($device.Count -gt 0) { $device[0] } else { $null }))))
    }

    # The other half of the machine. Without this row the card describes Windows
    # and calls it the system, which is how build tooling that exists and works
    # gets reported as missing.
    $wslText = 'not detected'
    if ($Toolchain -and $Toolchain.PSObject.Properties.Name -contains 'wsl' -and $Toolchain.wsl) {
        if (-not $Toolchain.wsl.available) {
            $wslText = $Toolchain.wsl.reason
        } else {
            $parts = @()
            if ($Toolchain.wsl.cuda) { $parts += ('CUDA ' + $Toolchain.wsl.cuda) }
            if ($Toolchain.wsl.nvcc) { $parts += 'nvcc' }
            if ($Toolchain.wsl.cudnn) { $parts += 'cuDNN (per-venv)' }
            if ($parts.Count -eq 0) { $parts += 'no CUDA tooling' }
            $wslText = ($parts -join '  ')
        }
    }
    $lines += ('wsl|' + (ConvertTo-SafeField $wslText))

    # A gap now carries why it matters; something merely living elsewhere is
    # named as such rather than counted against the machine.
    if ($Toolchain -and @($Toolchain.gaps).Count -gt 0) {
        $gaps = (@($Toolchain.gaps) -join '   ')
        # The GAPS column is 222px (~46 characters); past that the skin clips
        # mid-glyph. When the annotated list cannot fit, keep every gap name and
        # drop the annotations - health.json still carries the full strings.
        if ($gaps.Length -gt 46) {
            $gaps = (@($Toolchain.gaps | ForEach-Object { ($_ -split '\s-\s')[0] }) -join '   ') + ' - missing'
        }
    } elseif ($Toolchain -and @($Toolchain.elsewhere).Count -gt 0) {
        $gaps = 'none - ' + (@($Toolchain.elsewhere) -join ', ')
    } else {
        $gaps = 'none'
    }
    $lines += ('gaps|' + (ConvertTo-SafeField $gaps))
    return ($lines -join [Environment]::NewLine)
}

function ConvertTo-ResidentReport {
    <#
    .SYNOPSIS
        Renders the "what is resident" feed: one line per scope, each a short
        human-readable list that a skin can print without further parsing.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$DiscreteGpu,
        [AllowNull()][object]$IntegratedGpu,
        [AllowNull()][object]$Npu,
        [AllowNull()][object]$Processes
    )

    function Get-Summary {
        param([AllowNull()][object]$Device)
        if ($null -eq $Device) { return 'unavailable' }
        if ($Device.status -eq 'absent') { return 'not present' }
        $resident = ''
        if ($Device.PSObject.Properties.Name -contains 'resident') { $resident = [string]$Device.resident }
        if (-not $resident) { return 'idle' }
        return $resident
    }

    $lines = @(
        ('gpu|' + (ConvertTo-SafeField (Get-Summary $DiscreteGpu))),
        ('igpu|' + (ConvertTo-SafeField (Get-Summary $IntegratedGpu))),
        ('npu|' + (ConvertTo-SafeField (Get-Summary $Npu))),
        ('ram|' + (ConvertTo-SafeField $(if ($Processes) { Format-ResidentSummary -Rows $Processes.memory } else { 'unavailable' }))),
        ('cpu|' + (ConvertTo-SafeField $(if ($Processes) { Format-ResidentSummary -Rows $Processes.cpu } else { 'unavailable' })))
    )
    return ($lines -join [Environment]::NewLine)
}

function Get-RuntimeProperty {
    <#
    .SYNOPSIS
        Read a property off a decoded JSON object without trusting it exists.
    .DESCRIPTION
        Set-StrictMode -Version Latest is active module-wide, so touching a field
        a runtime did not emit is a terminating error, not $null. These payloads
        come from third-party HTTP APIs whose shape changes between versions, so
        every read of them goes through here.
    #>
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name, [AllowNull()][object]$Default = $null)

    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if (-not $prop) { return $Default }
    if ($null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Get-ServedModels {
    <#
    .SYNOPSIS
        Which model each accelerator is actually running, asked of the runtimes.
    .DESCRIPTION
        RESIDENT names processes, and process names collide: Ollama's runner and
        llama.cpp's are both "llama-server", while the iGPU embedder is only
        "pythonw". Knowing that 23 GB is held by "llama-server" does not tell you
        which model to unload, which is what the panel is actually asked.

        A WSL-hosted runtime is also invisible to Windows per-process GPU
        counters - its memory accounts to the VM worker process - so for the
        serving stack this is not merely nicer than a process name, it is the
        only route to a name at all. Every endpoint is optional with a short
        timeout: one runtime being down must never delay or blank the panel.
    #>
    [CmdletBinding()]
    param(
        [string]$OllamaUrl = 'http://127.0.0.1:11434',
        [string]$SwapUrl = 'http://127.0.0.1:9090',
        [string]$EmbedUrl = 'http://127.0.0.1:8201',
        [ValidateRange(1, 10)][int]$TimeoutSeconds = 2
    )

    function Get-RuntimeJson {
        param([string]$Url)
        try {
            return Invoke-RestMethod -Uri $Url -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        } catch {
            return $null
        }
    }

    $rows = New-Object Collections.Generic.List[object]

    # Ollama. size_vram below size means it split the model between GPU and host
    # RAM; say so rather than implying the card holds all of it.
    $ollama = Get-RuntimeJson (($OllamaUrl.TrimEnd('/')) + '/api/ps')
    foreach ($model in @(Get-RuntimeProperty -Object $ollama -Name 'models' -Default @())) {
        $name = [string](Get-RuntimeProperty -Object $model -Name 'name' -Default '')
        if (-not $name) { continue }
        $vram = [double](Get-RuntimeProperty -Object $model -Name 'size_vram' -Default 0)
        $total = [double](Get-RuntimeProperty -Object $model -Name 'size' -Default 0)
        $device = 'cpu'
        $split = $false
        if ($vram -gt 0) {
            $device = 'gpu'
            if ($total -gt 0 -and $vram -lt $total) { $split = $true }
        }
        $detail = '{0:N1}G' -f ($vram / 1GB)
        $ctx = Get-RuntimeProperty -Object $model -Name 'context_length' -Default ''
        if ($ctx) { $detail += ' ctx ' + $ctx }
        if ($split) { $detail += ' split' }
        $rows.Add([pscustomobject]@{ device = $device; name = $name; detail = $detail; source = 'ollama' })
    }

    # llama-swap: the gateway's registry. Its models run inside WSL, so this is
    # the only place their names exist as far as Windows is concerned.
    $swap = Get-RuntimeJson (($SwapUrl.TrimEnd('/')) + '/running')
    $running = Get-RuntimeProperty -Object $swap -Name 'running' -Default $swap
    foreach ($entry in @($running)) {
        $name = [string](Get-RuntimeProperty -Object $entry -Name 'model' -Default '')
        if (-not $name) { continue }
        $state = [string](Get-RuntimeProperty -Object $entry -Name 'state' -Default 'ready')
        if ($state -notin @('ready', 'starting')) { continue }
        $rows.Add([pscustomobject]@{ device = 'gpu'; name = $name; detail = $state; source = 'llama-swap' })
    }

    # OpenVINO embeddings. Its /health names the model and the device it compiled
    # for, which is what separates an iGPU tenant from a CPU one.
    $embed = Get-RuntimeJson (($EmbedUrl.TrimEnd('/')) + '/health')
    $embedModel = [string](Get-RuntimeProperty -Object $embed -Name 'model' -Default '')
    if ($embedModel) {
        $target = [string](Get-RuntimeProperty -Object $embed -Name 'device' -Default '')
        $device = 'cpu'
        if ($target -match '^GPU') { $device = 'igpu' }
        elseif ($target -match '^NPU') { $device = 'npu' }
        $detail = 'embeddings'
        $dims = Get-RuntimeProperty -Object $embed -Name 'dimensions' -Default ''
        if ($dims) { $detail += ' ' + $dims + 'd' }
        $rows.Add([pscustomobject]@{ device = $device; name = $embedModel; detail = $detail; source = 'openvino' })
    }

    return $rows.ToArray()
}

function ConvertTo-ModelReport {
    <#
    .SYNOPSIS
        Renders the "what model is where" feed: one line per scope, in the same
        scope|text shape as the resident and toolchain feeds.
    .DESCRIPTION
        Memory use does not prove that a model is loaded. When the runtimes
        supply no name, show the largest visible memory consumer as a process,
        not as a model. A Python worker or WSL tenant may not expose a model API.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Models,
        [AllowNull()][object]$DiscreteGpu,
        [AllowNull()][object]$IntegratedGpu,
        [AllowNull()][object]$Npu
    )

    function Format-Rows {
        # The MODELS column is 222px (~46 characters) and one Ollama tag can
        # spend most of that on its own. Same policy as the GAPS line: when the
        # detailed list cannot fit, keep every model name and drop the details;
        # if names alone still overflow, name the first and count the rest.
        # health.json carries the full rows either way.
        param([object[]]$Rows)
        $text = (@($Rows | ForEach-Object {
            if ($_.detail) { '{0} ({1})' -f $_.name, $_.detail } else { [string]$_.name }
        }) -join '   ')
        if ($text.Length -le 46) { return $text }
        $text = (@($Rows | ForEach-Object { [string]$_.name }) -join '   ')
        if ($text.Length -le 46) { return $text }
        $first = [string]$Rows[0].name
        if ($first.Length -gt 40) { $first = $first.Substring(0, 39) + [char]0x2026 }
        if ($Rows.Count -gt 1) { $first += (' +{0} more' -f ($Rows.Count - 1)) }
        return $first
    }

    function Format-Scope {
        param([string]$Scope, [AllowNull()][object]$Device)

        $mine = @($Models | Where-Object { $_ -and $_.device -eq $Scope })
        if ($mine.Count -gt 0) { return (Format-Rows -Rows $mine) }
        if ($null -eq $Device) { return 'unavailable' }
        if ($Device.PSObject.Properties['status'] -and $Device.status -eq 'absent') { return 'not present' }
        if (-not $Device.PSObject.Properties['status'] -or $Device.status -notin @('ok', 'limited')) { return 'unavailable' }
        if ([double]::IsNaN((Get-SampleNumber -Sample $Device -Name 'memory_used_mb' -Default ([double]::NaN)))) { return 'unavailable' }
        # Use the existing process sample; this adds no process or HTTP probes.
        # Even a small allocation may hold a model, while a large allocation
        # may belong to a browser. Do not infer model residency from a size.
        $used = Get-SampleNumber -Sample $Device -Name 'memory_used_mb'
        $owners = @(Get-RuntimeProperty $Device 'processes' @() | Where-Object {
            $_ -and (Get-SampleNumber $_ 'memory_bytes') -gt 0
        } | Sort-Object { Get-SampleNumber $_ 'memory_bytes' } -Descending)
        if ($used -gt 0 -and $owners.Count -gt 0) {
            $owner = $owners[0]
            $name = ConvertTo-SafeField ([string](Get-RuntimeProperty $owner 'name' 'process'))
            if (-not $name) { $name = 'process' }
            # Reserve space for the status and PID within the 222px column.
            if ($name.Length -gt 11) { $name = $name.Substring(0, 10) + [char]0x2026 }
            $ownerId = Get-SampleNumber $owner 'pid'
            if ($ownerId -gt 0) { return ('no model ID; {0} ({1:0})' -f $name, $ownerId) }
            return ('no model ID; {0}' -f $name)
        }
        if ($used -ge 2048) { return 'no model ID; memory in use' }
        return 'none reported'
    }

    $cpuRows = @($Models | Where-Object { $_ -and $_.device -eq 'cpu' })
    $cpuText = 'none'
    # CPU tenants stay names-only: the row exists to say "this also runs", not
    # to itemise host-side details the accelerator rows exist for.
    if ($cpuRows.Count -gt 0) {
        $cpuText = Format-Rows -Rows @($cpuRows | ForEach-Object { [pscustomobject]@{ name = $_.name; detail = '' } })
    }

    $lines = @(
        ('gpu|' + (ConvertTo-SafeField (Format-Scope -Scope 'gpu' -Device $DiscreteGpu))),
        ('igpu|' + (ConvertTo-SafeField (Format-Scope -Scope 'igpu' -Device $IntegratedGpu))),
        ('npu|' + (ConvertTo-SafeField (Format-Scope -Scope 'npu' -Device $Npu))),
        ('cpu|' + (ConvertTo-SafeField $cpuText))
    )
    return ($lines -join [Environment]::NewLine)
}

function Get-SampleNumber {
    <#
    .SYNOPSIS
        Read a numeric field off a sample without trusting that it exists.
    .DESCRIPTION
        Set-StrictMode -Version Latest is active module-wide, so reading a property
        a producer did not emit is a terminating error rather than $null. Sample
        numbers have also already been through ConvertTo-SafeField, so they arrive
        as strings and can be '' for a field nvidia-smi withheld.
    #>
    param([AllowNull()][object]$Sample, [Parameter(Mandatory)][string]$Name, [double]$Default = 0)

    if ($null -eq $Sample) { return $Default }
    $prop = $Sample.PSObject.Properties[$Name]
    if (-not $prop) { return $Default }
    $value = 0.0
    if ([double]::TryParse([string]$prop.Value, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -and
        -not [double]::IsNaN($value) -and -not [double]::IsInfinity($value)) { return $value }
    return $Default
}

function Get-ClaimField {
    <#
    .SYNOPSIS
        Read one field off a Get-GpuClaim result defensively.
    .DESCRIPTION
        The optional claim is written by another application and can gain fields.
        Read missing fields defensively, as Get-GpuClaim does for the JSON file.
    #>
    param([AllowNull()][object]$Claim, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Claim) { return '' }
    $prop = $Claim.PSObject.Properties[$Name]
    if (-not $prop) { return '' }
    return (ConvertTo-SafeField $prop.Value)
}

function New-GpuPhaseTracker {
    <#
    .SYNOPSIS
        A rolling, time-weighted view of what the GPU is actually doing.
    .DESCRIPTION
        Utilisation sampled at a point in time is the wrong instrument for the
        question people actually ask, and it misleads in a specific, repeatable
        way. A Wan 2.2 S2V render was watched at "8% the whole time" and read as a
        starved GPU. Measured, that same run held 90-100% utilisation at 575 W with
        31.8 of 32.6 GB resident *while sampling* - roughly 175 s of a 330 s job.
        The rest of the wall-clock was a 19.6 GB GGUF read off disk and dequantised,
        umt5 text encoding, VAE decode, and then ComfyUI sitting on 28.3 GB at 0%
        indefinitely. Each of those is real work or real waste, and none of it
        registers as SM utilisation.

        So classify each sample into a phase and accumulate *time* in each. That
        turns "8%" into the two numbers that can be acted on: how much of the
        window was saturated, and how long the card was held while doing nothing.

        Phases:
          computing      saturated - the job is doing its work
          overhead       engaged but not saturated: model load, dequant, text
                         encode, VAE decode, memory in motion
          resident-idle  memory held, no work. The waste signal - on a single-GPU
                         box this is what blocks every other consumer
          absent         nothing loaded

        Stateful by design, like New-AcceleratorSampler: the supervisor polls on
        its own cadence and this keeps only the window it needs.
    #>
    [CmdletBinding()]
    param(
        # Wall-clock kept. Ten minutes covers a video render without unbounded growth.
        [ValidateRange(10, 86400)][int]$WindowSeconds = 600,
        # >= this is "the job is running". 50 sits clear of the 0-8% that loading
        # and decoding produce, and well below the 90-100% of sampling.
        [ValidateRange(1, 100)][int]$SaturatedUtilPercent = 50,
        # Below this, treat the card as doing nothing at all.
        [ValidateRange(0, 100)][int]$IdleUtilPercent = 5,
        # Allocation worth flagging at low load. This includes desktop memory;
        # the threshold does not establish whether a model is loaded.
        [ValidateRange(0, 1048576)][int]$IdleResidentMb = 2048,
        # How long idle-but-resident must persist to be a warning rather than the
        # gap between two queued jobs.
        [ValidateRange(1, 86400)][int]$WasteWarnSeconds = 120,
        # Unattributed VRAM worth flagging. Inside WSL, nvidia-smi reports total
        # used but lists no Windows host processes; 9.4 GB was invisible that way.
        [ValidateRange(0, 1048576)][int]$UnattributedWarnMb = 1024,
        # Assumed gap for the first sample, which has no predecessor to measure.
        [ValidateRange(1, 3600)][int]$AssumedIntervalSeconds = 2
    )

    [pscustomobject][ordered]@{
        window_seconds = $WindowSeconds
        saturated_util_percent = $SaturatedUtilPercent
        idle_util_percent = $IdleUtilPercent
        idle_resident_mb = $IdleResidentMb
        waste_warn_seconds = $WasteWarnSeconds
        unattributed_warn_mb = $UnattributedWarnMb
        assumed_interval_seconds = $AssumedIntervalSeconds
        samples = [System.Collections.Generic.List[object]]::new()
    }
}

function Add-GpuPhaseSample {
    <#
    .SYNOPSIS
        Classify one sample, weight it by elapsed time, drop what fell out of the
        window. Returns the classified entry.
    .DESCRIPTION
        The phase depends on the previous sample as well as this one: memory in
        motion is what separates "loading" from "holding", and only a pair can show
        motion. A single reading cannot tell those apart - which is exactly why
        point sampling produced the wrong answer to begin with.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Tracker,
        [Parameter(Mandatory)][object]$Sample,
        # Optional Get-GpuClaim output. Carried per sample so a leak can be dated
        # to when it began rather than only noticed now.
        [AllowNull()][object]$Claim
    )

    $util = Get-SampleNumber -Sample $Sample -Name 'utilization_percent'
    $usedMb = Get-SampleNumber -Sample $Sample -Name 'memory_used_mb'
    $powerW = Get-SampleNumber -Sample $Sample -Name 'power_w'

    $stamp = [DateTime]::UtcNow
    $stampProp = $Sample.PSObject.Properties['timestamp_utc']
    if ($stampProp -and $stampProp.Value -is [DateTime]) {
        $stamp = $stampProp.Value
        if ($stamp.Kind -eq [DateTimeKind]::Unspecified) { $stamp = [DateTime]::SpecifyKind($stamp, [DateTimeKind]::Utc) }
        $stamp = $stamp.ToUniversalTime()
    } elseif ($stampProp) {
        $parsed = [DateTime]::MinValue
        if ([DateTime]::TryParse([string]$stampProp.Value, [ref]$parsed)) {
            $stamp = $parsed.ToUniversalTime()
        }
    }

    $previous = $null
    if ($Tracker.samples.Count -gt 0) { $previous = $Tracker.samples[$Tracker.samples.Count - 1] }

    $elapsed = [double]$Tracker.assumed_interval_seconds
    $memoryDeltaMb = 0.0
    if ($null -ne $previous) {
        $gap = ($stamp - [DateTime]$previous.timestamp_utc).TotalSeconds
        # Clamp: a supervisor that was paused, or a clock that stepped, would
        # otherwise credit hours to whichever phase happened to be current.
        if ($gap -gt 0 -and $gap -le $Tracker.window_seconds) { $elapsed = $gap }
        $memoryDeltaMb = $usedMb - [double]$previous.memory_used_mb
    }

    # Rising faster than ~64 MB/s is weights arriving, not noise.
    $memoryRising = ($elapsed -gt 0) -and (($memoryDeltaMb / $elapsed) -gt 64)

    $sampleStatus = Get-RuntimeProperty -Object $Sample -Name 'status' -Default 'unavailable'
    $utilKnown = -not [double]::IsNaN((Get-SampleNumber $Sample 'utilization_percent' ([double]::NaN)))
    $memoryKnown = -not [double]::IsNaN((Get-SampleNumber $Sample 'memory_used_mb' ([double]::NaN)))
    if ($sampleStatus -notin @('ok', 'limited') -or -not $utilKnown -or -not $memoryKnown) {
        $phase = 'unknown'
    } elseif ($util -ge $Tracker.saturated_util_percent) {
        $phase = 'computing'
    } elseif ($util -ge $Tracker.idle_util_percent -or $memoryRising) {
        $phase = 'overhead'
    } elseif ($usedMb -ge $Tracker.idle_resident_mb) {
        $phase = 'resident-idle'
    } else {
        $phase = 'absent'
    }

    # Sum only what the driver could attribute. In WDDM mode that is often nothing
    # at all, and inside WSL it never includes Windows host processes - so the
    # remainder is a real, load-bearing number rather than an error.
    $attributedMb = 0.0
    $procCount = 0
    $procProp = $Sample.PSObject.Properties['processes']
    if ($procProp -and $procProp.Value) {
        foreach ($p in @($procProp.Value)) {
            $procCount++
            $attributedMb += (Get-SampleNumber -Sample $p -Name 'memory_bytes') / 1MB
        }
    }

    $entry = [pscustomobject][ordered]@{
        timestamp_utc = $stamp
        phase = $phase
        seconds = [Math]::Round($elapsed, 3)
        utilization_percent = $util
        memory_used_mb = $usedMb
        power_w = $powerW
        process_count = $procCount
        attributed_mb = [Math]::Round($attributedMb, 1)
        unattributed_mb = [Math]::Round([Math]::Max(0, $usedMb - $attributedMb), 1)
        claim_state = [string](Get-ClaimField -Claim $Claim -Name 'state')
        claim_holder = [string](Get-ClaimField -Claim $Claim -Name 'holder')
    }
    $Tracker.samples.Add($entry)

    $cutoff = $stamp.AddSeconds(-1 * $Tracker.window_seconds)
    while ($Tracker.samples.Count -gt 0 -and ([DateTime]$Tracker.samples[0].timestamp_utc) -lt $cutoff) {
        $Tracker.samples.RemoveAt(0)
    }
    return $entry
}

function Get-GpuPhaseReport {
    <#
    .SYNOPSIS
        Time-weighted summary of the tracked window, plus the warnings utilisation
        alone cannot raise.
    .DESCRIPTION
        `duty_cycle_percent` is the field that answers "why does this look like 8%":
        saturated time as a share of *engaged* time. A render that spends 175 s
        sampling and 155 s loading and decoding reports ~53%, not a single digit.
        `mean_utilization_percent` is kept beside it - that is the number a naive
        monitor shows, so the gap can be explained instead of argued about.

        Three warnings, each from an observed failure on this box:

          resident-idle  28.3 GB stayed resident at 0% after a render finished,
                         blocking every other consumer on a single-GPU machine.
          claim leak     A worker exited without releasing its ownership record.
                         Held claim + idle is the shape to catch; the monitor
                         cannot determine whether this is intentional caching.
          unattributed   Inside WSL, nvidia-smi reported 9.4 GB used and listed
                         zero compute apps, because it cannot see Windows host
                         processes. ComfyUI then budgeted against the wrong number.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Tracker)

    $phases = [ordered]@{ computing = 0.0; overhead = 0.0; 'resident-idle' = 0.0; absent = 0.0; unknown = 0.0 }
    $peakMemory = 0.0; $peakPower = 0.0; $peakUtil = 0.0; $peakIdleMemory = 0.0
    $utilSeconds = 0.0; $total = 0.0; $maxUnattributed = 0.0
    $idleRun = 0.0; $longestIdleRun = 0.0; $idleHolder = ''

    foreach ($s in $Tracker.samples) {
        $seconds = [double]$s.seconds
        $total += $seconds
        $phases[[string]$s.phase] += $seconds
        if ($s.phase -eq 'unknown') { $idleRun = 0.0; continue }
        $utilSeconds += ([double]$s.utilization_percent) * $seconds
        if ([double]$s.memory_used_mb -gt $peakMemory) { $peakMemory = [double]$s.memory_used_mb }
        if ([double]$s.power_w -gt $peakPower) { $peakPower = [double]$s.power_w }
        if ([double]$s.utilization_percent -gt $peakUtil) { $peakUtil = [double]$s.utilization_percent }
        if ([double]$s.unattributed_mb -gt $maxUnattributed) { $maxUnattributed = [double]$s.unattributed_mb }

        if ([string]$s.phase -eq 'resident-idle') {
            $idleRun += $seconds
            if ([double]$s.memory_used_mb -gt $peakIdleMemory) { $peakIdleMemory = [double]$s.memory_used_mb }
            if ([string]$s.claim_state -eq 'held') { $idleHolder = [string]$s.claim_holder }
            if ($idleRun -gt $longestIdleRun) { $longestIdleRun = $idleRun }
        } else {
            $idleRun = 0.0
        }
    }

    $engaged = $phases['computing'] + $phases['overhead'] + $phases['resident-idle']
    $duty = 0.0
    if ($engaged -gt 0) { $duty = 100.0 * $phases['computing'] / $engaged }
    $meanUtil = 0.0
    $knownSeconds = $total - $phases['unknown']
    if ($knownSeconds -gt 0) { $meanUtil = $utilSeconds / $knownSeconds }

    $warnings = @()
    if ($longestIdleRun -ge $Tracker.waste_warn_seconds) {
        $warnings += ('{0:0.0} GB held at idle for {1:0}s - allocated memory can include cached models and desktop apps' -f
            ($peakIdleMemory / 1024), $longestIdleRun)
        if ($idleHolder) {
            $warnings += ("claim leak: '" + $idleHolder +
                "' still holds the card while idle - release through the owning application or claim-file writer")
        }
    }
    if ($maxUnattributed -ge $Tracker.unattributed_warn_mb) {
        $warnings += ('{0:0.0} GB not attributable to a visible process - WDDM, or host processes invisible from WSL' -f
            ($maxUnattributed / 1024))
    }

    [pscustomobject][ordered]@{
        window_seconds = [Math]::Round($total, 1)
        samples = $Tracker.samples.Count
        computing_seconds = [Math]::Round($phases['computing'], 1)
        overhead_seconds = [Math]::Round($phases['overhead'], 1)
        resident_idle_seconds = [Math]::Round($phases['resident-idle'], 1)
        absent_seconds = [Math]::Round($phases['absent'], 1)
        unknown_seconds = [Math]::Round($phases['unknown'], 1)
        duty_cycle_percent = [Math]::Round($duty, 1)
        mean_utilization_percent = [Math]::Round($meanUtil, 1)
        peak_utilization_percent = [Math]::Round($peakUtil, 0)
        peak_memory_mb = [Math]::Round($peakMemory, 0)
        peak_power_w = [Math]::Round($peakPower, 1)
        idle_resident_peak_mb = [Math]::Round($peakIdleMemory, 0)
        longest_idle_run_seconds = [Math]::Round($longestIdleRun, 1)
        max_unattributed_mb = [Math]::Round($maxUnattributed, 0)
        warnings = $warnings
        summary = (ConvertTo-SafeField (
            'duty {0:0}% ({1:0}s work / {2:0}s overhead / {3:0}s idle-held)  peak {4:0.0}G {5:0}W' -f
            $duty, $phases['computing'], $phases['overhead'], $phases['resident-idle'],
            ($peakMemory / 1024), $peakPower))
    }
}

function ConvertTo-PhaseReport {
    <#
    .SYNOPSIS
        Renders the phase feed: one display line and one warning line.
    .DESCRIPTION
        `phase|` is what the panel prints, so when a warning is active it takes
        the line - a held-idle card matters more than a duty cycle. `warn|` stays
        machine-readable ('none' when quiet) so the skin can recolour without
        parsing the display text. Full warning strings live in health.json.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Report)

    if ($null -eq $Report) {
        return ('phase|starting' + [Environment]::NewLine + 'warn|none')
    }

    if ((Get-SampleNumber $Report 'unknown_seconds') -ge $Report.window_seconds -and $Report.window_seconds -gt 0) {
        return ('phase|telemetry unavailable' + [Environment]::NewLine + 'warn|telemetry unavailable')
    }

    $display = 'duty {0:0}%  mean {1:0}%  work {2:0}s  idle-held {3:0}s' -f `
        [double]$Report.duty_cycle_percent, [double]$Report.mean_utilization_percent,
        [double]$Report.computing_seconds, [double]$Report.resident_idle_seconds
    $warn = 'none'
    $warnings = @($Report.warnings)
    if ($warnings.Count -gt 0) {
        # Keep the clause before the first ' - '; the rationale does not fit a
        # 264px line and is preserved in health.json.
        $warn = ([string]$warnings[0] -split '\s-\s')[0].Trim()
        if ($warnings.Count -gt 1) { $warn += (' (+{0})' -f ($warnings.Count - 1)) }
        $display = $warn
    }
    return ('phase|' + (ConvertTo-SafeField $display) + [Environment]::NewLine + 'warn|' + (ConvertTo-SafeField $warn))
}

function New-GpuDiagnosticReport {
    <#
    .SYNOPSIS
        Build an allowlisted diagnostic snapshot suitable for manual sharing.
    .DESCRIPTION
        Never serialize Health wholesale. Names, paths, endpoints, PIDs, claims,
        free-form warnings, and future producer fields must stay out of exports.
        Phase classification is a heuristic, not a runtime-reported job stage.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Health,
        [switch]$Demo,
        [DateTime]$Now = [DateTime]::UtcNow
    )

    function Read-Number([object]$Object, [string]$Name, [double]$Maximum = [double]::MaxValue) {
        $value = Get-SampleNumber $Object $Name ([double]::NaN)
        if ([double]::IsNaN($value) -or $value -lt 0 -or $value -gt $Maximum) { return $null }
        return [Math]::Round($value, 3)
    }

    $age = $null
    $freshness = 'unknown'
    $poll = Read-Number $Health 'poll_seconds' 30
    if ($null -eq $poll -or $poll -lt 1) { $poll = 2 }
    try {
        $rawStamp = Get-RuntimeProperty $Health 'updated_at'
        if ($null -eq $rawStamp) { throw 'No timestamp' }
        if ($rawStamp -is [DateTime]) {
            $stamp = $rawStamp
            if ($stamp.Kind -eq [DateTimeKind]::Unspecified) { $stamp = [DateTime]::SpecifyKind($stamp, [DateTimeKind]::Utc) }
            $stamp = $stamp.ToUniversalTime()
        } else {
            $stamp = [DateTimeOffset]::Parse([string]$rawStamp, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        }
        $age = [Math]::Round(($Now.ToUniversalTime() - $stamp).TotalSeconds, 1)
        $freshness = if ($age -lt -1) { 'clock-skew' } elseif ($age -gt (3 * $poll)) { 'stale' } else { 'fresh' }
    } catch { }

    $devices = foreach ($kind in @('gpu', 'igpu', 'npu')) {
        $device = Get-RuntimeProperty $Health $kind
        $status = [string](Get-RuntimeProperty $device 'status' 'unavailable')
        if ($status -notin @('ok', 'limited', 'absent', 'unavailable')) { $status = 'unavailable' }
        $available = $status -in @('ok', 'limited')
        [pscustomobject][ordered]@{
            device = $kind
            status = $status
            utilization_percent = $(if ($available) { Read-Number $device 'utilization_percent' 100 } else { $null })
            memory_used_mb = $(if ($available) { Read-Number $device 'memory_used_mb' } else { $null })
            memory_total_mb = $(if ($available) { Read-Number $device 'memory_total_mb' } else { $null })
            temperature_c = $(if ($available) { Read-Number $device 'temperature_c' } else { $null })
            power_w = $(if ($available) { Read-Number $device 'power_w' } else { $null })
        }
    }

    $phase = Get-RuntimeProperty $Health 'phase'
    $phaseFields = [ordered]@{}
    foreach ($name in @('window_seconds', 'samples', 'computing_seconds', 'overhead_seconds',
        'resident_idle_seconds', 'absent_seconds', 'unknown_seconds', 'duty_cycle_percent',
        'mean_utilization_percent', 'peak_memory_mb', 'peak_power_w', 'longest_idle_run_seconds', 'max_unattributed_mb')) {
        $maximum = if ($name.EndsWith('_percent')) { 100 } else { [double]::MaxValue }
        $phaseFields[$name] = Read-Number $phase $name $maximum
    }
    if ($null -ne $phaseFields.window_seconds -and
        ($phaseFields.window_seconds -eq 0 -or $phaseFields.unknown_seconds -eq $phaseFields.window_seconds)) {
        $phaseFields.duty_cycle_percent = $null
        $phaseFields.mean_utilization_percent = $null
    }

    $models = @(Get-RuntimeProperty $Health 'models' @())
    $runtimes = foreach ($source in @('ollama', 'llama-swap', 'openvino')) {
        $count = @($models | Where-Object { (Get-RuntimeProperty $_ 'source') -eq $source }).Count
        if ($count -gt 0) { [pscustomobject]@{ runtime = $source; reported_models = $count } }
    }

    # Fixed text only: never echo arbitrary producer summaries or error strings.
    $findings = @()
    if ($freshness -ne 'fresh') {
        $findings += 'Snapshot freshness is not confirmed; values describe historical observations.'
    }
    if ($devices[0].status -notin @('ok', 'limited')) {
        $findings += 'GPU telemetry is unavailable; missing measurements do not mean idle.'
    }
    if ($null -ne $phaseFields.longest_idle_run_seconds -and $phaseFields.longest_idle_run_seconds -gt 0) {
        $findings += 'GPU memory remained allocated during low utilization in this window. A loaded model may be intentionally cached.'
    }
    if ($null -ne $phaseFields.max_unattributed_mb -and $phaseFields.max_unattributed_mb -ge 1024) {
        $findings += 'Some GPU memory could not be attributed to visible processes. WDDM and WSL can limit attribution.'
    }
    if ($null -eq $phaseFields.window_seconds) { $findings += 'No workload history is available in this snapshot.' }
    $findings += 'Utilization phases are heuristics. They do not establish prefill, decode, a memory leak, or the cause of a slowdown.'

    [pscustomobject][ordered]@{
        contract = 'utils.gpu-monitor.diagnostic.v1'
        mode = $(if ($Demo) { 'demo-synthetic' } else { 'snapshot' })
        freshness = $freshness
        sample_age_seconds = $age
        devices = @($devices)
        phase = [pscustomobject]$phaseFields
        runtimes = @($runtimes)
        findings = $findings
        privacy = 'Allowlisted metrics only; names, paths, endpoints, PIDs, claim text, and raw logs omitted. Review before sharing.'
    }
}

function ConvertTo-GpuDiagnosticText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Report)

    function Show-Number($Value, [string]$Unit) {
        if ($null -eq $Value) { return 'unknown' }
        return ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.#}{1}', $Value, $Unit))
    }
    $lines = @('GPU Monitor | local AI diagnostic', ('Mode: ' + $Report.mode),
        ('Freshness: {0} | age: {1}' -f $Report.freshness, (Show-Number $Report.sample_age_seconds 's')), '')
    foreach ($device in $Report.devices) {
        $lines += '{0}: {1} | load {2} | memory {3} / {4}' -f $device.device.ToUpperInvariant(), $device.status,
            (Show-Number $device.utilization_percent '%'), (Show-Number $device.memory_used_mb ' MiB'),
            (Show-Number $device.memory_total_mb ' MiB')
    }
    $lines += ''
    $lines += 'Window: {0} | computing {1} | overhead {2} | idle-held {3} | unknown {4}' -f
        (Show-Number $Report.phase.window_seconds 's'), (Show-Number $Report.phase.computing_seconds 's'),
        (Show-Number $Report.phase.overhead_seconds 's'), (Show-Number $Report.phase.resident_idle_seconds 's'),
        (Show-Number $Report.phase.unknown_seconds 's')
    $lines += 'Duty: {0} | mean load: {1}' -f (Show-Number $Report.phase.duty_cycle_percent '%'),
        (Show-Number $Report.phase.mean_utilization_percent '%')
    foreach ($runtime in $Report.runtimes) { $lines += '{0}: {1} model(s) reported' -f $runtime.runtime, $runtime.reported_models }
    $lines += ''
    foreach ($finding in $Report.findings) { $lines += '- ' + $finding }
    $lines += ''; $lines += $Report.privacy
    return $lines -join [Environment]::NewLine
}

Export-ModuleMember -Function @(
    'New-GpuDiagnosticReport',
    'ConvertTo-GpuDiagnosticText',
    'Get-RainmeterExecutable',
    'Get-RainmeterSkinPath',
    'Resolve-NvidiaSmi',
    # Phase-aware tracking: utilisation at a point in time cannot distinguish a
    # saturated render from a card held idle, and both were misread on this box.
    'New-GpuPhaseTracker',
    'Add-GpuPhaseSample',
    'Get-GpuPhaseReport',
    'ConvertTo-PhaseReport',
    'Get-SampleNumber',
    'Get-ClaimField',
    # Callers that build their own sample objects need the same field sanitiser
    # the line contract uses; the supervisor does, on every device merge.
    'ConvertTo-SafeField',
    'Get-GpuSample',
    'Get-GpuComputeProcesses',
    'Get-GpuClaim',
    'ConvertTo-GpuMonitorLine',
    'Write-AtomicText',
    'Write-AtomicJson',
    'Get-AcceleratorInventory',
    'New-AcceleratorSampler',
    'Get-AcceleratorTelemetry',
    'New-AbsentAcceleratorSample',
    'Get-ProcessTelemetry',
    'Get-AcceleratorToolchain',
    # Exported for diagnosis: when the panel claims an SDK is missing, these
    # answer "was it detected, and where did the search actually look".
    'Get-OpenVinoRuntime',
    'Get-SitePackagesRoot',
    'Get-WslToolchain',
    'ConvertTo-ToolchainReport',
    'ConvertTo-ResidentReport',
    # Process names collide and WSL tenants have none at all, so the model feed
    # is the only one that answers "which model is on which device".
    'Get-ServedModels',
    'ConvertTo-ModelReport',
    'Get-RuntimeProperty',
    'Format-CompactSize',
    'Format-ResidentSummary'
)
