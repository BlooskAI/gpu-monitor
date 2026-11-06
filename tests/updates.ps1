$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'service/UpdateSupport.psm1') -Force
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
function Assert($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Reject([scriptblock]$Operation, [string]$Message) {
    $rejected = $false
    try { & $Operation | Out-Null } catch { $rejected = $true }
    Assert $rejected $Message
}
function New-Release([string]$Version = '2.10.0') {
    $name = 'BlooskAI-GpuMonitor-Windows-' + $Version + '.zip'
    [pscustomobject]@{ tag_name = 'v' + $Version; draft = $false; prerelease = $false; assets = @(
        [pscustomobject]@{ name = $name; state = 'uploaded'; size = 100; digest = 'sha256:' + ('a' * 64); browser_download_url = 'https://github.com/Example/Monitor/releases/download/v' + $Version + '/' + $name }
    ) }
}
function New-Package([string]$Path, [string]$BadEntry = '') {
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    $files = @{
        'GpuMonitor.psm1' = '# new module'
        'service/install.ps1' = '# synthetic installer; never executed'
        'service/run-hidden.vbs' = "' synthetic launcher"
        'skin/UtilsGpuMonitor.ini' = '[Rainmeter]'
        'package-manifest.json' = '{"contract":"utils.gpu-monitor.package.v1","platform":"windows","version":"2.10.0"}'
        'update-settings.json' = '{"contract":"utils.gpu-monitor.updates.v1","website_url":"https://www.bizniqueinc.com/blooskai","github_repository":""}'
    }
    if ($BadEntry) { $files[$BadEntry] = 'unsafe fixture' }
    try {
        foreach ($name in $files.Keys) {
            $entry = $zip.CreateEntry('BlooskAI-GpuMonitor-Windows-2.10.0/' + $name)
            $writer = New-Object IO.StreamWriter($entry.Open())
            try { $writer.Write($files[$name]) } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('gpu-updates-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $settings = Get-GpuMonitorUpdateSettings -Path (Join-Path $root 'update-settings.json')
    Assert ($settings.website_url -eq 'https://www.bizniqueinc.com/blooskai') 'The website does not match the approved URL.'
    $none = Get-GpuMonitorUpdateStatus -CurrentVersion '2.2.0'
    Assert ($none.status -eq 'not_configured' -and -not $none.can_install) 'Unconfigured updates must not make a network request or offer installation.'
    $release = New-Release
    $resolved = Resolve-GpuMonitorRelease '2.9.0' 'Example/Monitor' $release
    Assert ($resolved.can_install -and $resolved.latest_version -eq '2.10.0' -and $resolved.sha256 -eq ('a' * 64)) 'Stable versions or GitHub asset digest resolved incorrectly.'
    Assert ((Resolve-GpuMonitorRelease '2.10.0' 'Example/Monitor' $release).status -eq 'current') 'Equal versions offered an update.'
    Assert (-not (Resolve-GpuMonitorRelease '3.0.0' 'Example/Monitor' $release).can_install) 'An update offered a downgrade.'
    $release.prerelease = $true
    Reject { Resolve-GpuMonitorRelease '2.2.0' 'Example/Monitor' $release } 'A prerelease was accepted.'
    $release = New-Release; $release.tag_name = 'v2.10.0;bad'
    Reject { Resolve-GpuMonitorRelease '2.2.0' 'Example/Monitor' $release } 'An invalid release tag was accepted.'
    $release = New-Release; $release.assets[0].browser_download_url = 'https://example.org/package.zip'
    Reject { Resolve-GpuMonitorRelease '2.2.0' 'Example/Monitor' $release } 'A foreign asset URL was accepted.'
    $release = New-Release; $release.assets[0].digest = ''
    Assert (-not (Resolve-GpuMonitorRelease '2.2.0' 'Example/Monitor' $release).can_install) 'An unverified package was offered for installation.'
    $release.assets += [pscustomobject]@{ name = 'SHA256SUMS'; browser_download_url = 'https://github.com/Example/Monitor/releases/download/v2.10.0/SHA256SUMS' }
    Assert ((Resolve-GpuMonitorRelease '2.2.0' 'Example/Monitor' $release).can_install) 'The SHA256SUMS fallback failed.'
    $sum = ('b' * 64) + '  BlooskAI-GpuMonitor-Windows-2.10.0.zip'
    Assert ((Get-GpuMonitorPackageChecksum $sum 'BlooskAI-GpuMonitor-Windows-2.10.0.zip') -eq ('b' * 64)) 'The release checksum was not read.'
    Reject { Get-GpuMonitorPackageChecksum ($sum + "`n" + $sum) 'BlooskAI-GpuMonitor-Windows-2.10.0.zip' } 'Duplicate checksums were accepted.'

    $archive = Join-Path $fixture 'good.zip'; New-Package $archive
    $hash = (Get-FileHash $archive -Algorithm SHA256).Hash
    $expanded = Expand-GpuMonitorUpdatePackage $archive (Join-Path $fixture 'expanded') '2.10.0' $hash
    Assert (Test-Path (Join-Path $expanded 'service/install.ps1')) 'A valid package did not extract.'
    Reject { Expand-GpuMonitorUpdatePackage $archive (Join-Path $fixture 'hash-failure') '2.10.0' ('0' * 64) } 'A damaged download was accepted.'
    Assert (-not (Test-Path (Join-Path $fixture 'hash-failure'))) 'A damaged download was extracted.'
    foreach ($bad in @('../outside.txt', 'sub/../../outside.txt', 'folder\file.txt', 'drive:file.txt')) {
        $badZip = Join-Path $fixture ([guid]::NewGuid().ToString('N') + '.zip'); New-Package $badZip $bad
        $badHash = (Get-FileHash $badZip -Algorithm SHA256).Hash
        Reject { Expand-GpuMonitorUpdatePackage $badZip (Join-Path $fixture 'bad-extract') '2.10.0' $badHash } 'An unsafe ZIP path was accepted.'
    }

    $runtime = Join-Path $fixture 'installed'; New-Item -ItemType Directory -Path (Join-Path $runtime 'service') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $runtime 'GpuMonitor.psm1'), '# previous module')
    [IO.File]::WriteAllText((Join-Path $runtime 'service/install.ps1'), '# previous installer')
    $oldManifest = '{"version":"2.9.0","gpu_index":2,"detail_seconds":25}'
    [IO.File]::WriteAllText((Join-Path $runtime 'install-manifest.json'), $oldManifest)
    $resolved = Resolve-GpuMonitorRelease '2.9.0' 'Example/Monitor' (New-Release); $resolved.sha256 = $hash
    $downloader = { param($Url,$Path,$Limit) Copy-Item -LiteralPath $archive -Destination $Path }.GetNewClosure()
    $runner = {
        param($Script,$Manifest,$Repository)
        Assert ($Manifest.gpu_index -eq 2 -and $Manifest.detail_seconds -eq 25 -and $Repository -eq 'Example/Monitor') 'Update lost the installed settings.'
        [IO.File]::WriteAllText((Join-Path $runtime 'install-manifest.json'), '{"version":"2.10.0","gpu_index":2,"detail_seconds":25}')
        return 0
    }.GetNewClosure()
    $result = Invoke-GpuMonitorUpdate $resolved $runtime (Join-Path $fixture 'work') -Downloader $downloader -InstallerRunner $runner
    Assert ($result.status -eq 'updated') 'The verified installation did not complete.'

    [IO.File]::WriteAllText((Join-Path $runtime 'install-manifest.json'), $oldManifest)
    $failedRunner = {
        param($Script,$Manifest,$Repository)
        if ($Script -eq (Join-Path $runtime 'service/install.ps1')) { return 0 }
        [IO.File]::WriteAllText((Join-Path $runtime 'GpuMonitor.psm1'), '# partial replacement')
        return 1
    }.GetNewClosure()
    Reject { Invoke-GpuMonitorUpdate $resolved $runtime (Join-Path $fixture 'work') -Downloader $downloader -InstallerRunner $failedRunner } 'A failed installer was reported as successful.'
    Assert ([IO.File]::ReadAllText((Join-Path $runtime 'GpuMonitor.psm1')) -eq '# previous module') 'Recovery did not restore the previous module.'
    Assert ([IO.File]::ReadAllText((Join-Path $runtime 'install-manifest.json')) -eq $oldManifest) 'Recovery lost the previous install settings.'
    Assert (@(Get-ChildItem (Join-Path $fixture 'work') -Force).Count -eq 0) 'Completed update workspaces were not removed.'
    $changedDownloader = {
        param($Url,$Path,$Limit)
        Copy-Item -LiteralPath $archive -Destination $Path
        [IO.File]::WriteAllText((Join-Path $runtime 'install-manifest.json'), '{"version":"2.9.0","gpu_index":3,"detail_seconds":25}')
    }.GetNewClosure()
    Reject { Invoke-GpuMonitorUpdate $resolved $runtime (Join-Path $fixture 'work') -Downloader $changedDownloader -InstallerRunner { throw 'Installer must not run after concurrent changes.' } } 'An installation changed during download was overwritten.'
    Assert (([IO.File]::ReadAllText((Join-Path $runtime 'install-manifest.json')) | ConvertFrom-Json).gpu_index -eq 3) 'The updater overwrote a concurrent settings change.'
    Write-Host 'PASS updates: stable versions, unconfigured state, release URLs, digests, checksum fallback, ZIP paths, settings preservation, and failure recovery'
} finally {
    $resolvedPath = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolvedPath) -ne [IO.Path]::GetTempPath().TrimEnd('\','/')) { throw 'Unsafe updater fixture cleanup.' }
    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}
