<#
update-tools.ps1: checks and updates Archipelago worlds and the ISOs on a
Ventoy drive, on Windows. The PowerShell port of the bash update-tools: the
same cfg files and keys, the same managers and rules. Run without arguments
for the help. Works in Windows PowerShell 5.1 and PowerShell 7.
#>
param(
    [Alias('m')][string]$Mode,
    [Alias('c')][switch]$Check,
    [Alias('f')][switch]$Force,
    [Alias('r')][string]$Root,
    [Alias('d')][switch]$Debug,
    [Alias('h')][switch]$Help
)
Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

foreach ($lib in 'output', 'cfg', 'net', 'managers', 'files', 'apworlds', 'isos', 'main') {
    . (Join-Path (Join-Path $PSScriptRoot 'lib') "$lib.ps1")
}

function Show-Usage([switch]$ToError) {
    $settings = Get-Settings
    $apw = if ($settings.apw_dir) { Format-Path $settings.apw_dir } else { '(not set)' }
    $iso = if ($settings.iso_dir) { Format-Path $settings.iso_dir } else { '(not set)' }
    $h = $script:SkipSeconds / 3600
    $skip = if ($script:SkipSeconds) { "on, skip_hours=${h}: items checked in the last $h h are skipped" } else { 'off: every item is checked on every run' }
    $text = @"
Usage: update-tools.ps1 -m MODE [OPTIONS]
Check and update Archipelago worlds and ISOs. Each item has a cfg
(NAME.apworld.cfg or NAME.iso.cfg) in its folder's .cfg folder; one whose
item isn't there yet is installed.

Modes:
  apw, apworlds     the Archipelago custom worlds
  iso, isos         the ISOs on a Ventoy drive; each cfg's folder= names the
                    ISO's folder, and every download is checksum-verified
                    before it replaces anything
  all               both in turn, skipping any that can't run

Settings ($(Format-Path $script:SettingsFile)):
  apw_dir=          $apw
  iso_dir=          $iso
  skip_checked=     $skip

Options:
  -m, -Mode MODE    what to update (required; see Modes)
  -c, -Check        only look for updates: download and change nothing
  -f, -Force        check every item, even ones checked within skip_hours
  -r, -Root DIR     use DIR instead of the mode's folder (not with -m all)
  -d, -Debug        explain each decision and time each item
  -h, -Help         show this help
"@
    if ($ToError) { Write-Err $text } else { Say $text }
}

if ($Help -or -not ($Mode -or $Check -or $Force -or $Root -or $Debug)) { Show-Usage; exit 0 }
$modes = switch ($Mode) {
    { $_ -in 'apw', 'apworlds' } { @('apw') }
    { $_ -in 'iso', 'isos' } { @('iso') }
    'all' { @('apw', 'iso') }
    '' { Write-Err 'update-tools.ps1: -Mode is required'; Show-Usage -ToError; exit 2 }
    default { Write-Err "update-tools.ps1: unknown mode '$Mode' (apw, iso or all)"; Show-Usage -ToError; exit 2 }
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

$skipped = @()
foreach ($m in $modes) {
    $title = (Get-ModeSettings $m).Title
    if ($modes.Count -gt 1) { Say "▶ $title" }
    $script:TmpDir = ''
    if (-not (Invoke-Mode $m $Root ($Mode -eq 'all'))) { $skipped += $title }
}
if ($skipped.Count -eq 0) { exit 0 }
if ($modes.Count -gt 1) { Say "⚠ skipped: $($skipped -join ', ')" }
exit 1
