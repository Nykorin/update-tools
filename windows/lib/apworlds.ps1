# apworlds.ps1: the Archipelago world hooks. A world is a zip; a release zip
# that bundles an .apworld with a mod's own files gives up just the .apworld.
# Loaded by update-tools.ps1; used in -Mode apw.

Add-Type -AssemblyName System.IO.Compression.FileSystem

# The zip's entry names, or $null if it isn't a zip.
function Get-ZipListing([string]$Path) {
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)
        try { , @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }
    } catch { $null }
}

# Writes zip member $Member to file $Dest; $false if it can't, or comes out empty.
function Export-ZipMember([string]$Zip, [string]$Member, [string]$Dest) {
    try {
        $z = [IO.Compression.ZipFile]::OpenRead($Zip)
        try {
            $entry = $z.GetEntry($Member)
            if (-not $entry) { return $false }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $Dest, $true)
        } finally { $z.Dispose() }
        (Get-Item -LiteralPath $Dest).Length -gt 0
    } catch { $false }
}

function apw_PrepareDir {
    $script:TmpDir = Join-Path $script:Dir '.tmp'
    [void](New-Item -ItemType Directory -Force -Path $script:TmpDir)
    # left over from an interrupted earlier run: an old version goes back first
    Restore-Interrupted
    Get-ChildItem -LiteralPath $script:TmpDir -Force -File | Where-Object { $_.Name -like 'download.*' -or $_.Name -like 'extracted.*' } |
        ForEach-Object { Remove-IfThere $_.FullName }
}

function apw_Stage($it) {
    $it.tmp_download = Join-Path $script:TmpDir 'download.zip'
}

# A world must be a zip; a bundle's .apworld is extracted and used instead. The
# name stays the upstream one: Archipelago reports a world whose name doesn't
# match its module.
function apw_Validate($it) {
    $listing = Get-ZipListing $it.tmp_download
    if ($null -eq $listing) {
        Say "  ✗ $($it.name): download is not a valid .apworld (zip)"
        return $false
    }
    if (-not ($listing | Where-Object { $_ -match '(?i)\.apworld$' })) { return $true }
    # a world's module folder may ship .apworld files of its own (diceydungeons)
    if ($listing | Where-Object { $_ -match '^[^/]*/__init__\.py$' }) {
        Debug-Line 'plain world (top-level __init__.py), not a bundle'
        return $true
    }
    $pattern = if ($it.apworld_filename) { $it.apworld_filename } else { '*.apworld' }
    $found = @($listing | Where-Object { -not $_.EndsWith('/') -and ($_.Substring($_.LastIndexOf('/') + 1) -like $pattern) })
    if ($found.Count -eq 0) {
        Say "  ✗ $($it.name): no .apworld matching '$pattern' inside the release zip"
        return $false
    }
    if ($found.Count -gt 1) {
        $list = ($found | ForEach-Object { "`n      " + $_.Substring($_.LastIndexOf('/') + 1) }) -join ''
        Say "  ✗ $($it.name): release zip holds several .apworld files, set apworld_filename:$list"
        return $false
    }
    $member = $found[0]
    $extracted = Join-Path $script:TmpDir 'extracted.apworld'
    if (-not (Export-ZipMember $it.tmp_download $member $extracted)) {
        Say "  ✗ $($it.name): could not extract $member"
        Remove-IfThere $extracted
        return $false
    }
    Remove-IfThere $it.tmp_download
    $it.tmp_download = $extracted
    # .apworld files are themselves zips
    if ($null -eq (Get-ZipListing $extracted)) {
        Say "  ✗ $($it.name): extracted file is not a valid .apworld"
        return $false
    }
    $it.asset_name = $member.Substring($member.LastIndexOf('/') + 1)
    Debug-Line "bundle member: $member"
    Status "📦 extracted $($it.asset_name)"
    $true
}
