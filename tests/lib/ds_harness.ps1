# tests/lib/ds_harness.ps1 -- shared rig for the runtime suites.
#
# Dot-source it; nothing here executes at load time.
#
#   . "$PSScriptRoot\lib\ds_harness.ps1"
#
# Provides:
#   * server lifecycle (start / wait until the plugin really answers / stop)
#   * an RCON wrapper with retries (the first AUTH can race rcon_password)
#   * a tiny check recorder that writes BOTH a human markdown report and a
#     machine-readable JSON result, so tools\ci.ps1 can assert on it
#
# Required environment (no private defaults are baked in):
#   CS2U_DS_DIR          path to the L4D2 dedicated-server root (contains srcds.exe)
#   CS2U_DS_HOST         host/IP the dedicated server listens on
#   CS2U_DS_PORT         RCON port (optional, default 27016)
#   CS2U_RCON_PASSWORD   RCON password used to boot the server (optional here,
#                        but the server must start with a known rcon_password)
#
# Why the assertions live in the suites and not in ci.ps1: a suite knows what it
# just did (it set 0.50 and expects 0.6666); ci.ps1 only aggregates verdicts.

$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:DsRoot = if ($env:CS2U_DS_DIR) {
    $env:CS2U_DS_DIR
} else {
    throw 'CS2U_DS_DIR is not set: point it at your L4D2 dedicated-server root (the directory containing srcds.exe).'
}
$script:DsHost = if ($env:CS2U_DS_HOST) {
    $env:CS2U_DS_HOST
} else {
    throw 'CS2U_DS_HOST is not set: set it to the host/IP your dedicated server listens on.'
}
$script:DsPort   = if ($env:CS2U_DS_PORT) { [int]$env:CS2U_DS_PORT } else { 27016 }
$script:RconPs1  = Join-Path $script:RepoRoot 'tests\rcon.ps1'

# Tick mods parked by -NoTickMod.  They are Metamod plugins (.vdf next to the
# addons folder), so renaming the .vdf is the only way to get a real 30 Hz
# server without uninstalling anything.
$script:TickModParked = @()

function Get-DsRoot     { return $script:DsRoot }
function Get-DsEndpoint { return ('{0}:{1}' -f $script:DsHost, $script:DsPort) }
function Get-RepoRoot   { return $script:RepoRoot }

function Get-Cs2uVersion {
    $src = Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepoRoot 'src\cs2unified.sp')
    if ($src -match '#define\s+CS2U_VERSION\s+"([^"]+)"') { return $Matches[1] }
    throw 'CS2U_VERSION not found in src/cs2unified.sp'
}

function Get-DsConsoleLog { return (Join-Path $script:DsRoot 'left4dead2\console.log') }

# A detached srcds dies with its parent shell on this box, so two suites can
# never share one: refuse instead of silently killing whatever is running.
function Assert-DsIdle {
    $running = @(Get-Process srcds -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        throw ("an srcds process is already running (pid {0}); stop it first, or pass -Force" -f ($running[0].Id))
    }
}

function Stop-DsServer {
    Get-Process srcds -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    # Give the kernel a moment to release 27016: a new instance started in the
    # same second can exit before it ever creates console.log, which then looks
    # like "the plugin never loaded".
    for ($i = 0; $i -lt 30; $i++) {
        if (-not (Get-Process srcds -ErrorAction SilentlyContinue) -and -not (Test-DsPort -TimeoutMs 300)) { break }
        Start-Sleep -Seconds 1
    }
    # Measured 2026-11-08: a srcds started within ~5 s of a force-kill sometimes
    # hangs before it prints anything past "Network: IP" (process alive, no
    # listener, no log growth). Waiting a few seconds after the port is free is
    # what makes the next boot deterministic.
    Start-Sleep -Seconds 6
    # Always put the tick mods back: a suite that dies mid-run must not leave
    # the dedicated server permanently stuck at 30 Hz.
    Restore-DsTickMods
}

function Restore-DsTickMods {
    foreach ($vdf in $script:TickModParked) {
        $parked = "$vdf.notick"
        if ((Test-Path -LiteralPath $parked) -and -not (Test-Path -LiteralPath $vdf)) {
            Rename-Item -LiteralPath $parked -NewName (Split-Path -Leaf $vdf)
        }
    }
    $script:TickModParked = @()
}

# -condebug appends, so a stale "LOAD version=" from a previous boot would make
# Wait-DsReady return immediately.  Rotate it before every start.
function Reset-DsConsoleLog {
    $log = Get-DsConsoleLog
    if (Test-Path $log) {
        $prev = "$log.prev"
        Remove-Item $prev -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $log -Destination $prev -Force
    }
}

function Start-DsServer {
    param(
        [Parameter(Mandatory)][string]$Map,
        # 64 is the project default; 30 is used to prove the environment
        # adaptation actually produces a different recommendation.
        [int]$Tickrate = 64,
        # Park l4dtoolz.vdf / tickrate_enabler.vdf so the server really runs at
        # the engine default.  -tickrate alone proves nothing: the tick
        # enhancers are the thing that overrides it.
        [switch]$NoTickMod
    )

    $exe = Join-Path $script:DsRoot 'srcds.exe'
    if (-not (Test-Path $exe)) { throw "srcds.exe not found: $exe" }
    $pw = if ($env:CS2U_RCON_PASSWORD) {
        $env:CS2U_RCON_PASSWORD
    } else {
        throw 'CS2U_RCON_PASSWORD is not set: the harness boots the server with this value as rcon_password.'
    }

    if ($NoTickMod) {
        foreach ($name in @('l4dtoolz', 'tickrate_enabler')) {
            $vdf = Join-Path $script:DsRoot ("left4dead2\addons\{0}.vdf" -f $name)
            if (Test-Path -LiteralPath $vdf) {
                Rename-Item -LiteralPath $vdf -NewName ("{0}.vdf.notick" -f $name)
                $script:TickModParked += $vdf
                Write-Host ("tick mod parked: {0}" -f $vdf)
            }
        }
    }

    Reset-DsConsoleLog
    # NOTE: no -RedirectStandardOutput here.  On Windows PowerShell 5.1 that
    # switch makes Start-Process rebuild the environment block and it throws
    # "duplicate key http_proxy / HTTP_PROXY" on this box.  The engine writes
    # its own console.log (-condebug), which is what every assertion uses.
    $proc = Start-Process $exe -WorkingDirectory $script:DsRoot -PassThru -ArgumentList @(
        '-console', '-game', 'left4dead2', '-insecure',
        '-port', "$($script:DsPort)", '-tickrate', "$Tickrate", '-condebug', '-nobreakpad',
        '+rcon_password', $pw, '+map', $Map, 'coop', '+exec', 'server.cfg'
    )
    # An instance that dies within 4 s leaves no console.log and no listener:
    # without this the caller just waits out its whole budget and reports
    # "the plugin never answered".
    Start-Sleep -Seconds 4
    if ($proc.HasExited) {
        throw ("srcds exited immediately (code {0}); tickrate={1} noTickMod={2} map={3}" -f `
            $proc.ExitCode, $Tickrate, $NoTickMod.IsPresent, $Map)
    }
    return $proc
}

# Ready means "the plugin answers RCON", not "the port is open": the port opens
# before rcon_password is applied, and a too-early AUTH counts against
# sv_rcon_maxfailures.
#
# The listener is ALSO not continuously open: during Host_NewGame the engine
# tears it down and rebinds (measured 2026-11-07 on this box: a 5-15 s window
# right after LOAD). A probe landing in that window looks exactly like "the
# plugin is dead", so the wait gates on a raw TCP connect first and only then
# spends an RCON attempt.
function Test-DsPort {
    param([int]$TimeoutMs = 700)
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect($script:DsHost, $script:DsPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $c.Close(); return $false }
        $c.EndConnect($iar)
        $c.Close()
        return $true
    } catch {
        return $false
    }
}

function Wait-DsReady {
    param([int]$TimeoutSec = 200, [int]$LoadTimeoutSec = 150)

    $log = Get-DsConsoleLog
    $start = Get-Date
    $loadDeadline = $start.AddSeconds($LoadTimeoutSec)
    $deadline = $start.AddSeconds($TimeoutSec)

    $loaded = $false
    while ((Get-Date) -lt $loadDeadline) {
        if (Test-Path $log) {
            $t = Get-Content $log -Tail 400 -ErrorAction SilentlyContinue
            if ($t -match 'CS2Unified\] LOAD version=') { $loaded = $true; break }
        }
        if (-not (Get-Process srcds -ErrorAction SilentlyContinue)) { return $false }
        Start-Sleep -Seconds 3
    }
    if (-not $loaded) { return $false }

    Start-Sleep -Seconds 12   # OnConfigsExecuted + the persisted-settings timer
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process srcds -ErrorAction SilentlyContinue)) { return $false }
        if (Test-DsPort) {
            $probe = Invoke-Rcon @('sm_cs2u_status') -Attempts 2
            if ($probe -match 'CS2Unified') { return $true }
        }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Invoke-Rcon {
    param([Parameter(Mandatory)][string[]]$Commands, [int]$Attempts = 4)

    $text = ''
    for ($i = 1; $i -le $Attempts; $i++) {
        # Do not burn an RCON attempt (or an auth failure) on a closed listener.
        if (-not (Test-DsPort)) {
            if ($i -lt $Attempts) { Start-Sleep -Seconds 3; continue }
            return 'RCON ERROR: port closed'
        }
        try {
            $text = & $script:RconPs1 -Server $script:DsHost -Port $script:DsPort -Command $Commands 2>&1 | Out-String
            $text = $text.TrimEnd()
            # rcon.ps1 prints "### <command>" once per command it actually sent.
            # Requiring one marker per command is what catches a HALF response
            # (socket died after the first of two commands): that used to slip
            # through because a single marker looked like success, and the caller
            # then asserted on the second command's silence.
            $markers = ([regex]::Matches($text, '(?m)^### ')).Count
            $ok = $text -and ($markers -eq $Commands.Count) -and ($text -notmatch 'RCON AUTH FAILED')
            if ($ok) { return $text }
        } catch {
            $text = ("RCON ERROR: {0}" -f $_.Exception.Message)
        }
        if ($i -lt $Attempts) { Start-Sleep -Seconds 3 }
    }
    return $text
}

function Get-DsLogLines {
    param([string]$Pattern, [int]$Tail = 400, [int]$Last = 40)
    $log = Get-DsConsoleLog
    if (-not (Test-Path $log)) { return @() }
    return @(Get-Content $log -Tail $Tail | Where-Object { $_ -match $Pattern } | Select-Object -Last $Last)
}

# LogMessage() output (the ACTION telemetry, module state dumps) goes to
# addons/sourcemod/logs/L<date>.log, NOT to console.log -- which is where the
# "was this edit recorded" questions have to look.
function Get-SmLogPath {
    return (Join-Path $script:DsRoot ('left4dead2\addons\sourcemod\logs\L{0}.log' -f (Get-Date -Format 'yyyyMMdd')))
}

function Get-SmLogLines {
    param([string]$Pattern, [int]$Last = 60)
    $log = Get-SmLogPath
    if (-not (Test-Path $log)) { return @() }
    return @(Get-Content $log -Encoding UTF8 | Where-Object { $_ -match $Pattern } | Select-Object -Last $Last)
}

# ---- result recorder -----------------------------------------------------

function New-TestSuite {
    param([string]$Name, [string]$Title)
    return [pscustomobject]@{
        name     = $Name
        title    = $Title
        started  = (Get-Date)
        finished = $null
        ok       = $true
        checks   = (New-Object System.Collections.Generic.List[object])
        sections = (New-Object System.Collections.Generic.List[object])
        meta     = (New-Object System.Collections.Generic.List[object])
    }
}

function Add-TestMeta {
    param($Suite, [string]$Key, [string]$Value)
    $Suite.meta.Add([pscustomobject]@{ key = $Key; value = $Value })
}

function Add-TestCheck {
    param($Suite, [string]$Name, [bool]$Ok, [string]$Detail = '')

    $Suite.checks.Add([pscustomobject]@{ name = $Name; ok = $Ok; detail = $Detail })
    if (-not $Ok) { $Suite.ok = $false }

    $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
    $col = if ($Ok) { 'Green' } else { 'Red' }
    $line = if ($Detail) { "  $tag  $Name ($Detail)" } else { "  $tag  $Name" }
    Write-Host $line -ForegroundColor $col
}

# Record a command output block for the human report (not asserted on).
function Add-TestSection {
    param($Suite, [string]$Title, [string]$Text)
    $Suite.sections.Add([pscustomobject]@{ title = $Title; text = $Text })
}

function Complete-TestSuite {
    param($Suite, [Parameter(Mandatory)][string]$OutDir)

    $Suite.finished = Get-Date
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    $passed = @($Suite.checks | Where-Object { $_.ok }).Count
    $failed = @($Suite.checks | Where-Object { -not $_.ok }).Count

    $md = New-Object System.Collections.Generic.List[string]
    $md.Add(("# {0}" -f $Suite.title))
    $md.Add('')
    $md.Add(("- started: {0:yyyy-MM-dd HH:mm:ss}" -f $Suite.started))
    $md.Add(("- finished: {0:yyyy-MM-dd HH:mm:ss}" -f $Suite.finished))
    $md.Add(("- endpoint: {0}" -f (Get-DsEndpoint)))
    foreach ($m in $Suite.meta) { $md.Add(("- {0}: {1}" -f $m.key, $m.value)) }
    $md.Add('')
    $md.Add(("## Checks ({0} passed / {1} failed)" -f $passed, $failed))
    $md.Add('')
    $md.Add('| # | check | result | detail |')
    $md.Add('|---:|---|---|---|')
    $i = 1
    foreach ($c in $Suite.checks) {
        $md.Add(("| {0} | {1} | {2} | {3} |" -f $i, $c.name, $(if ($c.ok) { 'PASS' } else { '**FAIL**' }), $c.detail))
        $i++
    }
    foreach ($s in $Suite.sections) {
        $md.Add('')
        $md.Add(("## {0}" -f $s.title))
        $md.Add('```')
        $md.Add($s.text)
        $md.Add('```')
    }
    $md.Add('')

    $mdPath = Join-Path $OutDir ("{0}.md" -f $Suite.name)
    [System.IO.File]::WriteAllText($mdPath, (($md -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

    $result = [pscustomobject]@{
        name     = $Suite.name
        title    = $Suite.title
        ok       = ($failed -eq 0)
        started  = $Suite.started.ToString('o')
        finished = $Suite.finished.ToString('o')
        endpoint = (Get-DsEndpoint)
        passed   = $passed
        failed   = $failed
        checks   = $Suite.checks
    }
    $jsonPath = Join-Path $OutDir ("{0}.json" -f $Suite.name)
    [System.IO.File]::WriteAllText($jsonPath, ($result | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

    Write-Host ("RESULT {0}: {1} passed / {2} failed  -> {3}" -f $Suite.name, $passed, $failed, $mdPath) `
        -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
    return $result
}
