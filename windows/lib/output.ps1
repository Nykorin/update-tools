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

# The session log, one per run (Start-Log), as in the bash version: every
# permanent line goes there too.
$script:RunLog = ''
$script:LogsKept = 10

function Write-Log([string]$Text) {
    if ($script:RunLog) {
        [IO.File]::AppendAllText($script:RunLog, $Text + "`n", [Text.UTF8Encoding]::new($false))
    }
}

# A line on screen. It never goes into a function's output, so it can't end
# up in a variable by accident. On a console it goes through the host, which
# clears the progress bar first.
function Write-Line([string]$Text) {
    if ($script:Plain) { [Console]::Out.WriteLine($Text) } else { Write-Host $Text }
}

# A permanent line, for warnings, errors and results: on screen and in the log.
function Say([string]$Text) {
    if ($script:Quiet) { return }
    Write-Line $Text
    Write-Log $Text
}

function Write-Err([string]$Text) {
    [Console]::Error.WriteLine($Text)
    Write-Log $Text
}

# Starts the session log in %LOCALAPPDATA%\update-tools (elsewhere the bash
# version's cache folder), named by the start time, with the date and the
# arguments first; only the newest LogsKept stay. Without a writable folder the
# run goes on without one.
function Start-Log([string]$Arguments) {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA }
            elseif ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME }
            else { Join-Path $HOME '.cache' }
    $dir = Join-Path $base 'update-tools'
    $path = Join-Path $dir ('session-' + $script:Now.ToString('yyyy-MM-dd_HH-mm-ss') + '.log')
    try {
        [void](New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop)
        [IO.File]::WriteAllText($path, '', [Text.UTF8Encoding]::new($false))
    } catch {
        [Console]::Error.WriteLine("update-tools.ps1: can't write a session log in $(Format-Path $dir), going on without one")
        return
    }
    $script:RunLog = $path
    Write-Log ("update-tools.ps1$(if ($Arguments) { ' ' + $Arguments }), " + $script:Now.ToString('yyyy-MM-dd HH:mm:ss'))
    $logs = @(Get-ChildItem -LiteralPath $dir -File -Filter 'session-*.log' | Sort-Object Name)
    if ($logs.Count -gt $script:LogsKept) {
        $logs[0..($logs.Count - $script:LogsKept - 1)] | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    }
}

# Transient status for the current item. Without a console it's a plain
# "NAME text" line, as in the bash version.
function Status([string]$Text) {
    if ($script:Plain) { if ($Text) { Write-Line "$($script:Label) $Text" }; return }
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
