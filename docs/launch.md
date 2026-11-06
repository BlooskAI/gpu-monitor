# Open source launch plan

Launch around a concrete question: **Why is my GPU full when it is doing
nothing?** Show the loaded model, a short workload history, and the limits of
the available evidence. The audience is people running local AI on their own
machines. Broad attention is uncertain; a useful diagnosis that someone can
reproduce and share is a practical starting point.

## Positioning

General device/process monitoring is already served by
[nvtop](https://github.com/Syllo/nvtop) and
[nvitop](https://github.com/XuehaiPan/nvitop). Local-AI metrics, demos, and
diagnostic output also appear in [toptop](https://github.com/ur-grue/toptop).
Those project descriptions were reviewed on October 6, 2026; this is not a
feature-by-feature benchmark.

The opportunity to test is a persistent desktop view that connects model
residency, declared ownership, and workload history across Windows and WSL.
Request timing and measured model handoffs can deepen that story. A generic
GPU graph, tokens/s alone, or a diagnostic command is not a unique claim.

## Prepared in this checkout

- Apache-2.0 license and dependency notice.
- A README with a runnable synthetic demo and explicit platform boundaries.
- A text/JSON export that omits identifying strings by construction.
- Offline regression checks, a GitHub Actions workflow, and a bug-report template.
- A public source packager using `packaging/public-files.txt`, a file manifest,
  and a ZIP checksum. It creates an inspectable copy without Git history.

## Before publication

### Public source boundary

The private development history contains a previously tracked response-history
file. Removing it from the current index or adding an ignore rule does not
remove earlier versions. Retain the private checkout and its remote separately
from the repository prepared for publication.

Run `tests/public-hygiene.ps1`, then `packaging/build-public-source.ps1`.
The packager uses `packaging/public-files.txt` as the complete source list.
It excludes Git metadata, local agent histories, workstation configuration,
runtime data, model weights, and generated output. Inspect the generated tree,
ZIP manifest, and checksum. Initialize a new Git repository from that reviewed
tree and create one initial commit. Do not clone or copy the private `.git`
directory into it. Check that it has exactly one root commit, no private remote,
and no private refs. Run the source, installer, hygiene, and package tests there
before adding the public remote. The generated `SOURCE_MANIFEST.json` remains
ignored by Git; retain it with the source ZIP as a release artifact.

Review the new commit's author name and email before publication. Use the chosen
GitHub account's noreply address to avoid exposing the login email. Keep previous
history candidates, local rewrite scripts, and QA reports outside the public
source list; they can contain the private strings that were removed.

The hygiene check screens common credential patterns and personal paths. It
does not prove that every secret format or identifying detail has been found.
If a credential is found in history, revoke it through its provider before
publication; removing a file or rewriting history does not revoke credentials.

### Release checks

1. Build the source package and review its exact files. Check the exported
   source and documentation for secrets, private identifiers, incompatible
   copied code, and broken links. An allowlist controls which files enter;
   it does not certify every byte inside them.
2. Create the public repository with one initial commit from the reviewed
   snapshot. Preserve the private checkout, local histories, and existing remote.
3. Run hygiene checks, offline checks, and packaging from the exported tree.
   Let hosted CI compile macOS, then test the native app on an actual Mac before
   claiming it works there.
4. Complete a clean Windows installation and removal, validate endpoint
   configuration, and record measured monitoring overhead. Track unsupported
   device/runtime combinations in the release notes.
5. Set the public repository owner/name, enable private vulnerability reporting,
   and provide a monitored maintainer contact. Review the public description and
   release assets before posting.

Set `github_repository` in `update-settings.json` only after the public repository
exists. Build the versioned Windows ZIP and `SHA256SUMS` with
`packaging/build-release.ps1`, then attach them to a stable release. The footer
and right-click update controls remain unconfigured until that step. See
[updates and repair](updates.md). Publish the reviewed product page from
`website/gpu-monitor.html` under the existing BlooskAI website. Replace its pending
release text with the verified public repository and download links at launch.

## Demonstration and announcement

Record a 20-30 second clip of the desktop panel: load a model, run a small job,
then let it remain resident. Keep the model and process names synthetic or
reviewed. Close with the matching diagnostic output. Do not present the
synthetic CLI demo as a real benchmark or as an implemented visual demo mode.

Suggested announcement, after the release checks pass:

> I built a desktop GPU monitor for local AI because 0% utilization was not
> telling me why my VRAM was still full. It shows loaded models, workload
> history, and memory that no runtime can name. The Windows version works
> with Rainmeter; the Mac version currently covers hardware telemetry.
> Apache-2.0, with a synthetic diagnostic demo you can try without a GPU.

Publish a useful technical explanation with the release: how WDDM/WSL limits
attribution, what idle-held memory does and does not mean, and how the monitor
keeps unknown measurements distinct from zero. Invite hardware compatibility
reports and small adapter contributions. Follow each community's posting rules
and identify yourself as the maintainer when sharing it.

## Evidence of traction

Track successful installs, users returning after a week, actionable bug reports,
accepted adapter contributions, and examples where the monitor clarified a real
problem. Stars and views describe attention, not whether the product helped.
Use voluntary feedback and repository activity; do not add background analytics
just to measure the launch.
