[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$')][string]$Version = '2.2.0',
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
& (Join-Path $root 'tests/public-hygiene.ps1') -Root $root
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }
$stageName = "BlooskAI-GpuMonitor-Windows-$Version"
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
# Copy reviewed files individually. Recursive folder copies can include ignored
# Paths.inc, runtime captures, or other private files in a developer checkout.
$files = @([IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'public-files.txt')) | Where-Object {
    $_ -match '^(GpuMonitor\.psm1|README\.md|LICENSE|NOTICE|CONTRIBUTING\.md|SECURITY\.md|ROADMAP\.md|RESPONSIVENESS_ROADMAP\.md|Install GPU Monitor\.cmd|update-settings\.json)$|^(docs|service|skin|contracts)/'
})
foreach ($relative in $files) {
    $destination = Join-Path $stage $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $destination
}

$manifest = [ordered]@{
    contract = 'utils.gpu-monitor.package.v1'
    platform = 'windows'
    version = $Version
    created_at = [DateTime]::UtcNow.ToString('o')
    entrypoint = 'Install GPU Monitor.cmd'
}
[IO.File]::WriteAllText((Join-Path $stage 'package-manifest.json'), ($manifest | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))

# Windows PowerShell's Compress-Archive can write backslash entry names.
# Name every file explicitly so the ZIP extracts correctly on every platform.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open($archive, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($relative in ($files + 'package-manifest.json')) {
        $entry = ($stageName + '/' + $relative).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $stage $relative),
            $entry, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally { $zip.Dispose() }
Write-Host "Built $archive"
