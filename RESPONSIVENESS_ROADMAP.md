# AI Development Responsiveness Roadmap

Status: proposed future work, based on the August 2026 workstation slowdown investigation.

## Purpose

GpuMonitor accurately answers "is the accelerator busy?" It does not yet answer the broader question a developer usually means when the machine feels bad: "what is delaying my interaction right now?"

The next version should keep the GPU workload view and add a low-overhead responsiveness view for local AI development. It should identify CPU, compositor, storage, memory, background synchronization, display, and stale-monitor conditions without collecting source code or uploading telemetry.

## What the current monitor missed

During the investigated incident, the headline RTX reading hovered near 3%. That was not evidence that the monitor was broken. Direct `nvidia-smi` sampling agreed with it. The limiting work was elsewhere:

- Total CPU appeared to be only about 21-28%, but this machine has 24 logical processors. That represents roughly five to seven fully occupied cores, and two individual logical processors were observed at 100%.
- The shared VS Code/Electron GPU process consumed about 4.4% of whole-machine CPU. On 24 logical processors, that is approximately 1.1 core equivalents even though it looks like a small percentage.
- Desktop Window Manager (`dwm.exe`) consumed about 5% of whole-machine CPU while the affected window was visible, or about 1.2 core equivalents. Minimizing the window reduced DWM to about 1.1%.
- Moving the VS Code window 60 times took about 2.52 seconds. The same operation with Paint took about 1.97 seconds. Temporarily lowering the VS Code GPU process from AboveNormal to Normal priority reduced the VS Code result to about 1.93 seconds. This implicated CPU scheduling/composition, not RTX compute saturation.
- Context switches averaged roughly 94,000/second and briefly approached 292,000/second.
- A separate focus-triggered problem launched 15 concurrent `git fetch` operations against a self-hosted Git server. That explained disk noise on the server machine, but it was not represented in the local GPU headline.
- After reboot, the week-old Electron/VS Code state was gone: CPU returned to a low baseline, the Code GPU process was no longer stuck, and disk queue and latency were effectively zero.

In short, low aggregate utilization did not mean low latency. A single saturated UI, compositor, driver, or renderer thread can make every window feel slow while most CPU cores and the RTX GPU remain idle.

## Current blind spots

The present implementation has several structural blind spots:

1. `nvidia-smi` reports NVIDIA device activity, not the CPU cost of Electron rendering, Windows composition, driver calls, or window presentation.
2. One total-CPU number hides hot cores and serialized work. On this machine, 4.17% of whole-machine CPU can represent one completely occupied logical processor.
3. The 2-second GPU and 10-second detail intervals can average away short stalls associated with focus, window movement, builds, Git operations, and file scans.
4. A process named `Code.exe` is ambiguous. The monitor does not classify the Electron browser, renderer, extension host, and `--type=gpu-process` roles.
5. Disk active time and queue length alone do not distinguish a healthy fast NVMe workload from a latency-bound disk or identify the process issuing I/O.
6. The monitor has no foreground-window or focus-change timeline, so it cannot correlate "I switched windows" with the work that immediately followed.
7. It cannot observe physical disk activity on a separate Git server. It can only identify local Git/network activity likely to have triggered it.
8. Supervisor health means the collector and Rainmeter processes exist. It does not prove that the displayed value is current or that the panel is responsive.
9. A non-elevated status check can mistake task-query access denial for a missing scheduled task.

## Desired operator experience

Add a first-class `RESPONSIVENESS` state alongside the GPU state:

```text
RESPONSIVENESS  DEGRADED
2 hot cores | Code GPU 1.1 cores | DWM 1.2 cores
Likely CPU/compositor bottleneck; RTX compute is idle
```

The state should be evidence-based and use three simple levels:

- `GOOD`: no sustained latency signal and samples are fresh.
- `DEGRADED`: a sustained bottleneck or correlated event can plausibly affect interaction.
- `STALLED`: the panel is stale, the foreground application is not responding, or an extreme latency threshold is sustained.

Every diagnosis should name its evidence. Do not turn a high utilization number into a bottleneck claim without latency, queueing, saturation, or event correlation.

## Telemetry to add

### Fast sample: approximately once per second

- Total CPU plus the hottest logical processor and top three logical processors.
- System processor queue length and context switches/second.
- CPU for `dwm.exe`, the foreground application, and relevant browser/Electron roles.
- Process priority class and normalized CPU in both whole-machine percent and core equivalents.
- WDDM engines separated by adapter and class: 3D, Copy, Compute, Video Decode, and Video Encode. Preserve the direct NVIDIA reading.
- Physical-disk read/write latency, queue length, and throughput.
- Collector timestamp, panel-consumed timestamp, sample age, and last successful render time.

Prefer long-lived performance-counter queries. Do not create WMI processes or enumerate every process on every fast tick.

### Detail sample: every 5-10 seconds

- Top processes by CPU delta, I/O byte delta, hard-fault delta, and private/working-set memory.
- Available memory, committed memory, paging, and hard faults.
- Per-disk latency, throughput, and queue depth rather than only `_Total` percent busy.
- Network throughput and top local process/remote endpoint when attribution is available.
- Foreground window PID, executable, role, and time since the last focus change.
- Current display resolution, refresh rate, active output/connection type, and display-driver reset events.
- Defender scan activity and Git activity as correlation signals, not assumptions about causality.

### Event-driven markers

Record lightweight timestamped markers for:

- Foreground-window changes, minimize/restore, and display-mode changes.
- Bursts of Git fetch/pull/push processes, including repository count and remote host after redaction.
- Defender scan, detection, remediation, and cloud-protection events that Windows exposes locally.
- Electron renderer or GPU-process restarts.
- Display-driver reset/TDR and WHEA hardware events.
- User-triggered "capture slowdown" actions.

The event stream is what turns a pile of counters into an explanation such as: "window focus was followed by 15 Git fetches and a storage/network burst."

## Process-role attribution

Group process instances without retaining full command lines:

- VS Code browser/main
- VS Code renderer, associated with a workspace/window when safely possible
- VS Code extension host
- VS Code shared GPU process (`--type=gpu-process`)
- Desktop Window Manager
- Defender antimalware service
- Git and known package/build/test workers
- Local model runtimes and their GPU/CPU workers

Only retain a recognized role and a stable local instance identifier. Full command lines can contain file paths, tokens, prompts, or customer names and should not be written to normal telemetry.

## Derived signals

Thresholds should be adaptive where possible and should require multiple consecutive samples. Initial rules to validate are:

- **Hot-core bottleneck:** total CPU is below 50%, but any logical processor exceeds 90% for at least three seconds.
- **UI/compositor pressure:** the foreground renderer, browser GPU process, and DWM collectively consume approximately one or more core equivalents while interaction latency is elevated.
- **Scheduler pressure:** processor queue or context-switch rate is materially above the machine's learned idle and working baselines.
- **Disk latency:** average transfer latency exceeds 20 ms or queue depth stays elevated while throughput cannot explain it. High active time with sub-millisecond latency and no queue should not be called disk-bound.
- **Memory pressure:** sustained hard faults/paging with low available memory, not merely a large resident model.
- **Remote sync burst:** multiple Git network operations start across repositories within a short interval. Report the local trigger and label remote-host disk activity as inferred.
- **GPU compute bottleneck:** compute utilization and workload progress agree; do not infer it from allocated VRAM alone.
- **CPU/compositor bottleneck with idle GPU:** explicitly report this when the UI path is saturated but accelerator utilization is low.
- **Stale monitor:** any displayed source is older than three times its intended interval, Rainmeter is not responding, or the rendered timestamp stops advancing. Replace `LIVE` with `STALE` immediately.

Display both process CPU representations to prevent misleading small numbers:

```text
Code GPU: 4.4% machine | 1.06 core equivalents
```

For a process measured as a percentage of the whole machine:

```text
core equivalents = machine percent * logical processor count / 100
```

## Slowdown capture

Maintain an in-memory ring buffer containing at least the last ten minutes of counters and events. Add a tray/menu action and command-line entry point named `Capture slowdown`.

When invoked, it should persist:

- The preceding five to ten minutes and the following 30 seconds.
- The responsiveness diagnosis and the raw counters behind it.
- Process roles, normalized CPU, disk/network deltas, focus events, and sample freshness.
- Machine/display summary, monitor version, sampling configuration, and precise timestamps.
- A compact human-readable summary plus JSON or CSV for deeper analysis.

The capture must be bounded and local. It should not take screenshots, record keystrokes, read source files, collect prompts, or upload anything automatically.

## Privacy and safety requirements

- Local-only collection and storage by default.
- No source contents, filenames, workspace paths, prompts, environment values, or full command lines in routine logs.
- Redact or hash repository names, remote hosts, usernames, and customer paths in exported reports.
- Make screenshot capture a separate explicit user action; never enable it as background telemetry.
- Keep export and any future upload strictly opt-in with a preview of the exact payload.
- Rotate bounded logs and document their locations and retention.
- Distinguish `access denied`, `not installed`, `not running`, and `stale` in health checks.

These constraints matter especially on development machines, where diagnostic context can accidentally expose credentials or proprietary paths even when no file contents are collected.

## Performance budget

The diagnostics must not become the new source of sluggishness:

- Target less than 0.5% whole-machine CPU at idle on the reference 24-logical-processor workstation.
- Avoid per-tick process creation and repeated broad WMI/CIM enumeration.
- Reuse PDH queries and compute process deltas in memory.
- Keep high-cost ETW tracing off during ordinary monitoring.
- Use bounded queues, atomic output, a single writer, and backpressure rather than overlapping writes.
- Skip a detail cycle when needed rather than blocking the fast sampler or Rainmeter.
- Measure and expose the monitor's own CPU, memory, I/O, missed samples, and write failures.

The intermittent historic `Cannot create a file when that file already exists` atomic-write error should be eliminated with a single-writer design or destination-specific synchronization. A failed detail write should increment a visible error counter and mark the affected data stale.

## Implementation sequence

### P0: make hidden bottlenecks visible

1. Add hottest-core CPU, processor queue, context switches, disk latency, and throughput.
2. Identify DWM, foreground process, and Electron/VS Code roles; show CPU as machine percent and core equivalents.
3. Add source age and real panel freshness, including a prominent `STALE` state.
4. Fix health reporting so permission errors are not reported as missing tasks.
5. Add the initial `GOOD / DEGRADED / STALLED` card with evidence text.

### P1: explain what triggered the slowdown

1. Add the bounded ring buffer and `Capture slowdown` report.
2. Correlate focus/minimize/restore events with process, disk, network, Git, and Defender changes.
3. Detect multi-repository Git bursts and identify the remote host in a privacy-preserving way.
4. Add adaptive baselines for idle, ordinary development, test, build, and local-model modes.

### P2: optional deep capture

1. Add an explicitly enabled, time-bounded ETW capture for CPU scheduling, file I/O, DWM/present, and input-latency investigation.
2. Add display-mode and driver-event diagnostics.
3. Generate a shareable, redacted incident bundle from the ring buffer and optional trace.

### P3: actionable guidance

Translate detected patterns into narrow suggestions, for example:

- "Two logical processors are pinned; total CPU is hiding a single-thread bottleneck."
- "VS Code GPU process and DWM are consuming 2.1 core equivalents; minimizing the window reduced composition load."
- "Fifteen Git fetches started after focus; check auto-fetch in the multi-root workspace."
- "Disk is 92% active but latency is 0.4 ms with no queue; storage is busy, not blocked."
- "RTX compute is 3%; current evidence points to CPU-side UI composition."

Suggestions must remain reversible and must not automatically change security settings, process priorities, refresh rates, or developer configuration.

## Acceptance tests

The feature is ready when these cases produce the expected explanation:

1. Pin two logical processors while keeping total CPU below 25%. The panel reports a hot-core bottleneck.
2. Make an Electron GPU process consume approximately one CPU core while RTX utilization stays low. The panel reports CPU/compositor pressure, not GPU compute pressure.
3. Minimize and restore a composition-heavy window. The timeline shows the focus/window event and corresponding DWM/process change.
4. Start 15 concurrent Git fetches across repositories. The panel reports a Git synchronization burst and attributes local disk/network activity where possible.
5. Drive disk active time above 90% with sub-millisecond latency and no sustained queue. The panel does not label the machine disk-bound.
6. Introduce sustained disk latency and queueing. The panel identifies the disk and top local I/O actor.
7. Stop advancement of a data file while Rainmeter and the collector remain alive. The panel changes from `LIVE` to `STALE` within three sample intervals.
8. Run the status command without permission to query scheduled tasks. It reports `ACCESS DENIED`, not `MISSING`.
9. Reproduce a slow UI with a valid 3% RTX reading. The dashboard preserves the accurate GPU number and explains why it is not the relevant bottleneck.
10. Leave the monitor idle for an hour. Its CPU/I/O use remains inside the performance budget with no overlapping-write errors.

## Non-goals

- Replacing Task Manager, Windows Performance Recorder, Process Monitor, or an antivirus product.
- Inspecting source code or AI prompts.
- Claiming visibility into another computer's disk without an agent on that computer.
- Automatically tuning priorities, exclusions, display modes, or IDE settings.
- Reducing every complex performance incident to a single utilization percentage.

The intended result is a monitor that preserves the simple GPU view but can also say, quickly and honestly, why an AI-development workstation feels slow even when the GPU graph is green.
