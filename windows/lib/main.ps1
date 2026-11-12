# main.ps1: each mode's settings, the one Invoke-UpdateItem every mode shares, and
# the mode runner. The hooks where the modes differ are functions named
# TYPE_HOOK in apworlds.ps1 and isos.ps1; a missing one does nothing.
# Loaded by update-tools.ps1.

# Each mode's settings: its title, cfg extension, key in the settings file, and
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
    $script:Outcome = 'current'
}

# The mode's summary, after its last item: what went well in one line, then the
# items that need a look, by name, so a long run's failures can't hide in the
# scrollback. $T holds the tallies from Invoke-Mode.
function Write-Summary($T) {
    $parts = @()
    if ($T.updated)   { $parts += "$($T.updated) updated" }
    if ($T.installed) { $parts += "$($T.installed) installed" }
    if ($T.current)   { $parts += "$($T.current) up to date" }
    if ($T.recent)    { $parts += "$($T.recent) checked recently" }
    if ($parts.Count) { Say "✓ $($parts -join ', ')" }
    if ($T.available.Count) {
        $word = if ($T.available.Count -eq 1) { 'update' } else { 'updates' }
        Say "⬆ $($T.available.Count) $word available: $($T.available -join ', ')"
    }
    if ($T.problems.Count) { Say "⚠ $($T.problems.Count) skipped or failed: $($T.problems -join ', ')" }
    if ($T.unchecked) { Say "⚠ $($T.unchecked) not checked (GitHub rate limit)" }
}

# One cfg: check it, and update it if needed. The same steps for every mode,
# with the mode's hooks where they differ. Returns 2 to stop the whole run.
function Invoke-UpdateItem([string]$CfgFile, [int]$Index, [int]$Count) {
    $name = [IO.Path]::GetFileName($CfgFile)
    $name = $name.Substring(0, $name.Length - '.json'.Length)
    $script:Label = $name
    $script:Done = $Index
    Status ''

    $it = Read-Item $CfgFile
    if ($null -eq $it) { return 0 }
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
        $script:Outcome = 'recent'
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
        $script:Outcome = 'available'
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
    # installed_path is still the old file's, empty on a first install
    $script:Outcome = if ($it.installed_path) { 'updated' } else { 'installed' }
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
    # the scripts' own folder in the item folder (dot-prefixed: Archipelago
    # skips it in custom_worlds): db holds the cfgs, tmp the staged downloads
    # and old versions during an install, on the items' own disk
    $script:Root = $script:Dir
    $cfgDir = Join-Path (Join-Path $script:Dir '.update-tools') 'db'
    $script:TmpDir = Join-Path (Join-Path $script:Dir '.update-tools') 'tmp'
    [void](New-Item -ItemType Directory -Force -Path $cfgDir)
    $script:Staged = ''
    [void](Invoke-Hook 'PrepareDir' $null)

    # -Filter would also match *.jsonX on Windows
    $cfgs = @(Get-ChildItem -LiteralPath $cfgDir -File | Where-Object { $_.Name -like '*.json' } | Sort-Object Name | ForEach-Object { $_.FullName })
    # the layout from before 2026-11-07 isn't read any more
    $oldDir = Join-Path $script:Dir '.cfg'
    if (Test-Path -LiteralPath $oldDir -PathType Container) { Say "⚠ $oldDir is ignored: cfgs are NAME.json in .update-tools/db now" }
    if ($cfgs.Count -eq 0) {
        Say "⚠ no *.json files in $cfgDir, nothing to do"
        return $true
    }
    Start-Progress $s.Title $cfgs.Count
    $total = [Diagnostics.Stopwatch]::StartNew()
    try {
        # each item's $script:Outcome (set when it ends well) is tallied for the
        # summary; one that ends without it has said why it was skipped or failed
        $tally = @{ updated = 0; installed = 0; current = 0; recent = 0; unchecked = 0
                    available = [Collections.Generic.List[string]]::new()
                    problems = [Collections.Generic.List[string]]::new() }
        for ($i = 0; $i -lt $cfgs.Count; $i++) {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $script:Outcome = ''
            $rc = Invoke-UpdateItem $cfgs[$i] $i $cfgs.Count
            if ($script:DebugOn) { Say ("  · $($script:Label): took {0:N2}s" -f $watch.Elapsed.TotalSeconds) }
            # a GitHub rate limit: this item wasn't checked either
            if ($rc -eq 2) { $tally.unchecked = $cfgs.Count - $i; break }
            switch ($script:Outcome) {
                'available' { $tally.available.Add($script:Label) }
                ''          { $tally.problems.Add($script:Label) }
                default     { $tally[$script:Outcome]++ }
            }
        }
        Write-Summary $tally
    } finally {
        # Ctrl+C included: no half-downloaded file stays, and an old version
        # set aside goes back unless the new one got in
        Remove-IfThere $script:Staged
        if ($script:TmpDir) { Remove-IfThere (Join-Path $script:TmpDir 'extracted.apworld') }
        Complete-Previous
        # ISOs need tmp only during an update
        if ($Type -eq 'iso') { Remove-EmptyTree $script:TmpDir }
        $script:Done = $cfgs.Count
        if ($script:DebugOn) { Say ("  · total: took {0:N2}s" -f $total.Elapsed.TotalSeconds) }
        Stop-Progress
    }
    $true
}
