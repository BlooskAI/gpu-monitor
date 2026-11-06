[CmdletBinding()]
param([string]$Root)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$list = Join-Path $Root 'packaging/public-files.txt'
$files = @([IO.File]::ReadAllLines($list) | Where-Object { $_.Trim() -and -not $_.StartsWith('#') })
$seen = @{}
$failures = [Collections.Generic.List[string]]::new()

function Test-PrivatePath([string]$Path) {
    $normalized = $Path.Replace('\', '/')
    if ($normalized -match '(?i)(^|/)(project_log[^/]*|ideas_parked[^/]*|responses[^/]*|oiresponses[^/]*|response-logs|_architecture|dist|build|out|node_modules|venv|\.venv|\.build|\.swiftpm|__pycache__|\.aws|\.azure|\.gcloud|\.ssh|\.codex|\.agents|\.claude|\.idea|\.vscode|\.vs)(/|$)') { return $true }
    if ($normalized -match '(?i)(^|/)(\.env[^/]*|id_rsa[^/]*|id_ed25519[^/]*|credentials(?:\.json)?|secrets\.json|Paths\.inc|health\.json|watchdog-health\.json|install-manifest\.json|package-manifest\.json|SOURCE_MANIFEST\.json|gpu-claim\.json|(?:gpu|igpu|npu|models|processes|toolchain|phase)\.txt|diagnostic[^/]*\.(?:json|txt))$') { return $true }
    return $normalized -match '(?i)(\.(?:pem|key|p12|pfx|jks|keystore|kdbx|log|tmp|bak|sqlite|sqlite3|db|gguf|safetensors|onnx|pt|pth|zip)$|\.log\.[^/]+$|\.local\.(?:json|toml|ya?ml)$)'
}

# This is a narrow pattern screen, not a complete secret scanner. Reports name
# only a rule, path, and line number; never print matched credential values.
$rules = [ordered]@{
    'private key' = '-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----'
    'GitHub token' = '\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b'
    'AWS access key' = '\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'
    'Google API key' = '\bAIza[0-9A-Za-z_-]{35}\b'
    'Slack token' = '\bxox[baprs]-[A-Za-z0-9-]{20,}\b'
    'service API key' = '\b(?:sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{32,}|hf_[A-Za-z0-9]{30,}|sk_live_[A-Za-z0-9]{20,})\b'
    'credential in URL' = 'https?://[^\s/"''<>:]+:[^\s/"''<>@]+@'
    'literal credential' = '(?i)\b(?:api[_-]?key|client[_-]?secret|password|access[_-]?token)\b["'']?\s*[:=]\s*["''][^\s"'']{12,}["'']'
    'private network URL' = 'https?://(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})(?=[:/\s]|$)'
    'personal home path' = '(?i)(?:\b[A-Z]:[\\/]Users[\\/](?!Public(?:[\\/]|\b)|Default(?:[\\/]|\b))[^\s\\/"''<>]+|/(?:Users|home)/[A-Za-z0-9_.-]+/)'
    'private checkout path' = '(?i)\b[A-Z]:[\\/]Source[\\/]repos[\\/]'
}

foreach ($relative in $files) {
    if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains(':') -or $relative -match '(^|[/\\])\.\.([/\\]|$)') { throw "Invalid public path: $relative" }
    if ($seen.ContainsKey($relative)) { throw "Duplicate public path: $relative" }
    $seen[$relative] = $true
    if (Test-PrivatePath $relative) { $failures.Add("Private path in public list: $relative"); continue }
    $path = Join-Path $Root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing public file: $relative" }
    $ancestor = Get-Item -LiteralPath $path
    while ($ancestor -and $ancestor.FullName -ne $Root) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked public source path: $relative" }
        $ancestor = if ($ancestor -is [IO.DirectoryInfo]) { $ancestor.Parent } else { $ancestor.Directory }
    }
    if ([IO.Path]::GetExtension($relative) -in @('.png', '.ico')) { continue }
    $content = [IO.File]::ReadAllText($path)
    foreach ($rule in $rules.GetEnumerator()) {
        foreach ($match in [regex]::Matches($content, $rule.Value)) {
            $line = 1 + [regex]::Matches($content.Substring(0, $match.Index), "`n").Count
            $failures.Add(('{0}: {1}:{2}' -f $rule.Key, $relative, $line))
        }
    }
}

# Reject tracked files outside the reviewed source list. Do not read private
# histories or credentials, even when an old commit accidentally tracked them.
if (Test-Path -LiteralPath (Join-Path $Root '.git')) {
    $tracked = @(& git -C $Root ls-files)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the Git index.' }
    foreach ($relative in $tracked) {
        if (-not $seen.ContainsKey($relative)) { $failures.Add("Tracked file outside public list: $relative") }
    }
}
if ($failures.Count) { throw ("Public hygiene check failed (values omitted):`n" + ($failures -join "`n")) }
Write-Host ('PASS public hygiene: {0} reviewed files; no private paths or credential-pattern findings' -f $files.Count)
