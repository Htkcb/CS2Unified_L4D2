<#
.SYNOPSIS
    Build a self-contained release package for a Left 4 Dead 2 server.

.DESCRIPTION
    Runs tools/verify.ps1 (unless -SkipVerify), then stages:

      <stage>/left4dead2/...        ready-to-copy server tree
      <stage>/build/configs/gamedata/addon/tools   for tools\deploy.ps1
      <stage>/docs, README.md, INSTALL.md, LICENSE, NOTICE

    and writes dist\CS2Unified_L4D2-v<version>-<date>.zip plus a .sha256.

    The package is a deployment bundle, not a source release: it contains the
    compiled smx, configs, gamedata, the VPK and the deploy/uninstall scripts.
#>
[CmdletBinding()]
param(
    # Empty = read CS2U_VERSION from src\cs2unified.sp.  A hardcoded default
    # here silently produced "v1.0.0" packages after every version bump (the
    # 1.0.12 run did exactly that), so the source is the only default now.
    [string]$Version = '',
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$DistRoot    = Join-Path $ProjectRoot 'dist'

if (-not $Version) {
    $entry = Get-Content -Raw -Encoding UTF8 (Join-Path $ProjectRoot 'src\cs2unified.sp')
    if ($entry -match '#define\s+CS2U_VERSION\s+"([^"]+)"') { $Version = $Matches[1] }
    if (-not $Version) { throw 'CS2U_VERSION not found in src/cs2unified.sp' }
}

$Stamp       = Get-Date -Format 'yyyyMMdd'
$Name        = "CS2Unified_L4D2-v$Version-$Stamp"
$Stage       = Join-Path $DistRoot $Name
$Zip         = Join-Path $DistRoot ("{0}.zip" -f $Name)

if (-not $SkipVerify) {
    & (Join-Path $PSScriptRoot 'verify.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'verify.ps1 failed; package not built' }
}

$smx = Join-Path $ProjectRoot 'build\cs2unified.smx'
if (-not (Test-Path $smx)) { throw 'build/cs2unified.smx missing; run tools/build.ps1' }

if (Test-Path $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Stage | Out-Null

# ---- staged server tree (manual install) ---------------------------------
$L = Join-Path $Stage 'left4dead2'
$sm = Join-Path $L 'addons\sourcemod'
New-Item -ItemType Directory -Force -Path (Join-Path $sm 'plugins'), (Join-Path $sm 'gamedata'),
    (Join-Path $sm 'configs\cs2feel'), (Join-Path $sm 'configs\cs2unified'),
    (Join-Path $L 'cfg\sourcemod'), (Join-Path $L 'addons') | Out-Null

Copy-Item $smx (Join-Path $sm 'plugins\cs2unified.smx') -Force
Copy-Item (Join-Path $ProjectRoot 'gamedata\*.txt') (Join-Path $sm 'gamedata') -Force
Copy-Item (Join-Path $ProjectRoot 'configs\cs2feel\*') (Join-Path $sm 'configs\cs2feel') -Recurse -Force
Copy-Item (Join-Path $ProjectRoot 'configs\cs2movement_weapons.cfg') (Join-Path $sm 'configs') -Force
Copy-Item (Join-Path $ProjectRoot 'configs\cs2unified\cs2unified.cfg') (Join-Path $sm 'configs\cs2unified') -Force
Copy-Item (Join-Path $ProjectRoot 'configs\cs2unified\menu.cfg') (Join-Path $sm 'configs\cs2unified') -Force
Copy-Item (Join-Path $ProjectRoot 'configs\cs2movement.cfg') (Join-Path $L 'cfg\sourcemod\cs2movement.cfg') -Force
Copy-Item (Join-Path $ProjectRoot 'addon\cs2feel_r2_plugin.vpk') (Join-Path $L 'addons') -Force

# ---- deploy-script layout ------------------------------------------------
foreach ($dir in 'build', 'configs', 'gamedata', 'addon', 'client') {
    Copy-Item (Join-Path $ProjectRoot $dir) (Join-Path $Stage $dir) -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $Stage 'tools') | Out-Null
foreach ($tool in 'deploy.ps1', 'uninstall.ps1', 'gen_menu_auth.ps1') {
    Copy-Item (Join-Path $ProjectRoot "tools\$tool") (Join-Path $Stage "tools\$tool") -Force
}

# ---- docs / license ------------------------------------------------------
Copy-Item (Join-Path $ProjectRoot 'docs') (Join-Path $Stage 'docs') -Recurse -Force
foreach ($f in 'README.md', 'LICENSE', 'NOTICE') {
    Copy-Item (Join-Path $ProjectRoot $f) (Join-Path $Stage $f) -Force
}

$install = Get-Content (Join-Path $PSScriptRoot 'INSTALL_TEMPLATE.md') -Raw -Encoding UTF8
[IO.File]::WriteAllText((Join-Path $Stage 'INSTALL.md'), $install, (New-Object System.Text.UTF8Encoding($false)))

New-Item -ItemType Directory -Force -Path $DistRoot | Out-Null
if (Test-Path $Zip) { Remove-Item $Zip -Force }
Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force

$zipHash = (Get-FileHash $Zip -Algorithm SHA256).Hash
Set-Content -Path ("{0}.sha256" -f $Zip) -Value ("{0}  {1}" -f $zipHash, (Split-Path -Leaf $Zip)) -Encoding ASCII

$count = (Get-ChildItem $Stage -Recurse -File | Measure-Object).Count
Write-Host ("PACKAGE {0}" -f $Zip)
Write-Host ("PACKAGE files={0} zip_bytes={1}" -f $count, (Get-Item $Zip).Length)
Write-Host ("PACKAGE sha256={0}" -f $zipHash)
