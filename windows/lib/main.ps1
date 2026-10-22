# main.ps1: each mode's settings, the one Invoke-Item every mode shares, and
# the mode runner. The hooks where the modes differ are functions named
# TYPE_HOOK in apworlds.ps1 and isos.ps1; a missing one does nothing.
# Loaded by update-tools.ps1.

# Each mode's settings: its title, cfg extension, key in the paths file, and
# the hints for a missing folder.
function Get-ModeSettings([string]$Type) {
    switch ($Type) {
        'apw' { @{ Title = 'Archipelago worlds'; Ext = 'apworld'; DirKey = 'apw_dir'
                   NotFoundHint = 'Is the games drive mounted?'; RootHint = 'Point to the folder with -Root DIR.' } }
        'iso' { @{ Title = 'ISOs'; Ext = 'iso'; DirKey = 'iso_dir'
                   NotFoundHint = 'Is the Ventoy drive mounted?'; RootHint = 'Point to it with -Root DIR.' } }
    }
}

# Runs hook $Hook of the current mode with the item; $true if there is none.
function Invoke-Hook([string]$Hook, $it) {
    $cmd = Get-Command "$($script:Type)_$Hook" -CommandType Function -ErrorAction SilentlyContinue
    if (-not $cmd) { return $true }
    $r = & $cmd $it
    $r -ne $false
}

function Report-UpToDate($it) {
    if (-not $script:CheckOnly) { Save-UpdateMetadata $it }
    $shown = if ($it.latest_tag) { $it.latest_tag } else { $it.installed_file }
    Status-Final "✓ up to date ($shown)"
}

# One cfg: check it, and update it if needed. The same steps for every mode,
# with the mode's hooks where they differ. Returns 2 to stop the whole run.
function Invoke-Item([string]$CfgFile, [int]$Index, [int]$Count) {
    $name = [IO.Path]::GetFileName($CfgFile)
    $name = $name.Substring(0, $name.Length - ".$($script:Ext).cfg".Length)
    $script:Label = $name
    $script:Done = $Index
    Status ''

    $it = Read-Cfg $CfgFile
    $it.name = $name; $it.cfg_file = $CfgFile; $it.dir = $script:Dir
    Debug-Line "cfg: manager=$(if ($it.manager) { $it.manager } else { '?' }) version=$(if ($it.current_version) { $it.current_version } else { 'none' }) installed_file=$(if ($it.installed_file) { $it.installed_file } else { 'none' }) last_checked=$(if ($it.last_checked) { $it.last_checked } else { 'never' })"
    if (-not (Invoke-Hook 'Setup' $it)) { return 0 }

    $it.installed_path = Find-Installed $it $it.dir
    if ($it.installed_path) { Debug-Line "installed file: $(Split-Path -Leaf $it.installed_path)" }
    else { Debug-Line 'not installed yet: installing it' }

    # skip_checked and skip_hours in the settings file: once per 24 hours by default
    if (-not $script:ForceAll -and $it.installed_path -and (Test-CheckedRecently $it)) {
        $shown = if ($it.current_version) { $it.current_version } else { $it.installed_file }
        Status-Final "✓ already checked $($it.checked_ago) ago ($shown)"
        return 0
    }

    # a 304 has no download URL, so ask for the full list when installing;
    # -Force always does (a static item's etag is the file's ETag, still needed)
    if ($it.manager -eq 'github' -and ($script:ForceAll -or -not $it.installed_path)) {
        $it.etag = ''
        Debug-Line $(if ($it.installed_path) { 'full release list requested (-Force)' } else { 'full release list requested (not installed yet)' })
    }
    $rc = Resolve-LatestAsset $it
    if ($rc -eq 2) {
        # every further GitHub request would fail the same way
        Say "  ✗ stopping, $($Count - $Index - 1) more $($script:Ext)(s) not checked"
        return 2
    }
    if ($rc) { return 0 }

    # nothing newer on the server, but the installed file is gone
    if ($it.remote_unchanged -and -not $it.installed_path) {
        $what = if ($it.installed_file) { $it.installed_file } else { 'its file' }
        Say "⚠ $($name): $what is missing and the server has nothing newer, skipping"
        return 0
    }
    # nothing newer (an old ISO's checksum file may be gone with it)
    if ($it.remote_unchanged) { Report-UpToDate $it; return 0 }
    if (-not (Invoke-Hook 'PrepareCheck' $it)) { return 0 }
    if ($it.installed_path -and (Test-UpToDate $it $it.installed_path)) { Report-UpToDate $it; return 0 }

    # -Check: report it, download and write nothing
    if ($script:CheckOnly) {
        Status-Final "⬆ update available: $(Get-ShownVersion $it $it.asset_name)"
        return 0
    }

    if (-not (Invoke-Hook 'Preflight' $it)) { return 0 }
    Status $(if ($it.installed_path) { '⬆ updating' } else { '⬇ installing' })

    $it.tmp_download = ''
    [void](Invoke-Hook 'Stage' $it)
    $script:Staged = $it.tmp_download
    if (-not (Save-Download $it.asset_url $it.tmp_download)) {
        Say "  ✗ Failed to download update for $name"
        Remove-IfThere $it.tmp_download
        return 0
    }
    Debug-Line "downloaded to $($it.tmp_download)"

    if (-not (Invoke-Hook 'Validate' $it)) {
        Remove-IfThere $it.tmp_download
        $script:Staged = ''
        return 0
    }
    $script:Staged = $it.tmp_download

    $newName = Select-InstallName $it $it.asset_name
    $target = Join-Path $it.dir $newName

    # the installed version (and a stray file already using the new name)
    # waits in .tmp until the new one is in place
    if (-not (Set-Aside @($it.installed_path, $target))) {
        Say "  ✗ $($name): could not move the old version aside, nothing changed"
        Remove-IfThere $it.tmp_download
        return 0
    }

    # a rename on one disk; should it still fail, put the old version back
    Start-Install $target
    if (-not (Move-File $it.tmp_download $target)) {
        Restore-Previous
        Say "  ✗ $($name): could not install $newName, kept the old one"
        Remove-IfThere $it.tmp_download
        return 0
    }
    $script:Staged = ''
    Debug-Line "installed as $newName"
    Remove-Previous

    [void](Invoke-Hook 'Extras' $it)

    $it.installed_file = $newName
    Save-UpdateMetadata $it
    Status-Final "✓ updated to $(Get-ShownVersion $it $it.installed_file)"
    0
}

# One mode: its folder, its cfgs, each item in turn. Returns $false when the
# mode can't run (no folder set, or the folder is missing).
function Invoke-Mode([string]$Type, [string]$Root, [bool]$All) {
    $s = Get-ModeSettings $Type
    $script:Type = $Type; $script:Ext = $s.Ext
    $rootHint = if ($All) { '' } else { " $($s.RootHint)" }
    $dir = if ($Root) { $Root } else { (Get-Settings)[$s.DirKey] }
    if (-not $dir) {
        Write-Err "ERROR: no folder set for $($s.Title): add $($s.DirKey)=DIR to $(Format-Path $script:SettingsFile).$rootHint"
        return $false
    }
    $dir = $dir.TrimEnd('/', '\')
    # a bare "E:" is the current folder on E:, not the drive's root
    if ($dir -match '^[A-Za-z]:$') { $dir += '\' }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        $hint = if ($s.NotFoundHint) { " $($s.NotFoundHint)" } else { '' }
        Write-Err "ERROR: $dir not found.$hint$rootHint"
        return $false
    }
    $script:Dir = (Resolve-Path -LiteralPath $dir).ProviderPath
    $cfgDir = Join-Path $script:Dir '.cfg'
    [void](New-Item -ItemType Directory -Force -Path $cfgDir)
    $script:Staged = ''
    [void](Invoke-Hook 'PrepareDir' $null)

    $cfgs = @(Get-ChildItem -LiteralPath $cfgDir -File -Filter "*.$($s.Ext).cfg" | Sort-Object Name | ForEach-Object { $_.FullName })
    if ($cfgs.Count -eq 0) {
        Say "⚠ no *.$($s.Ext).cfg files in $cfgDir, nothing to do"
        return $true
    }
    Start-Progress $s.Title $cfgs.Count
    $total = [Diagnostics.Stopwatch]::StartNew()
    try {
        for ($i = 0; $i -lt $cfgs.Count; $i++) {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $rc = Invoke-Item $cfgs[$i] $i $cfgs.Count
            if ($script:DebugOn) { Say ("  · $($script:Label): took {0:N2}s" -f $watch.Elapsed.TotalSeconds) }
            if ($rc -eq 2) { break }
        }
    } finally {
        # Ctrl+C included: no half-downloaded file stays, and an old version
        # set aside goes back unless the new one got in
        Remove-IfThere $script:Staged
        if ($script:TmpDir) { Remove-IfThere (Join-Path $script:TmpDir 'extracted.apworld') }
        Complete-Previous
        $script:Done = $cfgs.Count
        if ($script:DebugOn) { Say ("  · total: took {0:N2}s" -f $total.Elapsed.TotalSeconds) }
        Stop-Progress
    }
    $true
}
