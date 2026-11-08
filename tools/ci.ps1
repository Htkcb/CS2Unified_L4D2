<#
.SYNOPSIS
    Local CI gate for CS2Unified_L4D2: static contract + deploy + runtime suites.

.DESCRIPTION
    The static half is what a hosted runner could do; the runtime half needs the
    real dedicated server (Steam files, an -insecure srcds, RCON on the LAN), so
    this script is the CI: one command, one exit code, one summary artifact.

    Stages
      static   tools\verify.ps1 (sync drift + compile + 114 checks)
      deploy   tools\deploy.ps1 against the test DS (backs up, writes manifest)
      runtime  tests\water_runtime.ps1 + tests\weapons_runtime.ps1 + tests\env_runtime.ps1
               (each starts the DS, asserts, stops it, writes .md + .json)

    Artifacts: tests\results\ci-<stamp>\{summary.md, summary.json, static.log,
    deploy.log, water.md/json, weapons.md/json}

.PARAMETER Stage
    Static (default, ~20 s, no server), Runtime (static + deploy + suites,
    ~4-6 min), All (= Runtime).

.PARAMETER Only
    Restrict the runtime half to some suites: -Only water,weapons,env.

.PARAMETER Quiet
    Print only failures and the final verdict (used by the git hook).

.PARAMETER Force
    Replace an srcds that is already running. Without it the run refuses to
    start: killing somebody's live server is not a CI decision.

.PARAMETER Map
    Map for the runtime suites (default c5m1_waterfront: water + flat ground).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\ci.ps1
    powershell -ExecutionPolicy Bypass -File tools\ci.ps1 -Stage Runtime -Force
#>
[CmdletBinding()]
param(
    [ValidateSet('Static', 'Runtime', 'All')]
    [string]$Stage = 'Static',
    [string[]]$Only,
    [switch]$Quiet,
    [switch]$Force,
    [string]$Map = 'c5m1_waterfront',
    # deploy/runtime target; falls back to CS2U_DS_DIR. Static stage does not need it.
    [string]$DsDir = $env:CS2U_DS_DIR,
    [string]$CompilerPath,
    [string]$IncludePath
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $repo ("tests\results\ci-{0}" -f $stamp)
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$stages = New-Object System.Collections.Generic.List[object]
$suites = New-Object System.Collections.Generic.List[object]

function Say([string]$text, [string]$colour = 'Gray') {
    if (-not $Quiet) { Write-Host $text -ForegroundColor $colour }
}

function Add-Stage([string]$name, [bool]$ok, [string]$detail, [double]$seconds) {
    $stages.Add([pscustomobject]@{ name = $name; ok = $ok; detail = $detail; seconds = [math]::Round($seconds, 1) })
    $tag = if ($ok) { 'PASS' } else { 'FAIL' }
    $col = if ($ok) { 'Green' } else { 'Red' }
    if ($ok -and $Quiet) { return }
    Write-Host ("{0}  {1,-8} {2}  ({3:N1}s)" -f $tag, $name, $detail, $seconds) -ForegroundColor $col
}

function Invoke-Child([string]$exe, [string[]]$arguments, [string]$logPath) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.WorkingDirectory = $repo
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    @($stdout, $stderr) | Where-Object { $_ } | Set-Content -Path $logPath -Encoding UTF8
    return [pscustomobject]@{ exit = $p.ExitCode; stdout = $stdout; stderr = $stderr }
}

# ---- stage: static -------------------------------------------------------
function Invoke-StaticStage {
    $t0 = Get-Date
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repo 'tools\verify.ps1'))
    if ($CompilerPath) { $args += @('-CompilerPath', $CompilerPath) }
    if ($IncludePath)  { $args += @('-IncludePath', $IncludePath) }

    $r = Invoke-Child 'powershell.exe' $args (Join-Path $outDir 'static.log')
    $checks = 0
    if ($r.stdout -match 'VERIFY PASS \((\d+) checks\)') { $checks = [int]$Matches[1] }
    $failedNames = @()
    if ($r.stdout -match 'VERIFY FAIL \(([^)]+)\)') { $failedNames = @($Matches[1]) }

    $ok = ($r.exit -eq 0)
    $detail = if ($ok) { "$checks checks" } else { ($failedNames -join '; ') }
    if (-not $ok -and -not $detail) { $detail = "verify.ps1 exit=$($r.exit)" }
    Add-Stage 'static' $ok $detail ((Get-Date) - $t0).TotalSeconds

    if (-not $ok -and -not $Quiet) {
        Write-Host '--- verify.ps1 tail ---'
        ($r.stdout -split "`r?`n" | Select-Object -Last 25) | ForEach-Object { Write-Host "  $_" }
    }
    return $ok
}

# ---- stage: deploy -------------------------------------------------------
function Invoke-DeployStage {
    $t0 = Get-Date
    if (-not $DsDir) {
        Add-Stage 'deploy' $false 'no deploy target: pass -DsDir or set CS2U_DS_DIR' ((Get-Date) - $t0).TotalSeconds
        return $false
    }
    $smx = Join-Path $repo 'build\cs2unified.smx'
    if (-not (Test-Path $smx)) {
        Add-Stage 'deploy' $false 'build\cs2unified.smx missing' ((Get-Date) - $t0).TotalSeconds
        return $false
    }
    if (-not (Test-Path (Join-Path $DsDir 'left4dead2\addons\sourcemod\plugins'))) {
        Add-Stage 'deploy' $false "not a sourcemod server: $DsDir" ((Get-Date) - $t0).TotalSeconds
        return $false
    }

    $r = Invoke-Child 'powershell.exe' @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repo 'tools\deploy.ps1'),
        '-GameDir', $DsDir
    ) (Join-Path $outDir 'deploy.log')

    $ok = ($r.exit -eq 0)
    $bytes = (Get-Item $smx).Length
    Add-Stage 'deploy' $ok ("{0} -> {1}" -f $bytes, $DsDir) ((Get-Date) - $t0).TotalSeconds
    if (-not $ok -and -not $Quiet) {
        ($r.stdout -split "`r?`n" | Select-Object -Last 15) | ForEach-Object { Write-Host "  $_" }
    }
    return $ok
}

# ---- stage: runtime ------------------------------------------------------
function Invoke-RuntimeStage {
    $wanted = @('water', 'weapons', 'env')
    if ($Only) { $wanted = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

    $allOk = $true
    foreach ($name in $wanted) {
        $script = Join-Path $repo ("tests\{0}_runtime.ps1" -f $name)
        if (-not (Test-Path $script)) {
            Add-Stage ("suite:{0}" -f $name) $false 'script missing' 0
            $allOk = $false
            continue
        }

        $t0 = Get-Date
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-OutDir', $outDir, '-Map', $Map)
        if ($Force) { $args += '-Force' }

        Say ("--- suite {0} ---" -f $name) 'Cyan'
        $r = Invoke-Child 'powershell.exe' $args (Join-Path $outDir ("{0}.console.log" -f $name))

        $jsonPath = Join-Path $outDir ("{0}.json" -f $name)
        $passed = 0; $failed = 0; $failedChecks = @()
        if (Test-Path $jsonPath) {
            $res = Get-Content -Raw -Encoding UTF8 $jsonPath | ConvertFrom-Json
            $passed = [int]$res.passed
            $failed = [int]$res.failed
            $failedChecks = @($res.checks | Where-Object { -not $_.ok } | ForEach-Object { $_.name })
            $suites.Add($res)
        }

        $ok = ($r.exit -eq 0 -and $failed -eq 0)
        $detail = if ($ok) { "$passed checks" } else { ("{0} failed: {1}" -f $failed, (($failedChecks | Select-Object -First 3) -join '; ')) }
        if (-not $ok -and -not (Test-Path $jsonPath)) { $detail = "no result file (exit=$($r.exit))" }
        Add-Stage ("suite:{0}" -f $name) $ok $detail ((Get-Date) - $t0).TotalSeconds
        if (-not $ok -and -not $Quiet) {
            ($r.stdout -split "`r?`n" | Where-Object { $_ -match 'FAIL|RUN|error' } | Select-Object -Last 10) | ForEach-Object { Write-Host "  $_" }
        }
        if (-not $ok) { $allOk = $false }
    }
    return $allOk
}

# ---- run -----------------------------------------------------------------
Say ("CI {0} stage={1} out={2}" -f $stamp, $Stage, $outDir) 'Cyan'

$staticOk = Invoke-StaticStage
$overall = $staticOk

if ($Stage -ne 'Static') {
    if (-not $staticOk) {
        Say 'static stage failed: skipping deploy + runtime (a broken build cannot be tested)' 'Yellow'
    }
    else {
        $deployOk = Invoke-DeployStage
        if (-not $deployOk) {
            $overall = $false
        }
        else {
            $runtimeOk = Invoke-RuntimeStage
            $overall = $overall -and $runtimeOk
        }
    }
}

# ---- summary -------------------------------------------------------------
$totalChecks = 0
$failedChecks = 0
foreach ($s in $suites) { $totalChecks += [int]$s.passed + [int]$s.failed; $failedChecks += [int]$s.failed }

$summary = [pscustomobject]@{
    stamp     = $stamp
    stage     = $Stage
    ok        = $overall
    repo      = $repo
    build     = if (Test-Path (Join-Path $repo 'build\cs2unified.smx')) {
                    [pscustomobject]@{
                        bytes  = (Get-Item (Join-Path $repo 'build\cs2unified.smx')).Length
                        sha256 = (Get-FileHash (Join-Path $repo 'build\cs2unified.smx') -Algorithm SHA256).Hash
                    }
                } else { $null }
    stages    = $stages
    suites    = $suites
    totals    = [pscustomobject]@{ runtime_checks = $totalChecks; runtime_failed = $failedChecks }
}
$summaryPath = Join-Path $outDir 'summary.json'
[System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

$md = New-Object System.Collections.Generic.List[string]
$md.Add('# CS2Unified CI run')
$md.Add('')
$md.Add(("- stamp: {0}" -f $stamp))
$md.Add(("- stage: {0}" -f $Stage))
$md.Add(("- verdict: **{0}**" -f $(if ($overall) { 'PASS' } else { 'FAIL' })))
if ($summary.build) { $md.Add(("- build: {0} bytes, sha256 {1}" -f $summary.build.bytes, $summary.build.sha256)) }
$md.Add('')
$md.Add('| stage | result | detail | seconds |')
$md.Add('|---|---|---|---:|')
foreach ($s in $stages) {
    $md.Add(("| {0} | {1} | {2} | {3:N1} |" -f $s.name, $(if ($s.ok) { 'PASS' } else { '**FAIL**' }), $s.detail, $s.seconds))
}
foreach ($s in $suites) {
    $md.Add('')
    $md.Add(("## {0} — {1}" -f $s.name, $(if ($s.ok) { 'PASS' } else { '**FAIL**' })))
    $md.Add('')
    $md.Add(("{0} passed / {1} failed — see [{2}.md]({2}.md)" -f $s.passed, $s.failed, $s.name))
}
$mdPath = Join-Path $outDir 'summary.md'
[System.IO.File]::WriteAllText($mdPath, (($md -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host ("CI {0}  static={1}  suites={2}/{3}  artifacts={4}" -f `
    $(if ($overall) { 'PASS' } else { 'FAIL' }),
    $(if ($staticOk) { 'ok' } else { 'fail' }),
    @($suites | Where-Object { $_.ok }).Count, $suites.Count, $outDir) `
    -ForegroundColor $(if ($overall) { 'Green' } else { 'Red' })

if ($overall) { exit 0 } else { exit 1 }
