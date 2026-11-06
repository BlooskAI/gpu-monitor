$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$installer = [IO.File]::ReadAllText((Join-Path $root 'service/install.ps1'))
Import-Module (Join-Path $root 'service/UpdateSupport.psm1') -Force

function Invoke-InstallFixture([bool]$LegacyShortcut, [bool]$LegacyWriter, [bool]$OldPosition = $true) {
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('gpu-install-' + [guid]::NewGuid().ToString('N'))
    $fixtureSourceRoot = $root
    $calls = [Collections.Generic.List[object]]::new()
    $stopped = [Collections.Generic.List[int]]::new()
    $oldLocal = $env:LOCALAPPDATA
    $oldRoaming = $env:APPDATA

    # System operations are replaced in this scope. File writes are restricted
    # to a fresh temporary profile. No real task, process, registry key, shortcut,
    # or Rainmeter window is changed by this test.
    function Get-ScheduledTask { return $null }
    function Stop-ScheduledTask { }
    function Start-ScheduledTask { }
    function Register-ScheduledTask { }
    function New-ScheduledTaskAction { return [pscustomobject]@{} }
    function New-ScheduledTaskTrigger { return [pscustomobject]@{} }
    function New-ScheduledTaskPrincipal { return [pscustomobject]@{} }
    function New-ScheduledTaskSettingsSet { return [pscustomobject]@{} }
    function Import-Module { }
    function Start-Sleep { }
    function Set-ItemProperty { }
    function Write-Host { }
    function Invoke-FixtureStatus { }
    function Get-RainmeterExecutable { return (Join-Path $fixture 'Rainmeter.exe') }
    function Get-RainmeterSkinPath { return (Join-Path $fixture 'Skins') }
    function Get-CimInstance {
        if ($LegacyWriter) { return [pscustomobject]@{ CommandLine = 'powershell.exe -File aibench-gpu-writer.ps1'; ProcessId = 12345 } }
    }
    function Stop-Process([int]$Id, [switch]$Force) { $stopped.Add($Id) }
    function Start-Process([string]$FilePath, [string[]]$ArgumentList, [string]$WindowStyle) {
        if ($ArgumentList) { $calls.Add([pscustomobject]@{ Arguments = $ArgumentList }) }
    }
    function Assert-FixturePath([string]$Path) {
        if (-not [IO.Path]::GetFullPath($Path).StartsWith($fixture + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Installer fixture attempted to write outside its temporary profile.'
        }
    }
    function New-Item([string]$Path, [string]$ItemType, [switch]$Force) {
        if ($Path.StartsWith('HKCU:')) { return }
        Assert-FixturePath $Path
        Microsoft.PowerShell.Management\New-Item -Path $Path -ItemType $ItemType -Force:$Force
    }
    function Copy-Item([string[]]$LiteralPath, [string[]]$Path, [string]$Destination, [switch]$Recurse, [switch]$Force) {
        Assert-FixturePath $Destination
        if ($LiteralPath) {
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Recurse:$Recurse -Force:$Force
        } else {
            Microsoft.PowerShell.Management\Copy-Item -Path $Path -Destination $Destination -Recurse:$Recurse -Force:$Force
        }
    }
    function Move-Item([string]$LiteralPath, [string]$Destination, [switch]$Force) {
        Assert-FixturePath $LiteralPath
        Assert-FixturePath $Destination
        Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
    }
    function New-FixtureShell {
        $shell = [pscustomobject]@{}
        $shell | Add-Member ScriptMethod CreateShortcut {
            param($Path)
            $shortcut = [pscustomobject]@{ TargetPath = ''; Arguments = ''; WorkingDirectory = ''; IconLocation = '' }
            $shortcut | Add-Member ScriptMethod Save { }
            return $shortcut
        }
        return $shell
    }

    try {
        $env:LOCALAPPDATA = Join-Path $fixture 'Local'
        $env:APPDATA = Join-Path $fixture 'Roaming'
        $settings = Join-Path $env:APPDATA 'Rainmeter/Rainmeter.ini'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $settings)) | Out-Null
        $settingsText = "[UtilsGpuMonitor]`r`nWindowX=300`r`nWindowY=200`r`n"
        if ($OldPosition) { $settingsText += "[HWMonitor]`r`nWindowX=900`r`nWindowY=500`r`n" }
        [IO.File]::WriteAllText($settings, $settingsText)
        $startup = Join-Path $env:APPDATA 'Microsoft/Windows/Start Menu/Programs/Startup/Aibench GPU Writer.lnk'
        if ($LegacyShortcut) {
            [IO.Directory]::CreateDirectory((Split-Path -Parent $startup)) | Out-Null
            [IO.File]::WriteAllText($startup, 'synthetic predecessor shortcut')
        }

        # Replace only three external dependencies. All migration conditions and
        # Rainmeter argument construction execute from the real installer text.
        $code = $installer.Replace('$sourceRoot = Split-Path -Parent $PSScriptRoot', '$sourceRoot = $fixtureSourceRoot').
            Replace('New-Object -ComObject WScript.Shell', 'New-FixtureShell').
            Replace('& (Join-Path $installedService ''status.ps1'')', 'Invoke-FixtureStatus')
        & ([scriptblock]::Create($code))

        $deactivations = @($calls | Where-Object { $_.Arguments[0] -eq '!DeactivateConfig' })
        $moves = @($calls | Where-Object { $_.Arguments[0] -eq '!Move' })
        $legacy = $LegacyShortcut -or $LegacyWriter
        if ($deactivations.Count -ne [int]$legacy) { throw 'An unrelated skin was deactivated, or a real predecessor was not migrated.' }
        if ($moves.Count -ne [int]($legacy -and $OldPosition)) { throw 'A normal reinstall moved the panel, or migration lost the predecessor position.' }
        if ($moves.Count -and (($moves[0].Arguments[1] -ne '900') -or ($moves[0].Arguments[2] -ne '500'))) { throw 'Migration used the wrong position.' }
        if (@($calls | Where-Object { $_.Arguments[0] -eq '!Refresh' }).Count -ne 1) { throw 'Reinstall did not refresh the installed skin.' }
        if ($LegacyWriter -and -not $stopped.Contains(12345)) { throw 'The predecessor writer was not stopped.' }
        if ($LegacyShortcut -and -not (Test-Path -LiteralPath ($startup + '.disabled'))) { throw 'The predecessor startup launch was not preserved and disabled.' }
        if ([IO.File]::ReadAllText($settings) -ne $settingsText) { throw 'The installer changed saved Rainmeter positions.' }
        $installed = Join-Path $env:LOCALAPPDATA 'Programs/UtilsGpuMonitor'
        foreach ($document in @('docs/gpu-claims.md', 'contracts/gpu-claim.schema.json', 'service/UpdateSupport.psm1', 'service/update.ps1', 'update-settings.json')) {
            if (-not (Test-Path -LiteralPath (Join-Path $installed $document))) { throw 'The installed runtime lost its public claim documentation or schema.' }
        }
        # Repair runs from the installed copy. It must not copy files onto
        # themselves, move the panel, or lose a configured public repository.
        $fixtureSourceRoot = $installed
        $LegacyWriter = $false
        $calls.Clear()
        & ([scriptblock]::Create($code)) -GitHubRepository 'Example/Monitor'
        $config = Get-GpuMonitorUpdateSettings -Path (Join-Path $installed 'update-settings.json')
        if ($config.github_repository -ne 'Example/Monitor') { throw 'Repair lost the configured repository.' }
        if (@($calls | Where-Object { $_.Arguments[0] -eq '!Move' }).Count -ne 0) { throw 'Repair moved the panel.' }
    } finally {
        $env:LOCALAPPDATA = $oldLocal
        $env:APPDATA = $oldRoaming
        $resolved = [IO.Path]::GetFullPath($fixture)
        if ([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetTempPath().TrimEnd('\', '/')) { throw 'Unsafe installer fixture cleanup.' }
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-InstallFixture $false $false
Invoke-InstallFixture $true $false
Invoke-InstallFixture $false $true
Invoke-InstallFixture $true $false $false
$supervisor = [IO.File]::ReadAllText((Join-Path $root 'service/supervisor.ps1'))
if ($supervisor -match '!DeactivateConfig') { throw 'The supervisor must not deactivate another Rainmeter config.' }
Write-Host 'PASS installer safety: ordinary reinstall preserves position and other skins; predecessor migration is gated and retains its position'
