<#
make-update-cfg.ps1: writes a new world's or ISO's cfg from a link, for
update-tools.ps1 to install on its next run. The PowerShell port of the bash
make-update-cfg. Run without arguments for the help.
#>
# positional in this order; no [Parameter()] attributes, which would make it an
# advanced script and claim -Debug for PowerShell's own use
param(
    [string]$Type,
    [string]$Link,
    [string]$Name,
    [Alias('r')][string]$Root,
    [Alias('d')][switch]$Debug,
    [Alias('h')][switch]$Help
)
Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

foreach ($lib in 'output', 'cfg', 'net', 'managers', 'files', 'isos', 'main') {
    . (Join-Path (Join-Path $PSScriptRoot 'lib') "$lib.ps1")
}

function Show-Usage([switch]$ToError) {
    $text = @"
Usage: make-update-cfg.ps1 [OPTIONS] TYPE LINK [NAME]
Write a cfg for a new Archipelago world or ISO, read from LINK. The next
update-tools.ps1 run installs it.

TYPE: apw (apworlds) or iso (isos).
LINK: a GitHub or GitLab project, or one of its release assets (to choose
      between several); any other URL is a fixed download (static).
NAME: the cfg's name (default: from the repo or the file name).

Options:
  -r, -Root DIR     the item folder (default: the mode's, as in update-tools.ps1)
  -d, -Debug        explain each decision
  -h, -Help         show this help
"@
    if ($ToError) { Write-Err $text } else { Say $text }
}

function Stop-WithError([string]$Text) {
    Write-Err "make-update-cfg.ps1: $Text"
    exit 1
}

# A cfg name from a file or repo name: no extension, arch or version,
# lowercase, and _ for anything but letters, digits, - and _.
function Get-CleanName([string]$N) {
    $N = $N -creplace '\.(AppImage|appimage|apworld|iso|zip|tar\..*)$', ''
    $N = $N -replace '[-_.](x86[-_]64|amd64|x64)', ''
    $N = $N -replace '[-_]v?[0-9].*$', ''
    $N.ToLower() -replace '[^a-z0-9_-]', '_'
}

# Asset names the type can install: its own file first, else an archive.
function Get-AssetPatterns {
    if ($script:Type -eq 'apw') { @('\.apworld$', '\.zip$') } else { @('\.iso$') }
}

# The asset names of a release, GitHub's or GitLab's.
function Get-ReleaseNames($Release) {
    if ($script:Kind -eq 'github') { @($Release.assets | ForEach-Object { [string]$_.name }) }
    else { @($Release.assets.links | ForEach-Object { [string]$_.name }) }
}

# @{ Tag; Names } for the newest release with an asset matching $Pattern
# (any case): stable first, like allow_prereleases=auto. $null if none has one.
function Find-ReleaseAssets($Releases, [string]$Pattern) {
    $first = $null
    foreach ($r in $Releases) {
        if ($r.draft) { continue }
        $names = @(Get-ReleaseNames $r | Where-Object { $_ -match $Pattern })
        if (-not $names.Count) { continue }
        $hit = @{ Tag = [string]$r.tag_name; Names = $names }
        if (-not $r.prerelease) { return $hit }
        if (-not $first) { $first = $hit }
    }
    $first
}

# Sets $script:Tag and $script:Asset from the release list: the asset LINK
# names (or $Wanted), else the only candidate. Several candidates without a
# choice end the script with the list.
function Select-Asset($Releases, [string]$Wanted) {
    $found = $null
    foreach ($pat in Get-AssetPatterns) {
        $found = Find-ReleaseAssets $Releases $pat
        if ($found) { break }
    }
    if (-not $found) { Stop-WithError "no release has a .$($script:Ext) asset (or an archive) to install" }
    $script:Tag = $found.Tag
    $names = $found.Names
    Debug-Line "release $($script:Tag) has $($names.Count) candidate(s): $($names -join ' ')"
    if (-not $Wanted) { $w = $script:Link -replace '\?.*$', ''; $Wanted = $w.Substring($w.LastIndexOf('/') + 1) }
    if ($names -ccontains $Wanted) { Debug-Line "the link names $Wanted"; $script:Asset = $Wanted; return }
    # builds for other systems or architectures can't run here (on Windows:
    # Linux, Mac and ARM; the bash version drops Windows builds instead)
    $keep = @($names | Where-Object { $_.ToLower() -notmatch '(aarch64|arm64|armhf|armv7|(^|[-_.])(linux|mac(os)?|osx|darwin)([-_.]|$))' })
    if (-not $keep.Count) {
        Write-Err "make-update-cfg.ps1: release $($script:Tag) has only builds for other systems:"
        $names | ForEach-Object { Write-Err "  $_" }
        exit 1
    }
    if ($keep.Count -gt 1) {
        Write-Err "make-update-cfg.ps1: release $($script:Tag) has several assets; pass the link of the one you want:"
        $keep | ForEach-Object { Write-Err "  $_" }
        exit 1
    }
    $script:Asset = $keep[0]
}

# Sets repo_filename to the asset's name with its version (the tag, with or
# without its v) replaced by *, so the next release still matches. When that
# glob also matches another asset of the release (Obsidian-*.AppImage takes
# Obsidian-1.14.4-arm64.AppImage too), sets repo_regex instead, with a version
# that can't hold a "-".
function Set-AssetPattern($it, $Releases) {
    $release = @($Releases | Where-Object { [string]$_.tag_name -eq $script:Tag })[0]
    $names = @(Get-ReleaseNames $release)
    $ver = ''
    foreach ($t in @($script:Tag, ($script:Tag -replace '^[vV]', ''))) {
        if ($t -match '[0-9]' -and $script:Asset.Contains($t)) { $ver = $t; break }
    }
    if (-not $ver) { $it.repo_filename = $script:Asset; return }
    $it.repo_filename = $script:Asset.Replace($ver, '*')
    $glob = ConvertTo-GlobRegex $it.repo_filename
    if (@($names | Where-Object { [regex]::IsMatch($_, $glob) }).Count -le 1) { return }
    Debug-Line "$($it.repo_filename) also matches other assets; using a regex"
    $prefix = $ver -replace '[0-9].*$', ''
    $re = (Get-RegexEscaped $script:Asset).Replace((Get-RegexEscaped $ver), (Get-RegexEscaped $prefix) + '[0-9][0-9A-Za-z.+~]*')
    if (@($names | Where-Object { [regex]::IsMatch($_, "^($re)`$") }).Count -eq 1) {
        $it.repo_filename = ''; $it.repo_regex = $re
    }
}

# A string as a regex that matches it literally; the same characters the bash
# version escapes, so both write the same repo_regex.
function Get-RegexEscaped([string]$Text) {
    $sb = [Text.StringBuilder]::new()
    foreach ($ch in $Text.ToCharArray()) {
        if ('.^$*+?()[]{}|\'.IndexOf($ch) -ge 0) { [void]$sb.Append('\') }
        [void]$sb.Append($ch)
    }
    $sb.ToString()
}

function From-Github($it) {
    $path = $script:Link.Substring($script:Link.IndexOf('github.com/') + 'github.com/'.Length)
    $owner, $project = $path.Split('/') | Select-Object -First 2
    if (-not $owner -or -not $project) { Stop-WithError "no owner/repo in $($script:Link)" }
    $it.repo = "$owner/$($project -replace '\.git$', '')"
    $script:Label = $it.repo
    # the same URL Resolve-LatestAsset asks for, so its check comes from the cache
    $r = Get-GithubReleases $it "https://api.github.com/repos/$($it.repo)/releases?per_page=100"
    if ($r.Rc) { exit 1 }
    $script:Kind = 'github'
    Select-Asset $r.Releases ''
    $it.manager = 'github'
    Set-AssetPattern $it $r.Releases
    $script:DefaultName = Get-CleanName ($it.repo.Split('/')[1])
}

function From-Gitlab($it) {
    $project = $script:Link.Substring($script:Link.IndexOf('gitlab.com/') + 'gitlab.com/'.Length)
    $project = ($project -replace '/-/.*$', '').TrimEnd('/') -replace '\.git$', ''
    $script:Label = $project
    $releases = Get-GitlabReleases $project
    if ($null -eq $releases) { exit 1 }
    $script:Kind = 'gitlab'
    # an asset's link ends in /download, so find its name in the list
    $wanted = ''
    foreach ($rel in $releases) {
        foreach ($l in @($rel.assets.links)) {
            if ($l -and ($l.url -eq $script:Link -or $l.direct_asset_url -eq $script:Link)) { $wanted = [string]$l.name; break }
        }
        if ($wanted) { break }
    }
    Select-Asset $releases $wanted
    $it.manager = 'gitlab'; $it.repo_url = "https://gitlab.com/$project"
    Set-AssetPattern $it $releases
    $script:DefaultName = Get-CleanName ($project.Substring($project.LastIndexOf('/') + 1))
}

function From-Static($it) {
    $given = $script:Link -replace '\?.*$', ''
    $given = $given.Substring($given.LastIndexOf('/') + 1)
    $script:Label = $given
    if (-not (Invoke-StaticHead $it $script:Link)) { exit 1 }
    Debug-Line "the link lands on $($it.asset_name)"
    if ($it.asset_name -notmatch ((Get-AssetPatterns) -join '|')) {
        Say "⚠ $($it.asset_name) doesn't look like a .$($script:Ext) file; check that the link is the download itself"
    }
    # a version in the link itself means it never points at a newer release
    if ($given -match '[0-9]+\.[0-9]+|[0-9]{6,}') {
        Say "⚠ $given names one release: a static cfg only sees that file change. For newer releases, use a link without the version, or manager=dirlist with * in place of it"
    }
    $it.manager = 'static'; $it.url = $script:Link
    $script:DefaultName = Get-CleanName $it.asset_name
}

# Sets checksum to the first checksum file next to the ISO that lists it, tried
# through the ISO lookup itself. Empty when none does. The link's own name
# covers a redirect (Garuda: latest.iso.sha256); the glob, which needs a server
# listing, goes last (Fedora's Fedora-KDE-…-CHECKSUM).
function Find-ChecksumFile($it) {
    $given = ([string]$it.url) -replace '\?.*$', ''
    $given = $given.Substring($given.LastIndexOf('/') + 1)
    $cands = @('{iso}.sha256', '{iso}.sha256sum', '{iso}.sha512', '{iso}.sha512sum', '{iso}-CHECKSUM', '{iso}.CHECKSUM')
    if ($given) { $cands += "$given.sha256" }
    $cands += @('SHA256SUMS', 'SHA256SUMS.txt', 'SHA512SUMS', 'sha256sums.txt', 'sha512sums.txt', 'sha256sum.txt', 'CHECKSUM', 'CHECKSUMS', 'CHECKSUMS.txt', '*CHECKSUM*')
    foreach ($c in $cands) {
        $it.checksum = $c
        $script:Quiet = $true
        $ok = iso_PrepareCheck $it
        $script:Quiet = $false
        if ($ok) { Debug-Line "checksum file: $($it.sum_url)"; return }
    }
    $it.checksum = ''
}

# --------------------------------------------------------------------------
if ($Help -or (-not $Type -and -not $Link)) { Show-Usage; exit 0 }
if (-not $Type -or -not $Link) { Write-Err 'make-update-cfg.ps1: need TYPE and LINK'; Show-Usage -ToError; exit 2 }
$script:Type = switch ($Type) {
    { $_ -in 'apw', 'apworlds' } { 'apw' }
    { $_ -in 'iso', 'isos' } { 'iso' }
    default { Write-Err "make-update-cfg.ps1: TYPE is apw or iso (got '$Type')"; Show-Usage -ToError; exit 2 }
}
$script:DebugOn = [bool]$Debug -or ($env:DEBUG -and $env:DEBUG -ne '0')
$script:Link = if ($Link -match '://') { $Link } else { "https://$Link" }
$script:Now = Get-Date
$script:CheckedAt = $script:Now.ToString("yyyy-MM-dd'T'HH:mm")
$s = Get-ModeSettings $script:Type
$script:Ext = $s.Ext

$dir = if ($Root) { $Root } else { (Get-Settings)[$s.DirKey] }
if (-not $dir) { Stop-WithError "no folder set for $($s.Title): add $($s.DirKey)=DIR to $(Format-Path $script:SettingsFile), or use -Root DIR" }
$dir = $dir.TrimEnd('/', '\')
if ($dir -match '^[A-Za-z]:$') { $dir += '\' }
if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Stop-WithError "$dir not found. $($s.NotFoundHint)" }
$script:Dir = (Resolve-Path -LiteralPath $dir).ProviderPath
$script:IsoDir = $script:Dir
$cfgDir = Join-Path $script:Dir '.cfg'

$it = @{}
$script:Tag = ''; $script:Asset = ''; $script:DefaultName = ''
if ($script:Link -match '^[a-z]+://(www\.)?github\.com/') { From-Github $it }
elseif ($script:Link -match '^[a-z]+://gitlab\.com/') { From-Gitlab $it }
else { From-Static $it }

$cfgName = if ($Name) { $Name } else { $script:DefaultName }
if (-not $cfgName -or $cfgName -match '[/\\]') { Stop-WithError "can't make a cfg name from the link; pass NAME" }
$cfg = Join-Path $cfgDir "$cfgName.$($s.Ext).cfg"
if (Test-Path -LiteralPath $cfg) { Stop-WithError "$(Format-Path $cfg) already exists" }
$script:Label = $cfgName
$it.name = $cfgName

# what update-tools.ps1 will find, with the cfg as written
if ((Resolve-LatestAsset $it) -ne 0) { exit 1 }
Debug-Line "resolves to $($it.latest_tag): $($it.asset_name)"
if ($script:Asset -and $it.asset_name -ne $script:Asset) {
    Stop-WithError "the cfg would find $($it.asset_name), not $($script:Asset); nothing written"
}

$pairs = [ordered]@{}
if ($script:Type -eq 'iso') {
    Find-ChecksumFile $it
    if (-not $it.checksum) { Say "⚠ $($cfgName): no checksum file found next to the ISO; add checksum= by hand (required)" }
    $pairs.folder = $cfgName
}
$pairs.manager = $it.manager
switch ($it.manager) {
    'github' { $pairs.repo = $it.repo }
    'gitlab' { $pairs.repo_url = $it.repo_url }
    'static' { $pairs.url = $it.url }
}
if ($it.repo_filename) { $pairs.repo_filename = $it.repo_filename }
if ($it.repo_regex) { $pairs.repo_regex = $it.repo_regex }
if ($it.checksum) { $pairs.checksum = $it.checksum }

# several worlds may share a repo, so this is only a warning
$what = if ($it.url) { 'URL' } else { 'repo' }
$lines = @(); if ($it.repo) { $lines += "repo=$($it.repo)" }; if ($it.repo_url) { $lines += "repo_url=$($it.repo_url)" }; if ($it.url) { $lines += "url=$($it.url)" }
if (Test-Path -LiteralPath $cfgDir) {
    foreach ($other in Get-ChildItem -LiteralPath $cfgDir -File -Filter "*.$($s.Ext).cfg") {
        $content = [IO.File]::ReadAllLines($other.FullName) | ForEach-Object { $_.TrimEnd("`r") }
        if ($lines | Where-Object { $content -ccontains $_ }) { Say "⚠ $($cfgName): $($other.Name) already uses this $what" }
    }
}

[void](New-Item -ItemType Directory -Force -Path $cfgDir)
[IO.File]::WriteAllText($cfg, "# $($script:Link)`n", [Text.UTF8Encoding]::new($false))
Write-CfgValues $cfg $pairs
$tagShown = if ($script:Tag) { "$($script:Tag): " } else { '' }
Say "✓ wrote $(Format-Path $cfg) ($tagShown$($it.asset_name)):"
[IO.File]::ReadAllLines($cfg) | ForEach-Object { Say "    $_" }
if ($script:Type -eq 'iso') { Say "  folder=$cfgName is a guess: set it to the ISO's folder under $(Format-Path $script:Dir)" }
Say "  update-tools.ps1 -m $($script:Type) -c shows the install; a run without -c does it"
exit 0
