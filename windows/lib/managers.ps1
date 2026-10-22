# managers.ps1: the managers worlds and ISOs use (github, gitlab, static,
# dirlist, dateprobe) and the up-to-date test. Loaded by update-tools.ps1.

# A shell glob as an anchored regex: * and ? are wildcards, [...] stays a
# character class, and every other regex character matches literally.
function ConvertTo-GlobRegex([string]$Glob) {
    $sb = [Text.StringBuilder]::new('^')
    foreach ($ch in $Glob.ToCharArray()) {
        switch -CaseSensitive ($ch) {
            '*' { [void]$sb.Append('.*') }
            '?' { [void]$sb.Append('.') }
            { '.\^$+(){}|'.IndexOf($_) -ge 0 } { [void]$sb.Append('\' + $ch) }
            default { [void]$sb.Append($ch) }
        }
    }
    [void]$sb.Append('$')
    $sb.ToString()
}

# The anchored regex an asset's name must match: repo_regex as written, or the
# repo_filename glob converted. $null (having said why) unless exactly one of
# them is set and the regex compiles.
function Get-AssetPattern($it, [string]$Manager) {
    if ($it.repo_regex -and $it.repo_filename) {
        Say "⚠ $($script:Label): set repo_filename or repo_regex, not both, skipping"
        return $null
    }
    if ($it.repo_regex) {
        $pat = "^(?:$($it.repo_regex))`$"
        try { [void][regex]::new($pat) } catch {
            Say "⚠ $($script:Label): repo_regex '$($it.repo_regex)' isn't a valid regex, skipping"
            return $null
        }
    } elseif ($it.repo_filename) {
        $pat = ConvertTo-GlobRegex $it.repo_filename
    } else {
        Say "⚠ $($script:Label): $Manager manager needs repo_filename or repo_regex, skipping"
        return $null
    }
    Debug-Line "asset pattern: $pat"
    $pat
}

# @(tag, url, digest) for the newest suitable release with a matching asset, or
# $null. digest is GitHub's sha256, or updated:<time> for older assets.
function Select-GithubAsset($Releases, [string]$Pattern, [bool]$Pre) {
    foreach ($r in $Releases) {
        if ($r.draft) { continue }
        if ($r.prerelease -and -not $Pre) { continue }
        foreach ($a in @($r.assets)) {
            if ($a -and [regex]::IsMatch([string]$a.name, $Pattern)) {
                $digest = if ($a.digest) { [string]$a.digest } elseif ($a.updated_at) { 'updated:' + (Format-GithubDate $a.updated_at) } else { '' }
                return , @([string]$r.tag_name, [string]$a.browser_download_url, $digest)
            }
        }
    }
    $null
}

function Select-GitlabAsset($Releases, [string]$Pattern) {
    foreach ($r in $Releases) {
        foreach ($l in @($r.assets.links)) {
            if ($l -and [regex]::IsMatch([string]$l.name, $Pattern)) {
                $u = if ($l.direct_asset_url) { [string]$l.direct_asset_url } else { [string]$l.url }
                return , @([string]$r.tag_name, $u, [string]$l.name)
            }
        }
    }
    $null
}

# ---------------------------------------------------------------------------
# dirlist: globs in a URL, resolved against the server's listings
# ---------------------------------------------------------------------------
# GNU sort -V order for two strings: digit runs compare as numbers, the rest
# as text. Returns <0, 0 or >0.
function Compare-Version([string]$A, [string]$B) {
    $pa = [regex]::Matches($A, '\d+|\D+'); $pb = [regex]::Matches($B, '\d+|\D+')
    for ($i = 0; $i -lt [Math]::Min($pa.Count, $pb.Count); $i++) {
        $x = $pa[$i].Value; $y = $pb[$i].Value
        $dx = $x -match '^\d'; $dy = $y -match '^\d'
        if ($dx -and $dy) {
            $c = ([decimal]$x).CompareTo([decimal]$y)
        } else {
            $c = [string]::CompareOrdinal($x, $y)
        }
        if ($c -ne 0) { return $c }
    }
    $pa.Count - $pb.Count
}

# Names in a server's folder listing, folders with a trailing "/". Copes with
# plain index pages and SourceForge (absolute links ending in "/download").
# Rc 1: the folder isn't there (404, 410, so the next candidate may be tried);
# Rc 2: no answer (timeout, connection error, other HTTP errors).
function Get-DirListing([string]$Url) {
    $r = Invoke-Http $Url
    if ($r.Code -ge 200 -and $r.Code -lt 300) {
        $names = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
        foreach ($m in [regex]::Matches($r.Body, 'href="([^"]+)"')) {
            $h = $m.Groups[1].Value -replace '[?#].*$', '' -replace '/download$', ''
            $dir = $h.EndsWith('/')
            $h = $h.TrimEnd('/')
            $name = $h.Substring($h.LastIndexOf('/') + 1)
            if ($name -and $name -ne '.' -and $name -ne '..') { [void]$names.Add($(if ($dir) { "$name/" } else { $name })) }
        }
        return @{ Rc = 0; Names = @($names) }
    }
    if ($r.Code -in 404, 410) { return @{ Rc = 1 } }
    @{ Rc = 2 }
}

# The entries matching glob $Glob, newest first, judged by the numbers in the
# part the wildcards matched: EndeavourOS_Titan-Nova-2026.08.15 must beat
# Ganymede-Neo-2026.01.12, and the fixed "amd64" in a name must not count.
# Entries without any number there come last; URL escapes don't count.
function Sort-Newest([string]$Glob, [string[]]$Entries) {
    $first = $Glob.IndexOfAny([char[]]'[*?')
    $head = if ($first -ge 0) { $first } else { $Glob.Length }
    $tail = $Glob.Length - $Glob.LastIndexOf('*') - 1
    if ($Glob.LastIndexOf('*') -lt 0) { $tail = 0 }
    $items = [Collections.Generic.List[object]]::new()
    foreach ($e in $Entries) {
        if (-not ($e -clike $Glob)) { continue }
        $k = if ($e.Length -ge $head + $tail) { $e.Substring($head, $e.Length - $head - $tail) } else { '' }
        $k = ($k -replace '%[0-9A-Fa-f]{2}', ' ' -replace '[^0-9]+', '.').Trim('.')
        $items.Add([pscustomobject]@{ Has = [int]($k -ne ''); Key = $k; Entry = $e })
    }
    # few entries, so a plain insertion sort with the three-key comparison
    $sorted = [Collections.Generic.List[object]]::new()
    foreach ($it in $items) {
        $at = $sorted.Count
        for ($i = 0; $i -lt $sorted.Count; $i++) {
            $o = $sorted[$i]
            $c = $it.Has - $o.Has
            if ($c -eq 0) { $c = Compare-Version $it.Key $o.Key }
            if ($c -eq 0) { $c = Compare-Version $it.Entry $o.Entry }
            if ($c -gt 0) { $at = $i; break }
        }
        $sorted.Insert($at, $it)
    }
    @($sorted | ForEach-Object { $_.Entry })
}

# $Prefix = URL so far (ending in "/"), $Segs = the remaining path segments. A
# glob in a folder falls back to the next-newest match (up to 3) when the rest
# finds nothing. @{ Rc 0 and Url; Rc 1 nothing matches; Rc 2 and Url = the
# folder that gave no answer (no fallback: an older folder would offer a
# downgrade) }.
function Resolve-Segments([string]$Prefix, [string[]]$Segs) {
    $seg = $Segs[0]
    $rest = if ($Segs.Count -gt 1) { $Segs[1..($Segs.Count - 1)] } else { @() }
    if ($rest.Count) { $seg += '/' }
    if ($seg.IndexOfAny([char[]]'*[') -lt 0) {
        if ($rest.Count) { return Resolve-Segments "$Prefix$seg" $rest }
        return @{ Rc = 0; Url = "$Prefix$seg" }
    }
    $listing = Get-DirListing $Prefix
    if ($listing.Rc -eq 2) { return @{ Rc = 2; Url = $Prefix } }
    if ($listing.Rc -ne 0) { return @{ Rc = 1 } }
    $cands = @(Sort-Newest $seg $listing.Names | Select-Object -First 3)
    foreach ($cand in $cands) {
        if (-not $rest.Count) { return @{ Rc = 0; Url = "$Prefix$cand" } }
        $r = Resolve-Segments "$Prefix$cand" $rest
        if ($r.Rc -ne 1) { return $r }
    }
    @{ Rc = 1 }
}

function Resolve-GlobUrl([string]$Url) {
    $scheme = $Url.Substring(0, $Url.IndexOf('://'))
    $parts = $Url.Substring($scheme.Length + 3).Split('/')
    $rest = if ($parts.Count -gt 1) { $parts[1..($parts.Count - 1)] } else { @() }
    Resolve-Segments "${scheme}://$($parts[0])/" $rest
}

# The static lookup: one HEAD request that follows redirects. Sets asset_url
# (where it landed), asset_name, remote_length, remote_modified, remote_etag
# and latest_tag: static-SIZE-ETAG-NAME, leaving out what the server didn't send.
function Invoke-StaticHead($it, [string]$Url) {
    $r = Invoke-Http $Url -Method HEAD
    if ($r.Code -eq 0 -or $r.Code -ge 400) {
        Say "⚠ $($script:Label): could not reach $Url, skipping"
        return $false
    }
    $h = $r.Headers
    $it.asset_url = $r.Url
    $it.remote_length = if ($h.ContainsKey('content-length')) { $h['content-length'] } else { '' }
    $it.remote_modified = if ($h.ContainsKey('last-modified')) { $h['last-modified'] } else { '' }
    # some servers send no size on HEAD; their ETag still tells a new file apart
    $it.remote_etag = if ($h.ContainsKey('etag')) { $h['etag'] -replace '^W/', '' } else { '' }
    # redirects can land on signed URLs with a long query string
    $path = $it.asset_url -replace '\?.*$', ''
    $it.asset_name = $path.Substring($path.LastIndexOf('/') + 1)
    $tag = 'static'
    foreach ($part in @($it.remote_length, ($it.remote_etag -replace '"', ''), $it.asset_name)) {
        if ($part) { $tag += "-$part" }
    }
    $it.latest_tag = $tag
    $true
}

# ---------------------------------------------------------------------------
# Finds the newest version. Sets latest_tag, asset_url, asset_name, the
# remote_* values and remote_unchanged (github's 304, dateprobe with nothing
# newer). Returns 0 (ok), 1 (skip; the reason is already printed) or 2 (GitHub
# rate limit: stop the run).
# ---------------------------------------------------------------------------
function Resolve-LatestAsset($it) {
    foreach ($k in 'latest_tag', 'asset_url', 'asset_name', 'remote_length', 'remote_modified', 'remote_digest', 'remote_etag') { $it[$k] = '' }
    $it.remote_unchanged = $false

    switch ($it.manager) {
        'github' {
            if (-not (Test-RequiredKeys $it 'github manager' 'repo')) { return 1 }
            $pat = Get-AssetPattern $it 'github'
            if (-not $pat) { return 1 }
            # the list, not /latest, to honour allow_prereleases=auto; 100 per
            # page, as repos that host several games bury older ones
            $api = "https://api.github.com/repos/$($it.repo)/releases?per_page=100"
            $r = Get-GithubReleases $it $api $it.etag
            if ($r.Rc -eq 3) {
                # 304: the list is exactly what this item saw at its last check
                $it.latest_tag = $it.current_version; $it.remote_digest = $it.asset_digest
                $it.remote_etag = $r.Etag; $it.remote_unchanged = $true
                Debug-Line 'release list unchanged since the last check (304)'
                return 0
            }
            if ($r.Rc) { return $r.Rc }
            $prerel = if ($it.allow_prereleases) { $it.allow_prereleases } else { 'auto' }
            if ($prerel -notin 'auto', 'false', 'true') {
                Say "⚠ $($script:Label): allow_prereleases must be auto, false or true (got '$prerel'), skipping"
                return 1
            }
            $all = @($r.Releases)
            $result = Select-GithubAsset $all $pat ($prerel -eq 'true')
            # older releases live on later pages; fetch them only while nothing
            # matches. The ETag stays page 1's: any new release lands there.
            $page = $api
            while (-not $result -and $script:GH.Next[$page]) {
                $page = $script:GH.Next[$page]
                Debug-Line 'no match yet, fetching the next page of releases'
                $p = Get-GithubReleases $it $page
                if ($p.Rc) { return $(if ($p.Rc -eq 3) { 1 } else { $p.Rc }) }
                $all += @($p.Releases)
                $result = Select-GithubAsset $all $pat ($prerel -eq 'true')
            }
            $it.remote_etag = $r.Etag
            # auto: a stable release on any page beats a pre-release
            if (-not $result -and $prerel -eq 'auto') { $result = Select-GithubAsset $all $pat $true }
            if ($result) {
                $it.latest_tag, $it.asset_url, $it.remote_digest = $result
                $it.asset_name = $it.asset_url.Substring($it.asset_url.LastIndexOf('/') + 1)
            }
        }
        'gitlab' {
            if (-not (Test-RequiredKeys $it 'gitlab manager' 'repo_url')) { return 1 }
            $pat = Get-AssetPattern $it 'gitlab'
            if (-not $pat) { return 1 }
            # accept the project's web address however it was copied
            $project = $it.repo_url -replace '^.*?://gitlab\.com/', '' -replace '/$', '' -replace '\.git$', ''
            $releases = Get-GitlabReleases $project
            if ($null -eq $releases) { return 1 }
            $result = Select-GitlabAsset $releases $pat
            if ($result) {
                # the link's own name: URLs often end in /download or carry ?job=…
                $it.latest_tag, $it.asset_url, $it.asset_name = $result
                $it.asset_name = $it.asset_name.Replace('/', '_')
            }
        }
        'static' {
            if (-not (Test-RequiredKeys $it 'static manager' 'url')) { return 1 }
            if (-not (Invoke-StaticHead $it $it.url)) { return 1 }
        }
        'dirlist' {
            if (-not (Test-RequiredKeys $it 'dirlist manager' 'url')) { return 1 }
            $g = Resolve-GlobUrl $it.url
            $file = $it.url.Substring($it.url.LastIndexOf('/') + 1)
            if ($g.Rc -eq 2) { Say "⚠ $($script:Label): could not list $($g.Url), skipping"; return 1 }
            if ($g.Rc) { Say "⚠ $($script:Label): nothing on the server matches $file, skipping"; return 1 }
            $it.asset_url = $g.Url
            $it.asset_name = $g.Url.Substring($g.Url.LastIndexOf('/') + 1)
            # never offer an older build than the installed one (a mirror still
            # syncing, say), ranked by the URL's glob
            if ($it.installed_file -and $it.asset_name -ne $it.installed_file) {
                $newest = @(Sort-Newest $file @($it.asset_name, $it.installed_file))
                if ($newest.Count -and $newest[0] -eq $it.installed_file) {
                    Say "⚠ $($script:Label): the server's newest is $($it.asset_name), older than the installed $($it.installed_file), skipping"
                    return 1
                }
            }
            $it.asset_url += [string]$it.download_suffix
            $it.latest_tag = $it.asset_name
        }
        'dateprobe' {
            if (-not (Test-RequiredKeys $it 'dateprobe manager' 'url')) { return 1 }
            # no listing (Nobara's bucket): try dates from today back, stopping at
            # the installed one; each try is one HEAD request, on the checksum
            # file when the cfg names one
            $days = if ($it.probe_days -match '^\d+$') { [int]$it.probe_days } else { 90 }
            $curDate = if ($it.installed_file -match '\d{4}-\d{2}-\d{2}') { $Matches[0] } else { '' }
            for ($d = 0; $d -le $days; $d++) {
                $day = (Get-Date).AddDays(-$d).ToString('yyyy-MM-dd')
                if ($curDate -and [string]::CompareOrdinal($day, $curDate) -lt 0) { break }
                $cand = $it.url.Replace('{date}', $day)
                $probe = $cand
                if ($it.checksum) {
                    $probe = $it.checksum.Replace('{iso}', $cand.Substring($cand.LastIndexOf('/') + 1))
                    if ($probe -notmatch '://') { $probe = $cand.Substring(0, $cand.LastIndexOf('/') + 1) + $probe }
                }
                $r = Invoke-Http $probe -Method HEAD
                if ($r.Code -ge 200 -and $r.Code -lt 400) { $it.asset_url = $cand; break }
            }
            if (-not $it.asset_url -and $curDate) {
                # nothing newer: what's installed is the latest
                $it.latest_tag = $it.installed_file; $it.asset_name = $it.installed_file; $it.remote_unchanged = $true
                Debug-Line "no build newer than $curDate on the server"
                return 0
            }
            if (-not $it.asset_url) {
                Say "⚠ $($script:Label): no $($it.url.Substring($it.url.LastIndexOf('/') + 1)) found in the last $days days, skipping"
                return 1
            }
            $it.asset_name = $it.asset_url.Substring($it.asset_url.LastIndexOf('/') + 1)
            $it.latest_tag = $it.asset_name
        }
        default {
            Say "⚠ $($script:Label): unknown or missing manager '$($it.manager)', skipping"
            return 1
        }
    }

    if (-not $it.asset_url -or $it.asset_url -eq 'null') {
        Say "⚠ $($script:Label): could not resolve download URL, skipping"
        return 1
    }
    $dg = if ($it.remote_digest) { ", $($it.remote_digest.Substring(0, [Math]::Min(23, $it.remote_digest.Length)))…" } else { '' }
    Debug-Line "latest ($($it.manager)): $($it.latest_tag), $($it.asset_name)$dg"
    Debug-Line "download URL: $($it.asset_url)"
    if ($it.manager -eq 'static') { Debug-Line "server says $($it.remote_length) bytes, last modified $($it.remote_modified)" }
    0
}

# The version to show for a result: latest_tag, plus file name $File in
# brackets unless the tag already ends in it (a static tag ends in -NAME, a
# dirlist tag is the name).
function Get-ShownVersion($it, [string]$File) {
    $shown = [string]$it.latest_tag
    if ($File -and $shown -ne $File -and -not $shown.EndsWith("-$File")) {
        $shown = if ($shown) { "$shown ($File)" } else { $File }
    }
    $shown
}

# True if the item is already up to date. $Installed = the installed file,
# hashed once for github cfgs saved before asset_digest, and for ISOs without
# an iso_hash for the checksum's algorithm.
function Test-UpToDate($it, [string]$Installed) {
    if ($it.remote_unchanged) { return $true }
    # ISOs compare checksums whatever the manager
    if ($script:Type -eq 'iso') {
        if (-not ([string]$it.iso_hash).StartsWith("$($it.algo):")) {
            Status "🔍 hashing $(Split-Path -Leaf $Installed)"
            $it.iso_hash = "$($it.algo):$(Get-Hash $it.algo $Installed)"
        }
        Debug-Line "installed $($it.iso_hash.Substring(0, [Math]::Min(23, $it.iso_hash.Length)))… vs expected $($it.algo) $($it.want.Substring(0, 16))…"
        return $it.iso_hash -eq "$($it.algo):$($it.want)"
    }
    switch ($it.manager) {
        'static' {
            Debug-Line "size $($it.remote_length) vs saved $($it.content_length), modified $($it.remote_modified) vs saved $($it.last_modified), ETag $($it.remote_etag) vs saved $($it.etag)"
            if (-not ($it.remote_length + $it.remote_modified + $it.remote_etag)) {
                Say "⚠ $($script:Label): the server gives no size, date or ETag, so it can't tell whether it changed; downloading again"
                return $false
            }
            # the version ends in the file's name: a URL that now lands on
            # another file isn't up to date. A version saved before names were
            # in it can't tell, so the other checks decide.
            $unnamed = 'static-' + $(if ($it.remote_length) { $it.remote_length } else { $it.remote_etag -replace '"', '' })
            if ($it.current_version -and $it.current_version -ne $unnamed -and -not $it.current_version.EndsWith("-$($it.asset_name)")) {
                Debug-Line "file name changed: now $($it.asset_name), saved version $($it.current_version)"
                return $false
            }
            $known = $false; $changed = $false
            foreach ($pair in @(@($it.remote_length, $it.content_length), @($it.remote_modified, $it.last_modified), @($it.remote_etag, $it.etag))) {
                if ($pair[0] -and $pair[1]) { $known = $true; if ($pair[0] -ne $pair[1]) { $changed = $true } }
            }
            return $known -and -not $changed
        }
        'github' {
            Debug-Line "tag $($it.latest_tag) vs installed $($it.current_version)"
            if ($it.latest_tag -ne $it.current_version) { return $false }
            # same tag, but rolling releases (latest, continuous) re-upload
            if ($it.asset_digest) {
                Debug-Line 'same tag; comparing the asset digest with the saved one'
                return $it.remote_digest -eq $it.asset_digest
            }
            if (([string]$it.remote_digest).StartsWith('sha256:')) {
                Debug-Line 'same tag, no saved digest: hashing the installed file once'
                return "sha256:$(Get-Hash sha256 $Installed)" -eq $it.remote_digest
            }
            # no sha256 to compare; adopt the upload time from now on
            return $true
        }
        default {
            Debug-Line "version $($it.latest_tag) vs installed $($it.current_version)"
            return $it.latest_tag -eq $it.current_version
        }
    }
}
