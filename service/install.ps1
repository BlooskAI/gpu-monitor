[CmdletBinding()]
param(
    [ValidateRange(0, 31)][int]$GpuIndex = 0,
    # Cadence for the integrated GPU, NPU and top-consumer readings.
    [ValidateRange(2, 600)][int]$DetailSeconds = 10,
    [AllowEmptyString()][string]$GitHubRepository
)

$ErrorActionPreference = 'Stop'
$taskName = 'Utils-GpuMonitor'
$watchdogTaskName = 'Utils-GpuMonitor-Watchdog'
$sourceRoot = Split-Path -Parent $PSScriptRoot
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\UtilsGpuMonitor'
$installedService = Join-Path $installRoot 'service'
$installedSkin = Join-Path $installRoot 'skin'

# Validate configuration before changing the running monitor. An unconfigured
# source package preserves an existing public repository setting on reinstall.
Import-Module (Join-Path $sourceRoot 'service/UpdateSupport.psm1') -Force
$updateSettings = Get-GpuMonitorUpdateSettings -Path (Join-Path $sourceRoot 'update-settings.json')
$installedUpdateSettings = Join-Path $installRoot 'update-settings.json'
if ($PSBoundParameters.ContainsKey('GitHubRepository')) {
    $updateSettings.github_repository = $GitHubRepository
} elseif (-not $updateSettings.github_repository -and (Test-Path -LiteralPath $installedUpdateSettings)) {
    $updateSettings.github_repository = (Get-GpuMonitorUpdateSettings -Path $installedUpdateSettings).github_repository
}
if ($updateSettings.github_repository -and ($updateSettings.github_repository -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$' -or ($updateSettings.github_repository -split '/')[1] -in @('.', '..'))) { throw 'Use a GitHub repository in owner/name form.' }
$sameRuntime = [IO.Path]::GetFullPath($sourceRoot).TrimEnd('\','/') -eq [IO.Path]::GetFullPath($installRoot).TrimEnd('\','/')

# Quiesce an older installation before replacing scripts or task definitions.
# This makes upgrades deterministic and prevents a refused duplicate launch from
# becoming the new task's last-result value.
foreach ($existingTaskName in @($watchdogTaskName, $taskName)) {
    if (Get-ScheduledTask -TaskName $existingTaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $existingTaskName -ErrorAction SilentlyContinue
    }
}

# Stopping the task does not reliably terminate PowerShell running under the
# windowless wscript launcher; a surviving supervisor would keep the mutex and
# make the freshly started task exit as a refused duplicate.
try {
    Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*UtilsGpuMonitor\service\supervisor.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { }
Start-Sleep -Seconds 1

# Install an independent user-local runtime. Scheduled tasks must not depend on
# a repository checkout remaining mounted or at the same path.
New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
New-Item -ItemType Directory -Path $installedService -Force | Out-Null
New-Item -ItemType Directory -Path $installedSkin -Force | Out-Null
if (-not $sameRuntime) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'GpuMonitor.psm1') -Destination (Join-Path $installRoot 'GpuMonitor.psm1') -Force
    Copy-Item -Path (Join-Path $sourceRoot 'service\*.ps1') -Destination $installedService -Force
    Copy-Item -Path (Join-Path $sourceRoot 'service\*.psm1') -Destination $installedService -Force
    Copy-Item -Path (Join-Path $sourceRoot 'service\*.vbs') -Destination $installedService -Force
    Copy-Item -Path (Join-Path $sourceRoot 'skin\*.ini') -Destination $installedSkin -Force
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'skin\@Resources') -Destination $installedSkin -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'README.md') -Destination (Join-Path $installRoot 'README.md') -Force
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'docs'), (Join-Path $sourceRoot 'contracts') -Destination $installRoot -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'LICENSE'), (Join-Path $sourceRoot 'NOTICE') -Destination $installRoot -Force
}
$publicSettings = [ordered]@{ contract = 'utils.gpu-monitor.updates.v1'; website_url = $updateSettings.website_url; github_repository = $updateSettings.github_repository }
[IO.File]::WriteAllText($installedUpdateSettings, ($publicSettings | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))

Import-Module (Join-Path $installRoot 'GpuMonitor.psm1') -Force

$rainmeter = Get-RainmeterExecutable
$skinRoot = Get-RainmeterSkinPath
$skinTarget = Join-Path $skinRoot 'UtilsGpuMonitor'
$resources = Join-Path $skinTarget '@Resources'
$runtime = Join-Path $env:LOCALAPPDATA 'Utils\GpuMonitor'
$dataPath = Join-Path $runtime 'gpu.txt'
$integratedPath = Join-Path $runtime 'igpu.txt'
$npuPath = Join-Path $runtime 'npu.txt'
$processPath = Join-Path $runtime 'processes.txt'
$modelPath = Join-Path $runtime 'models.txt'
$phasePath = Join-Path $runtime 'phase.txt'
$toolchainPath = Join-Path $runtime 'toolchain.txt'
$restartScript = Join-Path $installedService 'restart.ps1'
$supervisor = Join-Path $installedService 'supervisor.ps1'
$watchdogScript = Join-Path $installedService 'watchdog.ps1'
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$rainmeterSettings = Join-Path $env:APPDATA 'Rainmeter\Rainmeter.ini'

# Migration from the unpublished predecessor: a startup "Aibench GPU Writer"
# script feeding a Rainmeter config named HWMonitor. HWMonitor is a common
# third-party skin name, so the name proves nothing. Migrate only while the
# predecessor is present - its startup shortcut or its writer process. On any
# other machine no other Rainmeter config is read, moved, or deactivated.
# The shortcut is renamed only after the migration finishes, so an interrupted
# install is migrated again on the next run.
$legacyLink = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Aibench GPU Writer.lnk'
$legacyWriters = @()
try {
    $legacyWriters = @(Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*aibench-gpu-writer.ps1*' })
} catch {
    Write-Verbose "Could not inspect legacy process command lines: $($_.Exception.Message)"
}
$legacyInstall = (Test-Path -LiteralPath $legacyLink) -or ($legacyWriters.Count -gt 0)

# Rainmeter keeps a skin's own position across reinstalls and refreshes, so the
# panel is moved only to adopt the predecessor widget's position. A reinstall
# never moves a panel the user has placed.
$windowX = $null
$windowY = $null
if ($legacyInstall -and (Test-Path -LiteralPath $rainmeterSettings)) {
    $settingsText = [IO.File]::ReadAllText($rainmeterSettings)
    $oldSection = [regex]::Match($settingsText, '(?ims)^\[HWMonitor\]\s*(.*?)(?=^\[|\z)')
    if ($oldSection.Success) {
        $x = [regex]::Match($oldSection.Groups[1].Value, '(?im)^WindowX=(.+?)\s*$')
        $y = [regex]::Match($oldSection.Groups[1].Value, '(?im)^WindowY=(.+?)\s*$')
        if ($x.Success -and $y.Success) {
            $windowX = $x.Groups[1].Value.Trim()
            $windowY = $y.Groups[1].Value.Trim()
        }
    }
}

Write-Host "Source     : $sourceRoot"
Write-Host "Installed  : $installRoot"
Write-Host "Rainmeter  : $rainmeter"
Write-Host "Skin path  : $skinTarget"
Write-Host "Runtime    : $runtime"
Write-Host "Task       : $taskName"

New-Item -ItemType Directory -Path $skinTarget -Force | Out-Null
New-Item -ItemType Directory -Path $resources -Force | Out-Null
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $installedSkin 'UtilsGpuMonitor.ini') -Destination (Join-Path $skinTarget 'UtilsGpuMonitor.ini') -Force
Copy-Item -Path (Join-Path $installedSkin '@Resources\*') -Destination $resources -Recurse -Force

$paths = @(
    '[Variables]',
    ('GpuFile={0}' -f $dataPath),
    ('IgpuFile={0}' -f $integratedPath),
    ('NpuFile={0}' -f $npuPath),
    ('ProcessFile={0}' -f $processPath),
    ('ModelFile={0}' -f $modelPath),
    ('PhaseFile={0}' -f $phasePath),
    ('ToolchainFile={0}' -f $toolchainPath),
    ('RestartScript={0}' -f $restartScript),
    ('UpdateScript={0}' -f (Join-Path $installedService 'update.ps1')),
    ('HiddenLauncher={0}' -f (Join-Path $installedService 'run-hidden.vbs')),
    ('WScriptExe={0}' -f (Join-Path $env:WINDIR 'System32\wscript.exe')),
    ('WebsiteUrl={0}' -f $updateSettings.website_url),
    ('GitHubMenuTitle={0}' -f $(if ($updateSettings.github_repository) { 'GitHub repository' } else { '' })),
    ('GitHubUrl={0}' -f $(if ($updateSettings.github_repository) { 'https://github.com/' + $updateSettings.github_repository } else { '' })),
    ('Repository={0}' -f $sourceRoot)
) -join [Environment]::NewLine
[IO.File]::WriteAllText((Join-Path $resources 'Paths.inc'), $paths + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))

# The new supervisor owns telemetry and Rainmeter; stop the predecessor writer.
foreach ($writer in $legacyWriters) {
    Write-Host "Stopping legacy writer pid=$($writer.ProcessId)"
    Stop-Process -Id $writer.ProcessId -Force -ErrorAction SilentlyContinue
}

# Launch through wscript so no console window flashes: powershell.exe creates
# its console before -WindowStyle Hidden can take effect.
$hiddenLauncher = Join-Path $installedService 'run-hidden.vbs'
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
$arguments = '//B //NoLogo "{0}" "{1}" -GpuIndex {2} -DetailSeconds {3}' -f $hiddenLauncher, $supervisor, $GpuIndex, $DetailSeconds
$action = New-ScheduledTaskAction -Execute $wscript -Argument $arguments -WorkingDirectory $installRoot
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$logon = New-ScheduledTaskTrigger -AtLogOn -User $identity
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $taskName -Description 'Starts the Utils GPU desktop monitor at logon; Task Scheduler restarts abnormal supervisor exits.' `
    -Action $action -Trigger $logon -Principal $principal -Settings $settings -Force | Out-Null

# A separate, short-lived watchdog avoids overlapping launches of the long-running
# main task. It repairs killed/orphaned supervisors without corrupting the main
# task's result state with a refused duplicate-launch code.
$watchdogArguments = '//B //NoLogo "{0}" "{1}"' -f $hiddenLauncher, $watchdogScript
$watchdogAction = New-ScheduledTaskAction -Execute $wscript -Argument $watchdogArguments -WorkingDirectory $installRoot
$watchdogLogon = New-ScheduledTaskTrigger -AtLogOn -User $identity
$watchdogRecurring = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(-1)) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$watchdogSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $watchdogTaskName -Description 'Checks GPU Monitor health and restarts a missing or stale supervisor.' `
    -Action $watchdogAction -Trigger @($watchdogLogon, $watchdogRecurring) -Principal $principal -Settings $watchdogSettings -Force | Out-Null

$manifest = [ordered]@{
    contract = 'utils.gpu-monitor.install.v1'
    version = '2.2.0'
    installed_at = [DateTime]::UtcNow.ToString('o')
    source = $sourceRoot
    install_root = $installRoot
    skin_root = $skinTarget
    task = $taskName
    watchdog_task = $watchdogTaskName
    gpu_index = $GpuIndex
    detail_seconds = $DetailSeconds
}
[IO.File]::WriteAllText((Join-Path $installRoot 'install-manifest.json'), ($manifest | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))

# Add normal Windows discoverability: Start-menu controls and Apps & Features.
$programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\GPU Monitor'
New-Item -ItemType Directory -Path $programs -Force | Out-Null
$shell = New-Object -ComObject WScript.Shell
$shortcutSpecs = @(
    @{ Name = 'Restart GPU Monitor.lnk'; Script = 'restart.ps1'; NoExit = $false },
    @{ Name = 'GPU Monitor Status.lnk'; Script = 'status.ps1'; NoExit = $true },
    @{ Name = 'Uninstall GPU Monitor.lnk'; Script = 'uninstall.ps1'; NoExit = $true }
)
foreach ($spec in $shortcutSpecs) {
    $shortcut = $shell.CreateShortcut((Join-Path $programs $spec.Name))
    $shortcut.TargetPath = $powershell
    $noExit = if ($spec.NoExit) { '-NoExit ' } else { '' }
    $shortcut.Arguments = "$noExit-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $installedService $spec.Script)`""
    $shortcut.WorkingDirectory = $installRoot
    $shortcut.IconLocation = "$rainmeter,0"
    $shortcut.Save()
}
$updateShortcut = $shell.CreateShortcut((Join-Path $programs 'Check for GPU Monitor updates.lnk'))
$updateShortcut.TargetPath = $wscript
$updateShortcut.Arguments = '//B //NoLogo "{0}" "{1}"' -f $hiddenLauncher, (Join-Path $installedService 'update.ps1')
$updateShortcut.WorkingDirectory = $installRoot
$updateShortcut.IconLocation = "$rainmeter,0"
$updateShortcut.Save()

$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\UtilsGpuMonitor'
New-Item -Path $uninstallKey -Force | Out-Null
Set-ItemProperty -Path $uninstallKey -Name DisplayName -Value 'BlooskAI GPU Monitor'
Set-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value '2.2.0'
Set-ItemProperty -Path $uninstallKey -Name Publisher -Value 'BlooskAI (a division of Biznique)'
Set-ItemProperty -Path $uninstallKey -Name InstallLocation -Value $installRoot
Set-ItemProperty -Path $uninstallKey -Name DisplayIcon -Value $rainmeter
Set-ItemProperty -Path $uninstallKey -Name NoModify -Value 1 -Type DWord
Set-ItemProperty -Path $uninstallKey -Name NoRepair -Value 0 -Type DWord
Set-ItemProperty -Path $uninstallKey -Name UninstallString -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $installedService 'uninstall.ps1')`""

Start-ScheduledTask -TaskName $taskName
Start-ScheduledTask -TaskName $watchdogTaskName
Start-Sleep -Seconds 4

# Activate the panel now rather than waiting for the supervisor. The supervisor
# repeats activation every minute, so a later unload is repaired.
Start-Process -FilePath $rainmeter | Out-Null
Start-Sleep -Seconds 1
if ($legacyInstall) {
    Start-Process -FilePath $rainmeter -ArgumentList @('!DeactivateConfig', '"HWMonitor"') -WindowStyle Hidden | Out-Null
}
Start-Process -FilePath $rainmeter -ArgumentList @('!ActivateConfig', '"UtilsGpuMonitor"', '"UtilsGpuMonitor.ini"') -WindowStyle Hidden | Out-Null
Start-Sleep -Seconds 1
# !ActivateConfig does not reload a config that is already active, so an upgrade
# would keep rendering the previous skin from memory until the next Rainmeter
# restart. Force the reload so a reinstall always shows the installed skin.
Start-Process -FilePath $rainmeter -ArgumentList @('!Refresh', '"UtilsGpuMonitor"') -WindowStyle Hidden | Out-Null
Start-Sleep -Seconds 1
if ($null -ne $windowX) {
    Start-Process -FilePath $rainmeter -ArgumentList @('!Move', $windowX, $windowY, '"UtilsGpuMonitor"') -WindowStyle Hidden | Out-Null
}
Start-Process -FilePath $rainmeter -ArgumentList @('!ZPos', '-1', '"UtilsGpuMonitor"') -WindowStyle Hidden | Out-Null

# Disable the predecessor's startup launch without destroying it, now that the
# migration above has completed.
if (Test-Path -LiteralPath $legacyLink) {
    $disabled = $legacyLink + '.disabled'
    Move-Item -LiteralPath $legacyLink -Destination $disabled -Force
    Write-Host "Disabled legacy Startup shortcut: $disabled"
}

& (Join-Path $installedService 'status.ps1')
