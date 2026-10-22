# files.ps1: checksums, setting the old version aside, and choosing the
# install name. Loaded by update-tools.ps1.

function Get-Hash([string]$Algo, [string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm $Algo.ToUpper()).Hash.ToLower()
}

# Moves a file, replacing nothing: on one disk it's a rename, so no half-written
# file is ever visible.
function Move-File([string]$From, [string]$To) {
    try { [IO.File]::Move($From, $To); $true } catch { $false }
}

function Remove-IfThere([string]$Path) {
    if ($Path -and (Test-Path -LiteralPath $Path)) { Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# The old version during an install: renamed into TmpDir (always ROOT\.tmp,
# on the same disk) right before the new one goes in, deleted once it's in
# place, renamed back if the install fails or the run is interrupted. It keeps
# its path below the root and gets a .previous suffix, which never ends in .iso,
# so Ventoy can't list it.
# ---------------------------------------------------------------------------
$script:Aside = [Collections.Generic.List[string]]::new()
# The new file's path from just before it's moved in. The old versions are
# aside by then, so a target that exists means the install happened: an old one
# with another name must not come back next to it. Also kept in TmpDir\target
# for Restore-Interrupted after a run killed outright.
$script:InstallTarget = ''

function Get-PreviousPath([string]$File) {
    $root = Split-Path -Parent $script:TmpDir
    Join-Path $script:TmpDir ($File.Substring($root.Length).TrimStart('\', '/') + '.previous')
}

# Removes the folders Get-PreviousPath made, up to TmpDir, once empty.
function Remove-EmptyParents([string]$Path) {
    $d = Split-Path -Parent $Path
    while ($d -and $d.Length -gt $script:TmpDir.Length -and $d.StartsWith($script:TmpDir) -and
           (Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force | Select-Object -First 1)) {
        Remove-Item -LiteralPath $d -Force
        $d = Split-Path -Parent $d
    }
}

# Moves each existing file aside (empty and missing ones are skipped). On a
# failure, puts back what it moved and returns $false.
function Set-Aside([string[]]$Files) {
    $script:Aside.Clear()
    foreach ($f in $Files) {
        if (-not $f -or -not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        # the installed file is often the target too
        if ($script:Aside.Contains($f)) { continue }
        $p = Get-PreviousPath $f
        [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p))
        Remove-IfThere $p
        if (-not (Move-File $f $p)) {
            Remove-EmptyParents $p
            Restore-Previous
            return $false
        }
        $script:Aside.Add($f)
    }
    $true
}

# Records the install's target, right before the move.
function Start-Install([string]$Target) {
    $script:InstallTarget = $Target
    [void](New-Item -ItemType Directory -Force -Path $script:TmpDir)
    [IO.File]::WriteAllText((Join-Path $script:TmpDir 'target'), $Target)
}

function Stop-Install {
    $script:InstallTarget = ''
    if ($script:TmpDir) { Remove-IfThere (Join-Path $script:TmpDir 'target') }
}

function Restore-Previous {
    foreach ($f in @($script:Aside)) {
        $p = Get-PreviousPath $f
        if (Move-File $p $f) { Remove-EmptyParents $p }
    }
    $script:Aside.Clear()
    Stop-Install
}

function Remove-Previous {
    foreach ($f in @($script:Aside)) {
        $p = Get-PreviousPath $f
        Remove-IfThere $p
        Remove-EmptyParents $p
        Debug-Line "deleted the old version, $(Split-Path -Leaf $f)"
    }
    $script:Aside.Clear()
    Stop-Install
}

# On exit, Ctrl+C included: an interrupted install keeps the new file if it got
# in, and the old one otherwise.
function Complete-Previous {
    if ($script:InstallTarget -and (Test-Path -LiteralPath $script:InstallTarget)) { Remove-Previous } else { Restore-Previous }
}

# After a run that was killed outright: an old version whose file is missing
# goes back, unless the new one got in under another name; one whose file is
# there is deleted.
function Restore-Interrupted {
    if (-not (Test-Path -LiteralPath $script:TmpDir -PathType Container)) { return }
    $targetFile = Join-Path $script:TmpDir 'target'
    $target = if (Test-Path -LiteralPath $targetFile) { ([IO.File]::ReadAllText($targetFile)).Trim() } else { '' }
    $root = Split-Path -Parent $script:TmpDir
    foreach ($p in @(Get-ChildItem -LiteralPath $script:TmpDir -Recurse -Force -File -Filter '*.previous')) {
        $f = Join-Path $root ($p.FullName.Substring($script:TmpDir.Length).TrimStart('\', '/') -replace '\.previous$', '')
        if ((Test-Path -LiteralPath $f) -or ($target -and (Test-Path -LiteralPath $target))) {
            Remove-IfThere $p.FullName
        } elseif (Move-File $p.FullName $f) {
            Say "⚠ put back $(Split-Path -Leaf $f), which an interrupted run had moved aside"
        }
        Remove-EmptyParents $p.FullName
    }
    Remove-IfThere $targetFile
}

# The name to install under: the upstream name (versions and casing included)
# if it ends in .EXT, so Archipelago or Ventoy recognises it; otherwise the
# installed file's name, or on a first install the cfg's name with the extension.
function Select-InstallName($it, [string]$Candidate) {
    if ($Candidate.ToLower().EndsWith(".$($script:Ext)")) { return $Candidate }
    $new = if ($it.installed_path) { Split-Path -Leaf $it.installed_path } else { "$($it.name).$($script:Ext)" }
    Debug-Line "upstream name '$Candidate' doesn't end in .$($script:Ext); installing as $new"
    $new
}
