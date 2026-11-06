[CmdletBinding()]
param([ValidateSet('Check', 'Repair')][string]$Action = 'Check', [switch]$Json)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UpdateSupport.psm1') -Force
$installRoot = Split-Path -Parent $PSScriptRoot
$settings = Get-GpuMonitorUpdateSettings -Path (Join-Path $installRoot 'update-settings.json')
$manifestPath = Join-Path $installRoot 'install-manifest.json'
$manifest = if (Test-Path -LiteralPath $manifestPath) { [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json } else { $null }
$version = if ($manifest) { $manifest.version } else { '2.2.0' }
if ($Json) {
    if ($Action -ne 'Check') { throw 'JSON mode supports update checks only.' }
    Get-GpuMonitorUpdateStatus -CurrentVersion $version -Repository $settings.github_repository | ConvertTo-Json -Depth 4
    return
}

$mutex = New-Object Threading.Mutex($false, 'Local\UtilsGpuMonitor.UpdateControl')
$ownsMutex = $false
try {
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { return }
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object Windows.Forms.Form
    $form.Text = 'BlooskAI GPU Monitor'
    $form.ClientSize = New-Object Drawing.Size(470, 240)
    $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false; $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object Drawing.Font('Segoe UI', 10)
    $title = New-Object Windows.Forms.Label
    $title.Location = New-Object Drawing.Point(22, 18); $title.Size = New-Object Drawing.Size(426, 30)
    $title.Font = New-Object Drawing.Font('Segoe UI', 14, [Drawing.FontStyle]::Bold)
    $title.Text = if ($Action -eq 'Repair') { 'Repair installation' } else { 'Check for updates' }
    $form.Controls.Add($title)
    $status = New-Object Windows.Forms.Label
    $status.Location = New-Object Drawing.Point(22, 58); $status.Size = New-Object Drawing.Size(426, 104)
    $status.Text = 'Installed version: ' + $version
    $form.Controls.Add($status)
    $website = New-Object Windows.Forms.LinkLabel
    $website.Text = 'BlooskAI by Biznique'; $website.AutoSize = $true
    $website.Location = New-Object Drawing.Point(22, 199)
    $website.Add_LinkClicked({ Start-Process $settings.website_url })
    $form.Controls.Add($website)
    $close = New-Object Windows.Forms.Button
    $close.Text = 'Close'; $close.Location = New-Object Drawing.Point(348, 191); $close.Size = New-Object Drawing.Size(100, 32)
    $close.Add_Click({ $form.Close() }); $form.Controls.Add($close); $form.CancelButton = $close
    $install = New-Object Windows.Forms.Button
    $install.Text = 'Install update'; $install.Location = New-Object Drawing.Point(224, 191); $install.Size = New-Object Drawing.Size(116, 32)
    $install.Visible = $false; $form.Controls.Add($install)
    $script:checkedRelease = $null
    $setStatus = { param($Text) $status.Text = $Text; $form.Refresh(); [Windows.Forms.Application]::DoEvents() }
    $install.Add_Click({
        $answer = [Windows.Forms.MessageBox]::Show($form,
            ('Install version ' + $script:checkedRelease.latest_version + '? The monitor will restart. Your panel position and sampling settings will be kept.'),
            'Install update', 'YesNo', 'Question', 'Button2')
        if ($answer -ne 'Yes') { return }
        $install.Enabled = $false; $close.Enabled = $false; $form.ControlBox = $false; $form.UseWaitCursor = $true
        try {
            $null = Invoke-GpuMonitorUpdate -Release $script:checkedRelease -InstallRoot $installRoot -WorkParent (Join-Path $env:LOCALAPPDATA 'Utils/GpuMonitor/updates') -Progress $setStatus
            & $setStatus ('Version ' + $script:checkedRelease.latest_version + ' is installed. The monitor has restarted.')
            $install.Visible = $false
        } catch { & $setStatus $_.Exception.Message }
        finally { $close.Enabled = $true; $form.ControlBox = $true; $form.UseWaitCursor = $false }
    })
    $form.Add_Shown({
        if ($Action -eq 'Repair') {
            if (-not $manifest) { & $setStatus 'Install the monitor before using Repair installation.'; return }
            $answer = [Windows.Forms.MessageBox]::Show($form,
                'Restore the installed skin and launch tasks, then restart the monitor? Your panel position and sampling settings will be kept.',
                'Repair installation', 'YesNo', 'Question', 'Button2')
            if ($answer -ne 'Yes') { $form.Close(); return }
            $close.Enabled = $false; $form.ControlBox = $false; $form.UseWaitCursor = $true
            try {
                & $setStatus 'Repairing the installed monitor...'
                $exitCode = Invoke-GpuMonitorInstaller -Script (Join-Path $PSScriptRoot 'install.ps1') -Manifest $manifest -Repository $settings.github_repository
                if ($exitCode -ne 0) { throw 'Repair did not finish. Use the installer from the release package to try again.' }
                & $setStatus 'The installed skin and launch tasks were restored. The monitor has restarted.'
            } catch { & $setStatus $_.Exception.Message }
            finally { $close.Enabled = $true; $form.ControlBox = $true; $form.UseWaitCursor = $false }
        } else {
            & $setStatus ('Installed version: ' + $version + "`r`nChecking GitHub...")
            $script:checkedRelease = Get-GpuMonitorUpdateStatus -CurrentVersion $version -Repository $settings.github_repository
            $text = 'Installed version: ' + $version
            if ($script:checkedRelease.latest_version) { $text += "`r`nLatest release: " + $script:checkedRelease.latest_version }
            & $setStatus ($text + "`r`n`r`n" + $script:checkedRelease.message)
            $install.Visible = $script:checkedRelease.can_install
        }
    })
    $null = $form.ShowDialog()
    $form.Dispose()
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
