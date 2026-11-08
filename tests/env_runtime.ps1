# Environment adaptation runtime suite (CS2Unified 1.0.12+).
#
# Proves the loop the menu offers, over the same command surface:
#   probe -> preview (nothing changes) -> apply (only the previewed items, and
#   persisted) -> idempotent second pass -> undo (exact restore) -> clear.
#
# Two phases, two entry points (one implementation):
#   -Phase A   (default)  64 Hz, tick enhancers on        -> tests\env_runtime.ps1
#   -Phase B              30 Hz, tick enhancers parked    -> tests\env30_runtime.ps1
#   -Phase Both           both in one run
#
# Why the 30 Hz leg is a separate entry point: on this rig a 30 Hz boot
# intermittently stalls inside Host_NewGame for minutes (the RCON listener is
# closed while the engine maps; measured 2026-11-07, reproduced with the plugin
# disabled as well). That is a property of this machine, not of the feature, so
# it must not be able to redden the gate that protects the feature. Phase B is
# still fully asserted and still runs in CI on demand (`ci.ps1 -Only env30`).
#
# Value reads go through sm_cs2u_status, not `sm_cvar`: this build's RCON path
# returns the plugin's PrintToServer lines but not sm_cvar's console echo, and a
# test that silently reads $null would "pass" for the wrong reason.
param(
    [ValidateSet('A', 'B', 'Both')]
    [string]$Phase = 'A',
    [string]$SuiteName,
    [string]$Map = 'c5m1_waterfront',
    [string]$OutDir,
    [switch]$Force,
    [int]$StartTimeoutSec = 240
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\ds_harness.ps1')

$repo = Get-RepoRoot
if (-not $OutDir) { $OutDir = Join-Path $repo 'tests\results' }
if (-not $SuiteName) {
    $SuiteName = if ($Phase -eq 'B') { 'env30' } else { 'env' }
}

if ($Force) { Stop-DsServer } else { Assert-DsIdle }

$expected = Get-Cs2uVersion
$smx = Join-Path $repo 'build\cs2unified.smx'
if (-not (Test-Path $smx)) { throw "build\cs2unified.smx missing; run tools\build.ps1" }

$cfgPath = Join-Path (Get-DsRoot) 'left4dead2\addons\sourcemod\configs\cs2unified\cs2unified.cfg'
$profileCvar = 'cs2feel_spread_tick_profile'

# All three live values are visible in one status block:
#   env: hz=.. profile_cvar=N ..
#   movement: .. air_jump=N sustain=N ..
function Get-StatusField([string]$Pattern) {
    $text = Invoke-Rcon @('sm_cs2u_status')
    if ($text -match $Pattern) { return $Matches[1] }
    return $null
}

function Get-ProfileCvar { return (Get-StatusField 'env: hz=[0-9.]+ dedicated=\d+ maxplayers=\d+ band=\d+ profile_cvar=(\d+)') }
function Get-AirJump     { return (Get-StatusField 'air_jump=(\d+)') }
function Get-Sustain     { return (Get-StatusField 'sustain=(\d+)') }

function Get-CfgText {
    if (-not (Test-Path $cfgPath)) { return '' }
    return (Get-Content -Raw -Encoding UTF8 $cfgPath)
}

# The env section is a KeyValues block; asserting on the file (not only on the
# plugin's echo) is what proves "survives a map change / restart".
function Test-CfgEnv([string]$Key) { return ((Get-CfgText) -match ('"' + $Key + '"')) }

function Get-ApplyCount { return @(Get-SmLogLines -Pattern 'ACTION env-apply').Count }

$title = switch ($Phase) {
    'A'    { 'Environment adaptation runtime suite (64 Hz)' }
    'B'    { 'Environment adaptation runtime suite (30 Hz leg)' }
    default { 'Environment adaptation runtime suite (64 Hz + 30 Hz)' }
}
$suite = New-TestSuite $SuiteName $title
Add-TestMeta $suite 'phase' $Phase
Add-TestMeta $suite 'map' $Map
Add-TestMeta $suite 'expected version' $expected
Add-TestMeta $suite 'build' ('{0} bytes, sha256 {1}' -f `
    (Get-Item $smx).Length, (Get-FileHash $smx -Algorithm SHA256).Hash)
Add-TestMeta $suite 'config' $cfgPath
Add-TestMeta $suite 'note' 'A = 64 Hz (tick enhancers on), B = 30 Hz (l4dtoolz/tickrate_enabler parked)'

$proc = $null
try {
    # ---- phase A: 64 Hz ------------------------------------------------------
    if ($Phase -ne 'B') {
        $proc = Start-DsServer -Map $Map -Tickrate 64
        Write-Host ("phase A srcds pid={0} tickrate=64" -f $proc.Id)

        if (-not (Wait-DsReady -TimeoutSec $StartTimeoutSec)) {
            Add-TestCheck $suite 'phase A: server answers RCON within the timeout' $false ("{0} s" -f $StartTimeoutSec)
            $result = Complete-TestSuite $suite $OutDir
            Stop-DsServer
            exit 2
        }
        Add-TestCheck $suite 'phase A: server answers RCON within the timeout' $true ''

        # Deterministic precondition: profile off, the two 64-only opt-ins on.
        # Off is the shipped default for the profile and it is NOT persisted, so
        # this leaves the config untouched.
        Invoke-Rcon @("sm_cvar $profileCvar 0") | Out-Null
        Invoke-Rcon @('sm_cs2u_set cs2movement_air_jump_speed 1',
                      'sm_cs2u_set cs2movement_lowspeed_sustain 1') | Out-Null
        Invoke-Rcon @('sm_cs2u_env clear') | Out-Null

        # 1. version + probe
        $status = Invoke-Rcon @('sm_cs2u_status')
        # Recorded, not asserted: the team-gate / shared-physics lines are the
        # runtime side of the 1.0.13 per-team contract (docs/06 L26).
        Add-TestSection $suite '0. sm_cs2u_status (team gate + global physics)' $status
        Add-TestCheck $suite 'plugin loaded at the expected version' `
            ($status -match ("CS2Unified {0}" -f [regex]::Escape($expected))) ("expected=$expected")
        Add-TestCheck $suite 'status reports the measured 64 Hz and band=64' `
            ($status -match 'env: hz=6[34]\.\d+ dedicated=1 .*band=64') `
            ((($status -split "`n") | Where-Object { $_ -match 'env: hz=' }) -join ' ')

        $detail = Invoke-Rcon @('sm_cs2u_env')
        Add-TestSection $suite '1. sm_cs2u_env (probe block)' $detail
        Add-TestCheck $suite 'probe prints the hz with its source' ($detail -match '实测 1/GetTickInterval\(\)')
        Add-TestCheck $suite 'probe names the server form and its source' ($detail -match 'IsDedicatedServer')
        Add-TestCheck $suite 'tick enhancer is stated as an inference' `
            ($detail -match '推断 L4DToolZ / tickrate_enabler 生效')
        Add-TestCheck $suite 'probe resolves the 64 Hz calibration band' ($detail -match '标定档: 64 Hz')
        Add-TestCheck $suite 'probe recommends the forced-64 profile' `
            ($detail -match 'spread 建议: 强制 64（4）')
        Add-TestCheck $suite 'rate advice is printed but marked as never written' `
            ($detail -match '本插件从不写')
        Add-TestCheck $suite 'plan lists exactly the profile change at 64 Hz' `
            ($detail -match '将改 1 项' -and `
             $detail -match 'cs2feel_spread_tick_profile 关（0） → 强制 64（4）') `
            ((($detail -split "`n") | Where-Object { $_ -match '将改|\)\s' }) -join ' ')

        # 2. apply without a preview is refused (E-3)
        $noPreview = Invoke-Rcon @('sm_cs2u_env apply')
        Add-TestSection $suite '2. apply before preview' $noPreview
        Add-TestCheck $suite 'apply before preview is refused' `
            ($noPreview -match 'Apply refused: 请先预览')
        Add-TestCheck $suite 'refused apply changed nothing' ((Get-ProfileCvar) -eq '0') `
            ("profile={0}" -f (Get-ProfileCvar))

        # 3. preview changes nothing (E-3)
        $preview = Invoke-Rcon @('sm_cs2u_env preview')
        Add-TestSection $suite '3. preview' $preview
        Add-TestCheck $suite 'preview shows the old -> new diff' `
            ($preview -match '关（0） → 强制 64（4）')
        Add-TestCheck $suite 'preview itself does not touch the cvar' ((Get-ProfileCvar) -eq '0') `
            ("profile={0}" -f (Get-ProfileCvar))
        Add-TestCheck $suite 'preview does not write the env section' (-not (Test-CfgEnv 'spread_tick_profile'))

        # 4. apply (E-4)
        $applyBefore = Get-ApplyCount
        $apply = Invoke-Rcon @('sm_cs2u_env apply')
        $applyAfter = Get-ApplyCount
        Add-TestSection $suite '4. apply' $apply
        Add-TestCheck $suite 'apply reports the adaptation' ($apply -match '已适配 64 Hz')
        Add-TestCheck $suite 'apply recorded exactly one ACTION entry' `
            ($applyAfter -eq $applyBefore + 1) ("before={0} after={1}" -f $applyBefore, $applyAfter)
        Add-TestCheck $suite 'profile cvar is now 4 (forced 64)' ((Get-ProfileCvar) -eq '4') `
            ("value={0}" -f (Get-ProfileCvar))
        Add-TestCheck $suite 'env section is on disk with profile 4 and the adapted hz' `
            ((Test-CfgEnv 'spread_tick_profile') -and (Test-CfgEnv 'adapted_hz') -and `
             ((Get-CfgText) -match 'spread_tick_profile"\s*"4"'))
        Add-TestCheck $suite 'the 39 managed values are still written by the same file' `
            ((Get-CfgText) -match '"cs2movement_air_jump_speed"')

        # 5. idempotent (E-7)
        # Two separate calls on purpose: a single RCON request with two commands
        # can come back half-answered (socket closed after the first), and then
        # "the second command said nothing" is indistinguishable from "it wrote
        # nothing".  Separate calls make each answer its own round trip.
        $idemBefore = Get-ApplyCount
        $againPreview = Invoke-Rcon @('sm_cs2u_env preview')
        $again = Invoke-Rcon @('sm_cs2u_env apply')
        $idemAfter = Get-ApplyCount
        Add-TestSection $suite '5. second pass (idempotency)' `
            ($againPreview + "`n" + $again)
        Add-TestCheck $suite 'second preview says nothing to do' ($againPreview -match '无需改动')
        Add-TestCheck $suite 'second apply did not rewrite anything' ($again -match '未写盘') `
            ((($again -split "`n") | Where-Object { $_ -match '无需改动|未写盘|refused|拒绝' }) -join ' ')
        Add-TestCheck $suite 'the no-op pass recorded no ACTION entry' `
            ($idemAfter -eq $idemBefore) ("before={0} after={1}" -f $idemBefore, $idemAfter)

        # 6. menu surface
        $dump = Invoke-Rcon @('sm_cs2u_menudump')
        Add-TestSection $suite '6. menudump (env page)' `
            ((($dump -split "`n") | Where-Object { $_ -match 'ctx=env|env\.|env_adapt' }) -join "`n")
        Add-TestCheck $suite 'move page exposes the entry row' ($dump -match 'act:env_adapt')
        Add-TestCheck $suite 'env page is dumped as its own context' ($dump -match 'ctx=env')
        Add-TestCheck $suite 'env page carries preview/apply/undo rows' `
            ($dump -match 'env\.preview' -and $dump -match 'env\.apply' -and $dump -match 'env\.undo')

        # 6b. the menu row ids themselves (1.0.13 shipped rows that did nothing:
        # "env.preview:0" was split by ':' so parts[1] was "0").  Replaying the
        # raw id through the same dispatcher is the client-free equivalent of
        # clicking the row.
        $replay = Invoke-Rcon @('sm_cs2u_menusel env.detail:0')
        Add-TestSection $suite '6b. menu row replay (no client)' $replay
        Add-TestCheck $suite 'a menu row id runs its action when replayed' `
            ($replay -match '== 环境探测 ==') `
            ((($replay -split "`n") | Select-Object -First 2) -join ' ')
        $badRow = Invoke-Rcon @('sm_cs2u_menusel env.nope:0')
        Add-TestCheck $suite 'an unknown menu row id is rejected' ($badRow -match '没有这一行')
    }

    # ---- phase B: 30 Hz -----------------------------------------------------
    # When run alone, prepare the "adapted at 64 Hz" state it needs to compare
    # against; otherwise phase A already left exactly that behind.
    if ($Phase -eq 'B') {
        $proc = Start-DsServer -Map $Map -Tickrate 64
        Write-Host ("phase B prep srcds pid={0} tickrate=64" -f $proc.Id)
        if (-not (Wait-DsReady -TimeoutSec $StartTimeoutSec)) {
            Add-TestCheck $suite 'phase B prep (64 Hz): server answers RCON' $false ("{0} s" -f $StartTimeoutSec)
            $result = Complete-TestSuite $suite $OutDir
            Stop-DsServer
            exit 2
        }
        Invoke-Rcon @("sm_cvar $profileCvar 0") | Out-Null
        Invoke-Rcon @('sm_cs2u_set cs2movement_air_jump_speed 1',
                      'sm_cs2u_set cs2movement_lowspeed_sustain 1') | Out-Null
        Invoke-Rcon @('sm_cs2u_env clear') | Out-Null
        # Separate calls: a two-command request can come back half-answered.
        Invoke-Rcon @('sm_cs2u_env preview') | Out-Null
        Invoke-Rcon @('sm_cs2u_env apply') | Out-Null
        Add-TestCheck $suite 'prep: a 64 Hz adaptation is stored' ((Get-ProfileCvar) -eq '4') `
            ("profile={0}" -f (Get-ProfileCvar))
    }

    if ($Phase -ne 'A') {
        Stop-DsServer
        $proc = Start-DsServer -Map $Map -Tickrate 30 -NoTickMod
        Write-Host ("phase B srcds pid={0} tickrate=30 (tick mods parked)" -f $proc.Id)

        if (-not (Wait-DsReady -TimeoutSec $StartTimeoutSec)) {
            # One retry: the 30 Hz boot is the slowest path on this rig (two
            # Metamod plugins parked, full map load with 85 plugins). Evidence
            # for both attempts is kept in the report.
            Add-TestSection $suite 'phase B: first boot timed out, retrying once' `
                ((Get-DsLogLines -Pattern 'CS2Unified|Host_NewGame|maxplayers' -Tail 80) -join "`n")
            Stop-DsServer
            $proc = Start-DsServer -Map $Map -Tickrate 30 -NoTickMod
            Write-Host ("phase B retry srcds pid={0}" -f $proc.Id)
        }

        if (-not (Wait-DsReady -TimeoutSec $StartTimeoutSec)) {
            Add-TestCheck $suite 'phase B (30 Hz): server answers RCON within the timeout' `
                $false ("{0} s x2" -f $StartTimeoutSec)
            $result = Complete-TestSuite $suite $OutDir
            Stop-DsServer
            exit 2
        }
        Add-TestCheck $suite 'phase B (30 Hz): server answers RCON within the timeout' $true ''

        $status30 = Invoke-Rcon @('sm_cs2u_status')
        Add-TestCheck $suite 'phase B really runs at ~30 Hz' ($status30 -match 'env: hz=(29|30|31)\.\d+') `
            ((($status30 -split "`n") | Where-Object { $_ -match 'env: hz=' }) -join ' ')
        Add-TestCheck $suite 'phase B reports band=30' ($status30 -match 'band=30')

        $stored = @(Get-SmLogLines -Pattern 'ENV-APPLY profile=4' -Last 5)
        Add-TestCheck $suite 'stored adaptation was re-asserted after the reboot' ($stored.Count -ge 1)

        $drift = @(Get-SmLogLines -Pattern 'ENV-CHANGED' -Last 5)
        Add-TestSection $suite '9. tick drift after the reboot' ($drift -join "`n")
        Add-TestCheck $suite 'a tick change is reported, not silently re-applied' ($drift.Count -ge 1)

        $detail30 = Invoke-Rcon @('sm_cs2u_env')
        Add-TestSection $suite '10. probe at 30 Hz' $detail30
        Add-TestCheck $suite 'probe resolves the 30 Hz band' ($detail30 -match '标定档: 30 Hz')
        Add-TestCheck $suite 'the 30 Hz recommendation is NOT the 64 Hz one' `
            ($detail30 -match 'spread 建议: 关（0）') `
            ((($detail30 -split "`n") | Where-Object { $_ -match 'spread 建议' }) -join ' ')

        $preview30 = Invoke-Rcon @('sm_cs2u_env preview')
        Add-TestSection $suite '11. preview at 30 Hz' $preview30
        Add-TestCheck $suite 'the 30 Hz plan refuses the 64-only opt-ins' `
            ($preview30 -match 'cs2movement_air_jump_speed 1 → 0' -and `
             $preview30 -match 'cs2movement_lowspeed_sustain 1 → 0')
        Add-TestCheck $suite 'the 30 Hz plan also drops the forced-64 profile' `
            ($preview30 -match 'cs2feel_spread_tick_profile 强制 64（4） → 关（0）')
        Add-TestCheck $suite 'the 30 Hz plan is 3 items (not the 1-item 64 Hz plan)' `
            ($preview30 -match '将改 3 项')

        $apply30 = Invoke-Rcon @('sm_cs2u_env apply')
        Add-TestSection $suite '12. apply at 30 Hz' $apply30
        Add-TestCheck $suite 'apply reports the 30 Hz adaptation' ($apply30 -match '已适配 30 Hz')
        Add-TestCheck $suite 'air_jump_speed is off at 30 Hz' ((Get-AirJump) -eq '0') `
            ("air_jump={0}" -f (Get-AirJump))
        Add-TestCheck $suite 'lowspeed_sustain is off at 30 Hz' ((Get-Sustain) -eq '0') `
            ("sustain={0}" -f (Get-Sustain))
        Add-TestCheck $suite 'profile is 0 at 30 Hz' ((Get-ProfileCvar) -eq '0') `
            ("profile={0}" -f (Get-ProfileCvar))
        # The measured rate at 30 Hz is 29.99 in this engine (interval 0.0333417),
        # not the nominal 30.00 -- assert the band, not the pretty number.
        Add-TestCheck $suite 'env section now records profile 0 and ~30 Hz' `
            ((Get-CfgText) -match 'spread_tick_profile"\s*"0"' -and `
             (Get-CfgText) -match '"adapted_hz"\s*"(29|30|31)\.') `
            ((($(Get-CfgText) -split "`n") | Where-Object { $_ -match 'adapted_hz|spread_tick_profile' }) -join ' ')

        # 13. undo restores the 64 Hz adaptation exactly (E-6)
        $undo30 = Invoke-Rcon @('sm_cs2u_env undo')
        Add-TestSection $suite '13. undo at 30 Hz' $undo30
        Add-TestCheck $suite 'undo puts the three values back' `
            ((Get-ProfileCvar) -eq '4' -and (Get-AirJump) -eq '1' -and (Get-Sustain) -eq '1') `
            ("profile={0} air_jump={1} sustain={2}" -f (Get-ProfileCvar), (Get-AirJump), (Get-Sustain))
        Add-TestCheck $suite 'undo restores the previous env section (still profile 4)' `
            ((Get-CfgText) -match 'spread_tick_profile"\s*"4"')

        # 14. leave the server in a defined state
        $clear = Invoke-Rcon @('sm_cs2u_env clear')
        Add-TestSection $suite '14. clear' $clear
        Add-TestCheck $suite 'clear removes the stored marker' ($clear -match '已清除')
        Add-TestCheck $suite 'env section is gone after clear' (-not (Test-CfgEnv 'spread_tick_profile'))
        Invoke-Rcon @("sm_cvar $profileCvar 0") | Out-Null
        Add-TestCheck $suite 'server is left on the shipped profile (0)' ((Get-ProfileCvar) -eq '0') `
            ("profile={0}" -f (Get-ProfileCvar))
    }

    # ---- phase A tail (undo / second undo / re-apply) ------------------------
    if ($Phase -ne 'B') {
        $undo = Invoke-Rcon @('sm_cs2u_env undo')
        Add-TestSection $suite '7. undo' $undo
        Add-TestCheck $suite 'undo reports the restore' ($undo -match '已撤销上次适配')
        Add-TestCheck $suite 'profile cvar is back to 0' ((Get-ProfileCvar) -eq '0') `
            ("value={0}" -f (Get-ProfileCvar))
        Add-TestCheck $suite 'env section is gone after undo' (-not (Test-CfgEnv 'spread_tick_profile'))
        $undoAgain = Invoke-Rcon @('sm_cs2u_env undo')
        Add-TestCheck $suite 'a second undo is refused (no snapshot)' `
            ($undoAgain -match 'Undo refused: 没有可撤销的适配')

        # -Phase Both: phase B needs a stored 64 Hz adaptation to be stale about,
        # and the undo above just removed it.  Put one back on the running server.
        if ($Phase -eq 'Both') {
            Invoke-Rcon @("sm_cvar $profileCvar 0") | Out-Null
            Invoke-Rcon @('sm_cs2u_env preview') | Out-Null
            Invoke-Rcon @('sm_cs2u_env apply') | Out-Null
            Add-TestCheck $suite 're-adapts at 64 Hz for the 30 Hz comparison' `
                ((Get-ProfileCvar) -eq '4') ("profile={0}" -f (Get-ProfileCvar))
        }
    }

    $smErr = @(Get-DsLogLines -Pattern '\[SM\] (Error|Failed)|Failed to load' -Tail 600 -Last 10)
    Add-TestCheck $suite 'no SourceMod error during the run' ($smErr.Count -eq 0) (($smErr | Select-Object -First 3) -join ' | ')

    Add-TestSection $suite '15. NOT covered by this suite' `
        ("真人点选菜单（GENERIC 管理员看不到该行、ROOT 能进）—— 静态契约在 verify.ps1，交互需要客户端。" +
         "`nchangelevel 后的 PERSIST-APPLY + ENV-APPLY 组合用重启代替。" +
         "`n实测 tick 增强插件是否加载：本插件只能由 Hz 反推，日志里写成推断。" +
         "`n30 Hz 腿在 -Phase B / -Phase Both 或 tests\env30_runtime.ps1 里；本机 30 tick 起服偶发卡在 Host_NewGame。")
}
catch {
    Add-TestCheck $suite ("suite ran to completion") $false $_.Exception.Message
}
finally {
    # Leave no test residue: profile back to off, adaptation marker cleared.
    try { Invoke-Rcon @("sm_cvar $profileCvar 0") | Out-Null } catch { }
    try { Invoke-Rcon @('sm_cs2u_env clear') | Out-Null } catch { }
    if ($proc) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Stop-DsServer
}

$result = Complete-TestSuite $suite $OutDir
if ($result.ok) { exit 0 } else { exit 1 }
