<#
.SYNOPSIS
    Deploy CS2Unified to a Left 4 Dead 2 server with a per-run backup.

.DESCRIPTION
    Installs the merged plugin, both gamedata files, the cs2feel/cs2movement
    configs, the unified config (only if absent) and optionally the VScript data
    layer VPK.

    Legacy cs2feel_core.smx / cs2movement.smx are moved to plugins/disabled/ by
    default: the merged plugin registers the same ConVars and commands, so
    loading both would duplicate them.

    Every file that is overwritten is copied to
    <project>\_backup\<timestamp>\<relative path> first, and
    <timestamp>\install-manifest.csv records enough to undo the whole run
    (tools/uninstall.ps1 -Apply).

.PARAMETER DryRun
    Print the plan and the manifest without touching the server.

.PARAMETER KeepLegacy
    Do not disable the two upstream plugins. Not recommended: duplicate ConVars
    and command registrations will be logged.

.PARAMETER DisableProbes
    Also disable cs2f_mv3.smx / cs2f_aimdebug.smx (test-only probes) during the
    deployment. They are restored by uninstall.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GameDir,
    [switch]$DryRun,
    [switch]$NoAddon,
    [switch]$KeepLegacy,
    [switch]$DisableProbes,
    [switch]$Build
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$L4D2 = Join-Path $GameDir 'left4dead2'
$SM   = Join-Path $L4D2 'addons\sourcemod'

if (-not (Test-Path (Join-Path $SM 'plugins'))) {
    throw "Not a sourcemod server: $SM"
}

if ($Build) {
    & (Join-Path $PSScriptRoot 'build.ps1')
}

$smx = Join-Path $ProjectRoot 'build\cs2unified.smx'
if (-not (Test-Path $smx)) {
    Write-Host 'build/cs2unified.smx missing, building first'
    & (Join-Path $PSScriptRoot 'build.ps1')
}

$stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $ProjectRoot ("_backup\{0}" -f $stamp)
$manifest   = New-Object System.Collections.Generic.List[object]

function Write-RunManifest {
    if ($DryRun) { return }
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    $manifest | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $backupRoot 'install-manifest.csv')
}

function Add-Manifest([string]$action, [string]$rel, [string]$backupRel, [long]$bytes, [string]$sha) {
    $manifest.Add([pscustomobject]@{
        action = $action; relpath = $rel; backup = $backupRel; bytes = $bytes; sha256 = $sha
    })
    # Write after every action: a deploy that dies mid-way must still leave an
    # undo record for the files it already touched.
    Write-RunManifest
}

function Backup-Destination([string]$dest) {
    if (-not (Test-Path $dest)) { return '' }
    $rel = $dest.Substring($L4D2.Length + 1)
    if ($DryRun) { return $rel }
    $target = Join-Path $backupRoot $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $dest -Destination $target -Force
    return $rel
}

function Install-File([string]$src, [string]$rel, [bool]$onlyIfMissing = $false) {
    if (-not (Test-Path $src)) {
        Write-Host ("SKIP  {0} (source missing; generated on first plugin start)" -f $rel) -ForegroundColor Yellow
        return
    }
    $dest = Join-Path $L4D2 $rel
    if ($onlyIfMissing -and (Test-Path $dest)) {
        Write-Host ("SKIP  {0} (already present, not overwritten)" -f $rel)
        return
    }
    $backupRel = Backup-Destination $dest
    $bytes = (Get-Item $src).Length
    $sha   = (Get-FileHash $src -Algorithm SHA256).Hash
    Write-Host ("COPY  {0} -> {1}" -f $src.Substring($ProjectRoot.Length + 1), $rel)
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dest -Force
    }
    Add-Manifest 'copy' $rel $backupRel $bytes $sha
}

function Disable-Plugin([string]$name) {
    $src = Join-Path $SM ("plugins\{0}" -f $name)
    $disabled = Join-Path $SM ("plugins\disabled\{0}" -f $name)
    $rel = "addons\sourcemod\plugins\$name"

    if (-not (Test-Path $src)) {
        if (Test-Path $disabled) {
            # Already disabled by an earlier deploy. Record it anyway so that an
            # uninstall of THIS backup re-enables the legacy plugin instead of
            # silently leaving the merged plugin as the only one.
            Write-Host ("ALREADY-DISABLED {0} (recorded for uninstall)" -f $rel)
            Add-Manifest 'disable' $rel '' (Get-Item $disabled).Length (Get-FileHash $disabled -Algorithm SHA256).Hash
        }
        return
    }

    $bytes = (Get-Item $src).Length
    $sha   = (Get-FileHash $src -Algorithm SHA256).Hash
    $backupRel = Backup-Destination $src
    Write-Host ("DISABLE {0} -> plugins/disabled/" -f $rel)
    if (-not $DryRun) {
        $disabledDir = Join-Path $SM 'plugins\disabled'
        New-Item -ItemType Directory -Force -Path $disabledDir | Out-Null
        Move-Item -LiteralPath $src -Destination $disabled -Force
    }
    Add-Manifest 'disable' $rel $backupRel $bytes $sha
}

# ---------------------------------------------------------------------------
Write-Host ("DEPLOY target={0} dryrun={1}" -f $L4D2, $DryRun.IsPresent)
Write-Host ("BACKUP {0}" -f $backupRoot)

Install-File $smx 'addons\sourcemod\plugins\cs2unified.smx'

foreach ($gd in @('l4d2_cs2feel.txt', 'cs2movement.txt')) {
    Install-File (Join-Path $ProjectRoot "gamedata\$gd") ("addons\sourcemod\gamedata\{0}" -f $gd)
}

$feelConfigs = Get-ChildItem (Join-Path $ProjectRoot 'configs\cs2feel') -Recurse -File
foreach ($f in $feelConfigs) {
    $relInside = $f.FullName.Substring((Join-Path $ProjectRoot 'configs\cs2feel').Length + 1)
    Install-File $f.FullName ("addons\sourcemod\configs\cs2feel\{0}" -f $relInside)
}

Install-File (Join-Path $ProjectRoot 'configs\cs2movement_weapons.cfg') 'addons\sourcemod\configs\cs2movement_weapons.cfg'
Install-File (Join-Path $ProjectRoot 'configs\cs2unified\cs2unified.cfg') 'addons\sourcemod\configs\cs2unified\cs2unified.cfg' $true
Install-File (Join-Path $ProjectRoot 'configs\cs2unified\menu.cfg') 'addons\sourcemod\configs\cs2unified\menu.cfg' $true
Install-File (Join-Path $ProjectRoot 'configs\cs2movement.cfg') 'cfg\sourcemod\cs2movement.cfg' $true

if (-not $NoAddon) {
    Install-File (Join-Path $ProjectRoot 'addon\cs2feel_r2_plugin.vpk') 'addons\cs2feel_r2_plugin.vpk'
} else {
    Write-Host 'SKIP  data layer VPK (-NoAddon)'
}

if (-not $KeepLegacy) {
    Disable-Plugin 'cs2feel_core.smx'
    Disable-Plugin 'cs2movement.smx'
} else {
    Write-Host 'WARN  -KeepLegacy: duplicate ConVars/commands will be logged' -ForegroundColor Yellow
}

if ($DisableProbes) {
    Disable-Plugin 'cs2f_mv3.smx'
    Disable-Plugin 'cs2f_aimdebug.smx'
}

# Default unified config (only used if the admin had none yet).
$defaultConfig = Join-Path $ProjectRoot 'configs\cs2unified\cs2unified.cfg'
if (-not (Test-Path $defaultConfig)) {
    Write-Host 'NOTE  configs/cs2unified/cs2unified.cfg is generated on first plugin start'
}

if (-not $DryRun) {
    Write-RunManifest

    # Project-level manifest: the union of every deploy, keeping the FIRST
    # backup seen for a path (that is the true pre-project state). A repeated
    # deploy must not overwrite the only undo record with a backup of the
    # previous deploy's own files.
    $projectManifest = Join-Path $ProjectRoot '_backup\project-manifest.csv'
    $merged = [ordered]@{}
    if (Test-Path $projectManifest) {
        Import-Csv -Path $projectManifest | ForEach-Object { $merged[$_.relpath] = $_ }
    }
    foreach ($row in $manifest) {
        if ($merged.Contains($row.relpath)) { continue }
        $clone = $row.PSObject.Copy()
        if ($row.backup) { $clone.backup = (Join-Path $backupRoot $row.backup) }
        $merged[$row.relpath] = $clone
    }
    $merged.Values | Sort-Object relpath | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $projectManifest
}

Write-Host ''
Write-Host ("PLAN {0} actions" -f $manifest.Count)
Write-Host 'Next: restart srcds, then from rcon/console run:'
Write-Host '  sm plugins list                     (expect cs2unified, no [FAILED], no duplicate-command errors)'
Write-Host '  sm_cs2u_status'
Write-Host '  sm_cs2u_presets'
Write-Host '  sm_cs2u_preset cs2_matched'
Write-Host '  sm_cs2u_save'
Write-Host '  sm_cs2u_reload'
Write-Host '  sm_cs2u_rollback'
