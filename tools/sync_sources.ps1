<#
.SYNOPSIS
    Sync the two upstream plugin source trees into src/, applying the namespace
    transform that lets both compile inside one .smx.

.DESCRIPTION
    Upstream projects (read-only inputs, never modified):
      * CS2FeelVScript_L4D2\plugin_src\*.sp      (cs2feel 0.5.7-m11)
      * CS2Movement_L4D2.public\scripting\*.sp   (cs2movement 0.5.2 + water)

    The transform is mechanical and idempotent: every run rewrites src/feel and
    src/movement from the upstream copies and re-applies the same ordered rename
    table. src/cs2unified.sp, src/cs2u_*.sp are hand-written and untouched.

    Local behaviour that upstream does not have lives in a patch layer:
    patches\movement_water\apply.ps1 is dot-sourced here and applied to the
    renamed movement text *before* it is written, and its new file
    (cs2movement_water.sp) is added to src\movement.  -Check therefore proves
    "upstream + rename table + patches", which is what is on disk.

    Why a transform instead of a manual copy: the mapping is auditable, the
    result is reproducible, and a future upstream bump only needs this script
    plus a compile/test pass. tools/verify.ps1 re-runs the transform in -Check
    mode to prove src/ still matches upstream + table.

.PARAMETER Check
    Do not write. Compare the transformed output with what is on disk and exit
    non-zero if they differ (used by verify.ps1 / CI).

.PARAMETER UpstreamRoot
    Root that contains CS2FeelVScript_L4D2 and CS2Movement_L4D2.
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [string]$UpstreamRoot
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is not reliably populated while param defaults are evaluated on
# Windows PowerShell 5.1, so resolve paths inside the body.
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($UpstreamRoot)) {
    $UpstreamRoot = Split-Path -Parent $ProjectRoot
}
$FeelUp      = Join-Path $UpstreamRoot 'CS2FeelVScript_L4D2\plugin_src'
# 0.4.6 lives in the public repo; the plain repo is still 0.4.5.
$MoveUp      = Join-Path $UpstreamRoot 'CS2Movement_L4D2.public\scripting'
$FeelOut     = Join-Path $ProjectRoot 'src\feel'
$MoveOut     = Join-Path $ProjectRoot 'src\movement'

foreach ($p in @($FeelUp, $MoveUp)) {
    if (-not (Test-Path $p)) { throw "Upstream source directory not found: $p" }
}

# ---------------------------------------------------------------------------
# Ordered rename table. Earlier entries win; keys must not be prefixes of each
# other unless the longer one is listed first (we use \b word matching, so the
# order below is safe but kept explicit for auditability).
# ---------------------------------------------------------------------------
$FeelRenames = [ordered]@{
    # plugin callbacks -> module entry points (dispatched by src/cs2unified.sp)
    'AskPluginLoad2'      = 'CS2F_AskPluginLoad2'
    'OnPluginStart'       = 'CS2F_OnPluginStart'
    'OnPluginEnd'         = 'CS2F_OnPluginEnd'
    'OnPlayerRunCmd'      = 'CS2F_OnPlayerRunCmd'
    'OnEnableChanged'     = 'CS2F_OnEnableChanged'
    # command callbacks
    'Cmd_Status'          = 'CS2F_Cmd_Status'
    'Cmd_Reload'          = 'CS2F_Cmd_Reload'
    'Cmd_Verify'          = 'CS2F_Cmd_Verify'
    'Cmd_SpreadTest'      = 'CS2F_Cmd_SpreadTest'
    'Cmd_RecoilTest'      = 'CS2F_Cmd_RecoilTest'
    'Cmd_BallisticsTest'  = 'CS2F_Cmd_BallisticsTest'
    # helpers / globals that collide with cs2movement
    'CreateConVars'       = 'CS2F_CreateConVars'
    'g_cvEnable'          = 'g_cvCS2FEnable'
    'g_cvDebug'           = 'g_cvCS2FDebug'
}

$MoveRenames = [ordered]@{
    'OnPluginStart'       = 'CS2M_OnPluginStart'
    'OnConfigsExecuted'   = 'CS2M_OnConfigsExecuted'
    'OnPluginEnd'         = 'CS2M_OnPluginEnd'
    'OnPlayerRunCmd'      = 'CS2M_OnPlayerRunCmd'
    'OnPostThink'         = 'CS2M_OnPostThink'
    'OnClientPutInServer' = 'CS2M_OnClientPutInServer'
    'OnClientDisconnect'  = 'CS2M_OnClientDisconnect'
    'OnEnableChanged'     = 'CS2M_OnEnableChanged'
    'OnApplyGlobalChanged'= 'CS2M_OnApplyGlobalChanged'
    'OnMoveTargetChanged' = 'CS2M_OnMoveTargetChanged'
    'Event_PlayerJump'    = 'CS2M_Event_PlayerJump'
    'Cmd_Status'          = 'CS2M_Cmd_Status'
    'Cmd_Reload'          = 'CS2M_Cmd_Reload'
    'Cmd_Apply'           = 'CS2M_Cmd_Apply'
    'Cmd_Unapply'         = 'CS2M_Cmd_Unapply'
    'Cmd_SelfTest'        = 'CS2M_Cmd_SelfTest'
    'CreateConVars'       = 'CS2M_CreateConVars'
    'g_cvEnable'          = 'g_cvCS2MEnable'
    'g_cvDebug'           = 'g_cvCS2MDebug'
}

function Convert-Module {
    param([string]$Text, [System.Collections.Specialized.OrderedDictionary]$Renames, [string]$Tag)

    # Drop the per-module Plugin myinfo block; the merged plugin has exactly one.
    $Text = [regex]::Replace($Text, '(?s)public\s+Plugin\s+myinfo\s*=.*?\};',
        "/* [CS2Unified] Plugin myinfo removed by tools/sync_sources.ps1 ($Tag); the merged core owns it. */")

    foreach ($k in $Renames.Keys) {
        $pattern = '\b' + [regex]::Escape($k) + '\b'
        $Text = [regex]::Replace($Text, $pattern, $Renames[$k])
    }
    return $Text
}

$plan = @()
foreach ($f in Get-ChildItem $FeelUp -Filter *.sp) {
    $plan += [pscustomobject]@{
        Source = $f.FullName
        Target = Join-Path $FeelOut $f.Name
        Text   = Convert-Module -Text (Get-Content -Raw -Encoding UTF8 $f.FullName) -Renames $FeelRenames -Tag 'feel'
    }
}
foreach ($f in Get-ChildItem $MoveUp -Filter *.sp) {
    $plan += [pscustomobject]@{
        Source = $f.FullName
        Target = Join-Path $MoveOut $f.Name
        Text   = Convert-Module -Text (Get-Content -Raw -Encoding UTF8 $f.FullName) -Renames $MoveRenames -Tag 'movement'
    }
}

# ---------------------------------------------------------------------------
# Local patch layer: src/movement = upstream + rename table + patches.  The
# same transform must run in -Check mode, otherwise verify.ps1 could not prove
# the patch is present.
# ---------------------------------------------------------------------------
$PatchDir  = Join-Path $ProjectRoot 'patches\movement_water'
$PatchMain = Join-Path $PatchDir 'apply.ps1'
if (-not (Test-Path $PatchMain)) { throw "patch layer not found: $PatchMain" }
. $PatchMain

foreach ($item in $plan) {
    if ((Split-Path -Leaf (Split-Path -Parent $item.Target)) -ne 'movement') { continue }
    $item.Text = Get-MovementWaterFileText -FileName (Split-Path -Leaf $item.Target) -Text $item.Text
}
foreach ($extra in (Get-MovementWaterExtraFiles -PatchDir $PatchDir)) {
    $plan += [pscustomobject]@{
        Source = $extra.Path
        Target = Join-Path $MoveOut $extra.Name
        Text   = $extra.Text
    }
}

$drift = @()
foreach ($item in $plan) {
    $current = if (Test-Path $item.Target) { Get-Content -Raw -Encoding UTF8 $item.Target } else { $null }
    if ($current -ne $item.Text) { $drift += $item.Target }
}

if ($Check) {
    if ($drift.Count -gt 0) {
        Write-Host "DRIFT: src/ is not a faithful transform of upstream:" -ForegroundColor Red
        $drift | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        exit 1
    }
    Write-Host ("SYNC-OK {0} files match upstream + rename table + patches" -f $plan.Count)
    exit 0
}

New-Item -ItemType Directory -Force -Path $FeelOut, $MoveOut | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
foreach ($item in $plan) {
    [System.IO.File]::WriteAllText($item.Target, $item.Text, $utf8NoBom)
}

Write-Host ("SYNC-DONE {0} files rewritten" -f $plan.Count)
Write-Host ("  feel     : {0} files from {1}" -f (Get-ChildItem $FeelUp -Filter *.sp).Count, $FeelUp)
Write-Host ("  movement : {0} files from {1}" -f (Get-ChildItem $MoveUp -Filter *.sp).Count, $MoveUp)
Write-Host ("  patches  : movement_water ({0} new file(s) from {1})" -f @(Get-MovementWaterExtraFiles -PatchDir $PatchDir).Count, $PatchDir)
Write-Host ("  renames  : feel={0} movement={1}" -f $FeelRenames.Count, $MoveRenames.Count)
