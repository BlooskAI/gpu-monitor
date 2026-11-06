# GPU Monitor

By **BlooskAI**, a division of **Biznique**.

**See what holds your GPU, when it works, and when memory stays allocated.**

A desktop monitor for people running local AI. The Windows edition combines
GPU, integrated-GPU, and NPU telemetry with model residency and a rolling
workload history. The native macOS edition currently provides hardware telemetry;
model attribution and workload phases are Windows features.

Licensed under [Apache-2.0](LICENSE). No account or cloud service is required.

[BlooskAI](https://www.bizniqueinc.com/blooskai) is a division of Biznique.
The Windows footer links to BlooskAI and provides **Options** and **Updates**.
The menu includes restart and local repair. Update checks run only when clicked;
installation requires confirmation. The GitHub repository is not connected until
public publication. See [updates and repair](docs/updates.md).

## Try the diagnostic demo

From a Windows checkout, run this without Rainmeter, an NVIDIA GPU, or a model server:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\service\diagnose.ps1 -Demo
```

The synthetic five-minute workload loads a model, computes, then leaves memory
allocated. It uses the same phase tracker as the desktop monitor:

```text
GPU Monitor | local AI diagnostic
Mode: demo-synthetic
GPU: ok | load 0% | memory 24000 MiB / 32768 MiB
Window: 300s | computing 120s | overhead 40s | idle-held 140s | unknown 0s
Duty: 40% | mean load: 39.5%
```

This is an excerpt of synthetic output, not a performance benchmark or desktop
screenshot. With the monitor running, omit `-Demo` to read its latest snapshot.
Add `-Json` for structured output, or `-HealthPath path\to\health.json` to inspect
a saved Windows snapshot. Stale snapshots are labelled. Output stays in the terminal
unless you explicitly redirect it to a file.

The diagnostic export omits names, paths, endpoints, PIDs, claim text, and raw
logs using an allowlist. Review it before sharing. The regular desktop panel and
local `health.json` still contain model and process names; see [privacy](docs/privacy.md).

## What it helps explain

- **Memory held at low utilization:** distinguish sustained work from an idle
  allocation. A cached model can be intentional; low utilization alone does not prove a leak.
- **Which model is loaded:** query supported runtime registries instead of guessing
  from a generic `llama-server` process name.
- **Missing attribution:** label held memory that no runtime names, including WSL
  and WDDM visibility limits.
- **Missing measurements:** report unavailable or limited data rather than presenting
  an unknown reading as idle.

Request timing, prefill/decode metrics, configurable adapters, and broader platform
parity are planned in the [roadmap](ROADMAP.md). [Contributions](CONTRIBUTING.md)
can be tested without special hardware.

## Editions

| Platform | Desktop surface | GPU source | Installer and recovery |
|---|---|---|---|
| Windows 10/11 | Rainmeter glass dashboard | `nvidia-smi`, plus WDDM performance counters for the integrated GPU and NPU | User-local installed runtime, Apps & Features entry, Start-menu controls, logon supervisor plus independent one-minute health watchdog |
| macOS 13+ | Native SwiftUI/AppKit panel and menu-bar control | Metal identity plus best-effort IOAccelerator/AGX counters | Ad-hoc signed `.app` in `~/Applications`, LaunchAgent at login and restart after abnormal exit |

Both editions show a GPU hero card and live history alongside CPU, memory,
disk, and network telemetry. Both retain the panel position and keep the
monitor below normal application windows as a desktop gadget.

## Devices

The dashboard covers three accelerator classes and reports what is resident on
each of them.

| Card | Windows source | macOS source |
|---|---|---|
| GPU | `nvidia-smi` when an NVIDIA driver is present, otherwise WDDM counters | Metal device plus IOAccelerator/AGX counters |
| IGPU | WDDM adapter flagged `HybridIntegrated`, read through `\GPU Engine` and `\GPU Adapter Memory` | Metal device with unified or low-power memory |
| NPU | WDDM compute-only adapter, enumerated through `D3DKMTEnumAdapters3` — the only interface that lists it | Detected on Apple silicon, reported as `LIMITED` |
| RESIDENT | Per-process `\GPU Process Memory` and `\GPU Engine` counters, plus top host RAM and CPU consumers | Top host RAM and CPU consumers from `ps` |
| MODELS | Each runtime's own registry: Ollama `/api/ps`, llama-swap `/running`, OpenVINO `/health` | not implemented |
| TOOLCHAIN | Per-adapter driver runtime registrations, plus the SDKs that are missing | not implemented |

The MODELS card answers "which model is on which device", which RESIDENT cannot.
Process names collide — Ollama's runner and llama.cpp's are both `llama-server`,
and the integrated-GPU embedder is only `pythonw` — and a model served inside WSL
has no name here at all, because its memory accounts to the VM worker process.
Runtimes are the only things that know their own model names, so the card asks
them rather than inferring from a process list. Each endpoint is optional with a
two-second timeout on the slow detail cadence; one runtime being down costs that
row and nothing else.

When no runtime reports a model name, the card shows `no model ID; python (12345)`
if process memory is visible. The name and PID identify the largest visible
memory consumer, not a confirmed model. Desktop apps also use GPU memory.
An arbitrary Python worker can cache a model without exposing a supported API.
If process ownership is unavailable and at least 2 GiB is used, the row says
`no model ID; memory in use`. Otherwise it says `none reported`; this does not
prove that the device is empty. Missing telemetry still reads `unavailable`.

An idle-held warning means memory stayed allocated at low GPU load. It does
not establish a model name or a memory leak. Hover over the phase or model row
for these explanations. Free disk space and disk queue occupy separate lines.

Each row fits its 222px column the same way the GAPS line does: when the
detailed list overflows, details are dropped before names, and names before the
count — `health.json` always carries the full rows.

Hardware that is not installed reports `absent` and its card dims; that is a
correct reading, not a failure, so a machine with no NPU still passes the smoke
test. Device utilization is the busiest engine class on the device, matching
what Task Manager shows, and the card note names that engine (`3D`, `Compute`,
`VideoDecode`, ...).

Honest limits:

- Windows exposes no temperature or power for the integrated GPU or the NPU, so
  those fields stay blank rather than showing a fabricated zero.
- An integrated device has no memory of its own; its total is the Windows shared
  budget, which is half of system memory.
- macOS publishes no Neural Engine counter without root, so the NPU card shows
  the device and says so instead of claiming it is idle.
- macOS has no per-process GPU accounting, so the resident GPU row says so.

### Installed toolchain

The TOOLCHAIN card answers "what can I actually run on this device, and what is
missing". It is read from the per-adapter driver registrations under the device
class key, not by probing SDKs, so it is authoritative and costs no process
spawn:

```
GPU    drv 595.95    CUDA 13.2  OpenCL  Vulkan
IGPU   drv 101.8331  Level Zero  OpenCL  Vulkan
NPU    drv 100.4512  Level Zero  DirectML  WinML
GAPS   CUDA toolkit  cuDNN  OpenVINO
```

A runtime is listed only when the driver declares it, the declared file is still
on disk, and the system-wide loader it is reached through is present. A driver
key outlives its hardware — this machine still lists an AMD Radeon entry for a
card that is not installed — so adapters are matched against the live inventory
and stale keys are never reported.

GAPS is the actionable half: the CUDA runtime ships with the display driver, but
the toolkit and cuDNN do not, and their absence is what stops a machine from
building or running most deep-learning code. OpenVINO is reported missing only
when there is an Intel device that would use it.

None of this changes without an install, so it is detected once and cached for
an hour. That hourly refresh is the only place `nvidia-smi` is called for
anything other than the live GPU reading, and it is the only way to learn the
CUDA version — it is not available from `--query-gpu`.

### Polling cost

The GPU hero card refreshes every `-PollSeconds` (default 2). Everything added
for the integrated GPU, the NPU and the resident lists refreshes on the separate
and slower `-DetailSeconds` cadence (default 10) and is deliberately allowed to
lag. It costs one collection on a long-lived PDH query — single-digit
milliseconds, no process spawn, no WMI call. Raise it if you want it cheaper
still:

```powershell
powershell -ExecutionPolicy Bypass -File .\service\install.ps1 -DetailSeconds 30
```

### Phase-aware tracking — because utilisation lies

`New-GpuPhaseTracker` / `Add-GpuPhaseSample` / `Get-GpuPhaseReport`.

**The failure this exists for.** A Wan 2.2 S2V video render was watched at "8% the
whole time" and read as a starved GPU. Measured, that run held **90–100%
utilisation at 575 W with 31.8 of 32.6 GB resident while it was sampling** —
roughly 175 s of a 330 s job. The remaining wall-clock was a 19.6 GB GGUF read off
disk and dequantised, text encoding, VAE decode, and then ComfyUI sitting on
**28.3 GB at 0% indefinitely**. Every part of that is real work or real waste, and
none of it registers as SM utilisation. A point sample cannot tell them apart.

So each sample is classified and *time* is accumulated per phase:

| Phase | Meaning |
|---|---|
| `computing` | saturated — the job is doing its work |
| `overhead` | engaged but not saturated: model load, dequant, text encode, VAE decode |
| `resident-idle` | memory held, no work. **The waste signal** |
| `absent` | nothing loaded |
| `unknown` | telemetry unavailable or required measurements missing |

The headline is `duty_cycle_percent` — saturated time as a share of *engaged* time.
`mean_utilization_percent` is reported beside it, because that is the number a
naive monitor shows, and the gap between the two is the whole point.

Three warnings, each from an observed failure on this box:

- **idle-but-resident** — 28.3 GB stayed on the card at 0% after a render finished.
  On a single-GPU machine that blocks every other consumer.
- **claim leak** — a worker left its ownership record held after it stopped.
  Held claim + idle is the signal to inspect. The monitor reads the optional
  record through `Get-GpuClaim`; it never changes ownership.
- **unattributed VRAM** — inside WSL, `nvidia-smi` reports total used but lists
  **zero** compute apps, because it cannot see Windows host processes. 9.4 GB was
  invisible that way, and ComfyUI budgeted against the wrong number.

Any worker can publish the [optional claim-file interface](docs/gpu-claims.md).
Use `GPUMONITOR_CLAIM_PATH` to select its file, or pass an explicit `-Path` to
`Get-GpuClaim`. The existing writer format and default location remain supported.
No separate CLI tool is required. Claims express intent and do not enforce locks.

```powershell
$tracker = New-GpuPhaseTracker -WasteWarnSeconds 120
$claim = Get-GpuClaim
while ($true) {
    $null = Add-GpuPhaseSample -Tracker $tracker -Sample (Get-GpuSample -IncludeProcesses) -Claim $claim
    Start-Sleep -Seconds 2
}
(Get-GpuPhaseReport -Tracker $tracker).summary
# duty 43% (60s work / 20s overhead / 60s idle-held)  peak 31.1G 575W
```

Thresholds are parameters, not constants — `-SaturatedUtilPercent` (50) sits clear
of the 0–8% that loading produces and well below the 90–100% of sampling.

The phase line is rendered at the bottom of the Rainmeter GPU card. The
classifications are utilization and memory heuristics; they cannot establish
prefill, decode, or why a job is slow. Unavailable samples accumulate as unknown
time and do not dilute the mean utilization of known samples.

## Windows installation

Prerequisites: Windows PowerShell 5.1 and [Rainmeter](https://www.rainmeter.net/).
An NVIDIA driver with `nvidia-smi` provides the fullest GPU reading; the supervisor
has a WDDM fallback with fewer metrics. The live smoke test requires NVIDIA hardware.

The current model probes use loopback ports 11434 (Ollama), 9090 (llama-swap),
and 8201 (the optional OpenVINO embedding service). No model runtime is required.
Other endpoints and authenticated runtimes need configuration work before support
can be claimed; the OpenVINO health endpoint is a specific service integration,
not a general OpenVINO API.

Double-click `Install GPU Monitor.cmd`, or run:

```powershell
powershell -ExecutionPolicy Bypass -File .\service\install.ps1
```

The installer copies the runtime into
`%LOCALAPPDATA%\Programs\UtilsGpuMonitor`. The scheduled task and Start-menu
shortcuts point to that installed copy, so the repository may later move or be
removed. Runtime telemetry and bounded logs live in
`%LOCALAPPDATA%\Utils\GpuMonitor`:

| File | Contents |
|---|---|
| `gpu.txt` | Discrete GPU, ten pipe-separated fields |
| `igpu.txt` | Integrated GPU, same ten fields |
| `npu.txt` | Neural processor, same ten fields |
| `processes.txt` | Five `scope\|what is resident` lines for gpu, igpu, npu, ram and cpu |
| `models.txt` | Four `scope\|models` lines for gpu, igpu, npu and cpu |
| `toolchain.txt` | Five `scope\|installed runtimes` lines for gpu, igpu, npu, wsl and gaps |
| `phase.txt` | Two lines: `phase\|` (duty cycle and per-phase seconds, or the active warning) and `warn\|` (`none` when quiet) — rendered at the bottom of the GPU hero card |
| `health.json` | Full structured sample including per-device process lists |

The ten device fields are `timestamp`, `status`, `name`, `load%`,
`temperature`, `memory used MB`, `memory total MB`, `watts`, `power limit`,
`note`. A blank field means the platform does not publish that value.

Controls:

```powershell
powershell -ExecutionPolicy Bypass -File .\service\status.ps1
powershell -ExecutionPolicy Bypass -File .\service\restart.ps1
powershell -ExecutionPolicy Bypass -File .\service\uninstall.ps1
```

Build a redistributable ZIP:

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\build-windows.ps1
```

Windows AMD and Intel discrete GPUs have a driver-counter fallback, but no
vendor-specific temperature, power, or discrete-memory capacity collector.
Hardware verification is still required. Multiple discrete GPUs are not yet
reliable: NVIDIA index selection and Windows process-adapter selection are
independent, and runtime model rows do not identify a physical GPU. Linux has
no collector or desktop app in this repository. The macOS source has a smaller
hardware-only feature set; validate it on a Mac before claiming compatibility.

## macOS installation

Prerequisites: macOS 13 or newer and current Xcode Command Line Tools.

```zsh
cd macos
zsh scripts/install.sh
```

The native app is built from the Swift package and installed in
`~/Applications/GPU Monitor.app`. See [macos/README.md](macos/README.md) for
operations and the honest GPU-counter compatibility boundary.

From Windows, build a portable source installer to move to a Mac:

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\build-macos-source.ps1
```

On the target Mac, extract it and run `zsh "Install GPU Monitor.command"`.
The Mac-native `scripts/build-release.sh` produces a signed application ZIP.

## Reliability model

Windows:

- named mutex prevents duplicate supervisors;
- Scheduled Task starts at logon with `MultipleInstances=IgnoreNew`;
- Task Scheduler retries an abnormal supervisor exit up to 99 times at
  one-minute intervals;
- a separate short-lived watchdog checks task state and heartbeat freshness
  every minute and repairs killed or stale supervisors;
- supervisor restarts Rainmeter and periodically reactivates the skin;
- telemetry and health files use atomic replacement;
- failures are recorded in a bounded rotating log.

macOS:

- LaunchAgent starts the app at login;
- `KeepAlive.SuccessfulExit=false` restarts crashes but respects a normal Quit;
- launchd throttles repeated failures;
- panel frame autosave preserves its desktop location;
- missing private GPU counters produce `LIMITED`, never a fabricated zero-load
  success state.

## Verification

Hardware-independent Windows checks (also run by the GitHub Actions workflow):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\offline.ps1
pwsh -NoProfile -File .\tests\offline.ps1
```

Live Windows smoke test, requiring Rainmeter and NVIDIA hardware:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\smoke.ps1
```

The macOS application must be compiled and exercised on a real Mac. The
Windows development host cannot prove Swift compilation, launchd behavior, or
which GPU counters a target Mac exposes.

## Public source preparation

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\packaging\build-public-source.ps1
```

This creates a reviewable source tree, ZIP, file manifest, and SHA-256 checksum
under `dist`. Only files in `packaging/public-files.txt` are included; Git metadata
and local histories are excluded. It does not publish a repository. The
[launch guide](docs/launch.md) covers the remaining checks and release story.

The packager runs `tests/public-hygiene.ps1` first. This rejects tracked files
outside the reviewed list and screens source text for common credentials and
private workstation paths. Ignore rules also protect environment files, keys,
agent histories, generated Rainmeter paths, runtime snapshots, and model weights.
Ignore rules do not clear private development history. The public release uses
one initial commit from the reviewed source export. The private development
checkout and its history remain separate. See the
[public source boundary](docs/launch.md#public-source-boundary).
