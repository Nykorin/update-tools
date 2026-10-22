# output.ps1: what the user sees. Permanent lines go to standard output (so a
# redirect captures them); the transient status and the progress bars use
# PowerShell's own progress display. Loaded by update-tools.ps1.

$script:Label = ''          # the item being handled, named in every message
$script:Done = 0
$script:Total = 0
$script:Title = ''
$script:Plain = [Console]::IsOutputRedirected
$script:DebugOn = $false
# set while make-update-cfg tries lookups that are allowed to fail
$script:Quiet = $false

# A permanent line, for warnings, errors and results. It never goes into a
# function's output, so it can't end up in a variable by accident. On a
# console it goes through the host, which clears the progress bar first.
function Say([string]$Text) {
    if ($script:Quiet) { return }
    if ($script:Plain) { [Console]::Out.WriteLine($Text) } else { Write-Host $Text }
}

function Write-Err([string]$Text) {
    [Console]::Error.WriteLine($Text)
}

# Transient status for the current item. Without a console it's a plain
# "NAME text" line, as in the bash version.
function Status([string]$Text) {
    if ($script:Plain) { if ($Text) { Say "$($script:Label) $Text" }; return }
    $pct = if ($script:Total) { [int]($script:Done * 100 / $script:Total) } else { 0 }
    Write-Progress -Id 1 -Activity $script:Title -Status "$($script:Label) $Text  ($($script:Done)/$($script:Total))" -PercentComplete $pct
}

# The item's result, kept in the scrollback.
function Status-Final([string]$Text) {
    Say "$($script:Label) $Text"
}

# A decision-trace line, only with -Debug.
function Debug-Line([string]$Text) {
    if ($script:DebugOn) { Say "  · $($script:Label): $Text" }
}

function Start-Progress([string]$Title, [int]$Total) {
    $script:Title = $Title; $script:Total = $Total; $script:Done = 0
}

function Stop-Progress {
    if (-not $script:Plain) {
        Write-Progress -Id 2 -Activity 'Download' -Completed
        Write-Progress -Id 1 -Activity $script:Title -Completed
    }
    $summary = Get-RateSummary
    if ($summary) { Say $summary }
}

# Download progress, under the item's bar. $Total may be 0 (unknown size).
function Show-DownloadProgress([long]$Got, [long]$Total) {
    if ($script:Plain) { return }
    $mb = '{0:N1} MB' -f ($Got / 1MB)
    if ($Total -gt 0) {
        Write-Progress -Id 2 -ParentId 1 -Activity "Downloading $($script:Label)" -Status ("$mb of {0:N1} MB" -f ($Total / 1MB)) -PercentComplete ([int]($Got * 100 / $Total))
    } else {
        Write-Progress -Id 2 -ParentId 1 -Activity "Downloading $($script:Label)" -Status $mb
    }
}

function Clear-DownloadProgress {
    if (-not $script:Plain) { Write-Progress -Id 2 -Activity 'Download' -Completed }
}
