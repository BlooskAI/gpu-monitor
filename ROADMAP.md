# GPU Monitor roadmap

The first audience is local AI developers and enthusiasts. The product should
answer three questions quickly: what holds accelerator memory, whether useful
work is happening, and what evidence explains the wait. Keep a quiet desktop
view with detail available when a workload becomes confusing.

## Current foundation

Windows has accelerator readings, runtime model residency, heuristic workload
phases, a supervisor/watchdog, a synthetic diagnostic demo, and an allowlisted
diagnostic export. macOS has a native hardware panel with explicit counter
limitations. Apache-2.0 licensing, contributor guidance, offline checks, a CI
workflow, and an allowlisted public source packager are included.

The items below are planned, not claims of existing functionality.

## Optional runtime integrations

These integrations are planned. GPU Monitor must remain independently buildable.
Use documented interfaces and synthetic fixtures for each new adapter.

| Integration | Idea for GPU Monitor | Evidence required before showing it |
| --- | --- | --- |
| Agent runtime statistics | Request history with latency percentiles, cache hits, local routes, and escalations | Provider counters, a time window, and a reset-aware baseline; estimated token savings remain labelled estimates |
| Agent request events | Explain whether an agent is waiting, using a cached result, running locally, or escalating | Explicit runtime events; never infer request state from a process name |
| Generation completion events | Distinguish successful completion, abstention, failed generation, and output-budget exhaustion | Runtime completion status; GPU activity is not a measure of answer correctness |
| Benchmark replay | Reproducible before/after workload comparisons | Fixed workload and settings, repeated runs, scope and uncertainty; no universal leaderboard from a single test |
| Optional GPU ownership file | Model handoff timeline, declared ownership, GPU/host-memory split, and fit estimates | Separate declared intent from measured residency; include KV/context/headroom assumptions |
| Inference timing and counters | Prefill/decode time, cache reuse, and speculative decoding acceptance | Actual request timings and accepted/drafted token counters; distinguish end-to-end latency from decode tokens/s |
| Result metadata | Every result names its scope and distinguishes measured from projected | Runtime version, device, configuration, time window, and source; synthetic results explicitly marked |

## First public preview

1. Make runtime endpoints configurable, optional, and individually disableable.
   An offline or slow endpoint must not delay the GPU sampler. Support documented
   Ollama and llama.cpp surfaces before expanding the adapter list.
2. Carry per-source sample times and render freshness. Distinguish collector
   heartbeat, runtime refresh age, and actual panel updates.
3. Exercise a clean Windows install and uninstall on another machine. Measure
   CPU, memory, process launches, and polling delays for an hour.
4. Review discrete GPU selection on multi-GPU machines and CPU-only runtimes.
   Do not assume the first WDDM adapter or a runtime's model belongs to GPU 0.
5. Compile and run macOS on real hardware. Describe its narrower feature set in
   screenshots and release notes until parity is tested.
6. Record a short desktop demonstration with synthetic or reviewed data. Show
   model loading, sustained compute, and idle-held memory in one visible story.

## Next useful release

- A request timeline: queue, load, prefill, decode, completion, and model release
  where the runtime provides those events. Keep heuristic phases separately labelled.
- A bounded local slowdown capture connecting GPU history with CPU hot cores,
  memory pressure, and disk latency. Follow the existing
  [responsiveness roadmap](RESPONSIVENESS_ROADMAP.md).
- Optional agent runtime statistics using a stable read-only adapter contract.
  Do not collect task text or use estimated savings as a billing claim.
- A comparison report for a user's own runs, including time to first token,
  total completion time, memory peak, cache conditions, and runtime versions.

## Later decisions

Linux support, a desktop UI that removes the Rainmeter prerequisite, remote
hosts, and a public adapter SDK need separate design and maintenance decisions.
Automatic unloading, model switching, priority changes, and system tuning are
outside the monitor's current scope.

The launch plan is in [docs/launch.md](docs/launch.md). Success means users can
understand and fix a confusing local workload, install the monitor again after
an update, and contribute a runtime adapter without owning the maintainer's PC.
