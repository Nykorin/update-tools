# menu.ps1: update-tools.ps1's menu, shown without -m on a console when fzf is
# installed, as in the bash version (lib/menu.sh). Step 1 picks the kinds;
# step 2, for each kind, either checks all its items or picks single ones;
# after the check, the updates found are offered for download (all marked).
# The runs themselves are the usual Invoke-Modes, limited through ModeItems.
# Loaded by update-tools.ps1.

function Test-MenuAvailable {
    (-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected) -and
        [bool](Get-Command fzf -CommandType Application -ErrorAction SilentlyContinue)
}

# fzf with the menu's look, inline below the prompt so the scrollback stays.
# Lines are tab-separated: field 1 is what's returned, the rest is shown.
# Returns the chosen lines (none after Esc).
function Invoke-Fzf([string[]]$Lines, [string[]]$FzfArgs) {
    # what PowerShell pipes to a program (5.1's default is ASCII)
    $OutputEncoding = [Text.UTF8Encoding]::new($false)
    # some Windows consoles can't draw rounded corners, so fzf's own default
    # there (sharp)
    $border = if ($env:OS -eq 'Windows_NT') { '--border' } else { '--border=rounded' }
    $all = @('--multi', '--delimiter=\t', '--with-nth=2..', '--layout=reverse',
             '--height=~60%', $border, '--info=inline-right') + $FzfArgs
    @($Lines | & fzf @all)
}

# The first field of each chosen line.
function Get-FzfKeys([string[]]$Chosen) {
    @($Chosen | ForEach-Object { $_.Split("`t")[0] })
}

# The cfgs of a mode's folder, sorted, as Invoke-Mode reads them.
function Get-MenuCfgs([string]$Dir) {
    $db = Join-Path (Join-Path $Dir '.update-tools') 'db'
    if (-not (Test-Path -LiteralPath $db -PathType Container)) { return @() }
    @(Get-ChildItem -LiteralPath $db -File | Where-Object { $_.Name -like '*.json' } | Sort-Object Name)
}

# What a cfg shows in step 2: the version (the installed file for static
# items, whose version is long), and when it was last checked.
function Get-MenuItemLine($Cfg) {
    $name = $Cfg.Name.Substring(0, $Cfg.Name.Length - '.json'.Length)
    $shown = '(not a valid cfg)'; $checked = ''
    try {
        $o = ConvertFrom-JsonText ([IO.File]::ReadAllText($Cfg.FullName))
        if ($o -is [Collections.IDictionary]) {
            $st = $o['state']
            if (-not ($st -is [Collections.IDictionary])) { $st = @{} }
            $cv = [string]$st['current_version']
            $shown = if ($cv -and -not $cv.StartsWith('static-')) { $cv }
                     elseif ($st['installed_file']) { [string]$st['installed_file'] }
                     else { 'not installed' }
            $checked = if ($st['last_checked']) { ([string]$st['last_checked']).Replace('T', ' ') } else { 'never' }
        }
    } catch { }
    "$name`t" + ('{0,-28} {1,-44} {2}' -f $name, $shown, "checked $checked")
}

# The mode's folder from the settings, as Invoke-Mode reads it; empty if unset.
function Get-MenuDir([string]$Type) {
    $dir = (Get-Settings)[(Get-ModeSettings $Type).DirKey]
    if (-not $dir) { return '' }
    $dir = $dir.TrimEnd('/', '\')
    if ($dir -match '^[A-Za-z]:$') { $dir += '\' }
    $dir
}

# The menu; $false if a mode couldn't run, or none can.
function Invoke-Menu {
    $avail = @(); $unavailable = ''
    # step 1 lines: every mode whose folder is there; the rest are named in
    # the header, since fzf can't grey out a line
    foreach ($m in 'apw', 'iso') {
        $s = Get-ModeSettings $m
        $dir = Get-MenuDir $m
        if (-not $dir) {
            $unavailable += "`n  $($s.Title): no $($s.DirKey) in $(Format-Path $script:SettingsFile)"
        } elseif (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            $unavailable += "`n  $($s.Title): $(Format-Path $dir) not found. $($s.NotFoundHint)"
        } else {
            $n = (Get-MenuCfgs $dir).Count
            $word = if ($n -eq 1) { 'item' } else { 'items' }
            $avail += "$m`t" + ('{0,-20} {1,4} {2,-5}   {3}' -f $s.Title, $n, $word, (Format-Path $dir))
        }
    }
    if ($avail.Count -eq 0) {
        Write-Err "⚠ nothing to update:$unavailable"
        return $false
    }
    $header = 'What to update  (Tab: mark, Enter: go, Esc: quit)'
    if ($unavailable) { $header += "`nNot available:$unavailable" }

    while ($true) {
        $check = @(); $runs = @(); $back = $false
        $script:ModeItems = @{}
        $picks = Get-FzfKeys (Invoke-Fzf $avail @("--header=$header"))
        if ($picks.Count -eq 0) { return $true }

        # step 2, per kind: all of it (checked first), or single items; Esc
        # goes back to step 1
        foreach ($m in 'apw', 'iso') {
            if ($picks -notcontains $m) { continue }
            $s = Get-ModeSettings $m
            $lines = @("*`t* check all for updates, then choose what to download")
            $lines += @(Get-MenuCfgs (Get-MenuDir $m) | ForEach-Object { Get-MenuItemLine $_ })
            $choice = Get-FzfKeys (Invoke-Fzf $lines @("--header=$($s.Title)  (Tab: mark, Enter: go, Esc: back)"))
            if ($choice.Count -eq 0) { $back = $true; break }
            if ($choice -contains '*') { $check += $m }
            else { $runs += $m; $script:ModeItems[$m] = $choice }
        }
        if (-not $back) { break }
    }

    $script:AlwaysHeadings = $true
    $ok = $true
    # the check: nothing is downloaded or written; what it finds is offered
    # below on a cleared screen, with each kind's summary and the session log
    # (with -Check, the check is all there is, and stays on screen)
    if ($check.Count) {
        $script:AvailableList = [Collections.Generic.List[string]]::new()
        $script:SummaryLines = [Collections.Generic.List[string]]::new()
        $savedCheck = $script:CheckOnly
        $script:CheckOnly = $true; $script:HeadingNote = 'checking for updates'
        if (-not (Invoke-Modes $check '' $true)) { $ok = $false }
        $script:CheckOnly = $savedCheck; $script:HeadingNote = ''

        # one line per kind: its summary lines joined
        $summary = ''; $prev = ''
        foreach ($l in $script:SummaryLines) {
            $t, $line = $l.Split("`t", 2)
            if ($t -eq $prev) { $summary += " · $line" } else { $summary += "`n${t}: $line" }
            $prev = $t
        }
        if ($script:RunLog) { $summary += "`nLog: $(Format-Path $script:RunLog)" }
        $script:SummaryLines = $null

        $lines = @(foreach ($l in $script:AvailableList) {
            $m, $n, $ver = $l.Split("`t", 3)
            $kind = if ($m -eq 'apw') { 'world' } else { 'ISO' }
            "$m`t$n`t" + ('{0,-9} {1,-28} {2}' -f $kind, $n, $ver)
        })
        $script:AvailableList = $null

        if (-not $script:CheckOnly) {
            # the check is in the log now
            [Console]::Write("$([char]27)[H$([char]27)[2J")
            $chosen = @()
            if ($lines.Count) {
                $sel = Invoke-Fzf $lines @('--with-nth=3..', '--bind=load:select-all',
                    "--header=Updates to download  (Tab: unmark, Enter: download, Esc: none)$summary")
                foreach ($l in $sel) {
                    $m, $f = $l.Split("`t")[0, 1]
                    if ($runs -notcontains $m) { $runs += $m }
                    if (-not $script:ModeItems.ContainsKey($m)) { $script:ModeItems[$m] = @() }
                    $script:ModeItems[$m] += $f
                    $chosen += $f
                }
            }
            if ($chosen.Count) {
                Write-Log "chosen for download: $($chosen -join ', ')"
            } else {
                # nothing to download: the check's results stay on screen
                foreach ($l in $summary.TrimStart("`n").Split("`n")) { if ($l) { Write-Line $l } }
                Say $(if ($lines.Count) { 'nothing downloaded' } else { '✓ nothing to update' })
            }
        }
    }

    # the downloads: the updates kept above, and the single items from step 2,
    # in the usual order
    if ($runs.Count) {
        $order = @('apw', 'iso' | Where-Object { $runs -contains $_ })
        $script:HeadingNote = if ($script:CheckOnly) { '' } else { 'updating' }
        if (-not (Invoke-Modes $order '' $true)) { $ok = $false }
    }
    $ok
}
