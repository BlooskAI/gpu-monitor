$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root ('dist/package-check-' + [guid]::NewGuid().ToString('N'))
& (Join-Path $root 'packaging/build-public-source.ps1') -OutputDirectory $output

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = @(Get-ChildItem -LiteralPath $output -Filter *.zip -File)
if ($archive.Count -ne 1) { throw 'Expected one public source archive.' }
$expected = @([IO.File]::ReadAllLines((Join-Path $root 'packaging/public-files.txt')) | Where-Object { $_ -and -not $_.StartsWith('#') })
$zip = [IO.Compression.ZipFile]::OpenRead($archive[0].FullName)
try {
    $actual = @($zip.Entries | ForEach-Object { $_.FullName })
    $difference = @(Compare-Object ($expected + 'SOURCE_MANIFEST.json') $actual)
    if ($difference.Count) { throw 'Public ZIP does not match the explicit source allowlist.' }
    $reader = [IO.StreamReader]::new($zip.GetEntry('SOURCE_MANIFEST.json').Open())
    try { $manifestText = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $manifest = $manifestText | ConvertFrom-Json
    if (@($manifest.files).Count -ne $expected.Count) { throw 'Manifest file count differs from public sources.' }
    foreach ($entry in $manifest.files) {
        # Also catches provider metadata leaking through PowerShell 5.1 JSON.
        if ($entry.path -isnot [string] -or $entry.path -notin $expected) { throw 'Manifest contains a non-relative source path.' }
        $stream = $zip.GetEntry($entry.path).Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose(); $sha.Dispose() }
        if ($hash -ne $entry.sha256) { throw "Manifest hash differs: $($entry.path)" }
    }
    if ($manifestText.Contains($root) -or $manifestText -match 'PSPath|PSProvider|PSDrive') {
        throw 'Local provider metadata leaked into the source manifest.'
    }
} finally { $zip.Dispose() }
$checksum = [IO.File]::ReadAllText($archive[0].FullName + '.sha256').Split(' ')[0]
if ($checksum -ne (Get-FileHash -LiteralPath $archive[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()) {
    throw 'ZIP checksum differs.'
}

# Validate both rejection and redaction with synthetic credentials. The values
# are assembled at runtime so the source check never needs an exception list.
$fixture = Join-Path $output 'hygiene-fixture'
New-Item -ItemType Directory -Path (Join-Path $fixture 'packaging') -Force | Out-Null
$fixtureList = Join-Path $fixture 'packaging/public-files.txt'
$payloadPath = Join-Path $fixture 'payload.txt'
$hygiene = Join-Path $root 'tests/public-hygiene.ps1'
$emptyIgnore = Join-Path $output 'empty-global-ignore'
[IO.File]::WriteAllText($emptyIgnore, '')
try {
    Copy-Item -LiteralPath (Join-Path $root '.gitignore') -Destination (Join-Path $fixture '.gitignore')
    & git -c init.templateDir= init --quiet $fixture
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the ignore-rule fixture.' }
    foreach ($probe in @('.env', '.env.local', '.aws/credentials', '.codex/config.toml',
        'skin/@Resources/Paths.inc', 'health.json', 'SOURCE_MANIFEST.json', 'PROJECT_LOG.md', 'project_log/capture.txt',
        'RESPONSES-old.md', 'responses-new/data.json', 'OIRESPONSES-old.md',
        'oiresponses-save/data.json', 'response-logs/private.json', '_architecture/layers.toml',
        'model/weights.bin', 'models/weights.gguf')) {
        & git -C $fixture -c "core.excludesFile=$emptyIgnore" check-ignore --no-index --quiet -- $probe
        if ($LASTEXITCODE -ne 0) { throw "Repository ignore rules do not protect $probe" }
    }
    foreach ($probe in @('skin/@Resources/blooskai-mark.png', 'docs/privacy.md', 'tests/public-hygiene.ps1')) {
        & git -C $fixture -c "core.excludesFile=$emptyIgnore" check-ignore --no-index --quiet -- $probe
        if ($LASTEXITCODE -ne 1) { throw "Repository ignore rules hide public source $probe" }
    }
    [IO.File]::WriteAllText($fixtureList, "payload.txt`n")
    foreach ($value in @(
        ('-----BEGIN ' + 'PRIVATE KEY-----'),
        ('ghp_' + ('a' * 36)),
        ('password' + ' = "' + ('a' * 24) + '"'),
        ('{"client_' + 'secret":"' + ('a' * 24) + '"}'),
        ('https://' + 'example:synthetic-password@example.invalid/'),
        ('http://' + '192.' + '168.1.5:9090/'),
        ('C:' + '/Users/' + 'example/private.txt')
    )) {
        [IO.File]::WriteAllText($payloadPath, $value)
        $rejected = $false
        try { & $hygiene -Root $fixture | Out-Null }
        catch {
            $rejected = $true
            if ($_.Exception.Message.Contains($value)) { throw 'Hygiene failure exposed the matched value.' }
        }
        if (-not $rejected) { throw 'A synthetic credential or private path passed public hygiene.' }
    }
    [IO.File]::WriteAllText($payloadPath, 'safe fixture')
    [IO.File]::WriteAllText($fixtureList, "oiresponses-test.md`n")
    $rejected = $false
    try { & $hygiene -Root $fixture | Out-Null }
    catch { $rejected = $_.Exception.Message -match 'Private path in public list' }
    if (-not $rejected) { throw 'A private history path was not rejected before reading its contents.' }
    [IO.File]::WriteAllText($fixtureList, "payload.txt`n")
    [IO.File]::WriteAllText((Join-Path $fixture 'unlisted.txt'), 'safe fixture')
    & git -C $fixture add -- unlisted.txt
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage the unlisted-file fixture.' }
    $rejected = $false
    try { & $hygiene -Root $fixture | Out-Null }
    catch { $rejected = $_.Exception.Message -match 'Tracked file outside public list' }
    if (-not $rejected) { throw 'An unreviewed tracked file passed public hygiene.' }
} finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolvedFixture) -ne [IO.Path]::GetFullPath($output)) { throw 'Unsafe test fixture cleanup.' }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}

# Build releases from an exported tree with extra, unreviewed local files.
# Such files must never enter either platform package through a folder copy.
$exportRoot = Join-Path $output ([IO.Path]::GetFileNameWithoutExtension($archive[0].Name))
& git -c init.templateDir= init --quiet $exportRoot
if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the public-source fixture.' }
& git -C $exportRoot -c "core.excludesFile=$emptyIgnore" -c core.safecrlf=false add -- .
if ($LASTEXITCODE -ne 0) { throw 'Could not stage the public-source fixture.' }
& $hygiene -Root $exportRoot
$privateExtras = @('skin/@Resources/Paths.inc', 'docs/health.json', 'contracts/private.local.json', 'macos/Resources/private.key')
try {
    foreach ($relative in $privateExtras) {
        $target = Join-Path $exportRoot $relative
        [IO.File]::WriteAllText($target, 'LOCAL_PACKAGE_SENTINEL')
    }
    foreach ($platform in @('windows', 'macos-source')) {
        $builder = if ($platform -eq 'windows') { 'build-windows.ps1' } else { 'build-macos-source.ps1' }
        $platformOutput = Join-Path $output $platform
        & (Join-Path $exportRoot ('packaging/' + $builder)) -OutputDirectory $platformOutput
        $platformZip = @(Get-ChildItem -LiteralPath $platformOutput -Filter *.zip -File)
        if ($platformZip.Count -ne 1) { throw "Missing $platform release archive." }
        $releaseZip = [IO.Compression.ZipFile]::OpenRead($platformZip[0].FullName)
        try {
            # Inspect raw entry names. Normalizing on read hides ZIPs that work
            # on Windows but extract incorrectly on macOS or Linux.
            $entries = @($releaseZip.Entries | ForEach-Object { $_.FullName })
            if (@($entries | Where-Object { $_.IndexOf([char]92) -ge 0 }).Count) { throw "$platform archive has nonportable backslash entry names." }
            foreach ($private in $privateExtras) {
                $leaf = [IO.Path]::GetFileName($private)
                if (@($entries | Where-Object { $_.EndsWith('/' + $leaf) }).Count) { throw "$platform package included a private fixture." }
            }
            $required = if ($platform -eq 'windows') { @('/service/run-hidden.vbs', '/service/update.ps1', '/service/UpdateSupport.psm1', '/update-settings.json', '/skin/@Resources/blooskai-mark.png', '/contracts/gpu-claim.schema.json') } else { @('/Package.swift', '/Install GPU Monitor.command', '/Resources/blooskai-mark.png') }
            foreach ($suffix in $required) {
                if (-not @($entries | Where-Object { $_.EndsWith($suffix) }).Count) { throw "$platform package lost $suffix" }
            }
        } finally { $releaseZip.Dispose() }
    }
} finally {
    foreach ($relative in $privateExtras) {
        Remove-Item -LiteralPath (Join-Path $exportRoot $relative) -Force -ErrorAction SilentlyContinue
    }
}
Write-Host 'PASS public package: exact source list, hashes, checksum, private-path guards, redacted failures, and both release archives exclude local fixtures'
