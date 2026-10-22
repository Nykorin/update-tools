# net.ps1: HTTP requests and downloads, GitHub and GitLab release lists, the
# GitHub token and request budget. Loaded by update-tools.ps1.

Add-Type -AssemblyName System.Net.Http

# Redirects are followed here, not by .NET, so the GitHub token only ever goes
# to api.github.com. Small requests get a hard time limit; downloads only fail
# when they stall, so a big ISO on a slow line still finishes.
function New-Client([TimeSpan]$Timeout) {
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = $Timeout
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('update-tools')
    $client
}
$script:MetaClient = New-Client ([TimeSpan]::FromSeconds(120))
$script:DlClient = New-Client ([System.Threading.Timeout]::InfiniteTimeSpan)

# The GitHub token: $env:GITHUB_TOKEN, else the first line of github_token in
# the config folder. Never printed.
$script:GithubToken = $env:GITHUB_TOKEN
if (-not $script:GithubToken) {
    $tokenFile = Join-Path (Get-ConfigDir) 'github_token'
    if (Test-Path -LiteralPath $tokenFile -PathType Leaf) {
        $script:GithubToken = ([IO.File]::ReadAllLines($tokenFile) | Select-Object -First 1).Trim()
    }
}

# Sends one request, following up to 10 redirects. Returns @{ Code; Body;
# Headers (lower-case names); Url (where it landed) }. Code 0 means no answer
# (timeout, connection error). -Token adds the GitHub token, on api.github.com only.
function Invoke-Http {
    param([string]$Url, [string]$Method = 'GET', [hashtable]$Headers = @{}, [switch]$Token,
          [switch]$Stream)
    $current = [Uri]$Url
    # file:// (a cfg may name a local file, as with curl): read it directly
    if ($current.IsFile) {
        $local = $current.LocalPath
        if (-not (Test-Path -LiteralPath $local -PathType Leaf)) { return @{ Code = 404; Body = ''; Headers = @{}; Url = $current.AbsoluteUri; Hops = 0 } }
        $f = Get-Item -LiteralPath $local
        $body = if ($Method -eq 'HEAD' -or $Stream) { '' } else { [IO.File]::ReadAllText($local) }
        return @{ Code = 200; Body = $body; Url = $current.AbsoluteUri; Hops = 0; LocalPath = $local
                  Headers = @{ 'content-length' = [string]$f.Length; 'last-modified' = $f.LastWriteTimeUtc.ToString('r') } }
    }
    for ($hop = 0; $hop -le 10; $hop++) {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $current)
        foreach ($k in $Headers.Keys) { [void]$req.Headers.TryAddWithoutValidation($k, $Headers[$k]) }
        if ($Token -and $script:GithubToken -and $current.Host -eq 'api.github.com') {
            [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $($script:GithubToken)")
        }
        $client = if ($Stream) { $script:DlClient } else { $script:MetaClient }
        $completion = if ($Stream) { [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead } else { [System.Net.Http.HttpCompletionOption]::ResponseContentRead }
        try {
            $resp = $client.SendAsync($req, $completion).GetAwaiter().GetResult()
        } catch {
            return @{ Code = 0; Body = ''; Headers = @{}; Url = $current.AbsoluteUri; Error = $_.Exception.Message }
        }
        $code = [int]$resp.StatusCode
        $hdr = @{}
        foreach ($h in @($resp.Headers) + @($resp.Content.Headers)) { $hdr[$h.Key.ToLower()] = ($h.Value -join ', ') }
        if ($code -in 301, 302, 303, 307, 308 -and $hdr.location) {
            $resp.Dispose()
            $current = [Uri]::new($current, $hdr.location)
            if ($code -eq 303) { $Method = 'GET' }
            continue
        }
        $result = @{ Code = $code; Headers = $hdr; Url = $current.AbsoluteUri; Hops = $hop; Response = $null; Body = '' }
        if ($Stream) {
            $result.Response = $resp
        } else {
            if ($Method -ne 'HEAD') {
                try { $result.Body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch { $result.Code = 0 }
            }
            $resp.Dispose()
        }
        return $result
    }
    @{ Code = 0; Body = ''; Headers = @{}; Url = $current.AbsoluteUri; Error = 'too many redirects' }
}

# Downloads $Url to $Dest. Fails on any HTTP error, so an error page is never
# installed, and when less than 60 KB arrive in a minute.
function Save-Download([string]$Url, [string]$Dest) {
    $r = Invoke-Http $Url -Stream
    if ($r.LocalPath) {
        try { Copy-Item -LiteralPath $r.LocalPath -Destination $Dest -Force; return $true }
        catch { Say "  ✗ $($script:Label): download failed ($($_.Exception.Message))"; return $false }
    }
    if ($r.Code -lt 200 -or $r.Code -ge 300) {
        if ($r.Response) { $r.Response.Dispose() }
        $why = if ($r.Code) { "HTTP $($r.Code)" } else { $r.Error }
        Say "  ✗ $($script:Label): download failed ($why)"
        return $false
    }
    $resp = $r.Response
    $total = if ($resp.Content.Headers.ContentLength) { [long]$resp.Content.Headers.ContentLength } else { 0 }
    $in = $null; $out = $null
    try {
        $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $out = [IO.File]::Create($Dest)
        $buf = New-Object byte[] 262144
        $got = 0L; $windowStart = [DateTime]::UtcNow; $windowBytes = 0L; $shown = [DateTime]::MinValue
        while ($true) {
            $task = $in.ReadAsync($buf, 0, $buf.Length)
            if (-not $task.Wait(60000)) { throw 'no data for 60 s' }
            $n = $task.Result
            if ($n -le 0) { break }
            $out.Write($buf, 0, $n)
            $got += $n; $windowBytes += $n
            $now = [DateTime]::UtcNow
            if (($now - $windowStart).TotalSeconds -ge 60) {
                if ($windowBytes -lt 61440) { throw 'slower than 1 KB/s for a minute' }
                $windowStart = $now; $windowBytes = 0
            }
            if (($now - $shown).TotalMilliseconds -ge 500) { Show-DownloadProgress $got $total; $shown = $now }
        }
        if ($total -gt 0 -and $got -ne $total) { throw "got $got of $total bytes" }
        return $true
    } catch {
        Say "  ✗ $($script:Label): download failed ($($_.Exception.Message -replace '^Exception calling .*?: ', ''))"
        return $false
    } finally {
        if ($out) { $out.Dispose() }
        if ($in) { $in.Dispose() }
        $resp.Dispose()
        Clear-DownloadProgress
    }
}

# ---------------------------------------------------------------------------
# GitHub
# ---------------------------------------------------------------------------
$script:GH = @{ Cache = @{}; Etags = @{}; Next = @{}; Calls = 0; Free = 0
                Limit = ''; Remaining = ''; Reset = ''; RateLimited = $false }

# GitHub dates as GitHub sends them; PowerShell 7 turns them into DateTime.
function Format-GithubDate($d) {
    if ($d -is [datetime]) { return $d.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    [string]$d
}

# The release list at $ApiUrl, fetched once per run. $Etag = the one this item
# saved; a 304 for it means nothing changed. Returns @{ Rc; Releases; Etag }:
# Rc 0 ok, 1 skip this item, 2 GitHub is rate limiting, 3 unchanged.
function Get-GithubReleases($it, [string]$ApiUrl, [string]$Etag = '') {
    if ($script:GH.Cache.ContainsKey($ApiUrl)) {
        Debug-Line "GitHub $($ApiUrl -replace '^https://api.github.com/', ''): from this run's cache"
        return @{ Rc = 0; Releases = $script:GH.Cache[$ApiUrl]; Etag = $script:GH.Etags[$ApiUrl] }
    }
    if ($script:GH.RateLimited) {
        Say "⚠ $($script:Label): GitHub rate limit reached earlier this run, skipping"
        return @{ Rc = 2 }
    }
    # the same Accept as curl, so both versions get the same ETag for a list
    $headers = @{ Accept = '*/*' }
    if ($Etag) { $headers['If-None-Match'] = $Etag }
    $r = Invoke-Http $ApiUrl -Headers $headers -Token
    $h = $r.Headers
    if ($h.ContainsKey('x-ratelimit-limit')) { $script:GH.Limit = $h['x-ratelimit-limit'] }
    if ($h.ContainsKey('x-ratelimit-remaining')) { $script:GH.Remaining = $h['x-ratelimit-remaining'] }
    if ($h.ContainsKey('x-ratelimit-reset')) { $script:GH.Reset = $h['x-ratelimit-reset'] }
    $sent = if ($Etag) { ' (sent ETag)' } else { '' }
    Debug-Line "GitHub $($ApiUrl -replace '^https://api.github.com/', '')$sent → HTTP $($r.Code), $(if ($script:GH.Remaining) { $script:GH.Remaining } else { '?' }) requests left"
    if ($r.Hops -gt 0) { Debug-Line "repo $($it.repo) has moved (redirected to $($r.Url)); consider updating repo= in the cfg" }
    # a 304 doesn't count against the limit when the request carries a token
    if ($r.Code -eq 304 -and $script:GithubToken) { $script:GH.Free++ } else { $script:GH.Calls++ }

    switch ($r.Code) {
        200 {
            # assigned first: Windows PowerShell 5.1 doesn't unroll a JSON array
            try { $parsed = ConvertFrom-Json $r.Body; $releases = @($parsed) } catch { $releases = @() }
            $etagNow = if ($h.ContainsKey('etag')) { $h['etag'] } else { '' }
            $next = ''
            if ($h.ContainsKey('link') -and $h['link'] -match '<([^>]*)>; rel="next"') { $next = $Matches[1] }
            $script:GH.Cache[$ApiUrl] = $releases
            $script:GH.Etags[$ApiUrl] = $etagNow
            $script:GH.Next[$ApiUrl] = $next
            return @{ Rc = 0; Releases = $releases; Etag = $etagNow }
        }
        304 { return @{ Rc = 3; Etag = $Etag } }
        { $_ -in 403, 429 } {
            if ($r.Code -eq 429 -or $r.Body -match '(?i)rate limit') {
                $script:GH.RateLimited = $true
                $when = ''
                if ($script:GH.Reset -match '^\d+$') {
                    $when = ' (resets {0:HH:mm})' -f [DateTimeOffset]::FromUnixTimeSeconds([long]$script:GH.Reset).LocalDateTime
                }
                Say "✗ $($script:Label): GitHub rate limit reached$when"
                return @{ Rc = 2 }
            }
            Say "⚠ $($script:Label): GitHub request failed (HTTP 403), skipping"
        }
        404 { Say "⚠ $($script:Label): GitHub repo $($it.repo) not found (HTTP 404), skipping" }
        0 { Say "⚠ $($script:Label): no response from GitHub, skipping" }
        default { Say "⚠ $($script:Label): GitHub request failed (HTTP $($r.Code)), skipping" }
    }
    @{ Rc = 1 }
}

# The last line of a run: the GitHub request budget, when GitHub was asked.
function Get-RateSummary {
    if ($script:GH.Calls + $script:GH.Free -eq 0) { return '' }
    if ($script:GH.Limit -notmatch '^\d+$' -or $script:GH.Remaining -notmatch '^\d+$') { return '' }
    $warn = if ([int]$script:GH.Remaining * 10 -le [int]$script:GH.Limit) { '⚠ ' } else { '' }
    $when = ''
    if ($script:GH.Reset -match '^\d+$') {
        $when = ', resets {0:HH:mm}' -f [DateTimeOffset]::FromUnixTimeSeconds([long]$script:GH.Reset).LocalDateTime
    }
    "${warn}GitHub API: $($script:GH.Remaining)/$($script:GH.Limit) requests left$when (used $($script:GH.Calls) this run)"
}

# ---------------------------------------------------------------------------
# GitLab
# ---------------------------------------------------------------------------
$script:GitlabRateLimited = $false

# The release list of GitLab project $Project (group/name). $null skips the
# item. A 429 skips GitLab items only; other managers still work.
function Get-GitlabReleases([string]$Project) {
    if ($script:GitlabRateLimited) {
        Say "⚠ $($script:Label): GitLab rate limit reached earlier this run, skipping"
        return $null
    }
    $r = Invoke-Http ("https://gitlab.com/api/v4/projects/" + [Uri]::EscapeDataString($Project) + "/releases")
    Debug-Line "GitLab $Project → HTTP $($r.Code)"
    switch ($r.Code) {
        200 { try { $parsed = ConvertFrom-Json $r.Body; return , @($parsed) } catch { Say "⚠ $($script:Label): GitLab sent something that isn't JSON, skipping"; return $null } }
        429 { $script:GitlabRateLimited = $true; Say "✗ $($script:Label): GitLab rate limit reached, skipping" }
        404 { Say "⚠ $($script:Label): GitLab project $Project not found (HTTP 404), skipping" }
        0 { Say "⚠ $($script:Label): no response from GitLab, skipping" }
        default { Say "⚠ $($script:Label): GitLab request failed (HTTP $($r.Code)), skipping" }
    }
    $null
}
