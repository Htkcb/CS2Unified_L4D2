# Per-weapon speed table runtime suite (CS2Unified 1.0.11+).
#
# Proves the loop the menu offers: list -> edit -> live value -> file on disk ->
# reload from disk (no revert) -> rejects bad input -> reset.
#
# Writes <OutDir>\weapons.md and <OutDir>\weapons.json.
# Exit code: 0 = all checks passed, 1 = a check failed, 2 = server never came up.
param(
    [string]$Map = 'c5m1_waterfront',
    [string]$OutDir,
    [switch]$Force,
    [int]$StartTimeoutSec = 150
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\ds_harness.ps1')

$repo = Get-RepoRoot
if (-not $OutDir) { $OutDir = Join-Path $repo 'tests\results' }

if ($Force) { Stop-DsServer } else { Assert-DsIdle }

$expected = Get-Cs2uVersion
$smx = Join-Path $repo 'build\cs2unified.smx'
if (-not (Test-Path $smx)) { throw "build\cs2unified.smx missing; run tools\build.ps1" }

$cfgPath = Join-Path (Get-DsRoot) 'left4dead2\addons\sourcemod\configs\cs2movement_weapons.cfg'

# Read the speed for one class straight out of the file the movement layer reads.
# Asserting on the file (not only on the plugin's echo) is the point: it is what
# survives a map change.
function Get-CfgWeaponSpeed([string]$Class) {
    if (-not (Test-Path $cfgPath)) { return $null }
    $lines = Get-Content $cfgPath
    $pattern = '^\s*"' + [regex]::Escape($Class) + '"\s*$'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) {
            for ($j = $i + 1; $j -lt [Math]::Min($lines.Count, $i + 4); $j++) {
                if ($lines[$j] -match '"speed"\s+"([0-9.]+)"') { return [double]$Matches[1] }
            }
        }
    }
    return $null
}

# Whole table as class -> speed.  Used to compare the DS file against the shipped
# copy by value: the plugin rewrites the header comment, so bytes can differ.
function Get-CfgSpeedMap([string]$Path) {
    $map = @{}
    if (-not (Test-Path $Path)) { return $map }
    $lines = Get-Content $Path
    $current = $null
    foreach ($line in $lines) {
        if ($line -match '^\s*"(weapon_[a-z0-9_]+)"\s*$') {
            $current = $Matches[1]
            continue
        }
        if ($current -and $line -match '"speed"\s+"([0-9.]+)"') {
            $map[$current] = [double]$Matches[1]
            $current = $null
        }
    }
    return $map
}

$suite = New-TestSuite 'weapons' 'Per-weapon speed table runtime suite'
Add-TestMeta $suite 'map' $Map
Add-TestMeta $suite 'expected version' $expected
Add-TestMeta $suite 'build' ('{0} bytes, sha256 {1}' -f `
    (Get-Item $smx).Length, (Get-FileHash $smx -Algorithm SHA256).Hash)
Add-TestMeta $suite 'weapon cfg' $cfgPath

$proc = $null
try {
    $proc = Start-DsServer -Map $Map
    Write-Host ("srcds pid={0}" -f $proc.Id)

    if (-not (Wait-DsReady -TimeoutSec $StartTimeoutSec)) {
        Add-TestCheck $suite 'server answers RCON within the timeout' $false ("{0} s" -f $StartTimeoutSec)
        $result = Complete-TestSuite $suite $OutDir
        Stop-DsServer
        exit 2
    }
    Add-TestCheck $suite 'server answers RCON within the timeout' $true ''

    # Deterministic precondition: whatever a previous session changed is undone.
    Invoke-Rcon @('sm_cs2u_weapons reset') | Out-Null

    # 1. version + table listing
    $status = Invoke-Rcon @('sm_cs2u_status')
    Add-TestCheck $suite 'plugin loaded at the expected version' `
        ($status -match ("CS2Unified {0}" -f [regex]::Escape($expected))) ("expected=$expected")
    Add-TestCheck $suite 'managed_params=39 (weapon table is not a managed param)' ($status -match 'managed_params=39')

    $list = Invoke-Rcon @('sm_cs2u_weapons')
    Add-TestSection $suite '1. sm_cs2u_weapons (as shipped)' $list
    $rows = ([regex]::Matches($list, '(?m)^\[CS2Unified\]\s+\d+\.\s+weapon_')).Count
    Add-TestCheck $suite 'lists all 18 weapons' ($rows -eq 18) ("rows=$rows")
    Add-TestCheck $suite 'shipped values are intact after the precondition reset' `
        ($list -match 'weapon_rifle_sg552\s+SG552\s+225' -and $list -match 'weapon_melee\s+近战武器\s+250')

    # 2. edit by index
    $edit = Invoke-Rcon @('sm_cs2u_weapons 3 200', 'sm_cs2u_weapons 3')
    Add-TestSection $suite '2. set weapon 3 (weapon_rifle_sg552) to 200' $edit
    Add-TestCheck $suite 'edit reported as written' ($edit -match 'SG552（weapon_rifle_sg552）= 200 u/s，已写盘')
    Add-TestCheck $suite 'read-back is 200' ($edit -match '3 weapon_rifle_sg552（SG552）= 200 u/s')

    # 3. on disk
    $fromFile = Get-CfgWeaponSpeed 'weapon_rifle_sg552'
    Add-TestCheck $suite 'value is in cs2movement_weapons.cfg' `
        ($null -ne $fromFile -and [math]::Abs($fromFile - 200) -lt 0.01) ("file={0}" -f $fromFile)

    # 4. reload from disk -- this is the "must not revert" case
    $reload = Invoke-Rcon @('sm_cs2movement_reload', 'sm_cs2u_weapons 3')
    Add-TestSection $suite '3. reload the table from disk' $reload
    Add-TestCheck $suite 'table reloaded 18 entries' ($reload -match 'WEAPON-TABLE loaded=18')
    Add-TestCheck $suite 'value survived the reload (no revert)' ($reload -match '3 weapon_rifle_sg552（SG552）= 200 u/s')

    # 5. edit by class name + rejections
    $byName = Invoke-Rcon @('sm_cs2u_weapons weapon_melee 260', 'sm_cs2u_weapons weapon_melee')
    Add-TestSection $suite '4. set by class name' $byName
    Add-TestCheck $suite 'class-name edit applied' ($byName -match '近战武器（weapon_melee）= 260 u/s，已写盘')
    Add-TestCheck $suite 'class-name read-back is 260' ($byName -match '16 weapon_melee（近战武器）= 260 u/s')

    $bad = Invoke-Rcon @('sm_cs2u_weapons weapon_melee 2000', 'sm_cs2u_weapons nonsense 100')
    Add-TestSection $suite '5. rejected inputs' $bad
    Add-TestCheck $suite 'out-of-range value is rejected' ($bad -match '超出范围 50–1000 u/s')
    Add-TestCheck $suite 'unknown weapon class is rejected' ($bad -match "未知武器 'nonsense'")
    Add-TestCheck $suite 'rejected value did not reach the file' `
        ((Get-CfgWeaponSpeed 'weapon_melee') -eq 260) ("file={0}" -f (Get-CfgWeaponSpeed 'weapon_melee'))
    $badLogs = @(Get-DsLogLines -Pattern 'weapon-speed' -Tail 800 -Last 20 | Where-Object { $_ -match 'value=2000' })
    Add-TestCheck $suite 'rejected value is not logged as an applied edit' ($badLogs.Count -eq 0)

    # 6. menu page
    $dump = Invoke-Rcon @('sm_cs2u_menudump')
    Add-TestSection $suite '6. menudump (weapon page)' `
        ((($dump -split "`n") | Where-Object { $_ -match 'ctx=weapons|wpn:|weapon_speeds' }) -join "`n")
    Add-TestCheck $suite 'move page exposes the entry row' ($dump -match 'act:weapon_speeds')
    Add-TestCheck $suite 'weapon page is dumped as its own context' ($dump -match 'ctx=weapons pages=3 rows=21')
    $wpnRows = ([regex]::Matches($dump, '(?m)^\[MENU-DUMP\]\s+wpn:\d+')).Count
    Add-TestCheck $suite 'weapon page has 18 value rows' ($wpnRows -eq 18) ("rows=$wpnRows")
    Add-TestCheck $suite 'weapon page ends with the reset row' ($dump -match 'wpn:reset')

    # 7. reset
    $reset = Invoke-Rcon @('sm_cs2u_weapons reset', 'sm_cs2u_weapons 3', 'sm_cs2u_weapons weapon_melee')
    Add-TestSection $suite '7. reset to the shipped defaults' $reset
    Add-TestCheck $suite 'reset reports the 18 defaults' ($reset -match '已恢复 18 件武器的默认速度并写盘')
    Add-TestCheck $suite 'SG552 back to 225' ($reset -match '3 weapon_rifle_sg552（SG552）= 225 u/s')
    Add-TestCheck $suite 'melee back to 250' ($reset -match '16 weapon_melee（近战武器）= 250 u/s')
    Add-TestCheck $suite 'file is back to the shipped table' `
        ((Get-CfgWeaponSpeed 'weapon_rifle_sg552') -eq 225 -and (Get-CfgWeaponSpeed 'weapon_melee') -eq 250)

    # Value-wise, not byte-wise: the plugin rewrites the file with its own header
    # comment, so the bytes differ from the shipped copy by design.  What must
    # match is the 18 class -> speed pairs.
    $dsMap = Get-CfgSpeedMap $cfgPath
    $repoMap = Get-CfgSpeedMap (Join-Path $repo 'configs\cs2movement_weapons.cfg')
    $sameValues = ($dsMap.Count -eq $repoMap.Count -and $repoMap.Count -eq 18)
    if ($sameValues) {
        foreach ($k in $repoMap.Keys) {
            if (-not $dsMap.ContainsKey($k) -or [math]::Abs($dsMap[$k] - $repoMap[$k]) -gt 0.01) { $sameValues = $false; break }
        }
    }
    Add-TestCheck $suite 'shipped table values match the repo copy (18 classes)' $sameValues `
        ("ds={0} repo={1}" -f $dsMap.Count, $repoMap.Count)

    $smErr = @(Get-DsLogLines -Pattern '\[SM\] (Error|Failed)|Failed to load' -Tail 600 -Last 10)
    Add-TestSection $suite '8. console.log (plugin + errors)' `
        ((Get-DsLogLines -Pattern 'CS2Unified|CS2Movement|weapon-speed|\[SM\]' -Tail 800 -Last 30) -join "`n")
    Add-TestCheck $suite 'no SourceMod error during the run' ($smErr.Count -eq 0) (($smErr | Select-Object -First 3) -join ' | ')

    Add-TestSection $suite '9. NOT covered by this suite' `
        ("真人点行 -> 聊天栏输入 -> 页面自动重开的交互（需要客户端）。" +
         "`n本套件走的是同一套 CS2U_WeaponSet / 写盘 / 重载路径的控制台入口。")
}
catch {
    Add-TestCheck $suite ("suite ran to completion") $false $_.Exception.Message
}
finally {
    # Leave the DS table at the shipped defaults even when an assertion failed
    # mid-run: the next suite (or a human) must not inherit a test value.
    try { Invoke-Rcon @('sm_cs2u_weapons reset') | Out-Null } catch { }
    if ($proc) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Stop-DsServer
}

$result = Complete-TestSuite $suite $OutDir
if ($result.ok) { exit 0 } else { exit 1 }
