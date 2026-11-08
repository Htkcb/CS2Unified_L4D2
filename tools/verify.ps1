<#
.SYNOPSIS
    Static acceptance for CS2Unified_L4D2: sync drift, compile, symbol and
    interface invariants.

.DESCRIPTION
    This is the check that must pass before any deployment. It is intentionally
    static: it proves the transform/merge is coherent, not that the plugin
    behaves correctly in game. Runtime evidence lives in tests/ and docs/05.

    Exit code 0 = every check passed.
#>
[CmdletBinding()]
param(
    [string]$CompilerPath,
    [string]$IncludePath
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SrcDir      = Join-Path $ProjectRoot 'src'
$failures    = New-Object System.Collections.Generic.List[string]
$checks      = 0

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    $script:checks++
    if ($ok) {
        Write-Host ("PASS  {0}" -f $name)
    } else {
        Write-Host ("FAIL  {0} {1}" -f $name, $detail) -ForegroundColor Red
        $script:failures.Add($name)
    }
}

# ---- 1. transform drift -----------------------------------------------------
& (Join-Path $PSScriptRoot 'sync_sources.ps1') -Check
Check 'sync: src/ is a faithful transform of upstream' ($LASTEXITCODE -eq 0)

# ---- 2. clean compile -------------------------------------------------------
$buildArgs = @{}
if ($CompilerPath) { $buildArgs.CompilerPath = $CompilerPath }
if ($IncludePath)  { $buildArgs.IncludePath  = $IncludePath }
& (Join-Path $PSScriptRoot 'build.ps1') @buildArgs -StrictWarnings
Check 'build: 0 errors / 0 warnings' ($LASTEXITCODE -eq 0)

$allFiles = Get-ChildItem $SrcDir -Recurse -Filter *.sp
$allText  = ($allFiles | ForEach-Object { Get-Content -Raw -Encoding UTF8 $_.FullName }) -join "`n"

# ---- 3. exactly one Plugin myinfo ------------------------------------------
$myinfo = [regex]::Matches($allText, 'public\s+Plugin\s+myinfo')
Check 'merge: exactly one Plugin myinfo' ($myinfo.Count -eq 1) "found=$($myinfo.Count)"

# ---- 4. upstream callbacks must not remain plugin callbacks ----------------
$callbackNames = 'OnPluginStart|OnPluginEnd|OnPlayerRunCmd|OnConfigsExecuted|OnPostThink|OnClientPutInServer|OnClientDisconnect|AskPluginLoad2|OnClientSayCommand'
$moduleFiles = @(Get-ChildItem (Join-Path $SrcDir 'feel') -Filter *.sp) + @(Get-ChildItem (Join-Path $SrcDir 'movement') -Filter *.sp)
$leftover = @()
foreach ($f in $moduleFiles) {
    $matches = [regex]::Matches((Get-Content -Raw -Encoding UTF8 $f.FullName),
        "(?m)^\s*public\s+[A-Za-z_][A-Za-z0-9_]*\s+($callbackNames)\s*\(")
    foreach ($m in $matches) { $leftover += "$($f.Name):$($m.Groups[1].Value)" }
}
Check 'merge: no duplicate plugin callbacks in modules' ($leftover.Count -eq 0) ($leftover -join ', ')

# ---- 5. managed cvar table ------------------------------------------------
$paramsText = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2u_params.sp')
$managed = [regex]::Matches($paramsText, 'CS2U_ParamAdd\("([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
Check 'params: table non-empty' ($managed.Count -ge 10) "count=$($managed.Count)"
Check 'params: table below capacity' ($managed.Count -le 40) "count=$($managed.Count)"

$missingCvar = @()
foreach ($cv in $managed) {
    if ($allText -notmatch ('CreateConVar\("' + [regex]::Escape($cv) + '"')) { $missingCvar += $cv }
}
Check 'params: injury group present' ((@($managed | Where-Object { $_ -like 'cs2movement_injury_*' }).Count -eq 7) -and ($allText -match 'PARAM_GROUP_INJURY'))
Check 'params: every managed cvar is created by a module' ($missingCvar.Count -eq 0) ($missingCvar -join ', ')

$dupeCvar = $managed | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }
Check 'params: no duplicate managed cvar' ($dupeCvar.Count -eq 0) ($dupeCvar -join ', ')

# ---- 6. mode entries only reference managed cvars --------------------------
$modesText = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2u_modes.sp')
$modeCvars = [regex]::Matches($modesText, 'CS2U_ModeEntry\([^,]+,\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
$unknownModeCvar = $modeCvars | Where-Object { $managed -notcontains $_ } | Select-Object -Unique
Check 'modes: every preset entry is a managed cvar' ($unknownModeCvar.Count -eq 0) ($unknownModeCvar -join ', ')

# ---- 7. duplicate CreateConVar across modules ------------------------------
$created = [regex]::Matches($allText, 'CreateConVar\("([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
$dupeCreated = $created | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }
Check 'merge: no duplicate CreateConVar registration' ($dupeCreated.Count -eq 0) ($dupeCreated -join ', ')

# ---- 8. namespacing applied ------------------------------------------------
Check 'merge: feel enable global renamed' ($allText -match 'g_cvCS2FEnable' -and $allText -notmatch '\bg_cvEnable\b')
Check 'merge: movement enable global renamed' ($allText -match 'g_cvCS2MEnable')

# ---- 9. menu contract (v1.0.5: two-level, 7 contexts) ----------------------
$menuText = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2u_menu.sp')
foreach ($handler in 'MenuHandler_Root','MenuHandler_Presets','MenuHandler_Feel','MenuHandler_Move','MenuHandler_Visual','MenuHandler_Status','MenuHandler_Config') {
    Check ("menu: {0} defined" -f $handler) ($menuText -match ('public int ' + $handler + '\('))
}
foreach ($gone in 'MenuHandler_Value','MenuHandler_Simple','MenuHandler_Diy','MenuHandler_Recoil','MenuHandler_BMode','MenuHandler_Camera') {
    Check ("menu: legacy {0} removed" -f $gone) ($menuText -notmatch ('public int ' + $gone + '\('))
}
Check 'menu: exactly seven dispatch contexts' (([regex]::Matches($menuText, 'StrEqual\(ctx, "')).Count -eq 7 -and $menuText -match 'CS2U_CTX_CONFIG')
Check 'menu: no third-level value page' ($menuText -notmatch 'CS2U_MenuParam\(' -and $menuText -notmatch '"v\.%d')
Check 'menu: inline parameter cycle row' ($menuText -match 'void CS2U_ApplyParamCycle' -and $menuText -match '"cyc:%d"')
Check 'menu: advanced view on/off rows' ($menuText -match '"adv\.on"' -and $menuText -match '"adv\.off"')
Check 'menu: back/previous/next labels' ($menuText -match 'CS2U_PREV_LABEL' -and $menuText -match 'CS2U_NEXT_LABEL' -and $menuText -match 'CS2U_BACK_LABEL')
Check 'menu: 7 content rows + disabled group headers' ($menuText -match '#define CS2U_MENU_ROWS\s+7' -and $menuText -match 'CS2U_RowHeader' -and $menuText -match 'ITEMDRAW_DISABLED')
Check 'menu: a group header never ends a page' ($menuText -match 'g_bRowHeader\[end - 1\]')
Check 'menu: auth gate + 权限不足 denial' ($menuText -match 'CS2U_AuthCheck\(' -and $menuText -match '权限不足')
Check 'menu: ROOT rows only in the advanced view' ($menuText -match 'CS2U_Advanced\(' -and $menuText -match 'g_iParamAccess\[idx\] == PARAM_ACCESS_ROOT')
Check 'menu: MENU-SELECT telemetry' ($menuText -match 'MENU-SELECT')
Check 'menu: config reload reloads both layers' ($menuText -match 'CS2U_MenuCfgReload\(')
$layoutText = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2u_layout.sp')
Check 'layout: built-in default layout' ($layoutText -match 'void CS2U_MenuCfgDefaults')
Check 'layout: fail-closed fallback + log' ($layoutText -match 'MENU-CONFIG-FALLBACK' -and $layoutText -match 'void CS2U_MenuCfgFallback')
Check 'layout: 20 configurable-key cap' ($layoutText -match 'CS2U_MENU_CFG_MAX_KEYS\s+20')
Check 'layout: hot reload entry' ($layoutText -match 'bool CS2U_MenuCfgReload')
Check 'layout: menu.cfg shipped' (Test-Path (Join-Path $ProjectRoot 'configs\cs2unified\menu.cfg'))
$authText = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2u_auth.sp')
Check 'auth: SteamID wins over group + conflict log' ($authText -match 'AUTH-CONFLICT' -and $authText -match 'chosen=steamid')
Check 'auth: OK/DENIED logs' ($authText -match 'AUTH-OK' -and $authText -match 'AUTH-DENIED')
Check 'auth: flag fallback when lists are empty' ($authText -match 'source, maxlen, "flag"')
Check 'auth: group membership via SourceMod groups' ($authText -match 'GetAdminGroupCount' -and $authText -match 'FindAdmGroup')
$modesText = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2u_modes.sp')
Check 'modes: bmode ensure helper' ($modesText -match 'void CS2U_ModesEnsureBmode' -and $modesText -match 'CS2U_ModeHasEntry\(i, "cs2u_bmode"')
Check 'modes: every built-in preset carries bmode' (([regex]::Matches($modesText, 'CS2U_ModeEntry\(m, "cs2u_bmode"')).Count -ge 6)
Check 'modes: cs2_full ships the TR-40 structure (bmode 1)' `
    ($modesText -match 'ModesBuildFull' -and $modesText -match 'CS2U_ModeEntry\(m, "cs2u_bmode", "1"\)' -and $modesText -match 'CS2U_ModeEntry\(m, "cs2feel_ballistics_scale", "1.20"\)')
Check 'modes: presets carry Chinese display labels' `
    ($modesText -match 'void CS2U_ModeLabelCn' -and $modesText -match 'CS2 完全仿真' -and $modesText -match 'CS2 竞技移动')
Check 'menu: preset rows use the Chinese label' `
    ($menuText -match 'CS2U_ModeLabelCn\(name, label' -and $menuText -match '%s（%s）%s')
Check 'modes: cs2_competitive slide time is 0.35' `
    (([regex]::Matches($modesText, 'CS2U_ModeEntry\(m, "cs2movement_crouch_slide_time", "0\.35"\)')).Count -ge 2)
Check 'modes: cs2_full slide time is the 0.35 feel tier' `
    ($modesText -match 'CS2U_ModeEntry\(m, "cs2movement_crouch_slide_time", "0\.35"\)')
Check 'modes: preset apply prints the client-side hint' `
    ($modesText -match 'void CS2U_PresetClientHint' -and $modesText -match 'cs2feel_aimsync\.ini' -and $modesText -match 'l4n_view_punch_scale')
Check 'modes: cs2_full preset built' ($modesText -match 'CS2U_ModesBuildFull' -and $modesText -match '"cs2_full"')
Check 'params: 39 managed parameters' (([regex]::Matches($paramsText, '\bp = CS2U_ParamAdd\(')).Count -eq 39)

# ---- 9c. water-depth slowdown (movement 0.5.3 / 1.0.10) --------------------
$waterPath = Join-Path $SrcDir 'movement\cs2movement_water.sp'
$waterText = if (Test-Path $waterPath) { Get-Content -Raw -Encoding UTF8 $waterPath } else { '' }
Check 'patch: movement_water new module is in src/movement' (Test-Path $waterPath)
Check 'patch: water layer is called from both target functions' `
    (([regex]::Matches($allText, 'speed = CS2M_WaterApply\(client, speed\);')).Count -eq 2)
Check 'patch: water runs after the injury cap' `
    ($allText -match 'speed = CS2M_InjuryApply\(client, speed\);\s*\r?\n\s*speed = CS2M_WaterApply\(client, speed\);')
Check 'movement: water gate is survivor-only and alive-only' `
    ($waterText -match 'if \(!CS2M_IsSurvivor\(client\) \|\| !IsPlayerAlive\(client\)\)')
Check 'movement: water factor is linear in depth and never raises speed' `
    ($waterText -match '1\.0 - slowdown \* \(float\(level\) / float\(CS2M_WATER_MAX_LEVEL\)\)' -and $waterText -match 'adjusted >= speed')
Check 'movement: water cvars are clamped by config validate' `
    ($allText -match 'CS2M_ConfigValidateFloat\("cs2movement_water_slowdown", 0\.0, 0\.8\)' -and `
     $allText -match 'CS2M_ConfigValidateInt\("cs2movement_water_enable", 0, 1\)')
Check 'params: water pair is managed' `
    (($managed -contains 'cs2movement_water_enable') -and ($managed -contains 'cs2movement_water_slowdown'))
Check 'layout: water group is pushed into the move order' `
    ($layoutText -match 'PARAM_GROUP_WATER' -and $layoutText -match 'CS2U_PushCvar\(CS2U_CTX_MOVE, g_sParamCvar\[i\]\)')
Check 'layout: an older menu.cfg cannot hide a new parameter' `
    ($layoutText -match 'void CS2U_OrderAppendMissing' -and $layoutText -match 'CS2U_OrderAppendMissing\(c\)')
Check 'menu: water rows get their own group header' `
    ($menuText -match '水面减速' -and $menuText -match 'cs2movement_water_')
Check 'modes: water ensure helper fills older presets' `
    ($modesText -match 'void CS2U_ModesEnsureWater' -and $modesText -match 'CS2U_ModeHasEntry\(i, "cs2movement_water_enable"')
Check 'core: status prints the water layer' `
    ((Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2u_core.sp')) -match '"water: enable=%d slowdown=%\.3f')

$fullFn = ''
$fi = $modesText.IndexOf('int CS2U_ModesBuildFull')
if ($fi -ge 0) {
    $end = $modesText.IndexOf("`n}", $fi)
    if ($end -gt $fi) { $fullFn = $modesText.Substring($fi, $end - $fi) }
}
Check 'modes: cs2_full writes all 39 managed values' `
    ((([regex]::Matches($fullFn, 'CS2U_ModeEntry\(m, ')).Count) -eq 39) `
    ("entries={0}" -f ([regex]::Matches($fullFn, 'CS2U_ModeEntry\(m, ')).Count)

# ---- 9d. per-weapon speed table (1.0.11) ----------------------------------
$wpnText = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2u_weapon.sp')
# Count the class names inside the ordered array only: the header comment also
# quotes "weapon_rifle" in its file-format example.
$wpnBlock = ''
$wi = $wpnText.IndexOf('g_sWpnClass[CS2U_WEAPON_COUNT]')
$we = $wpnText.IndexOf('};', $wi)
if ($wi -ge 0 -and $we -gt $wi) { $wpnBlock = $wpnText.Substring($wi, $we - $wi) }
$wpnClasses = [regex]::Matches($wpnBlock, '"weapon_[a-z0-9_]+"')
Check 'weapons: 18 weapon classes in the ordered table' `
    ($wpnText -match '#define CS2U_WEAPON_COUNT\s+18' -and $wpnClasses.Count -eq 18) `
    ("classes={0}" -f $wpnClasses.Count)
Check 'weapons: default and current arrays exist' `
    ($wpnText -match 'g_fWpnDefault\[CS2U_WEAPON_COUNT\]' -and $wpnText -match 'g_fWpnCurrent\[CS2U_WEAPON_COUNT\]')
Check 'weapons: edit writes the movement cfg back immediately' `
    ($wpnText -match 'bool CS2U_WeaponWriteFile' -and `
     $wpnText -match 'configs/cs2movement_weapons\.cfg' -and `
     $wpnText -match 'RenameFile\(bak, path\)' -and $wpnText -match 'RenameFile\(path, tmp\)')
Check 'weapons: reset restores the shipped defaults' `
    ($wpnText -match 'bool CS2U_WeaponResetAll' -and $wpnText -match 'g_fWpnDefault\[i\]')
Check 'weapons: chat input has a timeout, a cancel word and a range guard' `
    ($wpnText -match '#define CS2U_WEAPON_INPUT_TIMEOUT' -and `
     $wpnText -match '取消' -and `
     $wpnText -match 'CS2U_WEAPON_MIN_SPEED' -and `
     $wpnText -match 'GetGameTime\(\) - g_fWpnInputAt\[client\]')
Check 'weapons: console surface registered' `
    ($wpnText -match 'RegAdminCmd\("sm_cs2u_weapons"' -and $wpnText -match 'ADMFLAG_ROOT')
Check 'menu: weapon page + handler + row ids' `
    ($menuText -match 'void CS2U_MenuWeapon\(' -and `
     $menuText -match 'public int MenuHandler_Weapon\(' -and `
     $menuText -match '"wpn:%d"' -and $menuText -match '"wpn:reset"')
Check 'menu: weapon page is ROOT-only' `
    ($menuText -match '(?s)void CS2U_MenuWeapon\(int client, int page\).*?CS2U_TIER_ROOT')
Check 'menu: weapon entry row is in the move order and the shipped menu.cfg' `
    ($layoutText -match 'CS2U_PushAct\(CS2U_CTX_MOVE, "weapon_speeds"\)' -and `
     (Get-Content -Raw -Encoding UTF8 (Join-Path $ProjectRoot 'configs\cs2unified\menu.cfg')) -match 'act:weapon_speeds')
Check 'layout: an older menu.cfg still gets the weapon entry' `
    ($layoutText -match 'CS2U_OrderHas\(ctx, "act:weapon_speeds"\)')
$coreTextForWpn = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2u_core.sp')
Check 'weapons: say handler consumes the line before the chat aliases' `
    ($coreTextForWpn -match 'if \(CS2U_WeaponHandleInput\(client, sArgs\)\)')

# ---- 9e. every non-ASCII PowerShell script carries a UTF-8 BOM -------------
# PowerShell 5.1 reads a .ps1 without a BOM as ANSI: a Chinese string then turns
# into mojibake and can even break the parser (a stray byte eats a quote).  This
# is how the runtime suites failed once, so it is a contract now.
$badScripts = @()
foreach ($ps1 in @(Get-ChildItem (Join-Path $ProjectRoot 'tools') -Filter *.ps1) +
                  @(Get-ChildItem (Join-Path $ProjectRoot 'tests') -Filter *.ps1) +
                  @(Get-ChildItem (Join-Path $ProjectRoot 'tests\lib') -Filter *.ps1 -ErrorAction SilentlyContinue)) {
    $bytes = [System.IO.File]::ReadAllBytes($ps1.FullName)
    $hasNonAscii = $false
    foreach ($b in $bytes) { if ($b -gt 127) { $hasNonAscii = $true; break } }
    if (-not $hasNonAscii) { continue }
    if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
        $badScripts += $ps1.Name
    }
}
Check 'tooling: non-ASCII .ps1 files have a UTF-8 BOM' ($badScripts.Count -eq 0) ($badScripts -join ', ')

# ---- 9f. environment adaptation (1.0.12) ----------------------------------
$envPath = Join-Path $SrcDir 'cs2u_env.sp'
Check 'env: module present' (Test-Path $envPath)
$envText = if (Test-Path $envPath) { Get-Content -Raw -Encoding UTF8 $envPath } else { '' }
$cfgTextEnv  = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2u_config.sp')
$coreTextEnv = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2u_core.sp')
$entryTextEnv = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2unified.sp')
$sharedText = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2u_shared.sp')

Check 'env: probe reads the only trusted tick source' `
    ($envText -match 'GetTickInterval\(\)' -and $envText -match 'IsDedicatedServer\(\)' -and $envText -match 'MaxClients')
Check 'env: tick bands mirror the feel module (30/60/64)' `
    ((@('28.5','31.5','57.0','63.5','65.5') | Where-Object { $envText -notmatch [regex]::Escape($_) }).Count -eq 0) -and
    ((@('28.5','31.5','57.0','63.5','65.5') | Where-Object { $allText -notmatch [regex]::Escape($_) }).Count -eq 0)
Check 'env: tickrate plugins are reported as inference, never as a detection' `
    ($envText -match '推断 L4DToolZ' -and $envText -notmatch '已检测到 tickrate_enabler')
Check 'env: profile is NOT a managed parameter (capacity untouched)' `
    ($managed -notcontains 'cs2feel_spread_tick_profile') -and `
    ($sharedText -match 'CS2U_MAX_PARAMS\s+40' -and $sharedText -match 'CS2U_MAX_ENTRIES\s+40')
Check 'env: profile travels on its own channel' `
    ($envText -match '#define CS2U_ENV_CVAR_PROFILE\s+"cs2feel_spread_tick_profile"' -and `
     $envText -match 'FindConVar\(CS2U_ENV_CVAR_PROFILE\)')
Check 'env: apply is refused without a fresh preview' `
    ($envText -match 'g_bEnvPreviewOk\[client\]' -and $envText -match 'CS2U_ENV_PREVIEW_TTL')
Check 'env: apply is all-or-nothing (snapshot + restore on failure)' `
    ($envText -match 'void CS2U_EnvRestoreUndo' -and `
     $envText -match 'CS2U_EnvRestoreUndo\(\);' -and `
     $envText -match 'g_bEnvUndoProfile')
Check 'env: undo restores memory and the env section' `
    ($envText -match 'bool CS2U_EnvUndo' -and $envText -match 'env-undo' -and `
     $envText -match 'g_bEnvPersist = g_bEnvUndoPersist')
Check 'env: undo message counts the profile channel too' `
    ($envText -match 'int items = g_iEnvUndoItems \+ \(g_bEnvUndoProfile \? 1 : 0\);')
Check 'env: never writes an sv_* value' `
    ((($envText | Select-String -Pattern 'SetConVar[A-Za-z]*\([^)]*"sv_' -AllMatches).Matches.Count -eq 0) -and `
     (($envText | Select-String -Pattern 'ServerCommand\([^)]*sv_' -AllMatches).Matches.Count -eq 0) -and `
     ($envText -match 'sv_maxupdaterate') )
Check 'env: managed items go through the validated path' `
    ($envText -match 'CS2U_ParamSet\(idx, g_sEnvPlanValue' )
Check 'env: command is ROOT-only' `
    ($envText -match 'RegAdminCmd\("sm_cs2u_env"' -and $envText -match 'ADMFLAG_ROOT')
Check 'env: env section is written and read back' `
    ($cfgTextEnv -match 'JumpToKey\("env", true\)' -and $cfgTextEnv -match 'CS2U_EnvLoadFromConfig')
Check 'env: stored adaptation is re-asserted after a map change' `
    ($allText -match 'void CS2U_EnvApplyStored' -and $envText -match 'ENV-PROFILE-RECLAIM' -and `
     $entryTextEnv -match 'CS2U_EnvOnMapStart\(\)')
Check 'env: a tick change is reported, not silently patched' `
    ($envText -match 'ENV-CHANGED' -and $envText -match 'void CS2U_EnvCheckDrift')
Check 'env: menu page + handler + entry row' `
    ($menuText -match 'void CS2U_MenuEnv\(' -and `
     $menuText -match 'public int MenuHandler_Env\(' -and `
     $menuText -match '"env\.preview"' -and $menuText -match '"env\.apply"' -and `
     $menuText -match '"env\.undo"' -and $menuText -match '"env\.detail"')
Check 'env: entry row is ROOT-only for a GENERIC admin (E-8)' `
    ($menuText -match '(?s)if \(StrEqual\(id, "env_adapt"\)\)\s*\r?\n\s*return g_iClientTier\[client\] >= CS2U_TIER_ROOT;')
Check 'env: layout pushes the row and the old-config fallback covers it' `
    ($layoutText -match 'CS2U_PushAct\(CS2U_CTX_MOVE, "env_adapt"\)' -and `
     $layoutText -match 'CS2U_OrderHas\(ctx, "act:env_adapt"\)' -and `
     (Get-Content -Raw -Encoding UTF8 (Join-Path $ProjectRoot 'configs\cs2unified\menu.cfg')) -match 'act:env_adapt')
Check 'env: menudump covers the page' ($menuText -match 'CS2U_MenuEnv\(0, 0\);')

# ---- 9h. menu row ids are data, not guesses (1.0.14) ----------------------
# 1.0.13's env page split "env.preview:0" by ':' and read parts[1] -> "0", so
# every action row silently did nothing. The row id uses a DOT; MenuEmit appends
# ":<page>". These three checks pin the parse AND keep a client-free replay path.
Check 'menu: env row ids are parsed by the dot, not the colon' `
    ($menuText -match 'StrEqual\(key, "env\.preview"\)' -and `
     $menuText -match 'StrContains\(key, ":"\)' -and `
     $menuText -notmatch 'StrEqual\(parts\[1\], "(detail|preview|apply|undo)"\)')
Check 'menu: a row id can be replayed without a client (regression surface)' `
    ($envText -match 'RegAdminCmd\("sm_cs2u_menusel"' -and `
     $envText -match 'CS2U_EnvAction\(client, info, false\)' -and `
     $menuText -match 'bool CS2U_EnvAction\(int client, const char\[\] info, bool reRender\)')
Check 'menu: the env page echoes the last action in its title' `
    ($menuText -match '上次：' -and $sharedText -match 'g_sEnvLastMsg')
Check 'env: status page prints the measured environment' `
    ($coreTextEnv -match '"env: hz=%\.2f dedicated=%d')

# ---- 9g. per-team scope (1.0.13) ------------------------------------------
# The movement layers have been survivor-gated since 0.4.7; the feel layers were
# the last per-player path open to every team.  These checks keep that closed and
# keep the one genuinely un-gateable channel (engine physics) honest.
$entryTextTeam = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2unified.sp')
$moveText = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'movement\cs2movement_move.sp')
$moveCfgText = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'movement\cs2movement_config.sp')
Check 'team: feel layers are skipped for the infected team' `
    ($coreTextEnv -match 'bool CS2U_ShouldRunFeel' -and `
     $coreTextEnv -match 'GetClientTeam\(client\) != CS2U_TEAM_INFECTED' -and `
     $entryTextTeam -match 'if \(CS2U_ShouldRunFeel\(client\)\)')
Check 'team: the gate skips ONLY the infected (survivors/spectators unchanged)' `
    ($sharedText -match '#define CS2U_TEAM_INFECTED\s+3' -and `
     $moveCfgText -match '#define CS2M_TEAM_SURVIVOR\s+2' -and `
     $coreTextEnv -notmatch 'GetClientTeam\(client\) != 2\b')
Check 'team: the gate is switchable and defaults on' `
    ($coreTextEnv -match 'CreateConVar\("cs2u_feel_survivor_only", "1"' -and `
     $coreTextEnv -match 'cs2u_feel_survivor_only')
$gateCount = ([regex]::Matches($allText, 'CS2M_IsSurvivor\(')).Count
$skipCount = ([regex]::Matches($allText, 'g_iSkipNotSurvivor\+\+')).Count
Check 'team: movement keeps a survivor gate on every per-player write path' `
    (($gateCount -ge 12) -and ($skipCount -ge 5)) `
    ("gates={0} counters={1}" -f $gateCount, $skipCount)
Check 'team: engine physics never writes sv_maxspeed (it capped the Charger)' `
    (($moveText -notmatch 'SetConVar\w*\(\s*g_cvSVMaxspeed') -and `
     ($moveText -notmatch 'SetConVar\w*\(\s*FindConVar\("sv_maxspeed"\)'))
Check 'team: status reports the gate counters and the shared-physics boundary' `
    ($coreTextEnv -match 'team gate: feel_survivor_only=' -and `
     $coreTextEnv -match 'global physics: apply_global=' -and `
     $coreTextEnv -match 'sv_maxspeed is never written')

$visualText = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2u_visual.sp')
Check 'visual: bullet_impact hooked' ($visualText -match 'HookEvent\("bullet_impact"')
Check 'visual: server-side beam drawn' ($visualText -match 'TE_SetupBeamPoints' -and $visualText -match 'TE_SendToAll')

# ---- 9b. dispatch and symbol integrity ------------------------------------
$entryText = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2unified.sp')
$configText = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2u_config.sp')
Check 'entry: feel OnPlayerRunCmd dispatched' ($entryText -match 'CS2F_OnPlayerRunCmd\(')
Check 'entry: movement OnPlayerRunCmd dispatched' ($entryText -match 'CS2M_OnPlayerRunCmd\(')
Check 'entry: no dead OnPostThink forward' ($entryText -notmatch 'public\s+void\s+OnPostThink')

$defs = [regex]::Matches($allText,
    '(?m)^\s*(?:public|stock|static|native|forward)?\s*(?:void|int|float|bool|char|Action|APLRes|MRESReturn|Handle|any)\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(') |
    ForEach-Object { $_.Groups[1].Value }
$dupeFuncs = $defs | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }
Check 'merge: no duplicate function definitions' ($dupeFuncs.Count -eq 0) ($dupeFuncs -join ', ')

$coreText = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2u_core.sp')
Check 'core: master switch gates write commands' (([regex]::Matches($coreText, 'Management layer is disabled')).Count -ge 4)
Check 'config: single edits persist then capture' ($configText -match 'bool ok = CS2U_ConfigWriteInternal' -and $configText -match 'CS2U_PersistLive')
Check 'config: startup .bak recovery' ($configText -match 'CONFIG-RESTORED-FROM-BAK' -and $configText -match 'CONFIG-RECOVERED-FROM-BAK')
Check 'config: simple_mode persisted' ($configText -match '"simple_mode"' -and $configText -match 'g_cvUSimpleMode')
Check 'params: validates ConVar registration' ($paramsText -match 'is not registered')

# ---- 10. config contract ---------------------------------------------------
$configText = Get-Content -Raw -Encoding UTF8 (Join-Path $SrcDir 'cs2u_config.sp')
Check 'config: path is configs/cs2unified' ($configText -match 'configs/cs2unified/cs2unified\.cfg')
Check 'config: backup before export' ($configText -match 'RenameFile\(bak, path\)')
Check 'config: restore on export failure' ($configText -match 'RenameFile\(path, bak\)')
Check 'config: snapshot/rollback implemented' ($configText -match 'CS2U_Snapshot' -and $configText -match 'CS2U_Rollback')
Check 'config: traversal rewinds to root' ($configText -match 'kv\.Rewind\(\)')
Check 'config: rejects missing sections' ($configText -match 'no presets/settings sections')
Check 'config: rollback is persisted' ($configText -match 'ROLLBACK-PERSIST-FAILED')
Check 'config: BOM-tolerant import' ($configText -match 'ImportFromString')

# ---- 11. required deploy assets -------------------------------------------
foreach ($rel in @(
    'gamedata\l4d2_cs2feel.txt',
    'gamedata\cs2movement.txt',
    'configs\cs2feel\weapons.cfg',
    'configs\cs2feel\native_baseline.cfg',
    'configs\cs2movement_weapons.cfg',
    'addon\cs2feel_r2_plugin.vpk'
)) {
    Check ("asset: {0}" -f $rel) (Test-Path (Join-Path $ProjectRoot $rel))
}

# Camera / recoil / trajectory decisions are rows inside the feel/visual pages.
Check 'menu: camera detect still queries the client cvar' `
    ($menuText -match 'CS2U_ActionCamera' -and $menuText -match 'QueryClientConVar')
Check 'menu: cs2_split row names the client-side decal caveat' `
    ($menuText -match 'cs2_split' -and $menuText -match 'l4n_view_punch_scale')
$recoilFn = ''
$ri = $menuText.IndexOf('bool CS2U_ApplyRecoil')
if ($ri -ge 0) {
    $end = $menuText.IndexOf("`n}", $ri)
    if ($end -gt $ri) { $recoilFn = $menuText.Substring($ri, $end - $ri) }
}
Check 'menu: recoil switch = 7 managed writes + 1 persist' `
    ((([regex]::Matches($recoilFn, 'CS2U_ParamSetValue\("cs2feel_(enable|recoil_mode|recoil_view_scale|recoil_scale|ballistics_mode|ballistics_scale|ballistics_yaw)"')).Count -eq 7) -and ($recoilFn -match 'CS2U_PersistLive\(persistMsg'))
Check 'menu: client ratio derived from live cvars' `
    ($menuText -match 'void CS2U_RecoilRatio\(' -and $menuText -match 'off / cam')
Check 'menu: trajectory mode is a managed + created cvar' `
    ($managed -contains 'cs2u_bmode' -and $allText -match 'CreateConVar\("cs2u_bmode"')
Check 'menu: trajectory mode row cycles three modes (TR-40 replaces the split)' `
    ($menuText -match 'CS2U_ActionBmode' -and $menuText -match 'CS2U_BMODE_TR40' -and $menuText -match '\(base \+ 1\) % 3')
Check 'menu: trajectory mode policy uses the aim-sync probe cvar' `
    ($menuText -match 'QueryClientConVar\(i, "cs2feel_aimsync"' -and $menuText -match 'CS2U_BmodeUninstalled')
Check 'menu: auto policy has the three thresholds' `
    ($menuText -match 'u >= 0\.20 && u <= 0\.50' -and $menuText -match 'u > 0\.50')
Check 'client: aim-sync ini shipped next to the client cfg' `
    (Test-Path (Join-Path $ProjectRoot 'client\cs2feel_aimsync.ini'))
# ---- summary ---------------------------------------------------------------
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host ("VERIFY PASS ({0} checks)" -f $checks) -ForegroundColor Green
    exit 0
}
Write-Host ("VERIFY FAIL ({0}/{1} checks failed): {2}" -f $failures.Count, $checks, ($failures -join '; ')) -ForegroundColor Red
exit 1