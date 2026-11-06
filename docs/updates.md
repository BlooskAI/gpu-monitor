# Links, updates, and repair

The Windows panel has three footer controls:

- **BlooskAI** opens <https://www.bizniqueinc.com/blooskai>.
- **Options** opens the custom menu. Right-clicking the panel also opens the
  Rainmeter menu, with these controls under **Custom skin actions**.
- **Updates** checks the latest stable GitHub release. A newer release enables
  **Install update**. Installation requires confirmation and restarts the monitor.

The menu also has **Restart monitor** and **Repair installation**. Restart only
restarts monitoring. Repair restores the installed skin and scheduled tasks from
the local installed copy. It preserves the panel position, GPU index, sampling
cadence, and repository setting. It does not download a new version. If installed
files are missing or damaged, run the installer from a release package instead.

## Public repository setup

`update-settings.json` contains the website URL and optional `github_repository`
in `owner/name` form. The repository field is intentionally empty before public
publication. The update control then explains that updates are not available.
It sends no network request and does not display a dead repository link.

After creating the public repository, set this field in public source and build
a release. An existing Windows installation can also be connected with:

```powershell
.\service\install.ps1 -GitHubRepository 'OWNER/REPOSITORY'
```

Use the actual public repository name. The installer adds its GitHub menu link.
An unconfigured source package preserves an existing repository setting on
reinstall. An explicit empty parameter clears it. The setting is stored in the
user-local installed copy. No access token is required for public release checks.

## Release process

Run the source, installer, updater, hygiene, and package checks first. Then run:

```powershell
.\packaging\build-release.ps1
```

This creates new source, Windows, and macOS source ZIPs plus `SHA256SUMS` in a
new output directory. Review them and upload the ZIPs and `SHA256SUMS` to a
published, stable GitHub release tagged `vMAJOR.MINOR.PATCH`. The tag, Windows
asset name, package manifest, and installed version must agree. Bump all product
version fields together before building a new version; the live smoke check
detects inconsistent version fields. Do not rename the Windows asset:
`BlooskAI-GpuMonitor-Windows-MAJOR.MINOR.PATCH.zip`.

The updater uses GitHub's latest-release API. It accepts a Windows asset from
that same repository and tag. It verifies the SHA-256 digest from GitHub asset
metadata, or the exact asset entry in `SHA256SUMS`. This checks package integrity;
it is not an independent code signature. Trust in the configured repository and
its maintainers is required.

Downloads and expanded archives have size limits. ZIP paths, duplicate entries,
symbolic links, required files, and the package manifest are checked before
installation. The updater backs up the previous runtime and attempts to restore
it if installation fails. If recovery fails, the error identifies the retained
backup. Panel settings and telemetry remain outside the temporary update folder.

Checks run only when requested. They contact GitHub and its release-download
hosts. They do not upload telemetry, model names, process lists, or runtime data.
Network failures and missing releases are shown as such, never as an up-to-date
result. A window lock prevents concurrent checks or repairs in the same session.

The native macOS source does not yet include this Windows update control. Linux
does not have a supported desktop package.
