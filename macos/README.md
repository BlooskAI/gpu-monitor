# GPU Monitor for macOS

This is the native macOS edition of GPU Monitor by BlooskAI, a division of
Biznique. It is a menu-bar app
with a movable SwiftUI desktop panel. The panel uses Metal for GPU identity,
best-effort `IOAccelerator`/`AGXAccelerator` counters for GPU utilization,
and standard macOS interfaces for CPU, memory, disk, and network telemetry.

GPU utilization counters are not a stable public macOS API. On a Mac/driver
that does not expose the counters through `ioreg`, the app reports `LIMITED`
instead of inventing a number. CPU, memory, disk, network, and GPU identity
continue to work.

## Integrated GPU, Neural Engine and resident processes

The panel carries the same device model as the Windows edition, bounded by what
macOS actually publishes.

- **IGPU** is the Metal device with unified or low-power memory. On Apple
  silicon that is the same device as the hero card, so the tile says
  `unified with GPU` and repeats its load rather than implying a second GPU. On
  an Intel Mac with discrete graphics the two are different devices and the tile
  reports `LIMITED`, because macOS publishes no per-device counter.
- **NPU** is detected from `hw.optional.arm64`: every Apple silicon Mac has a
  Neural Engine. Its load is only available to `powermetrics` running as root,
  so the tile reports the device and states the limit. It never shows a
  fabricated `0%`.
- **RESIDENT** lists the largest host memory and CPU consumers from a single
  `ps` call. CPU share is a true measurement over the interval, computed from
  the change in cumulative processor time rather than from the decayed average
  `ps` prints. macOS has no per-process GPU accounting, so the GPU row says so.

These readings run every fifth refresh (about ten seconds) instead of on every
two-second tick, because each one spawns a helper tool. Use **Refresh Now** in
the menu-bar menu to force an immediate detail pass.

## Install

Requires macOS 13 or newer and current Xcode Command Line Tools.

```zsh
zsh scripts/install.sh
```

The installer:

- builds a release Swift executable;
- creates an ad-hoc signed `GPU Monitor.app`;
- installs it into `~/Applications`;
- registers `com.utils.gpumonitor` in `~/Library/LaunchAgents`;
- starts it at login;
- restarts it after an abnormal exit.

Use the menu-bar gauge to show/hide, refresh, or quit the panel. Its position is
remembered across launches.

```zsh
zsh scripts/status.sh
zsh scripts/restart.sh
zsh scripts/uninstall.sh
zsh scripts/build-release.sh 2.2.0
```

