# cfg.ps1: reading and saving the cfg files, and the paths file. Loaded by
# update-tools.ps1.

# Every key a cfg may hold; the same keys as the bash version, so a cfg works
# in either. Read-Cfg returns only these: a cfg is data, never code.
$script:CfgKeys = @(
    'manager', 'repo', 'repo_filename', 'repo_regex', 'allow_prereleases', 'repo_url',
    'feed_url', 'channel', 'arch_key', 'download_base', 'url',
    'content_length', 'last_modified', 'current_version',
    'apworld_filename', 'installed_file', 'last_checked',
    'asset_digest', 'etag',
    'checksum', 'checksum_save', 'download_suffix', 'probe_days',
    'folder', 'iso_hash', 'checksum_file'
)

# Keys the scripts keep up to date themselves, in the order new ones are added.
$script:SaveKeys = @('current_version', 'last_checked', 'content_length', 'last_modified',
                     'asset_digest', 'etag', 'installed_file', 'iso_hash', 'checksum_file')

# The cfg's KEY=VALUE lines as a hashtable. $Keys = the keys allowed (default:
# CfgKeys); others are reported and ignored. Blank lines and # comments are
# skipped, a value in double quotes loses them, and Windows line endings are fine.
function Read-Cfg([string]$Path, [string[]]$Keys = $script:CfgKeys) {
    $cfg = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $line = $line.TrimEnd("`r")
        if ($line -match '^\s*(#|$)') { continue }
        if ($line -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { continue }
        $key = $Matches[1]; $value = $Matches[2]
        if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2).Replace('\"', '"')
        }
        if ($Keys -ccontains $key) {
            $cfg[$key] = $value
        } else {
            Say "⚠ $($script:Label): unknown key '$key' in $(Split-Path -Leaf $Path), ignored"
        }
    }
    $cfg
}

# Sets each KEY=VALUE pair in the cfg: an existing key's line is replaced, a
# new one appended. Values with spaces or quotes are quoted. The file keeps its
# line endings and is written as UTF-8 without a byte-order mark.
function Write-CfgValues([string]$Path, [System.Collections.Specialized.OrderedDictionary]$Pairs) {
    $text = [IO.File]::ReadAllText($Path)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [Collections.Generic.List[string]]::new()
    if ($text.Length) {
        foreach ($l in ($text -split "`r?`n")) { $lines.Add($l) }
        # the split leaves an empty last line for a file that ends in a newline
        if ($lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    }
    foreach ($key in $Pairs.Keys) {
        $value = [string]$Pairs[$key]
        if ($value -match '[\s"]') { $value = '"' + $value.Replace('"', '\"') + '"' }
        $line = "$key=$value"
        $at = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].StartsWith("$key=")) { $at = $i; break }
        }
        if ($at -ge 0) { $lines[$at] = $line } else { $lines.Add($line) }
    }
    [IO.File]::WriteAllText($Path, ($lines -join $nl) + $nl, [Text.UTF8Encoding]::new($false))
}

# Saves the item's state after a successful check or install; never after a
# failure or with -Check. Each key takes its value from what the managers
# found, or from the item's own key of the same name. Empty values aren't written.
function Save-UpdateMetadata($it) {
    $pairs = [ordered]@{}
    foreach ($key in $script:SaveKeys) {
        $value = switch ($key) {
            'last_checked'    { $script:Today }
            'current_version' { $it.latest_tag }
            'content_length'  { $it.remote_length }
            'last_modified'   { $it.remote_modified }
            'asset_digest'    { $it.remote_digest }
            'etag'            { $it.remote_etag }
            default           { $it[$key] }
        }
        if (-not [string]::IsNullOrEmpty([string]$value)) { $pairs[$key] = $value }
    }
    Write-CfgValues $it.cfg_file $pairs
}

# True if every named key is set; otherwise says which are missing.
function Test-RequiredKeys($it, [string]$What, [string[]]$Keys) {
    $missing = @($Keys | Where-Object { [string]::IsNullOrEmpty($it[$_]) })
    if ($missing.Count -eq 0) { return $true }
    Say "⚠ $($script:Label): $What needs $($missing -join ' '), skipping"
    $false
}

# The installed file, if the cfg names one and it's still in the folder.
function Find-Installed($it, [string]$Dir) {
    if ([string]::IsNullOrEmpty($it.installed_file)) { return '' }
    $p = Join-Path $Dir $it.installed_file
    if (Test-Path -LiteralPath $p -PathType Leaf) { $p } else { '' }
}

# ---------------------------------------------------------------------------
# The paths file: each mode's folder, in %APPDATA%\update-tools (on other
# systems the same folder as the bash version). Read like a cfg, never run.
# ---------------------------------------------------------------------------
function Get-ConfigDir {
    if ($env:APPDATA) { return Join-Path $env:APPDATA 'update-tools' }
    $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    Join-Path $base 'update-tools'
}
$script:PathsFile = Join-Path (Get-ConfigDir) 'update-paths.cfg'
$script:Paths = $null

# app_dir is accepted (the file may be shared with the bash version) and unused.
function Get-Paths {
    if ($null -ne $script:Paths) { return $script:Paths }
    $script:Paths = @{}
    if (Test-Path -LiteralPath $script:PathsFile -PathType Leaf) {
        $saved = $script:Label
        $script:Label = Split-Path -Leaf $script:PathsFile
        $read = Read-Cfg $script:PathsFile @('app_dir', 'apw_dir', 'iso_dir')
        $script:Label = $saved
        foreach ($k in @($read.Keys)) {
            $v = [Environment]::ExpandEnvironmentVariables($read[$k])
            if ($v -eq '~' -or $v.StartsWith('~/') -or $v.StartsWith('~\')) { $v = $HOME + $v.Substring(1) }
            elseif ($v -eq '$HOME' -or $v.StartsWith('$HOME/') -or $v.StartsWith('$HOME\')) { $v = $HOME + $v.Substring(5) }
            $script:Paths[$k] = $v
        }
    }
    $script:Paths
}

# A path with the home folder shown as ~, for messages.
function Format-Path([string]$p) {
    if ($p -and ($p -eq $HOME -or $p.StartsWith($HOME + [IO.Path]::DirectorySeparatorChar))) {
        return '~' + $p.Substring($HOME.Length)
    }
    $p
}
