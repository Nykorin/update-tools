<#
update-tools.ps1: checks and updates Archipelago worlds and the ISOs on a
Ventoy drive, on Windows. The PowerShell port of the bash update-tools: the
same cfg files and keys, the same managers and rules. update-tools.ps1 make
writes a new item's cfg (lib\make.ps1). Run without arguments for the help.
Works in Windows PowerShell 5.1 and PowerShell 7.
#>
# Unnamed arguments fill the parameters in this order: the command (make, or a
# help topic after -h), then make's LINK and NAME. No [Parameter()]
# attributes, which would make it an advanced script and claim -Debug for
# PowerShell's own use.
param(
    [string]$Command,
    [string]$Link,
    [string]$Name,
    [Alias('m')][string]$Mode,
    [Alias('c')][switch]$Check,
    [Alias('f')][switch]$Force,
    [Alias('r')][string]$Root,
    [Alias('u')][string]$Url,
    [Alias('l')][switch]$Latest,
    [Alias('p')][switch]$Prerelease,
    [Alias('d')][switch]$Debug,
    [Alias('h')][switch]$Help
)
Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

foreach ($lib in 'output', 'cfg', 'net', 'managers', 'files', 'apworlds', 'isos', 'main', 'make', 'menu') {
    . (Join-Path (Join-Path $PSScriptRoot 'lib') "$lib.ps1")
}

# The help, as in the bash version: -h prints the overview (Show-Usage), -h
# TOPIC one part of it (Show-Topic). A usage error prints the overview to the
# error stream.
$script:HelpTopics = @('modes', 'menu', 'settings', 'make', 'all')

function Show-Text([string]$Text, [switch]$ToError) {
    if ($ToError) { Write-Err $Text } else { Say $Text }
}

function Show-Usage([switch]$ToError) {
    Show-Text -ToError:$ToError @"
Usage: update-tools.ps1 [-m MODE] [OPTIONS]
       update-tools.ps1 make -m MODE [OPTIONS] LINK [NAME]
Check and update Archipelago worlds and ISOs. Without -m, on a console with
fzf, a menu picks what to update.

Options:
  -m, -Mode MODE    apw, iso or all, without the menu (-h modes)
  -c, -Check        only look for updates: download and change nothing
  -f, -Force        check every item, even ones checked within skip_hours
  -r, -Root DIR     use DIR instead of the mode's folder (not with -m all)
  -d, -Debug        explain each decision and time each item
  -h, -Help [TOPIC] show this help, or one topic

Topics (-h TOPIC):
  modes             what each mode updates, and from where
  menu              the menu, without -m
  settings          the settings file, and what it sets now
  make              writing a new item's cfg (update-tools.ps1 make -h)
  all               every topic
"@
}

# The folders and the skip from the settings file, for modes and settings.
function Get-HelpSettings {
    $settings = Get-Settings
    $h = $script:SkipSeconds / 3600
    @{
        Apw  = if ($settings.apw_dir) { Format-Path $settings.apw_dir } else { '' }
        Iso  = if ($settings.iso_dir) { Format-Path $settings.iso_dir } else { '' }
        Skip = if ($script:SkipSeconds) { "on, skip_hours=${h}: items checked in the last $h h are skipped" } else { 'off: every item is checked on every run' }
    }
}

function Show-Modes {
    $v = Get-HelpSettings
    $apw = if ($v.Apw) { $v.Apw } else { 'no folder set (-h settings)' }
    $iso = if ($v.Iso) { $v.Iso } else { 'no folder set (-h settings)' }
    Show-Text @"
Modes:
  apw, apworlds     the Archipelago custom worlds: $apw
  iso, isos         the ISOs on a Ventoy drive: $iso
                    (each cfg's "folder" names the ISO's folder, and every
                    download is checksum-verified before it replaces anything)
  all               both in turn, skipping any that can't run

Each item has a cfg (NAME.json) in its folder's .update-tools\db; one whose
item isn't there yet is installed.
"@
}

function Show-MenuHelp {
    Show-Text @"
Menu:
Without -m, on a console with fzf (winget install fzf), a menu picks what to
update:
  1. the kinds (Tab marks several, Enter takes them, Esc quits)
  2. for each kind, "check all" (the first line), or single marked items,
     which are updated directly; Esc goes back
  3. after the check, which downloads nothing, the updates found are listed,
     all marked: Enter downloads what's still marked, Esc nothing
With -c the run ends after the check. The check's output is in the session
log, whose path the list shows. Without fzf, -m is needed.
"@
}

function Show-SettingsHelp {
    $v = Get-HelpSettings
    $apw = if ($v.Apw) { $v.Apw } else { '(not set)' }
    $iso = if ($v.Iso) { $v.Iso } else { '(not set)' }
    Show-Text @"
Settings ($(Format-Path $script:SettingsFile)):
  apw_dir=          $apw
  iso_dir=          $iso
  skip_checked=     $($v.Skip)

One key=value per line. skip_checked=off checks every item on every run;
skip_hours (default 24; 168 is weekly) sets how long a check counts. -f
ignores both for one run.
"@
}

# -h TOPIC: one part of the help; every part for "all".
function Show-Topic([string]$Topic) {
    switch ($Topic) {
        'modes'    { Show-Modes }
        'menu'     { Show-MenuHelp }
        'settings' { Show-SettingsHelp }
        'make'     { Show-MakeUsage }
        'all'      { Show-Usage; foreach ($t in 'modes', 'menu', 'settings', 'make') { Say ''; Show-Topic $t } }
        default {
            Write-Err "update-tools.ps1: no help topic '$Topic' ($($script:HelpTopics -join ', '))"
            exit 2
        }
    }
}

# The arguments as given, for the log's first line (make's LINK and NAME
# included).
function Get-GivenArguments($Bound) {
    @(foreach ($k in $Bound.Keys) {
        if ($k -eq 'Command') { continue }
        $v = $Bound[$k]
        if ($k -in 'Link', 'Name') { $v }
        elseif ($v -is [switch]) { "-$k" }
        else { "-$k $v" }
    }) -join ' '
}

if ($Help) {
    if ($Command) { Show-Topic $Command } else { Show-Usage }
    exit 0
}
if ($Command -eq 'make') {
    foreach ($k in 'Check', 'Force') {
        if ($PSBoundParameters.ContainsKey($k)) {
            Write-Err "update-tools.ps1 make: -$k is for updates, not make"
            Show-MakeUsage -ToError
            exit 2
        }
    }
    Invoke-Make $Link $Name $Mode $Url ([bool]$Latest) ([bool]$Prerelease) $Root ([bool]$Debug) (Get-GivenArguments $PSBoundParameters)
    exit 0
}
if ($Command) {
    Write-Err "update-tools.ps1: unknown command '$Command' (make, or -h TOPIC)"
    Show-Usage -ToError
    exit 2
}
if ($Url -or $Latest -or $Prerelease) {
    Write-Err 'update-tools.ps1: -Url, -Latest and -Prerelease are for make (update-tools.ps1 make -h)'
    Show-Usage -ToError
    exit 2
}
# without -m: the menu on a console with fzf; otherwise -m is needed, and with
# no arguments at all the help is shown
$menu = $false
$modes = @()
if (-not $Mode) {
    if ($Root) {
        Write-Err 'update-tools.ps1: -Root needs -m apw or iso (each mode has its own folder)'
        exit 2
    }
    if (-not (Test-MenuAvailable)) {
        if (-not ($Check -or $Force -or $Debug)) { Show-Usage; exit 0 }
        Write-Err 'update-tools.ps1: -Mode is required (or install fzf for the menu)'
        Show-Usage -ToError
        exit 2
    }
    $menu = $true
} else {
    $modes = switch ($Mode) {
        { $_ -in 'apw', 'apworlds' } { @('apw') }
        { $_ -in 'iso', 'isos' } { @('iso') }
        'all' { @('apw', 'iso') }
        default { Write-Err "update-tools.ps1: unknown mode '$Mode' (apw, iso or all)"; Show-Usage -ToError; exit 2 }
    }
}
if ($Mode -eq 'all' -and $Root) {
    Write-Err 'update-tools.ps1: -Root can''t be used with -m all (each mode has its own folder)'
    exit 2
}

[void](Get-Settings)   # the skip applies with -Root too
$script:CheckOnly = [bool]$Check
$script:ForceAll = [bool]$Force
$script:DebugOn = [bool]$Debug -or ($env:DEBUG -and $env:DEBUG -ne '0')
# one time for the whole run: what last_checked saves, and what it's compared with
$script:Now = Get-Date
$script:CheckedAt = $script:Now.ToString("yyyy-MM-dd'T'HH:mm")
# the arguments as given, for the log's first line
Start-Log (Get-GivenArguments $PSBoundParameters)

if ($menu) { $ok = Invoke-Menu } else { $ok = Invoke-Modes $modes $Root ($Mode -eq 'all') }
if ($ok) { exit 0 }
exit 1
