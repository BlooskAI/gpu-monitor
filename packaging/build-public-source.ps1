[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$')][string]$Version = '2.2.0',
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
& (Join-Path $root 'tests/public-hygiene.ps1') -Root $root
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
$name = 'BlooskAI-GpuMonitor-Source-' + $Version + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$stage = Join-Path $output $name
$archive = $stage + '.zip'

# Deliberate allowlist: no Git metadata, local captures, or response histories.
# Keep staging for inspection. Each build is unique and overwrites nothing.
# File.ReadAllLines avoids PowerShell 5.1's provider metadata on Get-Content
# strings, which ConvertTo-Json otherwise serializes along with local paths.
$files = @([IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'public-files.txt')) |
    Where-Object { $_.Trim() -and -not $_.StartsWith('#') })
$resolved = foreach ($relative in $files) {
    if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[/\\])\.\.([/\\]|$)' -or $relative.Contains(':')) {
        throw "Invalid public source path: $relative"
    }
    $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Public source path escaped the checkout: $relative"
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing public source file: $relative" }
    $item = Get-Item -LiteralPath $path
    $ancestor = $item
    while ($ancestor -and $ancestor.FullName -ne $root) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked public source path: $relative" }
        $ancestor = if ($ancestor -is [IO.DirectoryInfo]) { $ancestor.Parent } else { $ancestor.Directory }
    }
    [pscustomobject]@{ relative = $relative; path = $path }
}
New-Item -ItemType Directory -Path $stage -ErrorAction Stop | Out-Null
$manifest = foreach ($file in $resolved) {
    $destination = Join-Path $stage $file.relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $file.path -Destination $destination
    [ordered]@{ path = $file.relative; sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$metadata = [ordered]@{ version = $Version; files = @($manifest) }
[IO.File]::WriteAllText((Join-Path $stage 'SOURCE_MANIFEST.json'), ($metadata | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
# ZipFile includes .github and .gitignore; Compress-Archive can skip hidden files.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open($archive, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($relative in ($files + 'SOURCE_MANIFEST.json')) {
        # .NET Framework's CreateFromDirectory uses backslashes on Windows;
        # explicit portable entry names also extract correctly on macOS/Linux.
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $stage $relative),
            $relative.Replace('\', '/'), [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally { $zip.Dispose() }
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(($archive + '.sha256'), ($hash + '  ' + [IO.Path]::GetFileName($archive) + [Environment]::NewLine))
Write-Host "Public source: $archive"
Write-Host "Review tree : $stage"
Write-Host "Files       : $($files.Count) plus SOURCE_MANIFEST.json; no Git history included"
