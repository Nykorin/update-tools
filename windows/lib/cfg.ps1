# cfg.ps1: reading and saving the item cfgs (JSON), and the settings file.
# Loaded by update-tools.ps1.

# Each item's cfg is .cfg\NAME.json, as in the bash version: your keys at the
# top level, the ones the scripts write under "state", and an optional
# "comment" the scripts ignore. Values are text (numbers and true/false are
# read as text too). Read-Item returns only the keys below: a cfg is data,
# never code.
$script:ItemKeys = @(
    'manager', 'repo', 'repo_filename', 'repo_regex', 'allow_prereleases', 'repo_url',
    'feed_url', 'channel', 'arch_key', 'download_base', 'url',
    'apworld_filename', 'icon_name', 'install_name',
    'checksum', 'checksum_save', 'download_suffix', 'probe_days', 'folder'
)
# Keys the scripts keep up to date themselves, in the order new ones are added.
$script:SaveKeys = @('current_version', 'last_checked', 'content_length', 'last_modified',
                     'asset_digest', 'etag', 'installed_file', 'iso_hash', 'checksum_file')

# An ordered dictionary with case-sensitive keys, as JSON's are.
function New-JsonObject { ,[Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal) }

# JSON text as ordered dictionaries, lists, strings, numbers, booleans and
# $null. PowerShell 7's ConvertFrom-Json turns text that looks like a date into
# a DateTime, so 7 parses with System.Text.Json; 5.1's leaves text alone.
function ConvertFrom-JsonText([string]$Text) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $doc = [System.Text.Json.JsonDocument]::Parse($Text)
        try { return ,(ConvertFrom-JsonElement $doc.RootElement) } finally { $doc.Dispose() }
    }
    $o = ConvertFrom-Json $Text
    ,(ConvertFrom-JsonObject $o)
}

function ConvertFrom-JsonElement($e) {
    switch ($e.ValueKind.ToString()) {
        'Object' {
            $d = New-JsonObject
            foreach ($p in $e.EnumerateObject()) { $d[$p.Name] = ConvertFrom-JsonElement $p.Value }
            return ,$d
        }
        'Array' {
            $l = [Collections.Generic.List[object]]::new()
            foreach ($x in $e.EnumerateArray()) { $l.Add((ConvertFrom-JsonElement $x)) }
            return ,$l
        }
        'String' { return $e.GetString() }
        'Number' {
            $n = [long]0
            if ($e.TryGetInt64([ref]$n)) { return $n }
            return $e.GetDouble()
        }
        'True'   { return $true }
        'False'  { return $false }
        default  { return $null }
    }
}

function ConvertFrom-JsonObject($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [Management.Automation.PSCustomObject]) {
        $d = New-JsonObject
        foreach ($p in $o.PSObject.Properties) { $d[$p.Name] = ConvertFrom-JsonObject $p.Value }
        return ,$d
    }
    if ($o -is [Array]) {
        $l = [Collections.Generic.List[object]]::new()
        foreach ($x in $o) { $l.Add((ConvertFrom-JsonObject $x)) }
        return ,$l
    }
    $o
}

# A string as jq writes it: " and \ escaped, control characters as \b \f \n
# \r \t or \u00XX (DEL too), everything else as it is.
function ConvertTo-JqString([string]$s) {
    $sb = [Text.StringBuilder]::new('"')
    foreach ($c in $s.ToCharArray()) {
        $code = [int]$c
        switch ($code) {
            34 { [void]$sb.Append('\"') }
            92 { [void]$sb.Append('\\') }
            8  { [void]$sb.Append('\b') }
            12 { [void]$sb.Append('\f') }
            10 { [void]$sb.Append('\n') }
            13 { [void]$sb.Append('\r') }
            9  { [void]$sb.Append('\t') }
            default {
                if ($code -lt 32 -or $code -eq 127) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
                else { [void]$sb.Append($c) }
            }
        }
    }
    [void]$sb.Append('"')
    $sb.ToString()
}

# A number or boolean as jq prints it, also what jq's tostring gives.
function ConvertTo-JqScalar($v) {
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    if ($v -is [double] -or $v -is [single]) { return $v.ToString('R', [Globalization.CultureInfo]::InvariantCulture) }
    [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $v)
}

# A value as jq --indent 2 writes it, so either version can save a cfg the
# other wrote without reformatting it.
function ConvertTo-JqJson($v, [string]$Pad = '') {
    if ($null -eq $v) { return 'null' }
    if ($v -is [string]) { return ConvertTo-JqString $v }
    $inner = $Pad + '  '
    if ($v -is [Collections.IDictionary]) {
        if ($v.Count -eq 0) { return '{}' }
        $parts = foreach ($k in $v.Keys) { $inner + (ConvertTo-JqString $k) + ': ' + (ConvertTo-JqJson $v[$k] $inner) }
        return "{`n" + ($parts -join ",`n") + "`n$Pad}"
    }
    if ($v -is [Collections.IList]) {
        if ($v.Count -eq 0) { return '[]' }
        $parts = foreach ($x in $v) { $inner + (ConvertTo-JqJson $x $inner) }
        return "[`n" + ($parts -join ",`n") + "`n$Pad]"
    }
    ConvertTo-JqScalar $v
}

# Writes a JSON tree to $Path: to a hidden temp file next to it, then over it,
# so a cut-off write never leaves half a cfg. UTF-8 without a byte-order mark,
# ending in a newline, as jq writes it.
function Write-JsonFile([string]$Path, $Tree) {
    $tmp = Join-Path (Split-Path -Parent $Path) ".$(Split-Path -Leaf $Path).tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-JqJson $Tree) + "`n", [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path) {
        # ReplaceFile can fail on some file systems; a copy still writes it whole
        try { [IO.File]::Replace($tmp, $Path, $null) }
        catch { [IO.File]::Copy($tmp, $Path, $true); Remove-Item -LiteralPath $tmp -Force }
    } else {
        [IO.File]::Move($tmp, $Path)
    }
}

# One value of a cfg into the item: unset when null, refused when it's a list
# or object, reported when the key isn't one of $Keys.
function Set-ItemValue($it, [string]$Key, $Value, [string]$Prefix, [string[]]$Keys, [string]$Leaf) {
    if ($null -eq $Value) { return }
    if ($Value -is [Collections.IDictionary] -or $Value -is [Collections.IList]) {
        Say "⚠ $($script:Label): '$Key' in $Leaf must be text, ignored"; return
    }
    if ($Keys -cnotcontains $Key) { Say "⚠ $($script:Label): unknown key '$Prefix$Key' in $Leaf, ignored"; return }
    $it[$Key] = if ($Value -is [string]) { $Value } else { ConvertTo-JqScalar $Value }
}

# The item's keys from its JSON as a hashtable, or $null (having said why)
# when the file isn't a valid JSON object.
function Read-Item([string]$Path) {
    $leaf = Split-Path -Leaf $Path
    $why = ''
    $tree = $null
    try {
        $text = [IO.File]::ReadAllText($Path)
        if ($text.Trim().Length -eq 0) { $why = 'empty file' }
        else { $tree = ConvertFrom-JsonText $text }
    } catch {
        # the parser's own reason, not PowerShell's "Exception calling Parse"
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        $why = ($ex.Message -split "`r?`n")[0]
    }
    if (-not $why -and -not ($tree -is [Collections.IDictionary])) { $why = 'not a JSON object' }
    if ($why) {
        Say "⚠ $($script:Label): $leaf isn't a valid cfg ($why), skipping"
        return $null
    }
    $it = @{}
    foreach ($k in @($tree.Keys)) {
        if ($k -ceq 'state' -or $k -ceq 'comment') { continue }
        Set-ItemValue $it $k $tree[$k] '' $script:ItemKeys $leaf
    }
    $st = $tree['state']
    if ($null -ne $st) {
        if ($st -is [Collections.IDictionary]) {
            foreach ($k in @($st.Keys)) { Set-ItemValue $it $k $st[$k] 'state.' $script:SaveKeys $leaf }
        } else {
            Say "⚠ $($script:Label): 'state' in $leaf isn't an object, ignored"
        }
    }
    $it
}

# Sets each pair under the item's "state", keeping everything else (and the
# order of the keys already there); content_length is saved as a number.
function Save-State([string]$Path, [System.Collections.Specialized.OrderedDictionary]$Pairs) {
    try {
        $tree = ConvertFrom-JsonText ([IO.File]::ReadAllText($Path))
        if (-not ($tree -is [Collections.IDictionary])) { throw 'not a JSON object' }
        $st = $tree['state']
        if ($null -eq $st) { $st = New-JsonObject; $tree['state'] = $st }
        elseif (-not ($st -is [Collections.IDictionary])) { throw "'state' isn't an object" }
        foreach ($k in $Pairs.Keys) {
            $v = $Pairs[$k]
            $n = [long]0
            if ($k -ceq 'content_length' -and [long]::TryParse([string]$v, [ref]$n)) { $v = $n }
            $st[$k] = $v
        }
        Write-JsonFile $Path $tree
        $true
    } catch {
        Remove-IfThere (Join-Path (Split-Path -Parent $Path) ".$(Split-Path -Leaf $Path).tmp")
        Say "  ✗ $($script:Label): could not save $(Split-Path -Leaf $Path)"
        $false
    }
}

# Saves the item's state after a successful check or install; never after a
# failure or with -Check. Each key takes its value from what the managers
# found, or from the item's own key of the same name. Empty values aren't written.
function Save-UpdateMetadata($it) {
    $pairs = [ordered]@{}
    foreach ($key in $script:SaveKeys) {
        $value = switch ($key) {
            'last_checked'    { $script:CheckedAt }
            'current_version' { $it.latest_tag }
            'content_length'  { $it.remote_length }
            'last_modified'   { $it.remote_modified }
            'asset_digest'    { $it.remote_digest }
            'etag'            { $it.remote_etag }
            default           { $it[$key] }
        }
        if (-not [string]::IsNullOrEmpty([string]$value)) { $pairs[$key] = [string]$value }
    }
    [void](Save-State $it.cfg_file $pairs)
}

# The settings file's KEY=VALUE lines as a hashtable (the item cfgs were these
# too until 2026-11-07). $Keys = the keys allowed; others are reported and
# ignored. Blank lines and # comments are skipped, a value in double quotes
# loses them, and Windows line endings are fine.
function Read-Cfg([string]$Path, [string[]]$Keys) {
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
# The settings file, update-tools.cfg in %APPDATA%\update-tools (on other
# systems the same folder as the bash version): each mode's folder, and
# whether and for how long an item checked recently is skipped. Read like a
# cfg, never run.
# ---------------------------------------------------------------------------
function Get-ConfigDir {
    if ($env:APPDATA) { return Join-Path $env:APPDATA 'update-tools' }
    $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    Join-Path $base 'update-tools'
}
$script:SettingsFile = Join-Path (Get-ConfigDir) 'update-tools.cfg'
$script:Settings = $null
# seconds an item stays "checked" after its last check; 0: never skipped
$script:SkipSeconds = 86400

# app_dir is accepted (the file may be shared with the bash version) and unused.
function Get-Settings {
    if ($null -ne $script:Settings) { return $script:Settings }
    $script:Settings = @{}
    if (-not (Test-Path -LiteralPath $script:SettingsFile -PathType Leaf)) { return $script:Settings }
    $saved = $script:Label
    $script:Label = Split-Path -Leaf $script:SettingsFile
    $read = Read-Cfg $script:SettingsFile @('app_dir', 'apw_dir', 'iso_dir', 'skip_checked', 'skip_hours')
    $script:Label = $saved
    foreach ($k in @($read.Keys)) {
        $v = $read[$k]
        if ($k -like '*_dir') {
            $v = [Environment]::ExpandEnvironmentVariables($v)
            if ($v -eq '~' -or $v.StartsWith('~/') -or $v.StartsWith('~\')) { $v = $HOME + $v.Substring(1) }
            elseif ($v -eq '$HOME' -or $v.StartsWith('$HOME/') -or $v.StartsWith('$HOME\')) { $v = $HOME + $v.Substring(5) }
        }
        $script:Settings[$k] = $v
    }
    $file = Split-Path -Leaf $script:SettingsFile
    $on = if ($script:Settings.skip_checked) { $script:Settings.skip_checked } else { 'on' }
    if ($on -eq 'off') { $script:SkipSeconds = 0; return $script:Settings }
    if ($on -ne 'on') { Say "⚠ $($file): skip_checked must be on or off (got '$on'), using on" }
    $hours = if ($script:Settings.skip_hours) { $script:Settings.skip_hours } else { '24' }
    if ($hours -match '^[1-9][0-9]*$') { $script:SkipSeconds = [int]$hours * 3600 }
    else { Say "⚠ $($file): skip_hours must be a whole number of hours (got '$hours'), using 24" }
    $script:Settings
}

# True if the item was checked less than skip_hours ago; sets checked_ago for
# the message. last_checked is yyyy-MM-ddTHH:mm, or a date alone (saved before
# times were added), read as that day's midnight.
function Test-CheckedRecently($it) {
    if (-not $script:SkipSeconds) { return $false }
    $lc = [string]$it.last_checked
    if ($lc -notmatch '^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?$') { return $false }
    $format = if ($lc.Length -gt 10) { "yyyy-MM-dd'T'HH:mm" } else { 'yyyy-MM-dd' }
    $stamp = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($lc, $format, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$stamp)) { return $false }
    $age = ($script:Now - $stamp).TotalSeconds
    # a time in the future (a changed clock) counts as not checked
    if ($age -lt 0 -or $age -ge $script:SkipSeconds) { return $false }
    $it.checked_ago = if ($age -lt 3600) { "$([math]::Floor($age / 60)) min" } else { "$([math]::Floor($age / 3600)) h" }
    $true
}

# A path with the home folder shown as ~, for messages.
function Format-Path([string]$p) {
    if ($p -and ($p -eq $HOME -or $p.StartsWith($HOME + [IO.Path]::DirectorySeparatorChar))) {
        return '~' + $p.Substring($HOME.Length)
    }
    $p
}
