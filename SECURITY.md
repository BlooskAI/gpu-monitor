# Security reporting

Do not include credentials, private model names, prompts, full command lines,
or raw `health.json` files in public issues. The Windows `service/diagnose.ps1`
command produces an allowlisted report; inspect it before sharing.

For a vulnerability, use the repository host's private vulnerability reporting
channel when enabled. If it is unavailable, ask the maintainer for a private
contact channel without posting exploit details. A public release should enable
private reporting and identify a monitored contact before announcements.

GPU Monitor observes local hardware and supported runtime registries. It does
not need model API credentials for the currently supported default probes.
Diagnostic export does not upload anything. See [privacy](docs/privacy.md) for
the difference between local runtime state and shareable reports.
