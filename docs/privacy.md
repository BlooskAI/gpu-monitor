# Diagnostic privacy

Manual update checks contact GitHub. Confirmed update downloads use GitHub release
hosts. They send no model names, process lists, or telemetry. Opening the BlooskAI
website or repository link uses the default browser. No background update checks
run. See [updates and repair](updates.md) for the package verification process.

The normal desktop panel displays model and process names. Windows runtime files
in `%LOCALAPPDATA%\Utils\GpuMonitor` can contain those names, PIDs, executable
paths, GPU claim holder/notes, toolchain paths, and error messages. Treat
`health.json` and the supervisor logs as local data, not public bug reports.

`service/diagnose.ps1` builds a new report from an explicit allowlist. It keeps
device status and numeric measurements, snapshot age, numeric phase totals,
and counts for known runtimes. It omits device names, model names, process names,
PIDs, paths, endpoints, claim text, arbitrary errors, arbitrary warnings, and
unknown future fields. Invalid numeric values become null, not zero.

The output can still reveal approximate memory capacity, workload intensity,
phase duration, and the presence of a supported runtime. Review the exact text
or JSON before sharing it. The command does not upload, write a report file,
or copy to the clipboard. File redirection is an explicit user action.

The demo uses synthetic samples and does not probe hardware or runtime APIs.
Live diagnostics read one saved snapshot; they do not collect a new trace.
Freshness is based on the supervisor timestamp and three polling intervals.
This does not prove that every runtime row is fresh or that Rainmeter rendered
the current snapshot. Those are separate roadmap items.

Diagnostic export currently accepts the Windows health v2 format. Native macOS
diagnostic export is not implemented. No claim of universal anonymization or
formal privacy certification is made.
