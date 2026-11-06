[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root ('dist/release-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')) }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Choose a new output directory to preserve prior releases.' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
& (Join-Path $PSScriptRoot 'build-public-source.ps1') -OutputDirectory (Join-Path $OutputDirectory 'source')
& (Join-Path $PSScriptRoot 'build-windows.ps1') -OutputDirectory (Join-Path $OutputDirectory 'windows')
& (Join-Path $PSScriptRoot 'build-macos-source.ps1') -OutputDirectory (Join-Path $OutputDirectory 'macos-source')
$lines = @(Get-ChildItem -LiteralPath $OutputDirectory -Filter *.zip -Recurse -File | Sort-Object Name | ForEach-Object {
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.Name
})
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'SHA256SUMS'), ($lines -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
Write-Host "Release files: $OutputDirectory"
