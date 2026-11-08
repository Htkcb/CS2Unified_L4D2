/**
 * cs2movement.sp -- CS2 movement & crouch physics for Left 4 Dead 2.
 *
 * Version: 0.5.3 (2026-11-07) -- adds the water-depth slowdown layer
 *   (cs2movement_water.sp).  It is applied after the injury cap in both
 *   target functions, so depth costs speed on top of limp instead of
 *   replacing it.  No other physics path changed.
 * Version: 0.5.2 (2026-11-01) -- changes the shipped crouch_slide_time default
 *   from 0.10 s to 0.20 s (the CS2 friction-curve equivalent) and exposes
 *   crouch_slide_time / crouch_slide_min_speed as unified-layer managed
 *   parameters.  The slide curve and every other physics path are unchanged.
 *
 * Stage 1: global L4D2 movement cvars (apply/restore) -- the path with the
 *   longest confirmed behavioural track record.
 * Stage 2/3: per-player property and m_vecVelocity write paths.  Both were
 *   refuted at runtime (see docs/05_浜ゆ帴.md section 9); they stay behind gates
 *   that default to 0 and are kept only for reproduction.
 * Engine layer: per-player speed cap via the CPlayerMove::SetupMove pre-hook
 *   (see docs/07_绉诲姩閫熷害閾剧粨璁?md).  This is the only per-player path with a
 *   confirmed behavioural effect; enabled by default, fail-closed when DHooks
 *   or the matching gamedata signature is unavailable.
 * Default: ENABLED (cs2movement_enable 1 + engine per-player speed).
 *
 * Independent from CS2Feel_L4D2.  The spread/posture terms of that project are
 * explicitly out of scope.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>
#include "cs2movement_config.sp"
#include "cs2movement_injury.sp"
#include "cs2movement_water.sp"
#include "cs2movement_move.sp"
#include "cs2movement_crouch.sp"

#define CS2M_VERSION "0.5.3"
#define CS2M_PREFIX  "[CS2Movement]"

ConVar g_cvVersion = null;
ConVar g_cvCS2MEnable = null;
ConVar g_cvCS2MDebug = null;
ConVar g_cvMode = null;
ConVar g_cvApplyGlobal = null;

ConVar g_cvAccelerate = null;
ConVar g_cvFriction = null;
ConVar g_cvStopspeed = null;
ConVar g_cvAiraccelerate = null;
ConVar g_cvAirMaxWishspeed = null;
ConVar g_cvGravity = null;
ConVar g_cvMaxspeed = null;
ConVar g_cvMaxvelocity = null;
ConVar g_cvJumpImpulse = null;
ConVar g_cvJumpHeight = null;
ConVar g_cvBaseSpeed = null;
ConVar g_cvWeaponSpeedMode = null;
ConVar g_cvWalkMultiplier = null;
ConVar g_cvDuckMultiplier = null;

ConVar g_cvBhopEnable = null;
ConVar g_cvAutobhop = null;
ConVar g_cvBhopSpeedCap = null;
ConVar g_cvBhopWindow = null;
ConVar g_cvJumpSpamPenalty = null;
ConVar g_cvLandingPenalty = null;
ConVar g_cvLandingSpeedFactor = null;
ConVar g_cvLandingNextFactor = null;
ConVar g_cvLandingEnforce = null;
ConVar g_cvJumpEnforce = null;

ConVar g_cvCrouchEnable = null;
ConVar g_cvDuckRate = null;
ConVar g_cvTimeBetweenDucks = null;
ConVar g_cvStandEye = null;
ConVar g_cvDuckEye = null;
ConVar g_cvStandHull = null;
ConVar g_cvDuckHull = null;
ConVar g_cvAirCrouchShift = null;
ConVar g_cvCrouchJump = null;
ConVar g_cvCrouchView = null;

ConVar g_cvClientSync = null;
ConVar g_cvWriteProps = null;
ConVar g_cvSpeedEnforce = null;
ConVar g_cvCrouchEnforce = null;
ConVar g_cvWriteTiming = null;
ConVar g_cvCrouchSlide = null;
ConVar g_cvCrouchSlideClient = null;

/* [CS2Unified] Plugin myinfo removed by tools/sync_sources.ps1 (movement); the merged core owns it. */

public void CS2M_OnPluginStart()
{
    CS2M_CreateConVars();
    /* The version cvar can survive a reload with a stale string; keep it tied
     * to the compiled-in version so status/INTERFACE always agree with LOAD. */
    SetConVarString(g_cvVersion, CS2M_VERSION);
    CS2M_MoveCacheEngineCvars();
    CS2M_InjuryCacheEngineCvars();
    CS2M_MoveLoadWeaponTable();

    RegAdminCmd("sm_cs2movement_status", CS2M_Cmd_Status, ADMFLAG_ROOT, "Print CS2Movement status.");
    RegAdminCmd("sm_cs2movement_apply", CS2M_Cmd_Apply, ADMFLAG_ROOT, "Apply CS2 movement global cvars and enable.");
    RegAdminCmd("sm_cs2movement_unapply", CS2M_Cmd_Unapply, ADMFLAG_ROOT, "Restore global cvars and disable.");
    RegAdminCmd("sm_cs2movement_reload", CS2M_Cmd_Reload, ADMFLAG_ROOT, "Reload cfg/sourcemod/cs2movement.cfg.");
    RegAdminCmd("sm_cs2movement_selftest", CS2M_Cmd_SelfTest, ADMFLAG_ROOT, "Run CS2Movement static self-test.");

    HookEvent("player_jump", CS2M_Event_PlayerJump, EventHookMode_Post);

    AutoExecConfig(true, "cs2movement");

    PrintToServer("%s LOAD version=%s (effective state reported after configs execute)", CS2M_PREFIX, CS2M_VERSION);
}

public void CS2M_OnConfigsExecuted()
{
    CS2M_ConfigValidateAll();
    /* The engine-owned survivor_crouch_speed is registered before plugins load
     * in practice, but retry here once in case a stripped/listen server is late:
     * without it the client-slide layer stays fail-closed and status says
     * client_slide=missing. */
    if (g_cvSurvivorCrouchSpeed == null)
        g_cvSurvivorCrouchSpeed = FindConVar("survivor_crouch_speed");
    /* A map change must never inherit a raised replicated crouch cap. */
    CS2M_MoveClientSlideForceRestore();
    /* A map change re-executes cfg/sourcemod/cs2movement.cfg, so this is the
     * third place (after the convar callback and the unified settings timer)
     * where "slide on but duck layer off" can appear.  Latched: one line per
     * transition, never one per map. */
    CS2M_MoveCheckSlideReadiness("configs");

    if (GetConVarBool(g_cvCS2MEnable) && GetConVarBool(g_cvApplyGlobal))
    {
        CS2M_MoveApplyGlobal();
        /* Runs after every map start as well as the first one: L4D2 re-forces
         * sv_maxspeed (and possibly others) when a map loads, and ApplyGlobal
         * early-returns once applied, so without this the global layer silently
         * loses those cvars after a changelevel. */
        CS2M_MoveReassertGlobal();
        /* The external reset lands a few seconds AFTER this callback (measured:
         * +12.3 s vs CS2M_OnConfigsExecuted), so keep a cheap convergence timer. */
        CS2M_MoveStartReassertTimer();
    }

    PrintToServer("%s ACTIVE enable=%d apply_global=%d write_props=%d speed_enforce=%d engine_speed=%d duck_speed=%d lowspeed_sustain=%d air_jump_speed=%d crouch_slide=%d injury=%d injury_mode=%d water=%d water_slow=%.2f",
                  CS2M_PREFIX,
                  GetConVarInt(g_cvCS2MEnable),
                  GetConVarInt(g_cvApplyGlobal),
                  GetConVarInt(g_cvWriteProps),
                  GetConVarInt(g_cvSpeedEnforce),
                  GetConVarInt(FindConVar("cs2movement_engine_speed")),
                  GetConVarInt(FindConVar("cs2movement_duck_speed")),
                  GetConVarInt(FindConVar("cs2movement_lowspeed_sustain")),
                  GetConVarInt(FindConVar("cs2movement_air_jump_speed")),
                  GetConVarInt(FindConVar("cs2movement_crouch_slide")),
                  GetConVarInt(g_cvInjuryEnable),
                  GetConVarInt(g_cvInjuryMode),
                  GetConVarInt(g_cvWaterEnable),
                  GetConVarFloat(g_cvWaterSlowdown));
}

public void CS2M_OnPluginEnd()
{
    /* Never leave the global replicated crouch cap raised after an unload. */
    CS2M_MoveClientSlideForceRestore();
    CS2M_MoveShutdownEngineSpeedHook();
    CS2M_MoveShutdownDuckSpeedHook();
    CS2M_MoveShutdownSustainHook();
    CS2M_MoveRestoreGlobal();
    if (g_mWeaponSpeeds != null)
    {
        delete g_mWeaponSpeeds;
        g_mWeaponSpeeds = null;
    }
    PrintToServer("%s UNLOAD restored", CS2M_PREFIX);
}

public void CS2M_OnClientPutInServer(int client)
{
    CS2M_MoveResetClient(client);
    CS2M_CrouchResetClient(client);
    CS2M_InjuryResetClient(client);
    CS2M_WaterResetClient(client);
    CS2M_MoveCacheClientAddress(client);
    SDKHook(client, SDKHook_PostThink, CS2M_OnPostThink);
}

public void CS2M_OnClientDisconnect(int client)
{
    SDKUnhook(client, SDKHook_PostThink, CS2M_OnPostThink);
    CS2M_MoveResetClient(client);
    CS2M_CrouchResetClient(client);
    CS2M_InjuryResetClient(client);
    CS2M_WaterResetClient(client);
}

public Action CS2M_OnPlayerRunCmd(int client, int &buttons, int &impulse,
                             float vel[3], float angles[3], int &weapon,
                             int &subtype, int &cmdnum, int &tickcount,
                             int &seed, int mouse[2])
{
    if (!GetConVarBool(g_cvCS2MEnable))
        return Plugin_Continue;

    bool changed = false;
    CS2M_MoveOnPlayerRunCmd(client, buttons, changed);
    CS2M_CrouchOnPlayerRunCmd(client, buttons, changed);

    if (GetConVarInt(g_cvWriteTiming) == 0)
    {
        CS2M_MoveApplyPlayerSpeed(client, buttons);
        CS2M_CrouchApplyState(client, buttons);
    }

    return changed ? Plugin_Changed : Plugin_Continue;
}

public void CS2M_OnPostThink(int client)
{
    if (!GetConVarBool(g_cvCS2MEnable))
        return;
    if (GetConVarInt(g_cvWriteTiming) != 1)
        return;

    int buttons = g_iMoveLastButtons[client];
    CS2M_MoveApplyPlayerSpeed(client, buttons);
    CS2M_CrouchApplyState(client, buttons);
}

public void CS2M_Event_PlayerJump(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (client > 0)
        CS2M_MoveOnPlayerJump(client);
}

public void CS2M_OnEnableChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (GetConVarBool(g_cvCS2MEnable))
    {
        if (GetConVarBool(g_cvApplyGlobal))
        {
            CS2M_MoveApplyGlobal();
            CS2M_MoveStartReassertTimer();
        }
        PrintToServer("%s ENABLE on", CS2M_PREFIX);
    }
    else
    {
        CS2M_MoveClientSlideForceRestore();
        CS2M_MoveRestoreGlobal();
        PrintToServer("%s ENABLE off", CS2M_PREFIX);
    }
}

public void CS2M_OnApplyGlobalChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (!GetConVarBool(g_cvCS2MEnable))
        return;

    if (GetConVarBool(g_cvApplyGlobal))
    {
        CS2M_MoveApplyGlobal();
        CS2M_MoveStartReassertTimer();
    }
    else
        CS2M_MoveRestoreGlobal();
}

public void CS2M_OnMoveTargetChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (GetConVarBool(g_cvCS2MEnable) && GetConVarBool(g_cvApplyGlobal) && CS2M_MoveIsGlobalApplied())
        CS2M_MoveReapplyGlobal();
}

/* The slide only works when the duck layer is armed; telling the admin that at
 * the moment they flip the switch is the whole point of this callback.  Turning
 * the slide (or its client half) off must also release the replicated crouch
 * cap immediately, not on the next tick. */
public void OnCrouchSlideChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    CS2M_MoveClientSlideForceRestore();
    CS2M_MoveCheckSlideReadiness("convar");
}

public void OnCrouchSlideClientChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (!GetConVarBool(convar))
        CS2M_MoveClientSlideForceRestore();
}

public Action CS2M_Cmd_Status(int client, int args)
{
    ReplyToCommand(client, "%s version=%s enable=%d debug=%d mode=%d apply_global=%d",
                   CS2M_PREFIX, CS2M_VERSION, GetConVarInt(g_cvCS2MEnable), GetConVarInt(g_cvCS2MDebug),
                   GetConVarInt(g_cvMode), GetConVarInt(g_cvApplyGlobal));
    ReplyToCommand(client, "%s engine=SetupMove speed cap; Stage 2/3 property writes refuted at runtime (gates default 0)",
                   CS2M_PREFIX);

    CS2M_PrintInterface(client);
    CS2M_MoveStatus(client);
    CS2M_InjuryStatus(client);
    CS2M_WaterStatus(client);
    CS2M_CrouchStatus(client);
    return Plugin_Handled;
}

stock void CS2M_PrintInterface(int client)
{
    char version[32];
    GetConVarString(g_cvVersion, version, sizeof(version));

    ReplyToCommand(client, "%s INTERFACE version=%s", CS2M_PREFIX, version);
    ReplyToCommand(client,
        "%s   move airWish=%.1f jumpImpulse=%.3f jumpHeight=%.1f baseSpeed=%.1f speedMode=%d walk=%.2f duck=%.2f",
        CS2M_PREFIX,
        GetConVarFloat(g_cvAirMaxWishspeed),
        GetConVarFloat(g_cvJumpImpulse),
        GetConVarFloat(g_cvJumpHeight),
        GetConVarFloat(g_cvBaseSpeed),
        GetConVarInt(g_cvWeaponSpeedMode),
        GetConVarFloat(g_cvWalkMultiplier),
        GetConVarFloat(g_cvDuckMultiplier));
    ReplyToCommand(client,
        "%s   bhop enable=%d auto=%d cap=%.1f window=%.6f spam=%.6f landing=%d speed=%.2f next=%.2f enforce=%d jumpEnforce=%d",
        CS2M_PREFIX,
        GetConVarInt(g_cvBhopEnable),
        GetConVarInt(g_cvAutobhop),
        GetConVarFloat(g_cvBhopSpeedCap),
        GetConVarFloat(g_cvBhopWindow),
        GetConVarFloat(g_cvJumpSpamPenalty),
        GetConVarInt(g_cvLandingPenalty),
        GetConVarFloat(g_cvLandingSpeedFactor),
        GetConVarFloat(g_cvLandingNextFactor),
        GetConVarInt(g_cvLandingEnforce),
        GetConVarInt(g_cvJumpEnforce));
    ReplyToCommand(client,
        "%s   crouch enable=%d rate=%.2f tbd=%.3f eye=%.1f/%.1f hull=%.1f/%.1f airShift=%.1f jump=%d view=%d",
        CS2M_PREFIX,
        GetConVarInt(g_cvCrouchEnable),
        GetConVarFloat(g_cvDuckRate),
        GetConVarFloat(g_cvTimeBetweenDucks),
        GetConVarFloat(g_cvStandEye),
        GetConVarFloat(g_cvDuckEye),
        GetConVarFloat(g_cvStandHull),
        GetConVarFloat(g_cvDuckHull),
        GetConVarFloat(g_cvAirCrouchShift),
        GetConVarInt(g_cvCrouchJump),
        GetConVarInt(g_cvCrouchView));
    ReplyToCommand(client, "%s   client sync=%d writeProps=%d speedEnforce=%d crouchEnforce=%d writeTiming=%d",
        CS2M_PREFIX, GetConVarInt(g_cvClientSync), GetConVarInt(g_cvWriteProps),
        GetConVarInt(g_cvSpeedEnforce), GetConVarInt(g_cvCrouchEnforce), GetConVarInt(g_cvWriteTiming));
}

public Action CS2M_Cmd_Apply(int client, int args)
{
    SetConVarInt(g_cvCS2MEnable, 1);
    if (GetConVarBool(g_cvApplyGlobal))
        CS2M_MoveApplyGlobal();

    ReplyToCommand(client, "%s APPLIED enable=1 global=%d (engine speed path gated by engine_speed)",
                   CS2M_PREFIX, CS2M_MoveIsGlobalApplied() ? 1 : 0);
    return Plugin_Handled;
}

public Action CS2M_Cmd_Unapply(int client, int args)
{
    SetConVarInt(g_cvCS2MEnable, 0);
    CS2M_MoveRestoreGlobal();
    ReplyToCommand(client, "%s UNAPPLIED enable=0 global=%d", CS2M_PREFIX, CS2M_MoveIsGlobalApplied() ? 1 : 0);
    return Plugin_Handled;
}

public Action CS2M_Cmd_Reload(int client, int args)
{
    ServerCommand("exec sourcemod/cs2movement.cfg");
    CS2M_MoveLoadWeaponTable();
    ReplyToCommand(client, "%s RELOAD requested: exec sourcemod/cs2movement.cfg + weapon table", CS2M_PREFIX);
    return Plugin_Handled;
}

public Action CS2M_Cmd_SelfTest(int client, int args)
{
    int checks = 0;
    int fails = 0;

    char cvars[][] =
    {
        "cs2movement_version",
        "cs2movement_enable",
        "cs2movement_debug",
        "cs2movement_mode",
        "cs2movement_apply_global",
        "cs2movement_accelerate",
        "cs2movement_friction",
        "cs2movement_stopspeed",
        "cs2movement_airaccelerate",
        "cs2movement_air_max_wishspeed",
        "cs2movement_gravity",
        "cs2movement_maxspeed",
        "cs2movement_maxvelocity",
        "cs2movement_jump_impulse",
        "cs2movement_jump_height",
        "cs2movement_base_speed",
        "cs2movement_weapon_speed_mode",
        "cs2movement_walk_multiplier",
        "cs2movement_duck_multiplier",
        "cs2movement_bhop_enable",
        "cs2movement_autobhop",
        "cs2movement_bhop_speed_cap",
        "cs2movement_bhop_window",
        "cs2movement_jump_spam_penalty",
        "cs2movement_landing_penalty",
        "cs2movement_landing_speed_factor",
        "cs2movement_landing_next_factor",
        "cs2movement_landing_enforce",
        "cs2movement_jump_enforce",
        "cs2movement_crouch_enable",
        "cs2movement_duck_rate",
        "cs2movement_time_between_ducks",
        "cs2movement_stand_eye",
        "cs2movement_duck_eye",
        "cs2movement_stand_hull",
        "cs2movement_duck_hull",
        "cs2movement_air_crouch_shift",
        "cs2movement_crouch_jump",
        "cs2movement_crouch_view",
        "cs2movement_client_sync",
        "cs2movement_write_props",
        "cs2movement_speed_enforce",
        "cs2movement_crouch_enforce",
        "cs2movement_write_timing",
        "cs2movement_lowspeed_sustain",
        "cs2movement_injury_enable",
        "cs2movement_injury_mode",
        "cs2movement_injury_health",
        "cs2movement_injury_speed",
        "cs2movement_injury_temp_health",
        "cs2movement_injury_adrenaline",
        "cs2movement_water_enable",
        "cs2movement_water_slowdown"
    };

    for (int i = 0; i < sizeof(cvars); i++)
        CS2M_TestConVar(cvars[i], checks, fails);

    char engineCvars[][] =
    {
        "sv_accelerate",
        "sv_friction",
        "sv_stopspeed",
        "sv_airaccelerate",
        "sv_gravity",
        "sv_maxspeed",
        "sv_maxvelocity"
    };

    for (int i = 0; i < sizeof(engineCvars); i++)
        CS2M_TestEngineCvar(engineCvars[i], checks, fails);

    checks++;
    if (FindConVar("sv_air_max_wishspeed") != null)
        ReplyToCommand(client, "%s SELFTEST INFO sv_air_max_wishspeed exists unexpectedly", CS2M_PREFIX);
    checks++;
    if (FindConVar("sv_jump_impulse") != null)
        ReplyToCommand(client, "%s SELFTEST INFO sv_jump_impulse exists unexpectedly", CS2M_PREFIX);
    checks++;
    if (FindConVar("sv_timebetweenducks") != null)
        ReplyToCommand(client, "%s SELFTEST INFO sv_timebetweenducks exists unexpectedly", CS2M_PREFIX);

    checks++;
    if (!CS2M_ConfigFileExists())
        ReplyToCommand(client, "%s SELFTEST WARN cfg/sourcemod/cs2movement.cfg not found yet", CS2M_PREFIX);

    checks++;
    if (GetConVarFloat(g_cvDuckRate) <= 0.0)
    {
        fails++;
        ReplyToCommand(client, "%s SELFTEST FAIL duck_rate <= 0", CS2M_PREFIX);
    }

    checks++;
    if (GetConVarFloat(g_cvTimeBetweenDucks) < 0.0)
    {
        fails++;
        ReplyToCommand(client, "%s SELFTEST FAIL time_between_ducks < 0", CS2M_PREFIX);
    }

    /* 0.5.0: the limp layer must always resolve a usable threshold, otherwise
     * it silently disables the vanilla low-health slowdown. */
    checks++;
    float injuryThreshold = CS2M_InjuryThreshold();
    if (injuryThreshold <= 0.0)
    {
        fails++;
        ReplyToCommand(client, "%s SELFTEST FAIL injury threshold <= 0 (engine survivor_limp_health missing and no override)", CS2M_PREFIX);
    }
    else
    {
        ReplyToCommand(client, "%s SELFTEST INFO injury mode=%d threshold=%.1f limp_speed=%.1f base_speed=%.1f",
                       CS2M_PREFIX, GetConVarInt(g_cvInjuryMode), injuryThreshold,
                       CS2M_InjuryLimpSpeed(), CS2M_InjuryBaseSpeed());
    }

    int probe = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            probe = i;
            break;
        }
    }

    if (probe > 0)
    {
        ReplyToCommand(client, "%s SELFTEST PROPS client=%d duckTime=%d ducking=%d ducked=%d inDuckJump=%d viewOffset=%d maxspeed=%d",
                       CS2M_PREFIX, probe,
                       HasEntProp(probe, Prop_Data, "m_nDuckTimeMsecs") || HasEntProp(probe, Prop_Send, "m_nDuckTimeMsecs") ? 1 : 0,
                       HasEntProp(probe, Prop_Data, "m_bDucking") || HasEntProp(probe, Prop_Send, "m_bDucking") ? 1 : 0,
                       HasEntProp(probe, Prop_Data, "m_bDucked") || HasEntProp(probe, Prop_Send, "m_bDucked") ? 1 : 0,
                       HasEntProp(probe, Prop_Data, "m_bInDuckJump") || HasEntProp(probe, Prop_Send, "m_bInDuckJump") ? 1 : 0,
                       HasEntProp(probe, Prop_Data, "m_vecViewOffset") || HasEntProp(probe, Prop_Send, "m_vecViewOffset") ? 1 : 0,
                       HasEntProp(probe, Prop_Data, "m_flMaxspeed") || HasEntProp(probe, Prop_Send, "m_flMaxspeed") ? 1 : 0);
    }
    else
    {
        ReplyToCommand(client, "%s SELFTEST PROPS skipped (no non-fake client)", CS2M_PREFIX);
    }

    if (fails == 0)
        ReplyToCommand(client, "%s SELFTEST PASS checks=%d", CS2M_PREFIX, checks);
    else
        ReplyToCommand(client, "%s SELFTEST FAIL checks=%d fails=%d", CS2M_PREFIX, checks, fails);

    return Plugin_Handled;
}

stock void CS2M_TestConVar(const char[] name, int &checks, int &fails)
{
    checks++;
    if (FindConVar(name) == null)
    {
        fails++;
        ReplyToCommand(0, "%s SELFTEST FAIL missing cvar %s", CS2M_PREFIX, name);
    }
}

stock void CS2M_TestEngineCvar(const char[] name, int &checks, int &fails)
{
    checks++;
    if (FindConVar(name) == null)
    {
        fails++;
        ReplyToCommand(0, "%s SELFTEST FAIL missing engine cvar %s", CS2M_PREFIX, name);
    }
}

void CS2M_CreateConVars()
{
    g_cvVersion = CreateConVar("cs2movement_version", CS2M_VERSION, "CS2Movement plugin version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    g_cvCS2MEnable = CreateConVar("cs2movement_enable", "1", "Master switch. 0 = no behavior; 1 = global cvars + engine per-player speed.", FCVAR_NOTIFY);
    g_cvCS2MDebug = CreateConVar("cs2movement_debug", "0", "Verbose per-command logging (0/1).", FCVAR_NOTIFY);
    g_cvMode = CreateConVar("cs2movement_mode", "1", "0=off, 1=server-only, 2=server+client sync, 3=server+props (experimental).", FCVAR_NOTIFY);
    g_cvApplyGlobal = CreateConVar("cs2movement_apply_global", "1", "Apply/restore L4D2 global movement cvars (0/1).", FCVAR_NOTIFY);

    g_cvAccelerate = CreateConVar("cs2movement_accelerate", "5.5", "Target sv_accelerate (CS2 5.5).", FCVAR_NOTIFY, true, 0.1, true, 20.0);
    g_cvFriction = CreateConVar("cs2movement_friction", "5.2", "Target sv_friction (CS2 5.2).", FCVAR_NOTIFY, true, 0.1, true, 20.0);
    g_cvStopspeed = CreateConVar("cs2movement_stopspeed", "80.0", "Target sv_stopspeed (CS2 80 u/s).", FCVAR_NOTIFY, true, 0.0, true, 500.0);
    g_cvAiraccelerate = CreateConVar("cs2movement_airaccelerate", "12.0", "Target sv_airaccelerate (CS2 12).", FCVAR_NOTIFY, true, 0.0, true, 100.0);
    g_cvAirMaxWishspeed = CreateConVar("cs2movement_air_max_wishspeed", "30.0", "CS2 air addSpeed cap (L4D2 has no sv_air_max_wishspeed; used by model).", FCVAR_NOTIFY, true, 0.0, true, 200.0);
    g_cvGravity = CreateConVar("cs2movement_gravity", "800.0", "Target sv_gravity (CS2 800 u/s^2).", FCVAR_NOTIFY, true, 100.0, true, 2000.0);
    g_cvMaxspeed = CreateConVar("cs2movement_maxspeed", "1000.0", "Target sv_maxspeed. L4D2 ships 1000; lowering it also caps special-infected abilities (the Charger charge uses z_charge_max_speed 500).", FCVAR_NOTIFY, true, 50.0, true, 1000.0);
    g_cvMaxvelocity = CreateConVar("cs2movement_maxvelocity", "3500.0", "Target sv_maxvelocity (CS2 3500).", FCVAR_NOTIFY, true, 500.0, true, 10000.0);
    g_cvJumpImpulse = CreateConVar("cs2movement_jump_impulse", "301.993", "CS2 jump impulse (L4D2 has no sv_jump_impulse).", FCVAR_NOTIFY, true, 100.0, true, 500.0);
    g_cvJumpHeight = CreateConVar("cs2movement_jump_height", "57.0", "CS2 nominal jump height in units.", FCVAR_NOTIFY, true, 20.0, true, 100.0);
    g_cvBaseSpeed = CreateConVar("cs2movement_base_speed", "250.0", "Fallback CS2 ground speed for unmapped weapons.", FCVAR_NOTIFY, true, 50.0, true, 400.0);
    g_cvWeaponSpeedMode = CreateConVar("cs2movement_weapon_speed_mode", "1", "0=native L4D2 speed, 1=CS2 weapon speed table.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvWalkMultiplier = CreateConVar("cs2movement_walk_multiplier", "0.52", "CS2 walk multiplier.", FCVAR_NOTIFY, true, 0.1, true, 1.0);
    g_cvDuckMultiplier = CreateConVar("cs2movement_duck_multiplier", "0.34", "CS2 duck speed multiplier.", FCVAR_NOTIFY, true, 0.1, true, 1.0);

    g_cvBhopEnable = CreateConVar("cs2movement_bhop_enable", "0", "Bhop window/limit model. Unreachable at 30 Hz; no behavioural effect, keep 0.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvAutobhop = CreateConVar("cs2movement_autobhop", "0", "Auto-bhop. Holding jump produces no new edge, so it cannot chain jumps; keep 0.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvBhopSpeedCap = CreateConVar("cs2movement_bhop_speed_cap", "286.0", "Bhop landing speed cap (CS2 286 u/s).", FCVAR_NOTIFY, true, 100.0, true, 500.0);
    g_cvBhopWindow = CreateConVar("cs2movement_bhop_window", "0.0078125", "Bhop jump window seconds (CS2 1/128 s; 30 Hz quantized).", FCVAR_NOTIFY, true, 0.0, true, 0.2);
    g_cvJumpSpamPenalty = CreateConVar("cs2movement_jump_spam_penalty", "0.015625", "Jump press lockout seconds (CS2 1/64 s).", FCVAR_NOTIFY, true, 0.0, true, 0.2);
    g_cvLandingPenalty = CreateConVar("cs2movement_landing_penalty", "1", "Enable landing penalty model (Stage 3).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvLandingSpeedFactor = CreateConVar("cs2movement_landing_speed_factor", "0.75", "Landing speed factor (CS2 flat-bhop approx 0.75).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvLandingNextFactor = CreateConVar("cs2movement_landing_next_factor", "0.88", "Next-jump speed factor after landing (approx 0.88).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvLandingEnforce = CreateConVar("cs2movement_landing_enforce", "0", "Write m_vecVelocity for the landing penalty. Refuted at runtime (engine re-accelerates); keep 0.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvJumpEnforce = CreateConVar("cs2movement_jump_enforce", "0", "Write m_vecVelocity[2] for the jump impulse. No-op: native impulse is already 301.993; keep 0.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvCrouchEnable = CreateConVar("cs2movement_crouch_enable", "1", "Enable crouch model (press limit + gated Stage 2 duck state).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvDuckRate = CreateConVar("cs2movement_duck_rate", "6.4", "Duck amount rate per second (CS2 measured 6.4; alternative 8.0).", FCVAR_NOTIFY, true, 1.0, true, 20.0);
    g_cvTimeBetweenDucks = CreateConVar("cs2movement_time_between_ducks", "0.4", "Minimum seconds between duck presses (CS2 sv_timebetweenducks 0.4).", FCVAR_NOTIFY, true, 0.0, true, 2.0);
    g_cvStandEye = CreateConVar("cs2movement_stand_eye", "64.0", "Standing eye height (CS:GO inheritance; CS2 unconfirmed).", FCVAR_NOTIFY, true, 40.0, true, 100.0);
    g_cvDuckEye = CreateConVar("cs2movement_duck_eye", "46.0", "Crouched eye height (CS:GO inheritance; CS2 unconfirmed).", FCVAR_NOTIFY, true, 20.0, true, 80.0);
    g_cvStandHull = CreateConVar("cs2movement_stand_hull", "72.0", "Standing hull height reference.", FCVAR_NOTIFY, true, 40.0, true, 100.0);
    g_cvDuckHull = CreateConVar("cs2movement_duck_hull", "54.0", "Crouched hull height reference.", FCVAR_NOTIFY, true, 30.0, true, 80.0);
    g_cvAirCrouchShift = CreateConVar("cs2movement_air_crouch_shift", "9.0", "In-air crouch origin shift (CS2 9 u).", FCVAR_NOTIFY, true, 0.0, true, 30.0);
    g_cvCrouchJump = CreateConVar("cs2movement_crouch_jump", "1", "Enable crouch-jump model (Stage 3).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvCrouchView = CreateConVar("cs2movement_crouch_view", "0", "Write m_vecViewOffset for crouch view. Native 44/62 overrides it; keep 0.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvClientSync = CreateConVar("cs2movement_client_sync", "0", "Send replicated cvar values to clients. Dead config: no code path uses it; keep 0.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvWriteProps = CreateConVar("cs2movement_write_props", "1", "Allow per-player property writes. Required by the engine speed path.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvSpeedEnforce = CreateConVar("cs2movement_speed_enforce", "1", "Write m_flMaxspeed per player (requires write_props). Required by the engine speed path.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    CreateConVar("cs2movement_engine_speed", "1", "Use the engine-layer per-player speed path (SetupMove hook; requires write_props + speed_enforce).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    CreateConVar("cs2movement_duck_speed", "1", "Use the engine-layer per-player crouch speed path (CCS CheckParameters hook; requires write_props + speed_enforce).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    CreateConVar("cs2movement_duck_speed_min", "76.0", "Lowest crouch speed the ground friction model can sustain (80*5.2/5.5 = 75.64). Lower CS2 targets are floored to this; 0 disables the floor.", FCVAR_NOTIFY, true, 0.0, true, 200.0);
CreateConVar("cs2movement_air_jump_speed", "0", "Keep the weapon maxspeed while airborne when L4D2's automatic jump-crouch puts the player in the duck hull (CS2 does not duck in the air). Restores CS2 air acceleration at 64 tick, where the engine duck speed would otherwise cut the air accelerate term from 30 to ~14 u/s per tick. Opt-in: server-side only, the client still predicts the engine duck speed. Requires write_props + speed_enforce and DHooks/CS2M_CheckParams.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    CreateConVar("cs2movement_lowspeed_sustain", "0", "Per-player friction compensation so wishspeeds below 80*5.2/5.5 = 75.64 u/s stay sustainable (CGameMovement::Friction detour). Opt-in; requires write_props + speed_enforce and DHooks. With it on, duck_speed_min can be 0 and CS2's AK 73.1 / AWP 68 become exact.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvCrouchSlide = CreateConVar("cs2movement_crouch_slide", "0", "CS2-style crouch slide: when a player ducks while running on the ground, keep the momentum and decay it toward the crouch speed instead of letting the engine snap to it in one tick (CCS CheckParameters hook, same entry as duck_speed). Opt-in: server-side only, the client still predicts the vanilla duck clamp, so measure the pull before enabling. Requires write_props + speed_enforce + duck_speed.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvCrouchSlideClient = CreateConVar("cs2movement_crouch_slide_client", "0", "Also drive the replicated survivor_crouch_speed down the same decay curve so the CLIENT predicts the slide too (both sides slide, zero rubber-band). Side effect: that cvar is global, so while a slide is running any OTHER crouching survivor briefly gets a higher crouch cap. Requires cs2movement_crouch_slide 1 + the duck layer ready; fails closed if survivor_crouch_speed is missing. Test the feel on a test server before shipping.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    CreateConVar("cs2movement_crouch_slide_time", "0.20", "Seconds for the crouch slide to decay from the pre-duck speed to the crouch target (exponential curve). 0.20 s is the CS2 equivalent: ln(215/73.1)/5.2 = 0.207 s, (215-73.1)/5.2 = 27.3 u at AK speed; 0.10 s is only half of that (13.2 u). Range 0.02-2.0.", FCVAR_NOTIFY, true, 0.02, true, 2.0);
    CreateConVar("cs2movement_crouch_slide_min_speed", "100.0", "Only start a crouch slide when the pre-duck speed is at least this many u/s.", FCVAR_NOTIFY, true, 0.0, true, 1000.0);
    g_cvCrouchEnforce = CreateConVar("cs2movement_crouch_enforce", "0", "Write duck state (m_nDuckTimeMsecs/m_bDucking/m_bDucked; requires write_props). Clamped by the engine; keep 0.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvWriteTiming = CreateConVar("cs2movement_write_timing", "0", "0=CS2M_OnPlayerRunCmd, 1=PostThink. No behavioural difference at runtime.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    /* 0.5.0: low-health limp layer (restores the vanilla penalty the per-player
     * speed write erases).  Registers its own cvars and caches the engine
     * survivor_limp_* handles. */
    CS2M_InjurySetup();
    /* 0.5.3: water-depth slowdown.  Registers its own cvars, the probe
     * command and the per-client prop cache; the behaviour itself is
     * gated inside CS2M_WaterApply() by CS2M_IsSurvivor(). */
    CS2M_WaterSetup();

    HookConVarChange(g_cvCS2MEnable, CS2M_OnEnableChanged);
    HookConVarChange(g_cvApplyGlobal, CS2M_OnApplyGlobalChanged);
    HookConVarChange(g_cvAccelerate, CS2M_OnMoveTargetChanged);
    HookConVarChange(g_cvFriction, CS2M_OnMoveTargetChanged);
    HookConVarChange(g_cvStopspeed, CS2M_OnMoveTargetChanged);
    HookConVarChange(g_cvAiraccelerate, CS2M_OnMoveTargetChanged);
    HookConVarChange(g_cvGravity, CS2M_OnMoveTargetChanged);
    HookConVarChange(g_cvMaxspeed, CS2M_OnMoveTargetChanged);
    HookConVarChange(g_cvMaxvelocity, CS2M_OnMoveTargetChanged);
    HookConVarChange(g_cvCrouchSlide, OnCrouchSlideChanged);
    HookConVarChange(g_cvCrouchSlideClient, OnCrouchSlideClientChanged);

    /* Engine-owned, REPLICATED|CHEAT: the client's duck clamp reads this cvar
     * (client provider 0x10269E90).  We only ever write it while a slide is
     * running and restore it afterwards; missing -> client-slide layer stays
     * off (fail-closed) and status prints client_slide=missing. */
    g_cvSurvivorCrouchSpeed = FindConVar("survivor_crouch_speed");

    /* Engine layer defaults ON: without DHooks or the matching gamedata
     * signature it stays disabled (fail-closed) and only the global sv_* layer
     * remains active. */
    CS2M_MoveSetupEngineSpeedHook();
    CS2M_MoveSetupDuckSpeedHook();
    CS2M_MoveSetupSustainHook();
}

