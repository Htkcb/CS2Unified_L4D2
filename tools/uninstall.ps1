<#
.SYNOPSIS
    Undo a tools/deploy.ps1 run (or roll the installed plugin back to the
    pre-deploy state) using that run's manifest and backups.

.DESCRIPTION
    Default is DRY-RUN. Pass -Apply to mutate the server.

    For every manifest row:
      action=copy     delete the installed file, then restore the backup (if the
                      file existed before the deployment)
      action=disable  move plugins/disabled/<name> back to plugins/<name>

    The manifest is written by deploy.ps1 as
    <project>\_backup\<timestamp>\install-manifest.csv. Without -BackupDir the
    newest backup directory is used.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GameDir,
    [switch]$Apply,
    [string]$BackupDir
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$L4D2 = Join-Path $GameDir 'left4dead2'
$SM   = Join-Path $L4D2 'addons\sourcemod'

if (-not (Test-Path $SM)) { throw "Not a sourcemod server: $SM" }
$projectManifest = Join-Path $ProjectRoot '_backup\project-manifest.csv'
if (-not $BackupDir) {
    if (Test-Path $projectManifest) {
        # Preferred source: it keeps the true pre-project backup for each path
        # across repeated deploys (see deploy.ps1).
        $manifestPath = $projectManifest
        $BackupDir = Split-Path -Parent $projectManifest
    } else {
        $root = Join-Path $ProjectRoot '_backup'
        if (-not (Test-Path $root)) { throw "No backups found under $root" }
        $BackupDir = (Get-ChildItem $root -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
        $manifestPath = Join-Path $BackupDir 'install-manifest.csv'
    }
} else {
    $manifestPath = Join-Path $BackupDir 'install-manifest.csv'
}
if (-not (Test-Path $manifestPath)) { throw "Missing manifest: $manifestPath" }

$rows = Import-Csv -Path $manifestPath
Write-Host ("UNINSTALL manifest={0}" -f $manifestPath)
Write-Host ("UNINSTALL target={0} apply={1}" -f $L4D2, $Apply.IsPresent)

foreach ($row in $rows) {
    $dest = Join-Path $L4D2 $row.relpath
    if (-not $row.backup) {
        $backupFile = $null
    } elseif ([IO.Path]::IsPathRooted($row.backup)) {
        $backupFile = $row.backup
    } else {
        $backupFile = Join-Path $BackupDir $row.backup
    }

    switch ($row.action) {
        'copy' {
            Write-Host ("REMOVE  {0}" -f $row.relpath)
            if ($Apply -and (Test-Path $dest)) { Remove-Item -LiteralPath $dest -Force }
            if ($backupFile -and (Test-Path $backupFile)) {
                Write-Host ("RESTORE {0}" -f $row.backup)
                if ($Apply) {
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
                    Copy-Item -LiteralPath $backupFile -Destination $dest -Force
                }
            }
        }
        'disable' {
            $name = Split-Path -Leaf $row.relpath
            $disabled = Join-Path $SM ("plugins\disabled\{0}" -f $name)
            if (Test-Path $disabled) {
                Write-Host ("REENABLE {0}" -f $row.relpath)
                if ($Apply) { Move-Item -LiteralPath $disabled -Destination $dest -Force }
            } elseif ($backupFile -and (Test-Path $backupFile)) {
                Write-Host ("RESTORE  {0}" -f $row.relpath)
                if ($Apply) { Copy-Item -LiteralPath $backupFile -Destination $dest -Force }
            } else {
                Write-Host ("WARN    cannot re-enable {0}" -f $row.relpath) -ForegroundColor Yellow
            }
        }
        default {
            Write-Host ("WARN    unknown action '{0}' for {1}" -f $row.action, $row.relpath) -ForegroundColor Yellow
        }
    }
}

Write-Host ''
# Project-owned config directory: remove it only when the leftovers are exactly
# the files CS2Unified creates (config + its .bak), so an admin's custom file is
# never deleted.
$projectConfigDir = Join-Path $SM 'configs\cs2unified'
if (Test-Path $projectConfigDir) {
    $ownedNames = @('cs2unified.cfg', 'cs2unified.cfg.bak')
    $foreign = @(Get-ChildItem $projectConfigDir -Force | Where-Object {
        $_.PSIsContainer -or ($ownedNames -notcontains $_.Name)
    })
    if ($foreign.Count -eq 0) {
        Write-Host 'REMOVE  addons\sourcemod\configs\cs2unified (project-owned)'
        if ($Apply) { Remove-Item $projectConfigDir -Recurse -Force }
    } else {
        Write-Host 'KEEP    addons\sourcemod\configs\cs2unified (contains files not owned by CS2Unified)'
    }
}

if ($Apply) {
    Write-Host ("UNINSTALL DONE ({0} rows). Restart srcds to reload the previous plugin set." -f $rows.Count)
} else {
    Write-Host ("DRY-RUN ({0} rows). Re-run with -Apply to perform the rollback." -f $rows.Count)
}
