Set-StrictMode -Version Latest

function Read-UpdateField($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Assert-UpdateRepository([string]$Repository) {
    if ($Repository -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$' -or
        ($Repository -split '/')[1] -in @('.', '..')) { throw 'Use a GitHub repository in owner/name form.' }
}

function Get-GpuMonitorUpdateSettings {
    param([Parameter(Mandatory)][string]$Path)
    $value = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ((Read-UpdateField $value 'contract') -ne 'utils.gpu-monitor.updates.v1') { throw 'Unsupported update settings.' }
    $website = [uri][string](Read-UpdateField $value 'website_url' '')
    if (-not $website.IsAbsoluteUri -or $website.Scheme -ne 'https' -or $website.UserInfo -or $website.OriginalString -match '["\r\n]') { throw 'The website must be an HTTPS URL.' }
    $repository = [string](Read-UpdateField $value 'github_repository' '')
    if ($repository) { Assert-UpdateRepository $repository }
    [pscustomobject]@{ website_url = $website.AbsoluteUri; github_repository = $repository }
}

function ConvertTo-UpdateVersion([string]$Value) {
    if ($Value -notmatch '^v?(\d+\.\d+\.\d+)$') { throw 'Only stable MAJOR.MINOR.PATCH release versions are supported.' }
    return [version]$Matches[1]
}

function Assert-ReleaseAssetUri([string]$Url, [string]$Repository, [string]$Tag) {
    $uri = [uri]$Url
    $prefix = '/' + $Repository + '/releases/download/' + [uri]::EscapeDataString($Tag) + '/'
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or $uri.UserInfo -or
        -not $uri.AbsolutePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Release downloads must belong to the configured GitHub repository and release.'
    }
}

function Resolve-GpuMonitorRelease {
    param([Parameter(Mandatory)][string]$CurrentVersion, [Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)]$Release)
    Assert-UpdateRepository $Repository
    $current = ConvertTo-UpdateVersion $CurrentVersion
    $result = [pscustomobject][ordered]@{
        status = 'current'; installed_version = $current.ToString(); latest_version = ''; repository = $Repository
        repository_url = 'https://github.com/' + $Repository; message = ''; can_install = $false
        asset_name = ''; asset_url = ''; sha256 = ''; checksum_url = ''; tag = ''
    }
    if ((Read-UpdateField $Release 'draft' $false) -or (Read-UpdateField $Release 'prerelease' $false)) { throw 'This is not a published stable release.' }
    $tag = [string](Read-UpdateField $Release 'tag_name' '')
    $latest = ConvertTo-UpdateVersion $tag
    $result.latest_version = $latest.ToString(); $result.tag = $tag
    if ($latest -le $current) {
        $result.message = if ($latest -eq $current) { 'You have the latest published version.' } else { 'Your installed version is newer than the latest published release.' }
        return $result
    }
    $result.status = 'available'; $result.message = 'A newer version is available.'
    $name = 'BlooskAI-GpuMonitor-Windows-' + $latest.ToString() + '.zip'
    $assets = @(Read-UpdateField $Release 'assets' @())
    $matchingAssets = @($assets | Where-Object { (Read-UpdateField $_ 'name') -ceq $name })
    if ($matchingAssets.Count -ne 1) { $result.message = 'A newer release exists, but its Windows update package is unavailable.'; return $result }
    $asset = $matchingAssets[0]
    $size = [long](Read-UpdateField $asset 'size' 0)
    if ($size -le 0 -or $size -gt 100MB -or (Read-UpdateField $asset 'state' '') -ne 'uploaded') { throw 'The Windows release asset is incomplete or exceeds the update size limit.' }
    $url = [string](Read-UpdateField $asset 'browser_download_url' '')
    Assert-ReleaseAssetUri $url $Repository $tag
    $result.asset_name = $name; $result.asset_url = $url
    $digest = [string](Read-UpdateField $asset 'digest' '')
    if ($digest -match '^sha256:([a-fA-F0-9]{64})$') { $result.sha256 = $Matches[1].ToLowerInvariant() }
    if (-not $result.sha256) {
        $checksums = @($assets | Where-Object { (Read-UpdateField $_ 'name') -ceq 'SHA256SUMS' })
        if ($checksums.Count -eq 1) {
            $result.checksum_url = [string](Read-UpdateField $checksums[0] 'browser_download_url' '')
            Assert-ReleaseAssetUri $result.checksum_url $Repository $tag
        }
    }
    $result.can_install = [bool]($result.sha256 -or $result.checksum_url)
    if (-not $result.can_install) { $result.message = 'A newer release exists, but its package verification data is unavailable.' }
    return $result
}

function Get-GpuMonitorUpdateStatus {
    param([Parameter(Mandatory)][string]$CurrentVersion, [AllowEmptyString()][string]$Repository = '')
    $current = (ConvertTo-UpdateVersion $CurrentVersion).ToString()
    $result = [pscustomobject]@{ status = 'not_configured'; installed_version = $current; latest_version = ''; repository = $Repository; repository_url = ''; can_install = $false; message = 'GitHub updates will be available after the public repository and first release are connected.' }
    if (-not $Repository) { return $result }
    Assert-UpdateRepository $Repository
    $result.repository_url = 'https://github.com/' + $Repository
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $Repository + '/releases/latest') -TimeoutSec 10 -Headers @{
            'User-Agent' = 'BlooskAI-GpuMonitor'; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'
        } -ErrorAction Stop
        return Resolve-GpuMonitorRelease -CurrentVersion $current -Repository $Repository -Release $release
    } catch {
        $result.status = 'error'
        $response = Read-UpdateField $_.Exception 'Response'
        $statusCode = Read-UpdateField $response 'StatusCode' 0
        if ([int]$statusCode -eq 404) { $result.status = 'unpublished'; $result.message = 'No public GitHub release is available for this repository yet.' }
        elseif ([int]$statusCode -in @(403, 429)) { $result.message = 'GitHub temporarily limited update checks. Please try again later.' }
        else { $result.message = 'The update check could not be completed. Please try again later.' }
        return $result
    }
}

function Get-GpuMonitorPackageChecksum {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$AssetName)
    $values = @()
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^([a-fA-F0-9]{64})\s+\*?(.+?)\s*$') {
            $hash = $Matches[1]; $name = ($Matches[2].Replace('\', '/') -split '/')[-1]
            if ($name -ceq $AssetName) { $values += $hash.ToLowerInvariant() }
        }
    }
    if ($values.Count -ne 1) { throw 'The checksum list must identify the Windows package exactly once.' }
    return $values[0]
}

function Expand-GpuMonitorUpdatePackage {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Sha256)
    if ($Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -ne $Sha256) { throw 'The downloaded package failed SHA-256 verification.' }
    if (Test-Path -LiteralPath $Destination) { throw 'The update extraction directory must be new.' }
    $versionText = (ConvertTo-UpdateVersion $Version).ToString()
    $prefix = 'BlooskAI-GpuMonitor-Windows-' + $versionText + '/'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if ($zip.Entries.Count -gt 1000) { throw 'The update package has too many files.' }
        $total = 0L; $seen = @{}
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if ($name.IndexOf([char]92) -ge 0 -or $name.Contains(':') -or $name -match '(^|/)\.\.?(/|$)' -or
                -not $name.StartsWith($prefix, [StringComparison]::Ordinal) -or $seen.ContainsKey($name)) { throw 'Unsafe or unexpected archive path.' }
            $seen[$name] = $true; $total += $entry.Length
            if ($total -gt 100MB) { throw 'Expanded update package exceeds the size limit.' }
            if ($entry.PSObject.Properties['ExternalAttributes'] -and (($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960) { throw 'Symbolic links are not allowed in update packages.' }
        }
    } finally { $zip.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Destination)
    $root = Join-Path $Destination $prefix.TrimEnd('/')
    foreach ($required in @('GpuMonitor.psm1', 'service/install.ps1', 'service/run-hidden.vbs', 'skin/UtilsGpuMonitor.ini', 'package-manifest.json', 'update-settings.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $required) -PathType Leaf)) { throw 'The update package is incomplete.' }
    }
    $manifest = [IO.File]::ReadAllText((Join-Path $root 'package-manifest.json')) | ConvertFrom-Json
    if ((Read-UpdateField $manifest 'contract') -ne 'utils.gpu-monitor.package.v1' -or (Read-UpdateField $manifest 'platform') -ne 'windows' -or (Read-UpdateField $manifest 'version') -ne $versionText) { throw 'The package manifest does not match this Windows release.' }
    $null = Get-GpuMonitorUpdateSettings -Path (Join-Path $root 'update-settings.json')
    return $root
}

function Save-GpuMonitorReleaseFile {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Destination, [long]$MaximumBytes = 100MB)
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = 'BlooskAI-GpuMonitor'; $request.Timeout = 15000; $request.ReadWriteTimeout = 30000
    $request.MaximumAutomaticRedirections = 5
    $response = $null; $stream = $null; $file = $null
    try {
        $response = $request.GetResponse()
        if ($response.ResponseUri.Scheme -ne 'https' -or $response.ResponseUri.Host -notin @('github.com','release-assets.githubusercontent.com','objects.githubusercontent.com','github-releases.githubusercontent.com')) { throw 'Unexpected release download destination.' }
        if ($response.ContentLength -gt $MaximumBytes) { throw 'Release download exceeds the size limit.' }
        $stream = $response.GetResponseStream(); $file = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew)
        $buffer = New-Object byte[] 8192; $total = 0L
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $count
            if ($total -gt $MaximumBytes) { throw 'Release download exceeds the size limit.' }
            $file.Write($buffer, 0, $count)
        }
    } finally {
        if ($file) { $file.Dispose() }; if ($stream) { $stream.Dispose() }; if ($response) { $response.Close() }
    }
}

function Invoke-GpuMonitorInstaller {
    param([Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)]$Manifest, [AllowEmptyString()][string]$Repository)
    $gpu = [int](Read-UpdateField $Manifest 'gpu_index' 0); $detail = [int](Read-UpdateField $Manifest 'detail_seconds' 10)
    if ($gpu -lt 0 -or $gpu -gt 31 -or $detail -lt 2 -or $detail -gt 600) { throw 'Invalid installed sampling settings.' }
    if ($Repository) { Assert-UpdateRepository $Repository }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
    $info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -GpuIndex {1} -DetailSeconds {2}' -f $Script, $gpu, $detail
    if ($Repository) { $info.Arguments += ' -GitHubRepository "' + $Repository + '"' }
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    try { $process.WaitForExit(); return $process.ExitCode } finally { $process.Dispose() }
}

function Invoke-GpuMonitorUpdate {
    param([Parameter(Mandatory)]$Release, [Parameter(Mandatory)][string]$InstallRoot, [Parameter(Mandatory)][string]$WorkParent,
        [scriptblock]$Downloader, [scriptblock]$InstallerRunner, [scriptblock]$Progress)
    if (-not $Release.can_install -or $Release.status -ne 'available') { throw 'No verified update is available to install.' }
    Assert-UpdateRepository $Release.repository
    Assert-ReleaseAssetUri $Release.asset_url $Release.repository $Release.tag
    if ($Release.checksum_url) { Assert-ReleaseAssetUri $Release.checksum_url $Release.repository $Release.tag }
    if (-not $Downloader) { $Downloader = { param($Url,$Path,$Limit) Save-GpuMonitorReleaseFile -Url $Url -Destination $Path -MaximumBytes $Limit } }
    if (-not $InstallerRunner) { $InstallerRunner = { param($Script,$Manifest,$Repository) Invoke-GpuMonitorInstaller -Script $Script -Manifest $Manifest -Repository $Repository } }
    $manifest = [IO.File]::ReadAllText((Join-Path $InstallRoot 'install-manifest.json')) | ConvertFrom-Json
    $manifestHash = (Get-FileHash -LiteralPath (Join-Path $InstallRoot 'install-manifest.json') -Algorithm SHA256).Hash
    if ((Read-UpdateField $manifest 'version') -ne $Release.installed_version) { throw 'The installed version changed. Check for updates again.' }
    $workspace = Join-Path ([IO.Path]::GetFullPath($WorkParent)) ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
    $backup = Join-Path $workspace 'previous'; $installStarted = $false; $keepWorkspace = $false
    $owned = @('GpuMonitor.psm1','README.md','LICENSE','NOTICE','install-manifest.json','update-settings.json','service','skin','docs','contracts')
    try {
        if ($Progress) { & $Progress 'Downloading the release package...' | Out-Null }
        $archive = Join-Path $workspace $Release.asset_name
        & $Downloader $Release.asset_url $archive 100MB | Out-Null
        $hash = $Release.sha256
        if (-not $hash) {
            $checksumFile = Join-Path $workspace 'SHA256SUMS'
            & $Downloader $Release.checksum_url $checksumFile 1MB | Out-Null
            $hash = Get-GpuMonitorPackageChecksum -Text ([IO.File]::ReadAllText($checksumFile)) -AssetName $Release.asset_name
        }
        if ($Progress) { & $Progress 'Verifying the downloaded package...' | Out-Null }
        $package = Expand-GpuMonitorUpdatePackage -Archive $archive -Destination (Join-Path $workspace 'package') -Version $Release.latest_version -Sha256 $hash
        if ((Get-FileHash -LiteralPath (Join-Path $InstallRoot 'install-manifest.json') -Algorithm SHA256).Hash -ne $manifestHash) { throw 'The installation changed during the download. Check for updates again.' }
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        foreach ($name in $owned) {
            $source = Join-Path $InstallRoot $name
            if (Test-Path -LiteralPath $source) {
                if (@(Get-ChildItem -LiteralPath $source -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -or ((Get-Item -LiteralPath $source).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked runtime paths cannot be backed up safely.' }
                Copy-Item -LiteralPath $source -Destination $backup -Recurse -Force
            }
        }
        if ($Progress) { & $Progress 'Installing the update...' | Out-Null }
        $installStarted = $true
        $exitCode = & $InstallerRunner (Join-Path $package 'service/install.ps1') $manifest $Release.repository
        $installed = [IO.File]::ReadAllText((Join-Path $InstallRoot 'install-manifest.json')) | ConvertFrom-Json
        if ($exitCode -ne 0 -or (Read-UpdateField $installed 'version') -ne $Release.latest_version) { throw 'The new version did not finish installing.' }
        return [pscustomobject]@{ status = 'updated'; version = $Release.latest_version }
    } catch {
        $failure = $_
        if ($installStarted) {
            try {
                foreach ($name in $owned) { $source = Join-Path $backup $name; if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $InstallRoot -Recurse -Force } }
                $repairCode = & $InstallerRunner (Join-Path $InstallRoot 'service/install.ps1') $manifest $Release.repository
                if ($repairCode -ne 0) { throw 'Previous installation could not be restarted.' }
            } catch { $keepWorkspace = $true; throw ('Update failed and automatic recovery could not finish. Previous files are retained in ' + $backup) }
            throw 'The update did not finish. The previous version was restored.'
        }
        throw $failure
    } finally {
        $full = [IO.Path]::GetFullPath($workspace)
        if ([IO.Path]::GetDirectoryName($full) -ne [IO.Path]::GetFullPath($WorkParent).TrimEnd('\','/')) { throw 'Unsafe update workspace cleanup.' }
        if (-not $keepWorkspace) { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function Get-GpuMonitorUpdateSettings, Get-GpuMonitorUpdateStatus, Resolve-GpuMonitorRelease,
    Get-GpuMonitorPackageChecksum, Expand-GpuMonitorUpdatePackage, Invoke-GpuMonitorInstaller, Invoke-GpuMonitorUpdate
