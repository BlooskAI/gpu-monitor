# Optional GPU ownership claims

The Windows monitor can read a small JSON record from any application or worker.
It records declared intent to use the GPU. It does not reserve the GPU, enforce
exclusive access, or prove that a particular model is resident. The monitor
does not create, release, or modify claims. No separate CLI tool is required.
The macOS app does not currently read this interface.

## File selection

`Get-GpuClaim` selects one location in this order:

1. A nonblank explicit `-Path` argument.
2. A nonblank `GPUMONITOR_CLAIM_PATH` environment variable in the reader process.
3. `%LOCALAPPDATA%\LocalAISettings\gpu-claim.json`, the compatibility location
   used by existing writers.

A missing configured file returns `state=none`, even if a legacy claim exists.
Unreadable or malformed JSON returns `state=unreadable`. A configured file never
silently falls back to another file. Unknown fields are ignored; missing optional
fields become empty strings. Unknown states render as `unclaimed`.

For the installed monitor, set the user environment variable before signing in
again so that the logon supervisor inherits it:

```powershell
$claimPath = Join-Path $env:LOCALAPPDATA 'Utils\GpuMonitor\gpu-claim.json'
[Environment]::SetEnvironmentVariable('GPUMONITOR_CLAIM_PATH', $claimPath, 'User')
```

For a collector launched from the current shell, set `$env:GPUMONITOR_CLAIM_PATH`
before starting it. An API caller can use an explicit path immediately:

```powershell
Import-Module .\GpuMonitor.psm1
Get-GpuClaim -Path $claimPath
```

To restore the compatibility default for future sessions, remove the user
environment variable and sign in again. Remove a shell override with
`Remove-Item Env:GPUMONITOR_CLAIM_PATH -ErrorAction SilentlyContinue`.

## Writer format

The schema is [gpu-claim.schema.json](../contracts/gpu-claim.schema.json).
The existing unversioned format remains valid; no new field is required.

| Field | Meaning |
| --- | --- |
| `state` | `held` or `released`. This is the only required field. |
| `holder` | Name of the application or worker. Recommended for a held claim. |
| `note` | Optional local description. |
| `claimed_at` | Optional ISO 8601 timestamp with UTC or an offset. |
| `released_at` | Optional release timestamp. Empty or null is accepted. |
| `next_for` | Optional name of the next owner. |

Keep timestamps and optional fields empty or omit them when unavailable.
Readers tolerate older or incomplete records. The schema describes a valid
writer record; the reader does not reject extra fields or enforce the schema.

A worker can write a held record using the exported atomic writer. Atomic
replacement prevents readers from observing a partially written JSON file.

```powershell
Import-Module .\GpuMonitor.psm1
$claimPath = Join-Path $env:LOCALAPPDATA 'Utils\GpuMonitor\gpu-claim.json'
Write-AtomicJson -Path $claimPath -Value @{
    state = 'held'
    holder = 'example-worker'
    note = 'Processing a queued job'
    claimed_at = [DateTime]::UtcNow.ToString('o')
}

# The owning worker publishes release when it is finished.
Write-AtomicJson -Path $claimPath -Value @{
    state = 'released'
    holder = 'example-worker'
    released_at = [DateTime]::UtcNow.ToString('o')
    next_for = 'next-worker'
}
```

Use one coordinated writer per file. Concurrent publishers are not arbitrated;
the latest replacement wins. The existing warning can report a held claim
during sustained low GPU load. It is a signal to inspect the owning application.
It does not prove that the worker failed or that memory is leaking.

Claims, including their names and notes, remain local in normal runtime state.
Do not put credentials or prompts in them. The allowlisted diagnostic export
omits claim text and paths. See [diagnostic privacy](privacy.md).
