# isos.ps1: the ISO hooks (checksums, free space, the folder= key). Every
# download is verified against the upstream checksum before it replaces
# anything. Loaded by update-tools.ps1; used in -Mode iso.

# @(algo, hash) for file $Name in checksum text $Text, or $null. Reads GNU
# lines ("hash  name", "hash *name", "hash  ./name") and BSD lines
# ("SHA256 (name) = hash"), matching on the file name alone; sha512 wins over
# sha256, and md5/sha1 entries are ignored.
function Find-Checksum([string]$Text, [string]$Name) {
    $best = 0; $hash = ''
    foreach ($line in ($Text -split "`r?`n")) {
        $n = ''; $h = ''
        if ($line -match '^[A-Za-z0-9-]+ \((.*)\) = ([0-9a-fA-F]+)$') {
            $n = $Matches[1]; $h = $Matches[2]
        } elseif ($line -match '^([0-9a-fA-F]+) [ *](.*)$') {
            $h = $Matches[1]; $n = $Matches[2] -replace '^ ?\*?(\./)?', ''
        }
        $n = $n.Substring($n.LastIndexOf('/') + 1)
        if ($h -and $n -eq $Name -and ($h.Length -eq 64 -or $h.Length -eq 128) -and $h.Length -gt $best) {
            $best = $h.Length; $hash = $h.ToLower()
        }
    }
    if (-not $best) { return $null }
    , @($(if ($best -eq 128) { 'sha512' } else { 'sha256' }), $hash)
}

function iso_PrepareDir {
    # each item's dir is its ISO's folder, so keep the root
    $script:IsoDir = $script:Dir
    # old versions wait here during an update (as .previous, which Ventoy
    # doesn't list)
    $script:TmpDir = Join-Path $script:Dir '.tmp'
    # left over from a run that was killed outright (Ctrl+C cleans up after
    # itself): an old version goes back, a half-downloaded ISO goes
    Restore-Interrupted
    Get-ChildItem -LiteralPath $script:Dir -Recurse -Force -File -Filter '.*.part' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-IfThere $_.FullName }
}

# folder= is relative to the root, so -Root still works; it may not leave it.
# Every ISO is verified, so checksum is required.
function iso_Setup($it) {
    $folder = ([string]$it.folder).TrimEnd('/', '\')
    Debug-Line "folder: $(if ($folder) { $folder } else { 'none' })"
    $parts = $folder -split '[/\\]'
    if (-not $folder -or [IO.Path]::IsPathRooted($folder) -or $folder.StartsWith('/') -or $folder.StartsWith('\') -or $parts -contains '..') {
        Say "⚠ $($it.name): folder must be a path inside $($script:IsoDir), like Linux/Fedora/Fedora, skipping"
        return $false
    }
    $it.dir = Join-Path $script:IsoDir ($parts -join [IO.Path]::DirectorySeparatorChar)
    Test-RequiredKeys $it 'an ISO cfg' 'checksum'
}

# The checksum for asset_name: sets sum_url, sum_text, algo and want. A relative
# checksum sits next to the ISO; for static, next to the cfg's URL (Garuda's
# latest.iso.sha256 is beside latest.iso, not where it redirects).
function iso_PrepareCheck($it) {
    if ($it.manager -eq 'static') {
        $dirUrl = $it.url.Substring(0, $it.url.LastIndexOf('/') + 1)
    } else {
        $u = $it.asset_url
        if ($it.download_suffix -and $u.EndsWith($it.download_suffix)) { $u = $u.Substring(0, $u.Length - $it.download_suffix.Length) }
        $dirUrl = $u.Substring(0, $u.LastIndexOf('/') + 1)
    }
    $sum = $it.checksum.Replace('{iso}', $it.asset_name)
    if ($sum -notmatch '://') { $sum = $dirUrl + $sum }
    if ($sum.IndexOfAny([char[]]'*[') -ge 0) {
        $g = Resolve-GlobUrl $sum
        if ($g.Rc -eq 2) { Say "⚠ $($script:Label): could not list $($g.Url), skipping"; return $false }
        if ($g.Rc) { Say "⚠ $($script:Label): no checksum file matches $($sum.Substring($sum.LastIndexOf('/') + 1)), skipping"; return $false }
        $sum = $g.Url
    }
    $it.sum_url = $sum
    Debug-Line "checksum file: $sum"
    $r = Invoke-Http $sum
    if ($r.Code -lt 200 -or $r.Code -ge 300) {
        Say "⚠ $($it.name): could not fetch checksum file $sum, skipping"
        return $false
    }
    $it.sum_text = $r.Body.TrimEnd("`r", "`n")
    $found = Find-Checksum $it.sum_text $it.asset_name
    if (-not $found) {
        Say "⚠ $($it.name): $($it.asset_name) isn't listed in $($sum.Substring($sum.LastIndexOf('/') + 1)), skipping"
        return $false
    }
    $it.algo, $it.want = $found
    Debug-Line "expected $($it.algo) $($it.want.Substring(0, 16))…"
    $true
}

# keep 256 MiB spare; the old ISO stays until the new one verifies
function iso_Preflight($it) {
    [void](New-Item -ItemType Directory -Force -Path $it.dir)
    $size = $it.remote_length
    if (-not $size) {
        $h = Invoke-Http $it.asset_url -Method HEAD
        if ($h.Headers.ContainsKey('content-length')) { $size = $h.Headers['content-length'] }
    }
    $full = (Resolve-Path -LiteralPath $it.dir).ProviderPath
    $avail = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($full)).AvailableFreeSpace
    Debug-Line "size $(if ($size) { $size } else { 'unknown' }) bytes, $([math]::Floor($avail / 1MB)) MiB free"
    if ($size -match '^\d+$' -and [long]$size + 256MB -gt $avail) {
        Say "⚠ $($it.name): not enough space for $($it.asset_name) ($([math]::Floor([long]$size / 1MB)) MiB + 256 MiB spare needed, $([math]::Floor($avail / 1MB)) MiB free), skipping"
        return $false
    }
    $true
}

# next to the ISO (same disk, so installing is a rename), hidden and not ending
# in .iso so Ventoy never lists a partial download
function iso_Stage($it) {
    $it.tmp_download = Join-Path $it.dir ".$($it.asset_name).part"
}

# The checksum was looked up under the upstream name, which the install name
# may differ from.
function iso_Validate($it) {
    Status "🔍 verifying $($it.asset_name)"
    $got = Get-Hash $it.algo $it.tmp_download
    Debug-Line "downloaded file's $($it.algo): $($got.Substring(0, 16))…"
    if ($got -ne $it.want) {
        Say "  ✗ $($it.name): checksum mismatch for $($it.asset_name), download deleted"
        return $false
    }
    $it.iso_hash = "$($it.algo):$($it.want)"
    $true
}

# the upstream checksum file next to the ISO; the old one goes once it's saved
function iso_Extras($it) {
    $sumName = if ($it.checksum_save) { $it.checksum_save } else { $it.sum_url.Substring($it.sum_url.LastIndexOf('/') + 1) }
    $sumName = $sumName.Replace('{iso}', $it.asset_name)
    [IO.File]::WriteAllText((Join-Path $it.dir $sumName), $it.sum_text + "`n", [Text.UTF8Encoding]::new($false))
    if ($it.checksum_file -and $it.checksum_file -ne $sumName) { Remove-IfThere (Join-Path $it.dir $it.checksum_file) }
    $it.checksum_file = $sumName
}
