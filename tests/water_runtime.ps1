# Water-depth layer runtime suite (movement 0.5.3 / CS2Unified 1.0.10+).
#
# Starts the DS, asserts the water layer end to end, and writes BOTH
#   <OutDir>\water.md    (human evidence)
#   <OutDir>\water.json  (machine result for tools\ci.ps1)
#
# Exit code: 0 = every check passed, 1 = at least one failed, 2 = the server
# never came up.
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

$suite = New-TestSuite 'water' 'Water layer runtime suite'
Add-TestMeta $suite 'map' $Map
Add-TestMeta $suite 'expected version' $expected
Add-TestMeta $suite 'build' ('{0} bytes, sha256 {1}' -f `
    (Get-Item $smx).Length, (Get-FileHash $smx -Algorithm SHA256).Hash)

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

    # Deterministic precondition: the suite must not depend on what the last
    # manual session left behind.
    Invoke-Rcon @('sm_cs2u_set cs2movement_water_slowdown 0.35') | Out-Null

    # 1. load + interface
    $status = Invoke-Rcon @('sm_cs2u_status')
    Add-TestSection $suite '1. sm_cs2u_status' $status

    Add-TestCheck $suite 'plugin loaded at the expected version' `
        ($status -match ("CS2Unified {0}" -f [regex]::Escape($expected))) `
        ("expected=$expected")
    Add-TestCheck $suite 'managed_params=39' ($status -match 'managed_params=39')
    Add-TestCheck $suite 'water status line with the 0.35 curve' `
        ($status -match 'water: enable=1 slowdown=0\.3' -and $status -match 'ankle=0\.883' -and `
         $status -match 'waist=0\.766' -and $status -match 'eyes=0\.649')

    # 2. the layer itself
    $water = Invoke-Rcon @('sm_cs2movement_water')
    Add-TestSection $suite '2. sm_cs2movement_water' $water
    Add-TestCheck $suite 'water cvar on and enabled' ($water -match 'water=1 slowdown=0\.3' -and $water -match 'enabled=1')
    Add-TestCheck $suite 'AK reference row printed' ($water -match 'AK 215 -> 189 / 164 / 139')

    # 3. pure curve
    $curve = Invoke-Rcon @('sm_cs2movement_water 1', 'sm_cs2movement_water 2', 'sm_cs2movement_water 3')
    Add-TestSection $suite '3. curve per level' $curve
    Add-TestCheck $suite 'level 1 factor 0.8833' ($curve -match 'level=1 factor=0\.8833')
    Add-TestCheck $suite 'level 2 factor 0.7666' ($curve -match 'level=2 factor=0\.7666')
    Add-TestCheck $suite 'level 3 factor 0.6499' ($curve -match 'level=3 factor=0\.6499')

    # 4. live change + restore
    $live = Invoke-Rcon @('sm_cs2u_set cs2movement_water_slowdown 0.50', 'sm_cs2movement_water 2')
    Add-TestSection $suite '4. slowdown 0.50' $live
    Add-TestCheck $suite 'slowdown 0.50 is persisted' ($live -match 'cs2movement_water_slowdown = 0\.50 \(persisted\)')
    Add-TestCheck $suite 'level 2 factor follows to 0.6666' ($live -match 'level=2 factor=0\.6666')
    $restore = Invoke-Rcon @('sm_cs2u_set cs2movement_water_slowdown 0.35', 'sm_cs2movement_water')
    Add-TestCheck $suite 'restored to 0.35' ($restore -match 'ankle=0\.883')

    # 5. preset + menu
    $preset = Invoke-Rcon @('sm_cs2u_preset cs2_full')
    Add-TestSection $suite '5. preset cs2_full' $preset
    Add-TestCheck $suite 'preset applies all 39 values' ($preset -match 'Applied preset ''cs2_full'' \(39 parameters\)')

    $dump = Invoke-Rcon @('sm_cs2u_menudump')
    Add-TestSection $suite '6. menudump (move page)' `
        ((($dump -split "`n") | Where-Object { $_ -match 'ctx=move|水面减速|weapon_speeds|cyc:3[45]' }) -join "`n")
    Add-TestCheck $suite 'menu has the water group header' ($dump -match '水面减速')
    Add-TestCheck $suite 'menu has both water rows (cyc:34 / cyc:35)' `
        ($dump -match 'cyc:34' -and $dump -match 'cyc:35')

    # 6. engine gates + netprop
    $cvars = Invoke-Rcon @('sm_cvar cs2movement_engine_speed', 'sm_cvar cs2movement_weapon_speed_mode',
                           'sm_cvar cs2movement_water_enable', 'sm_cvar cs2movement_water_slowdown')
    Add-TestSection $suite '7. gates' $cvars
    Add-TestCheck $suite 'engine speed + weapon table are on' `
        ($cvars -match 'cs2movement_engine_speed": "1"' -and $cvars -match 'cs2movement_weapon_speed_mode": "1"')
    Add-TestCheck $suite 'water cvar is 1 and the slowdown is the shipped 0.35' `
        ($cvars -match 'cs2movement_water_enable": "1"' -and $cvars -match 'cs2movement_water_slowdown": "0\.350000"')

    Invoke-Rcon @('sm_dump_netprops cs2u_netprops.txt', 'sm_dump_datamaps cs2u_datamaps.txt') | Out-Null
    $np = Join-Path (Get-DsRoot) 'left4dead2\addons\sourcemod\cs2u_netprops.txt'
    if (-not (Test-Path $np)) { $np = Join-Path (Get-DsRoot) 'left4dead2\cs2u_netprops.txt' }
    $dm = $np -replace 'netprops', 'datamaps'

    $npHits = if (Test-Path $np) { (Select-String -Path $np -Pattern 'm_nWaterLevel' -SimpleMatch).Count } else { 0 }
    $dmHits = if (Test-Path $dm) { (Select-String -Path $dm -Pattern 'm_nWaterLevel' -SimpleMatch).Count } else { 0 }
    Add-TestSection $suite '8. prop tables' (
        ("netprops m_nWaterLevel: {0}`n" -f $npHits) +
        $(if (Test-Path $np) { ((Select-String -Path $np -Pattern 'm_nWaterLevel' -SimpleMatch | Select-Object -First 2 | ForEach-Object { $_.Line.Trim() }) -join "`n") } else { '(missing)' }) +
        ("`n`ndatamaps m_nWaterLevel: {0}`n" -f $dmHits) +
        $(if (Test-Path $dm) { ((Select-String -Path $dm -Pattern 'm_nWaterLevel' -SimpleMatch | Select-Object -First 2 | ForEach-Object { $_.Line.Trim() }) -join "`n") } else { '(missing)' }))
    Add-TestCheck $suite 'm_nWaterLevel exists on the networked table' ($npHits -gt 0) ("hits=$npHits")
    Add-TestCheck $suite 'm_nWaterLevel exists on the datamap' ($dmHits -gt 0) ("hits=$dmHits")

    # 7. clean log
    $smErr = @(Get-DsLogLines -Pattern '\[SM\] (Error|Failed)|Failed to load|Unknown command "sm_cs2' -Tail 600 -Last 10)
    Add-TestSection $suite '9. console.log (plugin + errors)' `
        ((Get-DsLogLines -Pattern 'CS2Unified|CS2Movement|WATER|\[SM\]' -Tail 800 -Last 30) -join "`n")
    Add-TestCheck $suite 'no SourceMod error during the run' ($smErr.Count -eq 0) (($smErr | Select-Object -First 3) -join ' | ')

    # 8. the human-only part must stay explicit
    Add-TestSection $suite '10. NOT covered by this suite' `
        ("真人进水：需要一名玩家走进水里看 sm_cs2movement_water 的 level/in_water/caps。" +
         "`n本套件只证明曲线、gate、持久化、菜单行与 prop 存在；不要把 caps=0 当成 PASS。")
}
catch {
    Add-TestCheck $suite ("suite ran to completion") $false $_.Exception.Message
}
finally {
    if ($proc) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Stop-DsServer
}

$result = Complete-TestSuite $suite $OutDir
if ($result.ok) { exit 0 } else { exit 1 }
