[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$')][string]$Version = '2.2.0',
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
& (Join-Path $root 'tests/public-hygiene.ps1') -Root $root
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }
$stageName = "BlooskAI-GpuMonitor-macOS-Source-$Version"
$stage = Join-Path $OutputDirectory $stageName
$archive = Join-Path $OutputDirectory ($stageName + '.zip')

if (Test-Path -LiteralPath $stage) {
    $resolvedStage = (Resolve-Path -LiteralPath $stage).Path
    $resolvedOutput = (Resolve-Path -LiteralPath $OutputDirectory).Path.TrimEnd('\', '/')
    if ([IO.Path]::GetDirectoryName($resolvedStage) -ne $resolvedOutput -or
        ((Get-Item -LiteralPath $stage).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe staging directory.' }
    Remove-Item -LiteralPath $resolvedStage -Recurse -Force
}
if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

$files = @([IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'public-files.txt')) | Where-Object {
    $_ -match '^(LICENSE|NOTICE)$|^(macos|contracts)/'
})
foreach ($relative in $files) {
    $target = if ($relative.StartsWith('macos/')) { $relative.Substring(6) } else { $relative }
    $destination = Join-Path $stage $target
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $destination
}

$manifest = [ordered]@{
    contract = 'utils.gpu-monitor.package.v1'
    platform = 'macos-source'
    version = $Version
    created_at = [DateTime]::UtcNow.ToString('o')
    entrypoint = 'Install GPU Monitor.command'
    build_requires = 'macOS 13+ and Xcode Command Line Tools'
}
[IO.File]::WriteAllText((Join-Path $stage 'package-manifest.json'), ($manifest | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open($archive, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($relative in ($files + 'package-manifest.json')) {
        $target = if ($relative.StartsWith('macos/')) { $relative.Substring(6) } else { $relative }
        $entry = ($stageName + '/' + $target).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $stage $target),
            $entry, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally { $zip.Dispose() }
Write-Host "Built $archive"
