# Contributing to GPU Monitor

GPU Monitor helps local AI users understand accelerator activity and model
residency. Useful contributions make a reading more accurate, an integration
more portable, or the first run easier to understand.

## Development

Clone the source and run `powershell -NoProfile -ExecutionPolicy Bypass -File
.\tests\offline.ps1` on Windows. Also run `pwsh -NoProfile -File
.\tests\offline.ps1` when PowerShell 7 is available. These checks require no
Rainmeter installation, GPU, model download, or running model service.

Try `powershell -NoProfile -ExecutionPolicy Bypass -File
.\service\diagnose.ps1 -Demo` to exercise a synthetic workload. For macOS changes,
run `swift build -c release` from `macos` and exercise the app on a Mac. The
PowerShell collector remains Windows-specific.

Run `tests/smoke.ps1` for collector or Rainmeter changes on a Windows machine
with Rainmeter and NVIDIA hardware. Include the tested GPU/OS/runtime and any
unsupported hardware in the pull request. A successful compilation does not
prove that a device exposes counters.

Run `tests/install-safety.ps1` for installer changes. It uses a temporary profile
and replaces system operations to check ordinary reinstalls and predecessor
migration without changing installed tasks, registry keys, processes, or skins.

## Design expectations

- Missing, stale, absent, and zero are different states. Preserve those distinctions.
- Keep runtime reads bounded and optional. Do not trigger generation or load,
  unload, or switch a model to collect metrics.
- Keep the fast sampler cheap. Use the slower detail cadence for discovery.
- Never add prompt text, full command lines, credentials, or paths to shareable
  reports. Extend the export allowlist deliberately and test privacy sentinels.
- Label estimates, synthetic data, and inferred phases. Do not infer model
  quality, request throughput, or a leak from GPU utilization alone.
- Reuse ideas through documented interfaces and independent implementations;
  do not import sibling repository checkouts or copy code without compatible rights.

## Pull requests

Describe the user-visible problem, the resulting behavior, and the checks run.
For a new runtime adapter, include synthetic response fixtures covering an
offline service, missing fields, stale data, and an unsupported response shape.
For a performance claim, provide the workload, sampling interval, baseline,
hardware, and measured overhead.

If you add a distributable file, update `packaging/public-files.txt` and check
the generated public source tree. Keep local captures and build output out of
the source list. Contributions are distributed under Apache-2.0.

Run `powershell -NoProfile -ExecutionPolicy Bypass -File
.\tests\public-hygiene.ps1` before committing. It rejects tracked files outside
the public source list and checks reviewed text for credential patterns and
private workstation paths. It reports locations without printing matched values.
The source packager runs this check automatically. Treat a failure as a review
item; do not add credentials or runtime captures to the public list.

Ignore rules do not remove files from existing commits. See
[public source preparation](docs/launch.md#public-source-boundary) before
creating a public remote from a private development checkout.
