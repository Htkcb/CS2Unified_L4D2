/**
 * cs2feel_core.sp -- MOD-0: plugin lifecycle, signature/build guard, module
 * orchestration, failure degradation.  Main plugin file (compiles to one .smx).
 *
 * M3/M4/M5 SCOPE
 *   M3: configuration loading + hot reload + fail-closed signature guard + native
 *   interface.  M4: MOD-2 spread state machine (default pass-through).  M5: MOD-3
 *   recoil, applying the archived CS2 per-shot punch sequence at the shot event
 *   (default pass-through), with the engine's own decay left untouched.
 *
 * FAIL-CLOSED SIGNATURE GUARD
 *   gamedata/l4d2_cs2feel.txt is Windows-only on purpose: on Linux every lookup
 *   fails and the plugin must refuse to activate rather than guess an offset.  The
 *   guard requires, at minimum:
 *     - the gamedata file loads;
 *     - CS2Feel::GunSpreadOffset resolves to exactly 6124 (0x17EC);
 *     - CS2Feel::GunSpreadReadSite resolves AND the 4 bytes at +4 still encode
 *       0x000017EC (an independent check that the read site really uses the offset).
 *   With cs2feel_strict 1 (default) it additionally requires both FireBullet
 *   signatures and GetRateOfFire to resolve.  On any failure the plugin stays
 *   inactive and prints an INACTIVE/SIG-ERROR line; nothing degrades silently.
 *
 * CONFIGURATION
 *   configs/cs2feel/weapons.cfg + native_baseline.cfg are loaded in CS2F_OnPluginStart
 *   and can be reloaded with sm_cs2feel_reload.  A failed reload keeps the previous
 *   table (see cs2feel_config.sp).  Missing config never blocks activation: the
 *   signature guard is independent, and getters report "not found" so callers fall
 *   back to native values.
 *
 * ASCII only on purpose (see cs2feel_config.sp header).
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include "cs2feel_config.sp"
#include "cs2feel_spread.sp"
#include "cs2feel_recoil.sp"
#include "cs2feel_ballistics.sp"

#define CS2F_VERSION                 "0.5.7-m11"
#define CS2F_GAMEDATA_NAME           "l4d2_cs2feel"
#define CS2F_EXPECTED_SPREAD_OFFSET  6124   /* 0x17EC, IM-41 gamedata */
#define CS2F_SIG_ERROR_LEN           192

ConVar g_cvCS2FEnable = null;
ConVar g_cvStrict = null;
ConVar g_cvCS2FDebug = null;
ConVar g_cvSpreadMode = null;
ConVar g_cvSpreadScale = null;
ConVar g_cvSpreadT50 = null;
ConVar g_cvSpreadPosture = null;
ConVar g_cvSpreadDuckFloor = null;
ConVar g_cvSpreadAirFloor = null;
ConVar g_cvSpreadMove = null;
ConVar g_cvSpreadMoveStep = null;
ConVar g_cvSpreadMoveMax = null;
ConVar g_cvSpreadMoveOnset = null;
ConVar g_cvSpreadMoveFull = null;
ConVar g_cvSpreadTickProfile = null;
ConVar g_cvRecoilMode = null;
ConVar g_cvRecoilScale = null;
ConVar g_cvRecoilLog = null;
ConVar g_cvRecoilDecay = null;
ConVar g_cvRecoilDecayRate = null;
ConVar g_cvRecoilDecayDelay = null;
ConVar g_cvRecoilCurve = null;
ConVar g_cvRecoilCurveK = null;
ConVar g_cvRecoilCurveR = null;
ConVar g_cvRecoilCurveMin = null;
ConVar g_cvRecoilViewScale = null;
ConVar g_cvRecoilWrap = null;
ConVar g_cvBallisticsMode = null;
ConVar g_cvBallisticsScale = null;
ConVar g_cvBallisticsYaw = null;
ConVar g_cvBallisticsCurve = null;
ConVar g_cvBallisticsLog = null;
ConVar g_cvMoveScale = null;
ConVar g_cvDeterministic = null;

Handle  g_hGameConf = null;
int     g_iSpreadOffset = -1;
Address g_aReadSite = Address_Null;
Address g_aGunFire = Address_Null;
Address g_aPlayerFire = Address_Null;
Address g_aRateOfFire = Address_Null;

bool g_bSigReady = false;
bool g_bSigStrict = false;
bool g_bActive = false;
char g_sSigError[CS2F_SIG_ERROR_LEN];

/* [CS2Unified] Plugin myinfo removed by tools/sync_sources.ps1 (feel); the merged core owns it. */

/* ---- natives ------------------------------------------------------------- */

public APLRes CS2F_AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        strcopy(error, err_max, "CS2Feel is a Left 4 Dead 2 plugin");
        return APLRes_SilentFailure;
    }

    CreateNative("CS2F_IsActive",            Native_IsActive);
    CreateNative("CS2F_SignaturesValid",     Native_SignaturesValid);
    CreateNative("CS2F_GetWeaponCount",      Native_GetWeaponCount);
    CreateNative("CS2F_GetMappedCount",      Native_GetMappedCount);
    CreateNative("CS2F_GetWeaponId",         Native_GetWeaponId);
    CreateNative("CS2F_GetWeaponParams",     Native_GetWeaponParams);
    CreateNative("CS2F_GetNativeBaseline",   Native_GetNativeBaseline);
    return APLRes_Success;
}

public int Native_IsActive(Handle plugin, int numParams)
{
    return g_bActive ? 1 : 0;
}

public int Native_SignaturesValid(Handle plugin, int numParams)
{
    return g_bSigReady ? 1 : 0;
}

public int Native_GetWeaponCount(Handle plugin, int numParams)
{
    return CS2F_ConfigWeaponCount();
}

public int Native_GetMappedCount(Handle plugin, int numParams)
{
    return CS2F_ConfigMappedCount();
}

public int Native_GetWeaponId(Handle plugin, int numParams)
{
    char cls[CS2F_CLASS_LEN];
    GetNativeString(1, cls, sizeof(cls));
    return CS2F_ConfigWeaponIdByClass(cls);
}

public int Native_GetWeaponParams(Handle plugin, int numParams)
{
    int id = GetNativeCell(1);
    float mode0[CS2F_Param_Count];
    float mode1[CS2F_Param_Count];
    int recoilSeed = 0;
    int spreadSeed = 0;

    if (!CS2F_ConfigGetParams(id, mode0, mode1, recoilSeed, spreadSeed))
        return 0;

    SetNativeArray(2, mode0, sizeof(mode0));
    SetNativeArray(3, mode1, sizeof(mode1));
    SetNativeCellRef(4, recoilSeed);
    SetNativeCellRef(5, spreadSeed);
    return 1;
}

public int Native_GetNativeBaseline(Handle plugin, int numParams)
{
    char cls[CS2F_CLASS_LEN];
    GetNativeString(1, cls, sizeof(cls));

    float out[CS2F_Native_Count];
    if (!CS2F_ConfigGetNative(cls, out))
        return 0;

    SetNativeArray(2, out, sizeof(out));
    return 1;
}

/* ---- lifecycle ----------------------------------------------------------- */

/**
 * Push every MOD-2 ConVar into the spread module and resolve the tickrate
 * profile (TR-31 / TV-60..TV-62).  The measured rate comes from the engine, not
 * from the launch line: AUTO applies the 30 Hz profile at 28.5..31.5 Hz and the
 * 60 Hz profile at 57..63 Hz; every other rate (64/100 Hz included) resolves to
 * "none" so the operator's ConVars stay in charge.  100 tick is unmeasured on
 * this machine, so this is deliberately fail-safe rather than a guess.
 */
void CS2F_ApplySpreadConfig()
{
    CS2F_SpreadConfigure(GetConVarInt(g_cvSpreadMode),
                         GetConVarFloat(g_cvSpreadScale),
                         GetConVarFloat(g_cvSpreadT50));
    CS2F_SpreadConfigurePosture(GetConVarBool(g_cvSpreadPosture),
                                GetConVarFloat(g_cvSpreadDuckFloor),
                                GetConVarFloat(g_cvSpreadAirFloor));
    CS2F_SpreadConfigureMove(GetConVarBool(g_cvSpreadMove),
                             GetConVarFloat(g_cvSpreadMoveStep),
                             GetConVarFloat(g_cvSpreadMoveMax),
                             GetConVarFloat(g_cvSpreadMoveOnset),
                             GetConVarFloat(g_cvSpreadMoveFull));

    float tickrate = 0.0;
    float interval = GetTickInterval();
    if (interval > 0.0)
        tickrate = 1.0 / interval;

    int requested = GetConVarInt(g_cvSpreadTickProfile);
    int profile = CS2F_SpreadProfileResolve(tickrate, requested);
    CS2F_SpreadConfigureProfile(profile);

    LogCore("TICKPROFILE requested=%d hz=%.2f profile=%d floor=%.3f inc=%.3f duck=%.3f air=%.3f",
            requested, tickrate, profile,
            CS2F_SpreadProfileFloorScale(), CS2F_SpreadProfileIncScale(),
            CS2F_SpreadProfileDuckScale(), CS2F_SpreadProfileAirScale());
}

public void CS2F_OnPluginStart()
{
    CS2F_CreateConVars();

    CS2F_ConfigInit();
    CS2F_SpreadInit();
    CS2F_ApplySpreadConfig();
    CS2F_RecoilInit();
    CS2F_RecoilConfigure(GetConVarInt(g_cvRecoilMode),
                         GetConVarFloat(g_cvRecoilScale),
                         GetConVarBool(g_cvRecoilLog),
                         GetConVarBool(g_cvRecoilDecay),
                         GetConVarFloat(g_cvRecoilDecayRate),
                         GetConVarFloat(g_cvRecoilDecayDelay),
                         GetConVarFloat(g_cvRecoilViewScale));
    CS2F_RecoilConfigureCurve(GetConVarBool(g_cvRecoilCurve),
                              GetConVarFloat(g_cvRecoilCurveK),
                              GetConVarFloat(g_cvRecoilCurveR),
                              GetConVarFloat(g_cvRecoilCurveMin));
    CS2F_RecoilConfigureWrap(GetConVarBool(g_cvRecoilWrap));
    CS2F_BallisticsInit();
    CS2F_BallisticsConfigureCurve(GetConVarBool(g_cvBallisticsCurve),
                                 CS2F_RecoilCurveKValue(), CS2F_RecoilCurveRValue(), CS2F_RecoilCurveMinValue());
    CS2F_BallisticsConfigure(GetConVarInt(g_cvBallisticsMode),
                             GetConVarFloat(g_cvBallisticsScale),
                             GetConVarBool(g_cvBallisticsYaw),
                             GetConVarBool(g_cvBallisticsLog));
    CS2F_VerifySignatures();

    if (CS2F_ConfigLoadAll())
    {
        LogCore("CONFIG-OK weapons=%d mapped=%d native=%d",
                CS2F_ConfigWeaponCount(), CS2F_ConfigMappedCount(), CS2F_ConfigNativeCount());
    }
    else
    {
        char cfgErr[CS2F_ERROR_LEN];
        CS2F_ConfigLastError(cfgErr, sizeof(cfgErr));
        LogCore("CONFIG-ERROR %s", cfgErr);
    }

    RegAdminCmd("sm_cs2feel_status", CS2F_Cmd_Status, ADMFLAG_ROOT,
                "Print CS2Feel activation, signature and config state");
    RegAdminCmd("sm_cs2feel_reload", CS2F_Cmd_Reload, ADMFLAG_CONFIG,
                "Reload configs/cs2feel/*.cfg (previous table is kept on failure)");
    RegAdminCmd("sm_cs2feel_verify", CS2F_Cmd_Verify, ADMFLAG_ROOT,
                "Re-run the gamedata/signature guard");
    RegAdminCmd("sm_cs2feel_spreadtest", CS2F_Cmd_SpreadTest, ADMFLAG_ROOT,
                "Run the MOD-2 deterministic model self-test");
    RegAdminCmd("sm_cs2feel_recoiltest", CS2F_Cmd_RecoilTest, ADMFLAG_ROOT,
                "Run the MOD-3 deterministic mapping self-test");
    RegAdminCmd("sm_cs2feel_ballisticstest", CS2F_Cmd_BallisticsTest, ADMFLAG_ROOT,
                "Run the MOD-5 deterministic mapping self-test");

    HookConVarChange(g_cvCS2FEnable, CS2F_OnEnableChanged);
    HookConVarChange(g_cvStrict, OnStrictChanged);
    HookConVarChange(g_cvSpreadMode, OnSpreadChanged);
    HookConVarChange(g_cvSpreadScale, OnSpreadChanged);
    HookConVarChange(g_cvSpreadT50, OnSpreadChanged);
    HookConVarChange(g_cvSpreadPosture, OnSpreadChanged);
    HookConVarChange(g_cvSpreadDuckFloor, OnSpreadChanged);
    HookConVarChange(g_cvSpreadAirFloor, OnSpreadChanged);
    HookConVarChange(g_cvSpreadMove, OnSpreadChanged);
    HookConVarChange(g_cvSpreadMoveStep, OnSpreadChanged);
    HookConVarChange(g_cvSpreadMoveMax, OnSpreadChanged);
    HookConVarChange(g_cvSpreadMoveOnset, OnSpreadChanged);
    HookConVarChange(g_cvSpreadMoveFull, OnSpreadChanged);
    HookConVarChange(g_cvSpreadTickProfile, OnSpreadChanged);
    HookConVarChange(g_cvRecoilMode, OnRecoilChanged);
    HookConVarChange(g_cvRecoilScale, OnRecoilChanged);
    HookConVarChange(g_cvRecoilLog, OnRecoilChanged);
    HookConVarChange(g_cvRecoilDecay, OnRecoilChanged);
    HookConVarChange(g_cvRecoilDecayRate, OnRecoilChanged);
    HookConVarChange(g_cvRecoilDecayDelay, OnRecoilChanged);
    HookConVarChange(g_cvRecoilCurve, OnRecoilChanged);
    HookConVarChange(g_cvRecoilCurveK, OnRecoilChanged);
    HookConVarChange(g_cvRecoilCurveR, OnRecoilChanged);
    HookConVarChange(g_cvRecoilCurveMin, OnRecoilChanged);
    HookConVarChange(g_cvRecoilViewScale, OnRecoilChanged);
    HookConVarChange(g_cvRecoilWrap, OnRecoilChanged);
    HookConVarChange(g_cvBallisticsMode, OnBallisticsChanged);
    HookConVarChange(g_cvBallisticsScale, OnBallisticsChanged);
    HookConVarChange(g_cvBallisticsYaw, OnBallisticsChanged);
    HookConVarChange(g_cvBallisticsCurve, OnBallisticsChanged);
    HookConVarChange(g_cvBallisticsLog, OnBallisticsChanged);

    g_bActive = g_bSigReady && GetConVarBool(g_cvCS2FEnable);

    if (g_bActive)
        LogCore("ACTIVE version=%s strict=%d offset=%d weapons=%d mapped=%d",
                CS2F_VERSION, g_bSigStrict, g_iSpreadOffset,
                CS2F_ConfigWeaponCount(), CS2F_ConfigMappedCount());
    else
        LogCore("INACTIVE version=%s reason=%s", CS2F_VERSION,
                g_bSigReady ? "cs2feel_enable 0" : g_sSigError);

    CS2F_PrintStatus(0);
}

public void CS2F_OnPluginEnd()
{
    CS2F_ConfigShutdown();
    if (g_hGameConf != null)
    {
        delete g_hGameConf;
        g_hGameConf = null;
    }
}

/* ---- configuration / ConVars -------------------------------------------- */

void CS2F_CreateConVars()
{
    CreateConVar("cs2feel_version", CS2F_VERSION, "CS2Feel plugin version",
                 FCVAR_NOTIFY | FCVAR_DONTRECORD);
    g_cvCS2FEnable = CreateConVar("cs2feel_enable", "1",
                 "Master switch for the CS2Feel runtime layers (M4+). The M3 guard is unaffected.",
                 FCVAR_NOTIFY);
    g_cvStrict = CreateConVar("cs2feel_strict", "1",
                 "1 = require every gamedata signature to resolve; 0 = dev mode, essential guard only.",
                 FCVAR_NOTIFY);
    g_cvCS2FDebug = CreateConVar("cs2feel_debug", "0",
                 "Verbose logging (0/1).", FCVAR_NOTIFY);
    g_cvSpreadMode = CreateConVar("cs2feel_spread_mode", "0",
                 "MOD-2 mode: 0 = pass-through (native trajectory untouched), 1 = provisional CS2 profile.",
                 FCVAR_NOTIFY);
    g_cvSpreadScale = CreateConVar("cs2feel_spread_scale", "1.0",
                 "MOD-2 per-shot increment scale (mode 1 only).", FCVAR_NOTIFY);
    g_cvSpreadT50 = CreateConVar("cs2feel_spread_t50", "0.28125",
                 "MOD-2 recovery half-life in seconds (TV-14 measured; mode 1 only).", FCVAR_NOTIFY, true, 0.01, true, 10.0);
    g_cvSpreadPosture = CreateConVar("cs2feel_spread_posture", "0",
                 "MOD-2 posture term (TR-28): 0 = off (mode 1 keeps the TV-45 behaviour), 1 = scale the mode-1 floor per posture.",
                 FCVAR_NOTIFY);
    g_cvSpreadDuckFloor = CreateConVar("cs2feel_spread_duck_floor_scale", "1.81",
                 "MOD-2 crouch floor multiplier when the posture term is on (TV-56 decision: CS2 total-ratio semantics, AK-47 = 1.81).",
                 FCVAR_NOTIFY, true, 0.01, true, 100.0);
    g_cvSpreadAirFloor = CreateConVar("cs2feel_spread_air_floor_scale", "23.74",
                 "MOD-2 air/fall floor multiplier when the posture term is on (TV-55/TV-56 profile, AK-47 = 23.74).",
                 FCVAR_NOTIFY, true, 0.01, true, 100.0);
    g_cvSpreadMove = CreateConVar("cs2feel_spread_move", "0",
                 "MOD-2 movement term (TR-29): 0 = off, 1 = scale the mode-1 floor by a horizontal-speed ramp.",
                 FCVAR_NOTIFY);
    g_cvSpreadMoveStep = CreateConVar("cs2feel_spread_move_step", "8.7",
                 "Movement floor multiplier just above the onset speed (TV-57 AK calibration; 1.0 = no step).",
                 FCVAR_NOTIFY, true, 1.0, true, 100.0);
    g_cvSpreadMoveMax = CreateConVar("cs2feel_spread_move_max", "36.0",
                 "Movement floor multiplier at full speed (TV-57 AK calibration; 1.0 = no move term).",
                 FCVAR_NOTIFY, true, 1.0, true, 100.0);
    g_cvSpreadMoveOnset = CreateConVar("cs2feel_spread_move_onset", "73.0",
                 "Horizontal speed (u/s) where the movement term starts (0.34*AK vmax = 73.1, TV-20).",
                 FCVAR_NOTIFY, true, 0.0, true, 400.0);
    g_cvSpreadMoveFull = CreateConVar("cs2feel_spread_move_full", "215.0",
                 "Horizontal speed (u/s) where the movement floor reaches its maximum (AK vmax, TV-20).",
                 FCVAR_NOTIFY, true, 1.0, true, 400.0);
    g_cvSpreadTickProfile = CreateConVar("cs2feel_spread_tick_profile", "0",
                 "MOD-2 tickrate profile (TR-31): 0 = off, 1 = auto from tick rate, 2 = force 30-tick, 3 = force 60-tick, 4 = force 64-tick. AUTO knows 30/60/64 Hz; 100 tick is unmeasured and stays off.",
                 FCVAR_NOTIFY, true, 0.0, true, 4.0);
    g_cvRecoilMode = CreateConVar("cs2feel_recoil_mode", "1",
                 "MOD-3 mode: 0 = pass-through (native kick untouched), 1 = apply the archived CS2 punch sequence (default; TV-76).",
                 FCVAR_NOTIFY);
    g_cvRecoilScale = CreateConVar("cs2feel_recoil_scale", "1.0",
                 "MOD-3 punch scale applied to the sequence (default 1.0 = CS2 aim amplitude, TV-82; 2.4 was the TV-76 perceptual exaggeration).", FCVAR_NOTIFY);
    g_cvRecoilLog = CreateConVar("cs2feel_recoil_log", "0",
                 "Log every MOD-3 shot write (M5-WRITE) for measurement (0/1).", FCVAR_NOTIFY);
    g_cvRecoilDecay = CreateConVar("cs2feel_recoil_decay", "1",
                 "MOD-3 recoil-index recovery (TR-35, TV-71): 1 = CS2 exponential decay, 0 = legacy integer shot counter.",
                 FCVAR_NOTIFY);
    g_cvRecoilDecayRate = CreateConVar("cs2feel_recoil_decay_rate", "4.605",
                 "MOD-3 recoil-index decay rate in 1/s (CS2 measured 0.0720/tick at 64 Hz, TV-71).",
                 FCVAR_NOTIFY, true, 0.0, true, 50.0);
    g_cvRecoilDecayDelay = CreateConVar("cs2feel_recoil_decay_delay", "0.1334",
                 "MOD-3 decay dead time in seconds after the last shot (CS2 7/64 tick = 0.109 s; 4/30 tick here for L4D2, TV-71).",
                 FCVAR_NOTIFY, true, 0.0, true, 2.0);
    g_cvRecoilCurve = CreateConVar("cs2feel_recoil_curve", "1",
                 "TR-24 camera curve (TV-73): 1 = pre-emphasise each write so the rendered mean over one shot interval equals the target (0 = raw absolute write). Default 1 (TV-76).",
                 FCVAR_NOTIFY);
    g_cvRecoilCurveK = CreateConVar("cs2feel_recoil_curve_k", "0.5",
                 "Camera-curve decay coefficient k in 1/s (L4D2 punch decay dL/dt = -kL - r, TV-27).",
                 FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvRecoilCurveR = CreateConVar("cs2feel_recoil_curve_r", "20.0",
                 "Camera-curve decay constant drift r in deg/s (TV-27).",
                 FCVAR_NOTIFY, true, 0.0, true, 200.0);
    g_cvRecoilCurveMin = CreateConVar("cs2feel_recoil_curve_min", "2.0",
                 "Camera-curve floor in degrees: rows below it keep the raw write (avoids an early spurious kick).",
                 FCVAR_NOTIFY, true, 0.0, true, 20.0);
    g_cvRecoilViewScale = CreateConVar("cs2feel_recoil_view_scale", "1.0",
                 "MOD-3 camera(view) punch scale: 1.0 = neutral (matched default). 0.055x cumulative = experimental only (TV-81: CS2 view punch is a per-shot impulse accumulator; L4D2 visible decals follow this camera).",
                 FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvRecoilWrap = CreateConVar("cs2feel_recoil_wrap", "1",
                 "TR-49 infinite-ammo continuation: 1 (default, MT-14 / TV-100) = fold rows >= cycle back into the measured 64-shot steady cycle; 0 = stop past the measured table (legacy).",
                 FCVAR_NOTIFY);
    g_cvBallisticsMode = CreateConVar("cs2feel_ballistics_mode", "0",
                 "MOD-5 mode: 0 = pass-through (default since M-V14 / D-044), 1 = add the CS2 punch sequence to the usercmd aim. WARNING: mode 1 is a SECOND, client-invisible copy of the same sequence -- the punch field already drives the bullet 1:1 (M-V14 measured gain 1.00), so mode 1 puts the hit MOD-5's offset above the visible crosshair (4.3 deg measured in a 12-shot burst).",
                 FCVAR_NOTIFY);
    g_cvBallisticsScale = CreateConVar("cs2feel_ballistics_scale", "1.0",
                 "MOD-5 offset as a fraction of the VISIBLE punch (0.5.7-m11): the offset is (this / recoil_scale) * m_vecPunchAngle, applied only while fire is held. For CS2's camera 1.10 / bullet 1.00 structure set this to -0.10 with recoil_scale 1.10 (D-046/D-047); it is NOT the old table-row scale and must NOT be set equal to recoil_scale (that reproduces D-044 at ~2x).", FCVAR_NOTIFY);
    g_cvBallisticsCurve = CreateConVar("cs2feel_ballistics_curve", "1",
                 "Legacy (0.5.7-m11): MOD-5 no longer applies a curve of its own -- it reads the already-curved punch field -- so this cvar is kept only for config compatibility and has no effect on the offset.",
                 FCVAR_NOTIFY);
    g_cvBallisticsYaw = CreateConVar("cs2feel_ballistics_yaw", "1",
                 "MOD-5 yaw axis (0 = pitch only; 1 = also yaw; default 1 since TR-49, TV-36 1:1 copyback).", FCVAR_NOTIFY);
    g_cvBallisticsLog = CreateConVar("cs2feel_ballistics_log", "0",
                 "Log every MOD-5 shot row (M6-SHOT) for measurement (0/1).", FCVAR_NOTIFY);
    g_cvMoveScale = CreateConVar("cs2feel_move_scale", "1.0",
                 "Movement spread scaling for MOD-4 (reserved; no effect in M3).", FCVAR_NOTIFY);
    g_cvDeterministic = CreateConVar("cs2feel_deterministic", "1",
                 "1 = use the archived deterministic spray tables (MOD-5), 0 = native RNG.",
                 FCVAR_NOTIFY);
    /* Deliberately NO AutoExecConfig: its generated cfg/sourcemod/cs2feel.cfg is
       executed after listenserver.cfg and would overwrite a mode selected there
       (observed in the M5 run: recoil_mode was reset to 0).  Operators set cvars in
       server.cfg / listenserver.cfg instead. */
}

public void CS2F_OnEnableChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    g_bActive = g_bSigReady && GetConVarBool(g_cvCS2FEnable);
    LogCore("ENABLE active=%d", g_bActive);
}

public void OnStrictChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    CS2F_VerifySignatures();
    g_bActive = g_bSigReady && GetConVarBool(g_cvCS2FEnable);
    LogCore("STRICT-CHANGED strict=%d active=%d", g_bSigStrict, g_bActive);
    CS2F_PrintStatus(0);
}

public void OnSpreadChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    CS2F_ApplySpreadConfig();
    LogCore("SPREAD-CONFIG mode=%d scale=%.3f t50=%.5f posture=%d duck=%.4f air=%.4f move=%d step=%.4f max=%.4f onset=%.1f full=%.1f profile=%d",
            CS2F_SpreadMode(), GetConVarFloat(g_cvSpreadScale), CS2F_SpreadT50(),
            CS2F_SpreadPostureOn() ? 1 : 0,
            CS2F_SpreadDuckFloorScale(), CS2F_SpreadAirFloorScale(),
            CS2F_SpreadMoveOn() ? 1 : 0,
            CS2F_SpreadMoveStep(), CS2F_SpreadMoveMax(),
            CS2F_SpreadMoveOnset(), CS2F_SpreadMoveFull(),
            CS2F_SpreadProfile());
}

public void OnRecoilChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    CS2F_RecoilConfigure(GetConVarInt(g_cvRecoilMode),
                         GetConVarFloat(g_cvRecoilScale),
                         GetConVarBool(g_cvRecoilLog),
                         GetConVarBool(g_cvRecoilDecay),
                         GetConVarFloat(g_cvRecoilDecayRate),
                         GetConVarFloat(g_cvRecoilDecayDelay),
                         GetConVarFloat(g_cvRecoilViewScale));
    CS2F_RecoilConfigureCurve(GetConVarBool(g_cvRecoilCurve),
                              GetConVarFloat(g_cvRecoilCurveK),
                              GetConVarFloat(g_cvRecoilCurveR),
                              GetConVarFloat(g_cvRecoilCurveMin));
    CS2F_RecoilConfigureWrap(GetConVarBool(g_cvRecoilWrap));
    LogCore("RECOIL-CONFIG mode=%d scale=%.3f log=%d decay=%d rate=%.3f delay=%.4f curve=%d k=%.3f r=%.2f view=%.3f",
            CS2F_RecoilMode(), CS2F_RecoilScaleValue(), CS2F_RecoilLogEnabled() ? 1 : 0,
            CS2F_RecoilDecayEnabled() ? 1 : 0, CS2F_RecoilDecayRateValue(), CS2F_RecoilDecayDelayValue(),
            CS2F_RecoilCurveEnabled() ? 1 : 0, CS2F_RecoilCurveKValue(), CS2F_RecoilCurveRValue(),
            CS2F_RecoilViewScaleValue());
}

public void OnBallisticsChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    CS2F_BallisticsConfigureCurve(GetConVarBool(g_cvBallisticsCurve),
                                 CS2F_RecoilCurveKValue(), CS2F_RecoilCurveRValue(), CS2F_RecoilCurveMinValue());
    CS2F_BallisticsConfigure(GetConVarInt(g_cvBallisticsMode),
                             GetConVarFloat(g_cvBallisticsScale),
                             GetConVarBool(g_cvBallisticsYaw),
                             GetConVarBool(g_cvBallisticsLog));
    LogCore("BALLISTICS-CONFIG mode=%d scale=%.3f yaw=%d log=%d",
            CS2F_BallisticsMode(), CS2F_BallisticsScaleValue(),
            CS2F_BallisticsYawEnabled() ? 1 : 0,
            CS2F_BallisticsLogEnabled() ? 1 : 0,
        CS2F_BallisticsCurveEnabled() ? 1 : 0);
}

/* ---- MOD-2 runtime path -------------------------------------------------- */

public Action CS2F_OnPlayerRunCmd(int client, int &buttons, int &impulse,
                             float vel[3], float angles[3], int &weapon,
                             int &subtype, int &cmdnum, int &tickcount,
                             int &seed, int mouse[2])
{
    bool changed = false;
    if (g_bActive)
    {
        CS2F_SpreadOnRunCmd(client);
        CS2F_RecoilOnRunCmd(client);
        changed = CS2F_BallisticsOnRunCmd(client, buttons, angles);
    }
    return changed ? Plugin_Changed : Plugin_Continue;
}

/* ---- signature guard ----------------------------------------------------- */

void CS2F_VerifySignatures()
{
    g_bSigReady = false;
    g_bSigStrict = false;
    g_sSigError[0] = '\0';
    g_iSpreadOffset = -1;
    g_aReadSite = Address_Null;
    g_aGunFire = Address_Null;
    g_aPlayerFire = Address_Null;
    g_aRateOfFire = Address_Null;

    if (g_hGameConf != null)
    {
        delete g_hGameConf;
        g_hGameConf = null;
    }

    /* SourceMod 1.12 THROWS from LoadGameConfigFile when the file is absent (the
       exception aborts CS2F_OnPluginStart and the plugin never loads).  Check the path
       first so a missing gamedata degrades to a logged INACTIVE instead.  A file
       that exists but cannot be parsed still throws -> SM refuses the plugin, which
       is also fail-closed but less verbose; see TV-30 limitations. */
    char gdPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, gdPath, sizeof(gdPath), "gamedata/%s.txt", CS2F_GAMEDATA_NAME);
    if (!FileExists(gdPath))
    {
        Format(g_sSigError, sizeof(g_sSigError),
               "gamedata '%s.txt' not found at %s (Windows-only file; Linux unsupported)",
               CS2F_GAMEDATA_NAME, gdPath);
        return;
    }

    g_hGameConf = LoadGameConfigFile(CS2F_GAMEDATA_NAME);
    if (g_hGameConf == null)
    {
        Format(g_sSigError, sizeof(g_sSigError),
               "gamedata '%s.txt' failed to load (parse error; Windows-only file)",
               CS2F_GAMEDATA_NAME);
        return;
    }

    int offset = GameConfGetOffset(g_hGameConf, "CS2Feel::GunSpreadOffset");
    if (offset != CS2F_EXPECTED_SPREAD_OFFSET)
    {
        Format(g_sSigError, sizeof(g_sSigError),
               "GunSpreadOffset=%d, expected %d (wrong build, or no entry for this OS)",
               offset, CS2F_EXPECTED_SPREAD_OFFSET);
        return;
    }
    g_iSpreadOffset = offset;

    Address readSite = GameConfGetAddress(g_hGameConf, "CS2Feel::GunSpreadReadSite");
    if (readSite == Address_Null)
    {
        Format(g_sSigError, sizeof(g_sSigError),
               "signature CS2Feel::GunSpreadReadSite did not resolve");
        return;
    }

    /* The pattern ends with the absolute constant and starts with the movss that
       encodes [reg+0x17EC]; re-read the displacement so a build that merely
       re-uses the bytes elsewhere cannot pass. */
    int displacement = view_as<int>(
        LoadFromAddress(view_as<Address>(view_as<int>(readSite) + 4), NumberType_Int32));
    if (displacement != CS2F_EXPECTED_SPREAD_OFFSET)
    {
        Format(g_sSigError, sizeof(g_sSigError),
               "read site 0x%08X encodes displacement 0x%X, expected 0x%X",
               view_as<int>(readSite), displacement, CS2F_EXPECTED_SPREAD_OFFSET);
        return;
    }
    g_aReadSite = readSite;

    g_aGunFire = GameConfGetAddress(g_hGameConf, "CTerrorGun::FireBullet");
    g_aPlayerFire = GameConfGetAddress(g_hGameConf, "CTerrorPlayer::FireBullet");
    g_aRateOfFire = GameConfGetAddress(g_hGameConf, "CTerrorGun::GetRateOfFire");

    g_bSigStrict = (g_aGunFire != Address_Null
                    && g_aPlayerFire != Address_Null
                    && g_aRateOfFire != Address_Null);

    if (GetConVarBool(g_cvStrict) && !g_bSigStrict)
    {
        Format(g_sSigError, sizeof(g_sSigError),
               "strict: unresolved signature(s) gunFire=%d playerFire=%d rateOfFire=%d",
               g_aGunFire != Address_Null ? 1 : 0,
               g_aPlayerFire != Address_Null ? 1 : 0,
               g_aRateOfFire != Address_Null ? 1 : 0);
        return;
    }

    g_bSigReady = true;
}

/* ---- commands ------------------------------------------------------------ */

public Action CS2F_Cmd_Status(int client, int args)
{
    CS2F_PrintStatus(client);
    return Plugin_Handled;
}

public Action CS2F_Cmd_Reload(int client, int args)
{
    if (CS2F_ConfigLoadAll())
    {
        CS2F_Reply(client, "[CS2Feel] CONFIG-RELOAD-OK weapons=%d mapped=%d native=%d",
                   CS2F_ConfigWeaponCount(), CS2F_ConfigMappedCount(), CS2F_ConfigNativeCount());
        LogCore("CONFIG-RELOAD-OK weapons=%d mapped=%d native=%d",
                CS2F_ConfigWeaponCount(), CS2F_ConfigMappedCount(), CS2F_ConfigNativeCount());
        return Plugin_Handled;
    }

    char cfgErr[CS2F_ERROR_LEN];
    CS2F_ConfigLastError(cfgErr, sizeof(cfgErr));
    CS2F_Reply(client, "[CS2Feel] CONFIG-RELOAD-FAIL kept_weapons=%d error=%s",
               CS2F_ConfigWeaponCount(), cfgErr);
    LogCore("CONFIG-RELOAD-FAIL kept_weapons=%d error=%s",
            CS2F_ConfigWeaponCount(), cfgErr);
    return Plugin_Handled;
}

public Action CS2F_Cmd_Verify(int client, int args)
{
    CS2F_VerifySignatures();
    g_bActive = g_bSigReady && GetConVarBool(g_cvCS2FEnable);
    CS2F_PrintStatus(client);
    return Plugin_Handled;
}

public Action CS2F_Cmd_SpreadTest(int client, int args)
{
    char report[1024];
    CS2F_SpreadSelfTest(report, sizeof(report));
    CS2F_Reply(client, "[CS2Feel] %s", report);
    LogCore("%s", report);
    CS2F_SpreadPostureSelfTest(report, sizeof(report));
    CS2F_Reply(client, "[CS2Feel] %s", report);
    LogCore("%s", report);
    CS2F_SpreadMoveSelfTest(report, sizeof(report));
    CS2F_Reply(client, "[CS2Feel] %s", report);
    LogCore("%s", report);
    CS2F_SpreadProfileSelfTest(report, sizeof(report));
    CS2F_Reply(client, "[CS2Feel] %s", report);
    LogCore("%s", report);
    return Plugin_Handled;
}

public Action CS2F_Cmd_RecoilTest(int client, int args)
{
    char report[1024];
    CS2F_RecoilSelfTest(report, sizeof(report));
    CS2F_Reply(client, "[CS2Feel] %s", report);
    LogCore("%s", report);
    CS2F_RecoilDecaySelfTest(report, sizeof(report));
    CS2F_Reply(client, "[CS2Feel] %s", report);
    LogCore("%s", report);
    CS2F_RecoilCurveSelfTest(report, sizeof(report));
    CS2F_Reply(client, "[CS2Feel] %s", report);
    LogCore("%s", report);
    CS2F_RecoilWrapSelfTest(report, sizeof(report));
    CS2F_Reply(client, "[CS2Feel] %s", report);
    LogCore("%s", report);
    return Plugin_Handled;
}

public Action CS2F_Cmd_BallisticsTest(int client, int args)
{
    char report[1024];
    CS2F_BallisticsSelfTest(report, sizeof(report));
    CS2F_Reply(client, "[CS2Feel] %s", report);
    LogCore("%s", report);
    return Plugin_Handled;
}

/* ---- reporting ----------------------------------------------------------- */

void CS2F_PrintStatus(int client)
{
    CS2F_Reply(client,
        "[CS2Feel] STATUS version=%s active=%d sig=%d strict=%d offset=%d config=%s weapons=%d mapped=%d native=%d enable=%d viewscale=%.3f",
        CS2F_VERSION,
        g_bActive ? 1 : 0,
        g_bSigReady ? 1 : 0,
        g_bSigStrict ? 1 : 0,
        g_iSpreadOffset,
        CS2F_ConfigIsReady() ? "ok" : "fail",
        CS2F_ConfigWeaponCount(),
        CS2F_ConfigMappedCount(),
        CS2F_ConfigNativeCount(),
        GetConVarBool(g_cvCS2FEnable) ? 1 : 0,
        GetConVarFloat(g_cvRecoilViewScale));

    CS2F_Reply(client,
        "[CS2Feel] SCALES spread=%.3f recoil=%.3f move=%.3f deterministic=%d spread_mode=%d t50=%.5f recoil_mode=%d punch_weapons=%d",
        GetConVarFloat(g_cvSpreadScale),
        GetConVarFloat(g_cvRecoilScale),
        GetConVarFloat(g_cvMoveScale),
        GetConVarBool(g_cvDeterministic) ? 1 : 0,
        CS2F_SpreadMode(),
        CS2F_SpreadT50(),
        CS2F_RecoilMode(),
        CS2F_ConfigPunchWeaponCount());

    CS2F_Reply(client,
        "[CS2Feel] RECOILDECAY on=%d rate=%.3f delay=%.4f wrap=%d",
        CS2F_RecoilDecayEnabled() ? 1 : 0,
        CS2F_RecoilDecayRateValue(),
        CS2F_RecoilDecayDelayValue(),
        CS2F_RecoilWrapEnabled() ? 1 : 0);

    CS2F_Reply(client,
        "[CS2Feel] RECOILCURVE on=%d k=%.3f r=%.2f min=%.2f",
        CS2F_RecoilCurveEnabled() ? 1 : 0,
        CS2F_RecoilCurveKValue(),
        CS2F_RecoilCurveRValue(),
        CS2F_RecoilCurveMinValue());

    CS2F_Reply(client,
        "[CS2Feel] BALLISTICS mode=%d scale=%.3f yaw=%d log=%d curve=%d",
        CS2F_BallisticsMode(),
        CS2F_BallisticsScaleValue(),
        CS2F_BallisticsYawEnabled() ? 1 : 0,
        CS2F_BallisticsLogEnabled() ? 1 : 0,
        CS2F_BallisticsCurveEnabled() ? 1 : 0);

    float tickrate = 0.0;
    float interval = GetTickInterval();
    if (interval > 0.0)
        tickrate = 1.0 / interval;
    CS2F_Reply(client,
        "[CS2Feel] TICKPROFILE requested=%d hz=%.2f profile=%d floor=%.3f inc=%.3f duck=%.3f air=%.3f",
        GetConVarInt(g_cvSpreadTickProfile), tickrate, CS2F_SpreadProfile(),
        CS2F_SpreadProfileFloorScale(), CS2F_SpreadProfileIncScale(),
        CS2F_SpreadProfileDuckScale(), CS2F_SpreadProfileAirScale());

    if (g_bSigReady)
    {
        CS2F_Reply(client,
            "[CS2Feel] SIGS readSite=0x%08X gunFire=0x%08X playerFire=0x%08X rateOfFire=0x%08X",
            view_as<int>(g_aReadSite), view_as<int>(g_aGunFire),
            view_as<int>(g_aPlayerFire), view_as<int>(g_aRateOfFire));
    }
    else
    {
        CS2F_Reply(client, "[CS2Feel] SIG-ERROR %s", g_sSigError);
    }

    if (!CS2F_ConfigIsReady())
    {
        char cfgErr[CS2F_ERROR_LEN];
        CS2F_ConfigLastError(cfgErr, sizeof(cfgErr));
        CS2F_Reply(client, "[CS2Feel] CONFIG-ERROR %s", cfgErr);
    }
}

void CS2F_Reply(int client, const char[] fmt, any ...)
{
    char msg[512];
    VFormat(msg, sizeof(msg), fmt, 3);
    ReplyToCommand(client, "%s", msg);
}

void LogCore(const char[] fmt, any ...)
{
    char msg[512];
    VFormat(msg, sizeof(msg), fmt, 2);
    PrintToServer("[CS2Feel] %s", msg);
    if (g_cvCS2FDebug != null && GetConVarBool(g_cvCS2FDebug))
        LogMessage("[CS2Feel] %s", msg);
}
