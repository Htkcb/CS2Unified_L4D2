/**
 * cs2movement_move.sp -- movement layer for CS2Movement_L4D2.
 *
 * Stage 1 scope:
 *   - save/apply/restore the L4D2 global movement cvars that exist
 *     (sv_accelerate, sv_friction, sv_stopspeed, sv_airaccelerate,
 *      sv_gravity, sv_maxspeed, sv_maxvelocity);
 *   - compute the CS2 weapon/walk/duck target speed for status output;
 *   - record jump/land/velocity state when debug is on.
 *
 * Stage 2 (offline implementation, runtime-gated):
 *   - external weapon table configs/cs2movement_weapons.cfg;
 *   - optional m_flMaxspeed write (cs2movement_speed_enforce + write_props);
 *   - still no m_vecVelocity write (Stage 3).
 *
 * L4D2 has no sv_air_max_wishspeed / sv_jump_impulse / sv_timebetweenducks /
 * sv_enablebunnyhopping (verified by binary string scan, see docs/01).
 */

#if defined _cs2movement_move_included
 #endinput
#endif
#define _cs2movement_move_included

#if !defined IN_SPEED
 #define IN_SPEED (1 << 17)
#endif
#if !defined IN_DUCK
 #define IN_DUCK (1 << 2)
#endif

ConVar g_cvSVAccelerate = null;
ConVar g_cvSVFriction = null;
ConVar g_cvSVStopspeed = null;
ConVar g_cvSVAiraccelerate = null;
ConVar g_cvSVGravity = null;
ConVar g_cvSVMaxspeed = null;
ConVar g_cvSVMaxvelocity = null;

bool  g_bHasSVAccelerate = false;
bool  g_bHasSVFriction = false;
/* Hook invocations dropped because the client is a special infected or a
 * spectator.  Declared early: CS2M_MoveApplyPlayerSpeed is defined before the
 * engine-speed section and needs it. */
int   g_iSkipNotSurvivor = 0;
bool  g_bHasSVStopspeed = false;
bool  g_bHasSVAiraccelerate = false;
bool  g_bHasSVGravity = false;
bool  g_bHasSVMaxvelocity = false;

float g_fOrigSVAccelerate = 0.0;
float g_fOrigSVFriction = 0.0;
float g_fOrigSVStopspeed = 0.0;
float g_fOrigSVAiraccelerate = 0.0;
float g_fOrigSVGravity = 0.0;
float g_fOrigSVMaxvelocity = 0.0;

bool  g_bGlobalApplied = false;
Handle g_hReassertTimer = null;
int   g_iMoveJumps[MAXPLAYERS + 1];
int   g_iMoveLandings[MAXPLAYERS + 1];
int   g_iMoveLastButtons[MAXPLAYERS + 1];
bool  g_bMoveWasOnGround[MAXPLAYERS + 1];
/* Last usercmd's +duck state.  Needed by the air maxspeed guard: L4D2 puts the
 * player in the duck hull automatically during a jump, so the duck flag alone
 * cannot tell "the player is crouching" from "the engine tucked the legs". */
bool  g_bMoveDuckHeld[MAXPLAYERS + 1];
bool  g_bMoveDuckPrev[MAXPLAYERS + 1];
float g_fMoveLastJump[MAXPLAYERS + 1];
float g_fMoveLastAppliedSpeed[MAXPLAYERS + 1];
bool  g_bMoveHasAppliedSpeed[MAXPLAYERS + 1];
StringMap g_mWeaponSpeeds = null;

/* Stage 3 (offline): jump / landing / bhop state.  All writes are gated. */
float g_fLastJumpPress[MAXPLAYERS + 1];
float g_fLastLandTime[MAXPLAYERS + 1];
bool  g_bJumpHeld[MAXPLAYERS + 1];
bool  g_bUseNextJumpFactor[MAXPLAYERS + 1];
int   g_iJumpBlocked[MAXPLAYERS + 1];
int   g_iBhopWindowHits[MAXPLAYERS + 1];
int   g_iLandingWrites[MAXPLAYERS + 1];
int   g_iJumpImpulseWrites[MAXPLAYERS + 1];
int   g_iBhopCaps[MAXPLAYERS + 1];

stock float CS2M_MoveTargetFloat(const char[] name, float fallback)
{
    ConVar cv = FindConVar(name);
    return (cv == null) ? fallback : GetConVarFloat(cv);
}

/**
 * Load the optional per-weapon speed table from
 * addons/sourcemod/configs/cs2movement_weapons.cfg.
 *
 * Format:
 *   "CS2MovementWeapons"
 *   {
 *       "weapon_rifle" "215"
 *       "weapon_smg"   "240"
 *   }
 *
 * Missing or malformed table is non-fatal: CS2M_MoveWeaponSpeed keeps its
 * inline fallback table.  Values are stored as strings so no untagged
 * StringMap float access is needed.
 */
stock bool CS2M_MoveLoadWeaponTable()
{
    if (g_mWeaponSpeeds != null)
        delete g_mWeaponSpeeds;
    g_mWeaponSpeeds = new StringMap();

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "configs/cs2movement_weapons.cfg");

    KeyValues kv = new KeyValues("CS2MovementWeapons");
    if (!kv.ImportFromFile(path))
    {
        delete kv;
        PrintToServer("[CS2Movement] WEAPON-TABLE missing/invalid: %s (using inline fallback)", path);
        return false;
    }

    if (!kv.GotoFirstSubKey())
    {
        delete kv;
        PrintToServer("[CS2Movement] WEAPON-TABLE empty: %s (using inline fallback)", path);
        return false;
    }

    int count = 0;
    do
    {
        char cls[64];
        char value[32];
        kv.GetSectionName(cls, sizeof(cls));

        float speed = kv.GetFloat("speed", -1.0);
        if (cls[0] != '\0' && speed > 0.0)
        {
            FloatToString(speed, value, sizeof(value));
            g_mWeaponSpeeds.SetString(cls, value);
            count++;
        }
    }
    while (kv.GotoNextKey());

    delete kv;
    PrintToServer("[CS2Movement] WEAPON-TABLE loaded=%d path=%s", count, path);
    return count > 0;
}

stock void CS2M_MoveCacheEngineCvars()
{
    if (g_cvSVAccelerate == null)   g_cvSVAccelerate = FindConVar("sv_accelerate");
    if (g_cvSVFriction == null)     g_cvSVFriction = FindConVar("sv_friction");
    if (g_cvSVStopspeed == null)    g_cvSVStopspeed = FindConVar("sv_stopspeed");
    if (g_cvSVAiraccelerate == null) g_cvSVAiraccelerate = FindConVar("sv_airaccelerate");
    if (g_cvSVGravity == null)      g_cvSVGravity = FindConVar("sv_gravity");
    if (g_cvSVMaxspeed == null)     g_cvSVMaxspeed = FindConVar("sv_maxspeed");
    if (g_cvSVMaxvelocity == null)  g_cvSVMaxvelocity = FindConVar("sv_maxvelocity");
}

stock bool CS2M_MoveApplyGlobal()
{
    if (g_bGlobalApplied)
        return true;

    CS2M_MoveCacheEngineCvars();

    bool ok = true;

    if (g_cvSVAccelerate != null)
    {
        g_fOrigSVAccelerate = GetConVarFloat(g_cvSVAccelerate);
        g_bHasSVAccelerate = true;
        SetConVarFloat(g_cvSVAccelerate, CS2M_MoveTargetFloat("cs2movement_accelerate", 5.5));
    }
    else
    {
        ok = false;
        PrintToServer("[CS2Movement] APPLY missing sv_accelerate");
    }

    if (g_cvSVFriction != null)
    {
        g_fOrigSVFriction = GetConVarFloat(g_cvSVFriction);
        g_bHasSVFriction = true;
        SetConVarFloat(g_cvSVFriction, CS2M_MoveTargetFloat("cs2movement_friction", 5.2));
    }
    else
    {
        ok = false;
        PrintToServer("[CS2Movement] APPLY missing sv_friction");
    }

    if (g_cvSVStopspeed != null)
    {
        g_fOrigSVStopspeed = GetConVarFloat(g_cvSVStopspeed);
        g_bHasSVStopspeed = true;
        SetConVarFloat(g_cvSVStopspeed, CS2M_MoveTargetFloat("cs2movement_stopspeed", 80.0));
    }
    else
    {
        ok = false;
        PrintToServer("[CS2Movement] APPLY missing sv_stopspeed");
    }

    if (g_cvSVAiraccelerate != null)
    {
        g_fOrigSVAiraccelerate = GetConVarFloat(g_cvSVAiraccelerate);
        g_bHasSVAiraccelerate = true;
        SetConVarFloat(g_cvSVAiraccelerate, CS2M_MoveTargetFloat("cs2movement_airaccelerate", 12.0));
    }
    else
    {
        ok = false;
        PrintToServer("[CS2Movement] APPLY missing sv_airaccelerate");
    }

    if (g_cvSVGravity != null)
    {
        g_fOrigSVGravity = GetConVarFloat(g_cvSVGravity);
        g_bHasSVGravity = true;
        SetConVarFloat(g_cvSVGravity, CS2M_MoveTargetFloat("cs2movement_gravity", 800.0));
    }
    else
    {
        ok = false;
        PrintToServer("[CS2Movement] APPLY missing sv_gravity");
    }

    /* sv_maxspeed is deliberately NOT written any more (0.4.8).  It is the
     * engine-wide ceiling: L4D2 ships 1000, and lowering it also caps special
     * infected abilities -- the Charger charge runs at z_charge_max_speed 500.
     * Survivor caps are enforced per player through m_flMaxspeed, so this
     * global write bought nothing and cost the infected their top speed. */

    if (g_cvSVMaxvelocity != null)
    {
        g_fOrigSVMaxvelocity = GetConVarFloat(g_cvSVMaxvelocity);
        g_bHasSVMaxvelocity = true;
        SetConVarFloat(g_cvSVMaxvelocity, CS2M_MoveTargetFloat("cs2movement_maxvelocity", 3500.0));
    }
    else
    {
        ok = false;
        PrintToServer("[CS2Movement] APPLY missing sv_maxvelocity");
    }

    g_bGlobalApplied = true;
    PrintToServer("[CS2Movement] APPLY-GLOBAL ok=%d accelerate=%.3f friction=%.3f stopspeed=%.1f airaccel=%.1f gravity=%.1f maxspeed=%.1f maxvel=%.1f",
               ok ? 1 : 0,
               g_cvSVAccelerate != null ? GetConVarFloat(g_cvSVAccelerate) : -1.0,
               g_cvSVFriction != null ? GetConVarFloat(g_cvSVFriction) : -1.0,
               g_cvSVStopspeed != null ? GetConVarFloat(g_cvSVStopspeed) : -1.0,
               g_cvSVAiraccelerate != null ? GetConVarFloat(g_cvSVAiraccelerate) : -1.0,
               g_cvSVGravity != null ? GetConVarFloat(g_cvSVGravity) : -1.0,
               g_cvSVMaxspeed != null ? GetConVarFloat(g_cvSVMaxspeed) : -1.0,
               g_cvSVMaxvelocity != null ? GetConVarFloat(g_cvSVMaxvelocity) : -1.0);
    return ok;
}

stock void CS2M_MoveRestoreGlobal()
{
    if (g_bHasSVAccelerate && g_cvSVAccelerate != null)
        SetConVarFloat(g_cvSVAccelerate, g_fOrigSVAccelerate);
    if (g_bHasSVFriction && g_cvSVFriction != null)
        SetConVarFloat(g_cvSVFriction, g_fOrigSVFriction);
    if (g_bHasSVStopspeed && g_cvSVStopspeed != null)
        SetConVarFloat(g_cvSVStopspeed, g_fOrigSVStopspeed);
    if (g_bHasSVAiraccelerate && g_cvSVAiraccelerate != null)
        SetConVarFloat(g_cvSVAiraccelerate, g_fOrigSVAiraccelerate);
    if (g_bHasSVGravity && g_cvSVGravity != null)
        SetConVarFloat(g_cvSVGravity, g_fOrigSVGravity);
    if (g_bHasSVMaxvelocity && g_cvSVMaxvelocity != null)
        SetConVarFloat(g_cvSVMaxvelocity, g_fOrigSVMaxvelocity);

    g_bHasSVAccelerate = false;
    g_bHasSVFriction = false;
    g_bHasSVStopspeed = false;
    g_bHasSVAiraccelerate = false;
    g_bHasSVGravity = false;
    g_bHasSVMaxvelocity = false;
    g_bGlobalApplied = false;
    CS2M_MoveStopReassertTimer();

    PrintToServer("[CS2Movement] RESTORE-GLOBAL done");
}

stock bool CS2M_MoveIsGlobalApplied()
{
    return g_bGlobalApplied;
}

stock void CS2M_MoveReapplyGlobal()
{
    CS2M_MoveRestoreGlobal();
    CS2M_MoveApplyGlobal();
}

/**
 * Re-assert the configured targets without touching the saved originals.
 *
 * L4D2 re-forces some global cvars shortly after a map starts.  Measured on
 * 2026-10-28 with 1.5 s polling across a changelevel:
 *     +9.3 s   sv_maxspeed = 320.000000   (this plugin wrote it)
 *     +12.3 s  sv_maxspeed = 1000.000000  (something outside the plugin reset it)
 * and it then stays at 1000.  CS2M_OnConfigsExecuted runs before that reset, and
 * CS2M_MoveApplyGlobal() early-returns because g_bGlobalApplied is still true,
 * so the applied set is silently lost after every map change.
 *
 * Re-snapshotting here would be wrong (it would capture our own values as
 * "originals" and break restore), so this only rewrites values that differ from
 * the configured target.  Comparing first keeps the periodic timer cheap and
 * quiet: it logs only when it actually repairs drift.
 */
stock void CS2M_MoveReassertGlobal()
{
    if (!g_bGlobalApplied)
        return;

    CS2M_MoveReassertOne(g_cvSVAccelerate,   g_bHasSVAccelerate,    "cs2movement_accelerate",    5.5);
    CS2M_MoveReassertOne(g_cvSVFriction,     g_bHasSVFriction,      "cs2movement_friction",      5.2);
    CS2M_MoveReassertOne(g_cvSVStopspeed,    g_bHasSVStopspeed,     "cs2movement_stopspeed",     80.0);
    CS2M_MoveReassertOne(g_cvSVAiraccelerate,g_bHasSVAiraccelerate, "cs2movement_airaccelerate", 12.0);
    CS2M_MoveReassertOne(g_cvSVGravity,      g_bHasSVGravity,       "cs2movement_gravity",       800.0);
    CS2M_MoveReassertOne(g_cvSVMaxvelocity,  g_bHasSVMaxvelocity,   "cs2movement_maxvelocity",   3500.0);
}

stock void CS2M_MoveReassertOne(ConVar cv, bool had, const char[] targetName, float fallback)
{
    if (!had || cv == null)
        return;

    float want = CS2M_MoveTargetFloat(targetName, fallback);
    if (GetConVarFloat(cv) == want)
        return;

    char name[64];
    GetConVarName(cv, name, sizeof(name));
    PrintToServer("[CS2Movement] REASSERT %s %.3f -> %.3f", name, GetConVarFloat(cv), want);
    SetConVarFloat(cv, want);
}

/**
 * Keep the applied set converged.  The engine/gamemode reset is a one-shot a few
 * seconds after map start, but its exact timing varies with map and plugins, so
 * a low-frequency timer is more robust than guessing a single delay.
 */
stock void CS2M_MoveStartReassertTimer()
{
    if (g_hReassertTimer != null)
        KillTimer(g_hReassertTimer);
    g_hReassertTimer = CreateTimer(5.0, Timer_MoveReassert, _, TIMER_REPEAT);
}

stock void CS2M_MoveStopReassertTimer()
{
    if (g_hReassertTimer != null)
    {
        KillTimer(g_hReassertTimer);
        g_hReassertTimer = null;
    }
}

public Action Timer_MoveReassert(Handle timer)
{
    if (!g_bGlobalApplied)
    {
        g_hReassertTimer = null;
        return Plugin_Stop;
    }
    if (!GetConVarBool(FindConVar("cs2movement_enable")) ||
        !GetConVarBool(FindConVar("cs2movement_apply_global")))
    {
        g_hReassertTimer = null;
        return Plugin_Stop;
    }
    CS2M_MoveReassertGlobal();
    return Plugin_Continue;
}

/**
 * L4D2 weapon class -> CS2 ground speed (u/s).  This is an explicit mapping
 * assumption, not a claim that L4D2 weapons are identical to CS2 weapons.
 * Unknown classes fall back to cs2movement_base_speed.
 */
stock float CS2M_MoveWeaponSpeed(const char[] cls)
{
    if (g_mWeaponSpeeds != null)
    {
        char value[32];
        if (g_mWeaponSpeeds.GetString(cls, value, sizeof(value)))
            return StringToFloat(value);
    }

    if (StrEqual(cls, "weapon_rifle") || StrEqual(cls, "weapon_rifle_ak47"))
        return 215.0;
    if (StrEqual(cls, "weapon_rifle_desert") || StrEqual(cls, "weapon_rifle_m4"))
        return 225.0;
    if (StrEqual(cls, "weapon_smg") || StrEqual(cls, "weapon_smg_silenced") || StrEqual(cls, "weapon_smg_mp5"))
        return 240.0;
    if (StrEqual(cls, "weapon_pistol") || StrEqual(cls, "weapon_pistol_magnum"))
        return 240.0;
    if (StrEqual(cls, "weapon_hunting_rifle") || StrEqual(cls, "weapon_sniper_scout") || StrEqual(cls, "weapon_sniper_military"))
        return 230.0;
    if (StrEqual(cls, "weapon_sniper_awp"))
        return 200.0;
    if (StrContains(cls, "shotgun") != -1)
        return 230.0;
    if (StrEqual(cls, "weapon_melee") || StrEqual(cls, "weapon_chainsaw"))
        return 250.0;

    return CS2M_MoveTargetFloat("cs2movement_base_speed", 250.0);
}

/**
 * Engine-path cap: the weapon's CS2 max speed with NO posture multipliers.
 *
 * L4D2 already scales movement for walking (smaller usercmd forwardmove) and
 * for ducking (engine-side duck cap), so applying 0.52/0.34 here would double
 * scale. Measured on a real client: ducking a 230 weapon with our 0.34 applied
 * (78.2) still produced m_flMaxspeed = actual = 75.0, i.e. the engine's own
 * duck value won. Walk does not even reach us: real clients do not set the
 * IN_SPEED usercmd bit (only bots do).
 *
 * Returns -1.0 when weapon_speed_mode = 0 (native L4D2 speed).
 */
stock float CS2M_MoveEngineTarget(int client)
{
    if (GetConVarInt(FindConVar("cs2movement_weapon_speed_mode")) == 0)
        return -1.0;

    char cls[64];
    cls[0] = '\0';

    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon > 0 && IsValidEntity(weapon))
        GetEdictClassname(weapon, cls, sizeof(cls));

    float speed = CS2M_MoveWeaponSpeed(cls);

    float cap = CS2M_MoveTargetFloat("cs2movement_maxspeed", 1000.0);
    if (speed > cap)
        speed = cap;
    if (speed < 0.0)
        speed = 0.0;

    /* 0.5.0 -- L4D2 caps a limping survivor by lowering m_flMaxspeed, and this
     * layer rewrites that field for every survivor every tick, so the engine's
     * own low-health value is erased.  Re-apply it here: this function is the
     * single source of the per-player standing target (SetupMove write, crouch
     * derivation, crouch-slide ceiling, status), so the penalty cannot be
     * bypassed by a new call site.  Never raises the speed. */
    speed = CS2M_InjuryApply(client, speed);
    speed = CS2M_WaterApply(client, speed);

    return speed;
}

/**
 * Target CS2 speed for the player's current weapon/posture.
 * Returns -1.0 when weapon_speed_mode = 0 (native L4D2 speed).
 * Stage 1 only reports this value; it does not write m_flMaxspeed.
 */
stock float CS2M_MoveDesiredMaxSpeed(int client, int buttons)
{
    if (GetConVarInt(FindConVar("cs2movement_weapon_speed_mode")) == 0)
        return -1.0;

    char cls[64];
    cls[0] = '\0';

    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon > 0 && IsValidEntity(weapon))
        GetEdictClassname(weapon, cls, sizeof(cls));

    float speed = CS2M_MoveWeaponSpeed(cls);

    if ((buttons & IN_SPEED) != 0)
        speed *= CS2M_MoveTargetFloat("cs2movement_walk_multiplier", 0.52);

    if ((GetEntityFlags(client) & FL_DUCKING) != 0)
        speed *= CS2M_MoveTargetFloat("cs2movement_duck_multiplier", 0.34);

    float cap = CS2M_MoveTargetFloat("cs2movement_maxspeed", 1000.0);
    if (speed > cap)
        speed = cap;
    if (speed < 0.0)
        speed = 0.0;

    /* Same limp rule as the engine path (0.5.0), applied to the posture-scaled
     * value so the Stage 2 property write and the status readout agree with
     * what the engine layer would produce. */
    speed = CS2M_InjuryApply(client, speed);
    speed = CS2M_WaterApply(client, speed);

    return speed;
}

/**
 * Stage 2: optional per-player speed write.  Both gates must be enabled:
 *   cs2movement_write_props 1
 *   cs2movement_speed_enforce 1
 * Default is 0/0, so this is inert unless explicitly turned on in a test.
 */
stock void CS2M_MoveApplyPlayerSpeed(int client, int buttons)
{
    if (client < 1 || client > MaxClients)
        return;
    if (!CS2M_IsSurvivor(client))
    {
        g_iSkipNotSurvivor++;
        return;
    }

    if (!GetConVarBool(FindConVar("cs2movement_write_props")))
        return;
    if (!GetConVarBool(FindConVar("cs2movement_speed_enforce")))
        return;

    /* In engine mode the SetupMove hook owns the write; writing here as well
     * would only race it. */
    if (CS2M_MoveEngineSpeedEnabled())
        return;

    float target = CS2M_MoveDesiredMaxSpeed(client, buttons);
    if (target <= 0.0)
        return;

    if (HasEntProp(client, Prop_Data, "m_flMaxspeed"))
        SetEntPropFloat(client, Prop_Data, "m_flMaxspeed", target);
    else if (HasEntProp(client, Prop_Send, "m_flMaxspeed"))
        SetEntPropFloat(client, Prop_Send, "m_flMaxspeed", target);
    else
        return;

    float actual = target;
    if (HasEntProp(client, Prop_Data, "m_flMaxspeed"))
        actual = GetEntPropFloat(client, Prop_Data, "m_flMaxspeed");
    else if (HasEntProp(client, Prop_Send, "m_flMaxspeed"))
        actual = GetEntPropFloat(client, Prop_Send, "m_flMaxspeed");

    g_fMoveLastAppliedSpeed[client] = actual;
    g_bMoveHasAppliedSpeed[client] = true;

    if (GetConVarBool(FindConVar("cs2movement_debug")))
        PrintToServer("[CS2Movement] SPEED-WRITE client=%d target=%.3f actual=%.3f", client, target, actual);
}

/* ------------------------------------------------------------------------- *
 * Engine-layer per-player speed (optional, default off)
 *
 * The property write above cannot change movement: the engine owns
 * m_flMaxspeed and copies it into CMoveData inside CPlayerMove::SetupMove,
 * which runs BEFORE CS2M_OnPlayerRunCmd. The working path hooks that function and
 * writes m_flMaxspeed just before the copy.
 *
 * DHooks cannot expose this detour's stack arguments (hParams is 0, "Invalid
 * Handle 0"), so the player cannot be identified from the call. Instead every
 * call refreshes EVERY player with that player's own target; the order is
 * irrelevant and the cost is O(N) per call.
 *
 * Evidence: tests/engine_setupmove_runtime.md, tests/engine_remote_predict.md,
 * tests/engine_perplayer_runtime.md. Static chain: docs/07.
 * ------------------------------------------------------------------------- */

DynamicDetour g_hEngineSpeedDetour = null;
bool  g_bEngineSpeedReady = false;
int   g_iEngineSpeedHits = 0;
/* Engine-speed layer rejections, split by cause so a "cap stopped working"
 * report can be traced: driven = engine controls the player, locked = the
 * engine itself parked m_flMaxspeed at ~0. */
int   g_iEngineSpeedSkipDriven = 0;
int   g_iEngineSpeedSkipLocked = 0;
/* Which state triggered a "driven" skip:
 *   1 incap, 2 hanging ledge, 3 falling ledge, 4 hanging from tongue,
 *   10..14 this client is held (victim side),
 *   20..24 this client is holding someone (attacker side: the Smoker etc.). */
int   g_iEngineSpeedSkipReason[32];

float g_fEngineSpeedTarget[MAXPLAYERS + 1];
float g_fEngineSpeedTick[MAXPLAYERS + 1];
float g_fEngineSpeedDiag[MAXPLAYERS + 1];
float g_fEngineSpeedMfsBefore[MAXPLAYERS + 1];
bool  g_bEngineSpeedPropKnown[MAXPLAYERS + 1];
bool  g_bEngineSpeedHasProp[MAXPLAYERS + 1];

stock bool CS2M_MoveEngineSpeedEnabled()
{
    if (!g_bEngineSpeedReady)
        return false;
    /* The master switch must gate the engine layer too: the detour is installed
     * in CS2M_OnPluginStart and stays installed, so without this an `enable 0` server
     * kept writing m_flMaxspeed (measured 2026-10-30: AK stayed 215.00 with
     * enable 0 and only returned to 220.00 after the plugin was unloaded). */
    if (!GetConVarBool(FindConVar("cs2movement_enable")))
        return false;
    if (GetConVarInt(FindConVar("cs2movement_engine_speed")) == 0)
        return false;
    if (!GetConVarBool(FindConVar("cs2movement_write_props")))
        return false;
    return GetConVarBool(FindConVar("cs2movement_speed_enforce"));
}

stock void CS2M_MoveSetupEngineSpeedHook()
{
    Handle conf = LoadGameConfigFile("cs2movement");
    if (conf == null)
    {
        LogMessage("engine_speed: gamedata cs2movement.txt missing; staying disabled");
        return;
    }

    g_hEngineSpeedDetour = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_Ignore);
    if (g_hEngineSpeedDetour == null ||
        !DHookSetFromConf(g_hEngineSpeedDetour, conf, SDKConf_Signature, "CS2M_SetupMove"))
    {
        LogMessage("engine_speed: signature CS2M_SetupMove missing; staying disabled");
        CloseHandle(conf);
        g_hEngineSpeedDetour = null;
        return;
    }

    DHookAddParam(g_hEngineSpeedDetour, HookParamType_Int);
    DHookAddParam(g_hEngineSpeedDetour, HookParamType_Int);
    DHookAddParam(g_hEngineSpeedDetour, HookParamType_Int);
    DHookAddParam(g_hEngineSpeedDetour, HookParamType_Int);

    if (!DHookEnableDetour(g_hEngineSpeedDetour, false, CS2M_MoveOnEngineSetupMove))
    {
        LogMessage("engine_speed: detour install failed; staying disabled");
        CloseHandle(conf);
        g_hEngineSpeedDetour = null;
        return;
    }

    CloseHandle(conf);
    g_bEngineSpeedReady = true;
    LogMessage("engine_speed: SetupMove hook installed (per-player cap; gated by cs2movement_engine_speed)");
}

stock void CS2M_MoveShutdownEngineSpeedHook()
{
    if (g_hEngineSpeedDetour != null)
    {
        DHookDisableDetour(g_hEngineSpeedDetour, false, CS2M_MoveOnEngineSetupMove);
        g_hEngineSpeedDetour = null;
    }
    g_bEngineSpeedReady = false;
}

stock bool CS2M_MoveSetMaxspeed(int client, float value)
{
    if (!g_bEngineSpeedPropKnown[client])
    {
        g_bEngineSpeedPropKnown[client] = true;
        g_bEngineSpeedHasProp[client] = HasEntProp(client, Prop_Data, "m_flMaxspeed");
    }

    if (g_bEngineSpeedHasProp[client])
    {
        SetEntPropFloat(client, Prop_Data, "m_flMaxspeed", value);
        return true;
    }
    if (HasEntProp(client, Prop_Send, "m_flMaxspeed"))
    {
        SetEntPropFloat(client, Prop_Send, "m_flMaxspeed", value);
        return true;
    }
    return false;
}

/**
 * True when the engine, not the player's own input, is driving this client's
 * motion: incapacitated, hanging/falling from a ledge, or held by a special
 * infected (Smoker tongue, Hunter pounce, Jockey ride, Charger charge /
 * carry / pummel).
 *
 * Why this exists (0.4.6): the per-player speed layer rewrites m_flMaxspeed
 * every tick for every alive client.  While a survivor is tongue-pulled L4D2
 * lowers that value to lock out self movement; raising it back to the weapon
 * speed handed control back to the victim, so a pulled player could walk and
 * drift in whatever direction they held.  Movement modifiers must never touch
 * a player the engine has taken over.
 *
 * Every property is probed with HasEntProp first.  If a game update renames
 * one, the check degrades to "not held" and the engine-intent guard inside
 * CS2M_MoveOnEngineSetupMove still protects the behaviour.
 */
stock bool CS2M_MoveEngineDrivenEx(int client, int &reason)
{
    reason = 0;

    /* Boolean states.  Names and types taken from this build's own
     * sm_dump_netprops (L4D2 2.2.4.3 / 10097): all are 1-bit integers. */
    char boolProps[4][32] = {
        "m_isIncapacitated", "m_isHangingFromLedge",
        "m_isFallingFromLedge", "m_isHangingFromTongue"
    };
    for (int b = 0; b < sizeof(boolProps); b++)
    {
        if (!HasEntProp(client, Prop_Send, boolProps[b]))
            continue;
        if (GetEntProp(client, Prop_Send, boolProps[b]) != 0)
        {
            reason = 1 + b;
            return true;
        }
    }

    /* Held / holding.  Both sides matter, and only one of them was obvious:
     *  - victim side  (m_tongueOwner ...)  : this client is being dragged;
     *  - attacker side (m_tongueVictim ...) : this client IS the Smoker/Hunter/
     *    Jockey/Charger that has someone.  L4D2 roots the attacker while the
     *    grab is held, and that root was exactly what got overwritten: the
     *    Smoker itself drifted while pulling (reported 2026-10-31).
     *    Charger has two distinct pairs: pummel (after impact) and carry. */
    char victimSide[5][32] = {
        "m_tongueOwner", "m_pounceAttacker", "m_jockeyAttacker",
        "m_pummelAttacker", "m_carryAttacker"
    };
    char attackerSide[5][32] = {
        "m_tongueVictim", "m_pounceVictim", "m_jockeyVictim",
        "m_pummelVictim", "m_carryVictim"
    };
    for (int k = 0; k < 5; k++)
    {
        /* These fields are unsigned 21-bit entity indices: an unset value is a
         * large unsigned number, not 0 or -1.  A bare >0 test therefore read
         * "held" for healthy players and skipped the run-speed cap for them
         * (measured on the live 64-tick server, 2026-10-31: 1100+ skips in 6 s
         * at idle).  Only a value that names a live client slot counts. */
        if (HasEntProp(client, Prop_Send, victimSide[k]))
        {
            int heldBy = GetEntProp(client, Prop_Send, victimSide[k]);
            if (heldBy > 0 && heldBy <= MaxClients && IsClientInGame(heldBy))
            {
                reason = 10 + k;
                return true;
            }
        }
        if (HasEntProp(client, Prop_Send, attackerSide[k]))
        {
            int holding = GetEntProp(client, Prop_Send, attackerSide[k]);
            if (holding > 0 && holding <= MaxClients && IsClientInGame(holding))
            {
                reason = 20 + k;
                return true;
            }
        }
    }
    return false;
}

stock bool CS2M_MoveEngineDriven(int client)
{
    int reason;
    return CS2M_MoveEngineDrivenEx(client, reason);
}

public MRESReturn CS2M_MoveOnEngineSetupMove(int pThis, DHookParam hParams)
{
    g_iEngineSpeedHits++;

    if (!CS2M_MoveEngineSpeedEnabled())
        return MRES_Ignored;

    float now = GetGameTime();


    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsPlayerAlive(i))
            continue;

        /* Survivors only.  The run-speed cap is a survivor feature: it looks the
         * CS2 speed up in the *survivor* weapon table, so writing it onto an
         * infected client is meaningless at best.  Worse, L4D2 roots an infected
         * while its ability is latched (Smoker tongue, Charger carry, Jockey
         * ride, Hunter pounce) and this write handed that movement back -- the
         * reported "Smoker drifts while pulling" (0.4.6).  Excluding team 3 here
         * covers every special infected, including future/edge states that no
         * netprop enumeration would catch. */
        if (!CS2M_IsSurvivor(i))
        {
            g_iSkipNotSurvivor++;
            continue;
        }

        /* Recompute at most once per server tick per player; the remaining
         * calls in the same tick just rewrite the cached value. */
        if (g_fEngineSpeedTick[i] != now)
        {
            g_fEngineSpeedTick[i] = now;
            float computed = CS2M_MoveEngineTarget(i);

            if (g_fEngineSpeedTarget[i] != computed &&
                GetConVarBool(FindConVar("cs2movement_debug")))
            {
                char cls[64];
                cls[0] = '\0';
                int wpn = GetEntPropEnt(i, Prop_Send, "m_hActiveWeapon");
                if (wpn > 0 && IsValidEntity(wpn))
                    GetEdictClassname(wpn, cls, sizeof(cls));
                PrintToServer("[CS2Movement] ENGINE-TARGET client=%d target=%.1f duck=%d weapon=%s",
                              i, computed,
                              (GetEntityFlags(i) & FL_DUCKING) ? 1 : 0, cls);
            }

            g_fEngineSpeedTarget[i] = computed;
        }

        float target = g_fEngineSpeedTarget[i];
        g_fEngineSpeedMfsBefore[i] = -1.0;
        if (HasEntProp(i, Prop_Data, "m_flMaxspeed"))
            g_fEngineSpeedMfsBefore[i] = GetEntPropFloat(i, Prop_Data, "m_flMaxspeed");

        /* 0.4.6: never hand self movement back to a player the engine has taken
         * over (Smoker tongue, Hunter pounce, Jockey ride, Charger, incap,
         * ledge).  Raising m_flMaxspeed there is exactly what let a dragged
         * survivor walk. */
        int drivenReason;
        if (CS2M_MoveEngineDrivenEx(i, drivenReason))
        {
            g_iEngineSpeedSkipDriven++;
            if (drivenReason >= 0 && drivenReason < 32)
                g_iEngineSpeedSkipReason[drivenReason]++;
            continue;
        }

        /* Engine-intent guard, dependency free: a real standing or crouch cap
         * is never this small, so a tiny value means the engine parked it on
         * purpose.  Leave it alone instead of overwriting. */
        if (g_fEngineSpeedMfsBefore[i] >= 0.0 && g_fEngineSpeedMfsBefore[i] <= 30.0)
        {
            g_iEngineSpeedSkipLocked++;
            continue;
        }

        if (target > 0.0)
            CS2M_MoveSetMaxspeed(i, target);
    }

    /* Post-write diagnostic: the engine writes its own value earlier in the
     * tick, so the interesting question is whether OUR value survives at hook
     * exit. One line per slot every 2 s. */
    if (GetConVarBool(FindConVar("cs2movement_debug")))
    {
        for (int d = 1; d <= MaxClients; d++)
        {
            /* L4DToolZ raises maxplayers (31 here) well above the number of real
             * slots.  A slot without a client has no edict, and GetEntityFlags()
             * on it raises "Entity -1 (N) is invalid" once every 2 s per empty
             * slot (found by the 2026-10-28 soak, with cs2movement_debug 1). */
            if (!IsClientInGame(d))
                continue;

            if (g_fEngineSpeedDiag[d] != 0.0 && (now - g_fEngineSpeedDiag[d]) < 2.0)
                continue;
            g_fEngineSpeedDiag[d] = now;

            float mfs = -1.0;
            if (IsClientInGame(d) && HasEntProp(d, Prop_Data, "m_flMaxspeed"))
                mfs = GetEntPropFloat(d, Prop_Data, "m_flMaxspeed");

            float vxy = -1.0;
            float v[3];
            if (IsClientInGame(d) && GetEntPropVector(d, Prop_Data, "m_vecVelocity", v))
                vxy = SquareRoot(v[0] * v[0] + v[1] * v[1]);

            PrintToServer("[CS2Movement] ENGINE-RC slot=%d ingame=%d alive=%d fake=%d target=%.1f vxy=%.1f duck=%d mfs_before=%.1f mfs_after=%.1f",
                          d, IsClientInGame(d) ? 1 : 0, IsPlayerAlive(d) ? 1 : 0,
                          IsFakeClient(d) ? 1 : 0, g_fEngineSpeedTarget[d], vxy, (GetEntityFlags(d) & FL_DUCKING) ? 1 : 0, g_fEngineSpeedMfsBefore[d], mfs);
        }
    }

    return MRES_Ignored;
}

/* ------------------------------------------------------------------------- *
 * Crouch-speed alignment (0.4.2)
 *
 * What the engine really does (measured, not inferred)
 *   L4D2 reduces crouch speed by clamping the movement maxspeed, not by the
 *   CDuckScale-style 0.34 multiply that the static CDuckScale path suggests:
 *
 *     - CPlayerMove::SetupMove copies player+0x1FFC (m_flMaxspeed) into
 *       CMoveData+0x3C, but while ducking the engine has already put its own
 *       crouch value (75.0) there, so mv+0x3C reads 75.0 even though the
 *       plugin's pre-hook just wrote the weapon speed.
 *     - CCSGameMovement::CheckParameters (0x10238C80) then does
 *       mv+0x38 = min(mv+0x38, mv+0x3C), multiplies by the
 *       surface factor, and rescales the usercmd move components to mv+0x38.
 *     - WalkMove clamps wishspeed against mv+0x38.
 *   Diagnostic proof (2026-10-29, cs2movement_debug 1):
 *       CHECK src=1 client=1 duck=0 mv38=215.0 mv3c=215.0 fwd=0.0 mfs=215.0
 *       CHECK src=1 client=1 duck=1 mv38=75.0  mv3c=75.0  fwd=75.0 mfs=215.0
 *   (src=1 is 0x10238C80, the CCS override; the base 0x100F58C0 got 0 hits.)
 *   That is why capping m_flMaxspeed never changed crouch speed, and why the
 *   crouch speed is weapon-independent (~75 for every L4D2 weapon).
 *
 * What this hook does
 *   Post-hook on 0x10238C80.  When the player is crouching:
 *     1. the engine's clamped move components are rescaled so their magnitude
 *        equals the per-player CS2 crouch target
 *        (weapon CS2 speed * cs2movement_duck_multiplier);
 *     2. mv+0x38 is set to that target, so WalkMove's final wishspeed clamp
 *        uses the CS2 value instead of the engine's 75.
 *   Partial stick input stays proportional: only an *already clamped* move
 *   vector (|move| >= mv+0x38) is scaled up; a smaller input is left alone and
 *   the raised cap simply does not bind.
 *
 *   Because the write happens after CheckParameters' surface factor, the
 *   result is the same on asphalt (factor 1.0) and on swamp/mud surfaces
 *   (factor ~0.9): the CS2 target, exactly.
 *
 *   Client prediction: client.dll has its own crouch clamp (engine 75), so the
 *   server correction is a bounded mismatch of |target - 75|: AK 215*0.34 = 73.1
 *   -> 1.9 u/s, SMG 240*0.34 = 81.6 -> 6.6 u/s.  Measured in
 *   tests/duck_speed_runtime.md.
 * ------------------------------------------------------------------------- */

DynamicDetour g_hCheckParamsDetour = null;
bool  g_bCheckParamsReady = false;
int   g_iCheckParamsHits = 0;
int   g_iDuckCapWrites = 0;
float g_fDuckLastTarget = 0.0;
float g_fDuckLastOrig = 0.0;
int   g_iPlayerAddr[MAXPLAYERS + 1];

/* Crouch slide (opt-in, cs2movement_crouch_slide).  The engine's WalkMove
 * rescales the velocity to mv+0x38 whenever the current speed is above it
 * (velocity *= mv+0x38 / speed), which is why L4D2 snaps 215 -> 75 in one tick
 * on a duck.  Writing a decaying mv+0x38 in the CheckParameters post-hook keeps
 * the clamp 'above' the current speed for a few ticks, so the momentum decays
 * at our curve instead of the engine's one-tick snap.  Client prediction still
 * uses the vanilla duck clamp; this is a server-side correction. */
bool  g_bSlideActive[MAXPLAYERS + 1];
bool  g_bSlidePending[MAXPLAYERS + 1];
float g_fSlideV0[MAXPLAYERS + 1];
float g_fSlideK[MAXPLAYERS + 1];
float g_fSlideElapsed[MAXPLAYERS + 1];
float g_fSlideDuckTarget[MAXPLAYERS + 1];
float g_fSlideLastStart[MAXPLAYERS + 1];
int   g_iSlideStarts = 0;
int   g_iSlideWrites = 0;
int   g_iSlideLastClient = 0;
float g_fSlideLastCeil = 0.0;
float g_fSlideLastV0 = 0.0;
/* Latch for "slide is on but the duck layer is not armed".  The condition is a
 * configuration error, not a per-tick event, so it is reported once per
 * transition and re-armed when the gates become ready again. */
bool  g_bSlideWarned = false;

/* ---- client-side slide (opt-in, cs2movement_crouch_slide_client) ----------
 *
 * Why this exists: client.dll has its own WalkMove with the same "rescale the
 * velocity to mv+0x38" step as server.dll, and its crouch ceiling comes from
 * the REPLICATED ConVar survivor_crouch_speed (client provider 0x10269E90 reads
 * that cvar's value block; default 75).  Writing that cvar down the same decay
 * curve makes the CLIENT predict the slide as well, so both sides slide and
 * there is no rubber-band correction.
 *
 * The cvar is GLOBAL, so while any slide is running every other crouching
 * survivor briefly sees a higher crouch cap.  We therefore only own it while
 * at least one slide is active and restore the value we found otherwise.
 * survivor_crouch_speed is FCVAR_CHEAT: SetConVarFloat works with sv_cheats 0
 * (tested with sm_cvar), which is why the write goes through the ConVar API.
 */
ConVar g_cvSurvivorCrouchSpeed = null;
bool   g_bSlideClientDirty = false;       /* we changed the cvar and must restore */
float  g_fSlideClientBase = 0.0;          /* value found before our first write   */
float  g_fSlideClientLastWrite = 0.0;     /* last value WE wrote (change detector) */
float  g_fSlideClientCeil[MAXPLAYERS + 1];/* per-client curve value, 0 = inactive */
float  g_fSlideClientTouch[MAXPLAYERS + 1];/* last Friction write (stale safeguard)*/

stock void CS2M_SlideReset(int client)
{
    if (client < 1 || client > MaxClients)
        return;
    g_bSlideActive[client] = false;
    g_bSlidePending[client] = false;
    g_fSlideV0[client] = 0.0;
    g_fSlideK[client] = 0.0;
    g_fSlideElapsed[client] = 0.0;
    g_fSlideClientCeil[client] = 0.0;
    g_fSlideClientTouch[client] = 0.0;
}

stock bool CS2M_MoveCrouchSlideEnabled()
{
    return (GetConVarInt(FindConVar("cs2movement_crouch_slide")) != 0);
}


stock bool CS2M_MoveDuckSpeedEnabled()
{
    if (!g_bCheckParamsReady)
        return false;
    if (!GetConVarBool(FindConVar("cs2movement_enable")))
        return false;
    if (GetConVarInt(FindConVar("cs2movement_duck_speed")) == 0)
        return false;
    if (GetConVarInt(FindConVar("cs2movement_weapon_speed_mode")) == 0)
        return false;
    if (!GetConVarBool(FindConVar("cs2movement_write_props")))
        return false;
    return GetConVarBool(FindConVar("cs2movement_speed_enforce"));
}

/** True only when a duck press can actually start a slide.
 *
 *  The cvar alone is not enough.  CS2M_MoveApplyCrouchSlide needs
 *  g_fSlideDuckTarget, and that is only published by the CS2M_CheckParams
 *  post-hook (CS2M_MoveDuckSpeedEnabled).  With cs2movement_crouch_slide 1 but
 *  the duck layer off, every duck press is a silent no-op: this is the failure
 *  the status/diag "ready" column exists to expose. */
stock bool CS2M_MoveCrouchSlideReady()
{
    return CS2M_MoveCrouchSlideEnabled() && CS2M_MoveDuckSpeedEnabled();
}

/* ---- replicated client crouch cap ---------------------------------------- */

/** Client-side slide requires the slide itself plus the duck layer, and a
 *  survivor_crouch_speed to write (fail-closed when the engine cvar is gone). */
stock bool CS2M_MoveCrouchSlideClientEnabled()
{
    if (g_cvSurvivorCrouchSpeed == null)
        return false;
    if (!GetConVarBool(FindConVar("cs2movement_crouch_slide_client")))
        return false;
    return CS2M_MoveCrouchSlideReady();
}

/** Recompute the replicated survivor_crouch_speed from the per-client slide
 *  ceilings and either publish the maximum or restore the baseline value.
 *  Called from the Friction post-hook (one client per call) and from
 *  CS2M_MoveOnPlayerRunCmd (every client every tick), so the restore happens
 *  inside the same tick as the last slide ends -- never on a timer.
 *
 *  Ownership: we never clobber a value somebody else wrote.  If the current
 *  value differs from our last write, it becomes the new baseline. */
stock void CS2M_MoveUpdateClientSlide(bool forceRestore)
{
    if (g_cvSurvivorCrouchSpeed == null)
        return;

    float desired = 0.0;
    if (!forceRestore && CS2M_MoveCrouchSlideClientEnabled())
    {
        int sliders = 0;
        int slider = 0;
        for (int i = 1; i <= MaxClients; i++)
        {
            if (g_fSlideClientCeil[i] < 0.5)
                continue;
            sliders++;
            slider = i;
            if (g_fSlideClientCeil[i] > desired)
                desired = g_fSlideClientCeil[i];
        }
        if (desired < 1.0)
            desired = 0.0;

        /* Clean-room gate.  survivor_crouch_speed is one GLOBAL value, so a
         * raised cap also rewrites every other survivor's client-side crouch
         * clamp.  A teammate who is crouch-walking at that moment would
         * predict an acceleration the server never grants (sv_accelerate *
         * wishspeed * dt = 5.5 * 230 * 0.0156 ~ 19.8 u/s per tick, against a
         * server-side 75-82 u/s ceiling) and then get yanked back, i.e. a
         * <=0.2 s rubber-band on somebody who is not even sliding.  Two
         * simultaneous sliders have the same problem with different v0.
         * So the client half only runs when the picture is unambiguous: one
         * sliding survivor and no other crouching survivor.  Otherwise the
         * slide falls back to the server-only correction, which has no
         * cross-player effect. */
        if (sliders != 1)
        {
            desired = 0.0;
        }
        else
        {
            for (int i = 1; i <= MaxClients; i++)
            {
                if (i == slider || !IsClientInGame(i))
                    continue;
                if (!CS2M_IsSurvivor(i))
                    continue;
                if ((GetEntityFlags(i) & FL_DUCKING) != 0)
                {
                    desired = 0.0;
                    break;
                }
            }
        }
    }

    float current = GetConVarFloat(g_cvSurvivorCrouchSpeed);

    if (desired > 0.0)
    {
        if (!g_bSlideClientDirty)
        {
            g_fSlideClientBase = current;
            g_bSlideClientDirty = true;
        }
        else if (FloatAbs(current - g_fSlideClientLastWrite) > 0.001)
        {
            /* A third party changed the cvar while we held it: adopt their
             * value as the new baseline instead of undoing it later. */
            g_fSlideClientBase = current;
        }

        if (FloatAbs(current - desired) > 0.001)
        {
            SetConVarFloat(g_cvSurvivorCrouchSpeed, desired);
            g_fSlideClientLastWrite = desired;
        }
        return;
    }

    if (!g_bSlideClientDirty)
        return;

    /* Restore.  If the live value is no longer what we wrote, somebody else
     * changed it: keep their value and only drop our ownership. */
    if (FloatAbs(current - g_fSlideClientLastWrite) <= 0.001)
    {
        if (FloatAbs(current - g_fSlideClientBase) > 0.001)
            SetConVarFloat(g_cvSurvivorCrouchSpeed, g_fSlideClientBase);
    }
    else
    {
        g_fSlideClientBase = current;
    }
    g_bSlideClientDirty = false;
}

/** Drop every client's contribution and restore the baseline immediately.
 *  Used on lifecycle/config transitions, not per tick. */
stock void CS2M_MoveClientSlideForceRestore()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_fSlideClientCeil[i] = 0.0;
        g_fSlideClientTouch[i] = 0.0;
    }
    CS2M_MoveUpdateClientSlide(true);
}

/** Status fragment shared by sm_cs2movement_status and the unified layer:
 *  "client_slide=0 cvar_now=75.00 base=75.00" or "client_slide=missing". */
stock void CS2M_MoveSlideClientStatus(char[] out, int maxlen)
{
    out[0] = '\0';
    if (g_cvSurvivorCrouchSpeed == null)
    {
        strcopy(out, maxlen, "client_slide=missing");
        return;
    }
    Format(out, maxlen, "client_slide=%d cvar_now=%.2f base=%.2f",
           GetConVarInt(FindConVar("cs2movement_crouch_slide_client")),
           GetConVarFloat(g_cvSurvivorCrouchSpeed), g_fSlideClientBase);
}

/** Report a coupled-gate failure (slide cvar on, duck layer not armed) once per
 *  transition.  Called from CS2M_OnConfigsExecuted, the crouch_slide convar callback
 *  and the unified layer's persisted-settings timer -- the three moments the
 *  effective state can change.  Without this the admin sees slide=1 in status
 *  and never learns why nothing slides. */
stock void CS2M_MoveCheckSlideReadiness(const char[] where)
{
    if (!CS2M_MoveCrouchSlideEnabled() || CS2M_MoveDuckSpeedEnabled())
    {
        g_bSlideWarned = false;
        return;
    }
    if (g_bSlideWarned)
        return;
    g_bSlideWarned = true;

    ConVar duckCv = FindConVar("cs2movement_duck_speed");
    ConVar modeCv = FindConVar("cs2movement_weapon_speed_mode");
    int duck = (duckCv == null) ? -1 : GetConVarInt(duckCv);
    int mode = (modeCv == null) ? -1 : GetConVarInt(modeCv);
    int enable = GetConVarInt(FindConVar("cs2movement_enable"));
    int writeProps = GetConVarInt(FindConVar("cs2movement_write_props"));
    int speedEnforce = GetConVarInt(FindConVar("cs2movement_speed_enforce"));

    LogMessage("crouch_slide: ON but the duck layer is not armed; slides will not start (where=%s hook=%d enable=%d duck_speed=%d weapon_speed_mode=%d write_props=%d speed_enforce=%d)",
               where, g_bCheckParamsReady ? 1 : 0, enable, duck, mode,
               writeProps, speedEnforce);
    PrintToServer("[CS2Movement] WARNING crouch_slide=1 but duck layer not armed (hook=%d enable=%d duck_speed=%d weapon_speed_mode=%d write_props=%d speed_enforce=%d); slides will NOT start. See docs/12 section 12.7.",
                  g_bCheckParamsReady ? 1 : 0, enable, duck, mode,
                  writeProps, speedEnforce);
}

stock void CS2M_MoveSetupDuckSpeedHook()
{
    Handle conf = LoadGameConfigFile("cs2movement");
    if (conf == null)
    {
        LogMessage("duck_speed: gamedata cs2movement.txt missing; staying disabled");
        return;
    }

    g_hCheckParamsDetour = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_Address);
    if (g_hCheckParamsDetour == null ||
        !DHookSetFromConf(g_hCheckParamsDetour, conf, SDKConf_Signature, "CS2M_CheckParams"))
    {
        LogMessage("duck_speed: signature CS2M_CheckParams missing; staying disabled");
        CloseHandle(conf);
        g_hCheckParamsDetour = null;
        return;
    }

    /* No stack parameters: this is a void __thiscall(void) and the whole
     * decision is read from [this+4] (player) and [this+8] (CMoveData). */
    if (!DHookEnableDetour(g_hCheckParamsDetour, true, CS2M_MoveOnCheckParamsPost))
    {
        LogMessage("duck_speed: CheckParameters detour install failed; staying disabled");
        CloseHandle(conf);
        g_hCheckParamsDetour = null;
        return;
    }

    CloseHandle(conf);
    g_bCheckParamsReady = true;
    LogMessage("duck_speed: CCS CheckParameters post-hook installed (per-player CS2 crouch speed)");
}

stock void CS2M_MoveShutdownDuckSpeedHook()
{
    if (g_hCheckParamsDetour != null)
    {
        DHookDisableDetour(g_hCheckParamsDetour, true, CS2M_MoveOnCheckParamsPost);
        g_hCheckParamsDetour = null;
    }
    g_bCheckParamsReady = false;
}

/** Cache the CBasePlayer address so the crouch hook is O(players) per call. */
stock void CS2M_MoveCacheClientAddress(int client)
{
    if (client < 1 || client > MaxClients)
        return;
    g_iPlayerAddr[client] = (IsClientInGame(client)) ? view_as<int>(GetEntityAddress(client)) : 0;
}

/** Resolve the CBasePlayer pointer DHooks hands us back to a client index. */
stock int CS2M_MoveClientFromPlayerAddress(Address playerAddr)
{
    if (playerAddr == Address_Null)
        return 0;
    int want = view_as<int>(playerAddr);
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
            continue;
        if (g_iPlayerAddr[i] == want || view_as<int>(GetEntityAddress(i)) == want)
            return i;
    }
    return 0;
}

stock float CS2M_MoveLoadFloat(Address addr)
{
    return view_as<float>(LoadFromAddress(addr, NumberType_Int32));
}

stock void CS2M_MoveStoreFloat(Address addr, float value)
{
    StoreToAddress(addr, view_as<int>(value), NumberType_Int32);
}

public MRESReturn CS2M_MoveOnCheckParamsPost(Address pThis)
{
    g_iCheckParamsHits++;

    if (!CS2M_MoveDuckSpeedEnabled())
        return MRES_Ignored;

    Address base = view_as<Address>(pThis);
    int playerAddr = LoadFromAddress(base + view_as<Address>(4), NumberType_Int32);
    int mv = LoadFromAddress(base + view_as<Address>(8), NumberType_Int32);
    if (playerAddr == 0 || mv == 0)
        return MRES_Ignored;
    if (!CS2M_IsSurvivor(CS2M_MoveClientFromPlayerAddress(view_as<Address>(playerAddr))))
    {
        g_iSkipNotSurvivor++;
        return MRES_Ignored;
    }

    int client = CS2M_MoveClientFromPlayerAddress(view_as<Address>(playerAddr));
    if (client == 0)
        return MRES_Ignored;
    if (!CS2M_IsSurvivor(client))
    {
        g_iSkipNotSurvivor++;
        return MRES_Ignored;
    }

    /* Only crouching players: standing/running keeps mv+0x38 = the engine cap
     * written by the SetupMove hook.  L4D2 sets FL_DUCKING one tick after the
     * +duck button reaches the move (the engine still clamps that first tick to
     * its own 75), so the pending/active slide must be allowed through here.
     * The engine's automatic jump tuck never sets the pending flag (it requires
     * a usercmd +duck edge on the ground). */
    if ((GetEntityFlags(client) & FL_DUCKING) == 0 &&
        !g_bSlidePending[client] && !g_bSlideActive[client])
    {
        return MRES_Ignored;
    }

    float runTarget = CS2M_MoveEngineTarget(client);
    if (runTarget <= 0.0)
        return MRES_Ignored;

    /* L4D2 tucks the survivor into the duck hull for most of every jump: the
     * engine sets FL_DUCKING / m_bDucked on the jump tick even from a standing
     * start and keeps it until roughly the last 1/8 s of the airtime (measured
     * on a real client: m_flMaxspeed becomes 75.00 and AirAccelerate receives
     * wishspeed 75.999 while airborne).  CS2 never ducks in the air, so its air
     * accelerate term uses the weapon maxspeed.  The L4D2 AirMove override
     * clamps wishspeed against mv+0x38 before calling AirAccelerate, therefore
     * the engine's automatic duck also divides air acceleration by
     * weapon_speed / duck_speed (215/76 = 2.8x at 64 tick: 12*76/64 = 14.25
     * u/s per tick instead of the 30 u/s addSpeed cap).
     *
     * cs2movement_air_jump_speed 1 keeps the run speed for the air move when the
     * player is NOT holding +duck.  A real crouch jump (holding duck) and any
     * in-air duck keep the crouch maxspeed, which is what CS2 does too.
     *
     * Opt-in (default 0): this is a per-player server-side correction; the
     * client's own predicted move still auto-ducks, so the extra acceleration is
     * not predicted.  Measure with tests/air_movement_runtime.md before relying
     * on it. */
    bool airRun = false;
    if ((GetEntityFlags(client) & FL_ONGROUND) == 0 && !g_bMoveDuckHeld[client])
        airRun = (GetConVarInt(FindConVar("cs2movement_air_jump_speed")) != 0);

    float target;
    if (airRun)
    {
        target = runTarget;
    }
    else
    {
        target = runTarget * CS2M_MoveTargetFloat("cs2movement_duck_multiplier", 0.34);
        if (target <= 0.0)
            return MRES_Ignored;

        /* Friction floor: on the ground, a wishspeed below
         *     sv_stopspeed * sv_friction / sv_accelerate
         *     = 80 * 5.2 / 5.5 = 75.64 u/s
         * loses more to friction than Accelerate() can add, so the speed decays
         * toward zero instead of holding (measured: cap 73 -> 27.0, cap 75 -> 63.4,
         * cap 78 -> 78.0 steady).  CS2 sustains its crouch speeds, so an exact
         * sub-threshold target would be *worse* than the engine's own 75.  Floor the
         * target at the lowest sustainable value (configurable, 0 disables), then
         * never let crouch exceed the standing target (a very low cap must not make
         * crouching faster than running). */
        float floorSpeed = CS2M_MoveTargetFloat("cs2movement_duck_speed_min", 76.0);
        if (floorSpeed > 0.0 && target < floorSpeed)
            target = floorSpeed;
        if (target > runTarget)
            target = runTarget;
    }

    Address mvA = view_as<Address>(mv);
    Address fwdA = mvA + view_as<Address>(0x2C);
    Address sideA = mvA + view_as<Address>(0x30);
    Address upA = mvA + view_as<Address>(0x34);
    Address maxA = mvA + view_as<Address>(0x38);

    float maxspeed = CS2M_MoveLoadFloat(maxA);
    float fwd = CS2M_MoveLoadFloat(fwdA);
    float side = CS2M_MoveLoadFloat(sideA);
    float up = CS2M_MoveLoadFloat(upA);
    float len = SquareRoot(fwd * fwd + side * side + up * up);
    float orig = maxspeed;

        /* Crouch slide (opt-in): this hook only records the duck target.  The actual
     * momentum preservation happens in the Friction post-hook, which runs after
     * L4D2's duck transition has already clamped the velocity (that clamp is
     * outside CheckParameters), so writing mv+0x38 here is too early. */
    if (!airRun)
        g_fSlideDuckTarget[client] = target;

    /* CheckParameters rescales the move vector to maxspeed only when it was
     * longer than maxspeed; rescale that same clamped vector to our target so
     * the wishspeed lands exactly on the CS2 crouch speed.  A shorter input is
     * left untouched (proportional stick movement). */
    if (len > 0.0 && (len >= maxspeed - 0.01))
    {
        float scale = target / len;
        CS2M_MoveStoreFloat(fwdA, fwd * scale);
        CS2M_MoveStoreFloat(sideA, side * scale);
        CS2M_MoveStoreFloat(upA, up * scale);
    }

    CS2M_MoveStoreFloat(maxA, target);
    g_fDuckLastTarget = target;
    g_fDuckLastOrig = orig;
    g_iDuckCapWrites++;

    if (GetConVarBool(FindConVar("cs2movement_debug")))
    {
        /* Debug-only readback: after the write, what did the engine actually
         * see for this move (mv+0x38 / mv+0x3C / move length) and what is the
         * player's velocity at CheckParameters time (the previous tick's end)? */
        float f2 = CS2M_MoveLoadFloat(fwdA);
        float s2 = CS2M_MoveLoadFloat(sideA);
        float u2 = CS2M_MoveLoadFloat(upA);
        float len2 = SquareRoot(f2 * f2 + s2 * s2 + u2 * u2);
        float mv3c = CS2M_MoveLoadFloat(mvA + view_as<Address>(0x3C));
        float mv38 = CS2M_MoveLoadFloat(maxA);
        /* Raw memory at player+0x1FFC vs the datamap property: if the engine
         * writes 75 into the field, raw_mfs shows it even when the property
         * lookup still returns the plugin's value (U1 diagnostic). */
        float raw_mfs = view_as<float>(LoadFromAddress(view_as<Address>(playerAddr) + view_as<Address>(0x1FFC), NumberType_Int32));
        float v3[3];
        GetEntPropVector(client, Prop_Data, "m_vecVelocity", v3);
        PrintToServer("[CS2Movement] DUCK-CAP client=%d orig=%.2f target=%.2f len=%.2f mv38=%.2f mv3c=%.2f len_after=%.2f raw_mfs=%.2f vel=%.2f,%.2f,%.2f flags=0x%X air=%d",
                      client, orig, target, len, mv38, mv3c, len2, raw_mfs, v3[0], v3[1], v3[2], GetEntityFlags(client),
                      airRun ? 1 : 0);
    }

    return MRES_Ignored;
}

/* ------------------------------------------------------------------------- *
 * Low-speed sustain (per-player friction compensation, opt-in)
 *
 * The problem
 *   CGameMovement::Friction (0x100F4680) computes
 *       control = max(|v|, sv_stopspeed)
 *       drop    = control * surfaceFriction * sv_friction * vt[0x25C]() * dt
 *       v      *= max(|v| - drop, 0) / |v|
 *   and Accelerate can only add
 *       accelspeed = sv_accelerate * dt * wishspeed * surfaceFriction
 *   per tick.  On the ground the two balance only when
 *       sv_accelerate * wishspeed >= sv_stopspeed * sv_friction
 *   i.e. wishspeed >= 80 * 5.2 / 5.5 = 75.636 u/s with the CS2 constants.
 *   Below that the engine removes more than it can add, so the speed collapses
 *   to the one accelerate step the clamp at |v| = 0 allows:
 *       5.5 * wishspeed * dt  (measured: 11.0 u/s at 30 tick, 5.12 at 64 tick
 *       for wishspeed 60; see tests/tickrate64_runtime.md section 3.2).
 *   This is why cs2movement_duck_speed_min floors the crouch target at 76:
 *   CS2's AK crouch speed is 73.1 and the AWP's is 68, both below the floor.
 *   It is also why any cap below 76 is unusable, which blocks the deceleration
 *   gameplay the user may want later (docs/05 section 24.5).
 *
 * What this hook does
 *   Pre+post detour on Friction.  The pre-hook only samples |v| before the
 *   call; the post-hook rescales mv->m_vecVelocity, which is the one and only
 *   velocity mutation inside Friction (a uniform 3-axis scale at
 *   0x100F478C/0x100F479A/0x100F47A8), so a scalar rescale is exact and does
 *   not need the pre-friction vector beyond its magnitude.
 *
 *   The cap is chosen so that Accelerate can still land exactly on the
 *   wishspeed instead of merely stopping the decay:
 *
 *       gain  = sv_accelerate * dt * wishspeed * surfaceFriction
 *       floor = wishspeed - gain     <- slowest post-friction speed from which
 *                                       Accelerate still reaches wishspeed
 *       new   = min(max(|v_post|, floor), |v_pre|)
 *
 *   Consequences, all of which matter (a naive "cap the drop at gain" would
 *   make the speed sticky instead of converging):
 *     - |v| > wishspeed   -> new == |v_post|, normal friction, vanilla braking;
 *     - |v| near wishspeed -> lands exactly on wishspeed every tick;
 *     - |v| far below       -> floor > pre, so new == pre: friction is fully
 *                              undone and the ramp-up is minimum-time.
 *   |v_pre| is a hard upper bound on `new`, so this can only ever make friction
 *   weaker; it can never add speed the player did not have.
 *
 *   Friction clamps newspeed at 0, so in the crawl regime it zeroes the velocity
 *   and the post-call sample loses its direction; the pre-hook therefore records
 *   the vector, not just its length.
 *
 *   Gates (fail-closed, default OFF so no shipped behaviour changes):
 *     cs2movement_lowspeed_sustain 1  (+ write_props + speed_enforce),
 *     DHooks and the CS2M_Friction gamedata signature must be present,
 *     wishspeed must be below the threshold, a movement key must be held,
 *     and surfaceFriction must be readable and non-zero.
 *
 *   Client prediction: Friction also runs in client.dll, and m_vecVelocity is
 *   networked, so the server-side sustain is a per-tick correction whose size is
 *   (sv_stopspeed*sv_friction - sv_accelerate*wishspeed) * dt * surfaceFriction:
 *   wishspeed 73 -> 0.22 u/s at 64 tick / 0.44 at 30 tick, and wishspeed 60 ->
 *   1.34 / 2.87 (both measured, see tests/lowspeed_sustain_runtime.md).  The
 *   run->duck pullback measured 2.17 u before this feature and 1.88 u after.
 * ------------------------------------------------------------------------- */

DynamicDetour g_hFrictionDetour = null;
bool  g_bFrictionReady = false;
ConVar g_cvLowSpeedSustain = null;
int   g_iFrictionHits = 0;
int   g_iFrictionPostHits = 0;
int   g_iSustainWrites = 0;
/* Rejection accounting so a silent "writes=0" can never again be a mystery:
 * index = the early return that fired (0 = disabled, 1 = pre invalid, ...). */
int   g_iSustainReject[12];
float g_fFrictionPreSpeed = -1.0;
int   g_iFrictionPrePlayer = 0;
float g_fFrictionPreX = 0.0;
float g_fFrictionPreY = 0.0;
float g_fFrictionPreZ = 0.0;
int   g_iSustainLastClient = 0;
float g_fSustainLastWish = 0.0;
float g_fSustainLastPre = 0.0;
float g_fSustainLastPost = 0.0;
float g_fSustainLastFloor = 0.0;
float g_fSustainLastGain = 0.0;

stock bool CS2M_MoveSustainEnabled()
{
    if (!g_bFrictionReady || g_cvLowSpeedSustain == null)
        return false;
    if (!GetConVarBool(FindConVar("cs2movement_enable")))
        return false;
    if (GetConVarInt(g_cvLowSpeedSustain) == 0)
        return false;
    if (!GetConVarBool(FindConVar("cs2movement_write_props")))
        return false;
    return GetConVarBool(FindConVar("cs2movement_speed_enforce"));
}

stock void CS2M_MoveSetupSustainHook()
{
    Handle conf = LoadGameConfigFile("cs2movement");
    if (conf == null)
    {
        LogMessage("lowspeed_sustain: gamedata cs2movement.txt missing; staying disabled");
        return;
    }

    g_hFrictionDetour = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_Address);
    if (g_hFrictionDetour == null ||
        !DHookSetFromConf(g_hFrictionDetour, conf, SDKConf_Signature, "CS2M_Friction"))
    {
        LogMessage("lowspeed_sustain: signature CS2M_Friction missing; staying disabled");
        CloseHandle(conf);
        g_hFrictionDetour = null;
        return;
    }

    /* void __thiscall(void): no stack parameters; the decision is read from
     * [this+4] (CBasePlayer*) and [this+8] (CMoveData*), exactly like the
     * CheckParameters detour above. */
    if (!DHookEnableDetour(g_hFrictionDetour, false, CS2M_MoveOnFrictionPre))
    {
        LogMessage("lowspeed_sustain: Friction pre-detour install failed; staying disabled");
        CloseHandle(conf);
        g_hFrictionDetour = null;
        return;
    }
    if (!DHookEnableDetour(g_hFrictionDetour, true, CS2M_MoveOnFrictionPost))
    {
        LogMessage("lowspeed_sustain: Friction post-detour install failed; staying disabled");
        DHookDisableDetour(g_hFrictionDetour, false, CS2M_MoveOnFrictionPre);
        CloseHandle(conf);
        g_hFrictionDetour = null;
        return;
    }

    CloseHandle(conf);
    g_cvLowSpeedSustain = FindConVar("cs2movement_lowspeed_sustain");
    g_bFrictionReady = true;
    LogMessage("lowspeed_sustain: CGameMovement::Friction pre+post detour installed (per-player friction compensation; gated by cs2movement_lowspeed_sustain)");
}

stock void CS2M_MoveShutdownSustainHook()
{
    if (g_hFrictionDetour != null)
    {
        DHookDisableDetour(g_hFrictionDetour, true, CS2M_MoveOnFrictionPost);
        DHookDisableDetour(g_hFrictionDetour, false, CS2M_MoveOnFrictionPre);
        g_hFrictionDetour = null;
    }
    g_bFrictionReady = false;
}

/**
 * Pre-hook: sample |v| before Friction runs.
 *
 * Pre and post of the same invocation are adjacent and the engine runs one move
 * per player at a time, so a single current-call slot is safe (no reentrancy).
 */
public MRESReturn CS2M_MoveOnFrictionPre(Address pThis)
{
    g_iFrictionHits++;
    g_fFrictionPreSpeed = -1.0;
    g_iFrictionPrePlayer = 0;

    if (!CS2M_MoveSustainEnabled() && !CS2M_MoveCrouchSlideEnabled())
        return MRES_Ignored;

    Address base = view_as<Address>(pThis);
    int playerAddr = LoadFromAddress(base + view_as<Address>(4), NumberType_Int32);
    int mv = LoadFromAddress(base + view_as<Address>(8), NumberType_Int32);
    if (playerAddr == 0 || mv == 0)
        return MRES_Ignored;
    if (!CS2M_IsSurvivor(CS2M_MoveClientFromPlayerAddress(view_as<Address>(playerAddr))))
    {
        g_iSkipNotSurvivor++;
        return MRES_Ignored;
    }

    Address mvA = view_as<Address>(mv);
    float vx = CS2M_MoveLoadFloat(mvA + view_as<Address>(0x40));
    float vy = CS2M_MoveLoadFloat(mvA + view_as<Address>(0x44));
    float vz = CS2M_MoveLoadFloat(mvA + view_as<Address>(0x48));
    float speed = SquareRoot(vx * vx + vy * vy + vz * vz);
    if (speed < 0.1)
        return MRES_Ignored;

    /* Keep the vector, not just its length.  Friction clamps newspeed at 0, so
     * below the threshold it zeroes the velocity outright (measured: the crawl
     * at wishspeed 60 sits at 5.12 u/s and Friction takes 6.5), and then the
     * post-call sample no longer carries a direction.  This is exactly the
     * regime the sustain exists for, so the pre-call direction is mandatory. */
    g_fFrictionPreSpeed = speed;
    g_fFrictionPreX = vx;
    g_fFrictionPreY = vy;
    g_fFrictionPreZ = vz;
    g_iFrictionPrePlayer = playerAddr;
    return MRES_Ignored;
}

/**
 * Post-hook: clamp how much speed Friction was allowed to remove this tick.
 * See the block comment above for the derivation.
 */
/** Apply one crouch-slide tick.  Runs from the Friction post-hook, i.e. after
 *  L4D2's duck transition and Friction have both had their say, and immediately
 *  before WalkMove.  Restoring the velocity here is what the CheckParameters
 *  post-hook cannot do: the duck transition clamps the velocity outside it. */
stock void CS2M_MoveApplyCrouchSlide(int playerAddr, Address mvA, float pre,
                                     float preX, float preY, float preZ,
                                     float vx, float vy, float vz, float post)
{
    if (!CS2M_MoveCrouchSlideEnabled() || playerAddr == 0)
        return;

    int client = CS2M_MoveClientFromPlayerAddress(view_as<Address>(playerAddr));
    if (client <= 0 || client > MaxClients)
        return;
    if ((GetEntityFlags(client) & FL_ONGROUND) == 0)
    {
        CS2M_SlideReset(client);
        return;
    }

    float duckTarget = g_fSlideDuckTarget[client];
    if (g_bSlidePending[client])
    {
        g_bSlidePending[client] = false;
        float v0 = g_fSlideV0[client];
        float slideTime = CS2M_MoveTargetFloat("cs2movement_crouch_slide_time", 0.20);
        float minSpeed = CS2M_MoveTargetFloat("cs2movement_crouch_slide_min_speed", 100.0);
        float cooldown = CS2M_MoveTargetFloat("cs2movement_time_between_ducks", 0.4);
        if (slideTime < 0.02)
            slideTime = 0.02;

        if (!g_bSlideActive[client] && duckTarget > 1.0 && v0 > duckTarget + 5.0 &&
            v0 >= minSpeed && (GetGameTime() - g_fSlideLastStart[client]) >= cooldown)
        {
            g_bSlideActive[client] = true;
            g_fSlideV0[client] = v0;
            g_fSlideK[client] = Logarithm(v0 / duckTarget, 2.718281828) / slideTime;
            g_fSlideElapsed[client] = 0.0;
            g_fSlideLastStart[client] = GetGameTime();
            g_iSlideStarts++;
        }
    }

    if (!g_bSlideActive[client])
    {
        g_fSlideClientCeil[client] = 0.0;
        CS2M_MoveUpdateClientSlide(false);
        return;
    }

    float k = g_fSlideK[client];
    if (k < 0.0)
        k = 0.0;
    float ceilSpeed = g_fSlideV0[client] * Exponential(-k * g_fSlideElapsed[client]);
    g_fSlideElapsed[client] += GetTickInterval();
    if (ceilSpeed <= duckTarget + 0.01)
    {
        ceilSpeed = duckTarget;
        g_bSlideActive[client] = false;
    }
    float runTarget = CS2M_MoveEngineTarget(client);
    if (runTarget > 0.0 && ceilSpeed > runTarget)
        ceilSpeed = runTarget;

    /* Direction: Friction's post vector keeps the direction; if it clamped to
     * zero the pre vector still has it. */
    float dirX = vx, dirY = vy, dirZ = vz, mag = post;
    if (mag <= 0.001)
    {
        dirX = preX; dirY = preY; dirZ = preZ; mag = pre;
    }
    if (mag > 0.001)
    {
        float scale = ceilSpeed / mag;
        CS2M_MoveStoreFloat(mvA + view_as<Address>(0x40), dirX * scale);
        CS2M_MoveStoreFloat(mvA + view_as<Address>(0x44), dirY * scale);
        CS2M_MoveStoreFloat(mvA + view_as<Address>(0x48), dirZ * scale);
    }

    /* Keep wishspeed on the same ceiling so Accelerate cannot refill above the
     * curve while the player holds +forward. */
    float fwd = CS2M_MoveLoadFloat(mvA + view_as<Address>(0x2C));
    float side = CS2M_MoveLoadFloat(mvA + view_as<Address>(0x30));
    float up = CS2M_MoveLoadFloat(mvA + view_as<Address>(0x34));
    float mlen = SquareRoot(fwd * fwd + side * side + up * up);
    if (mlen > 0.001)
    {
        float ms = ceilSpeed / mlen;
        CS2M_MoveStoreFloat(mvA + view_as<Address>(0x2C), fwd * ms);
        CS2M_MoveStoreFloat(mvA + view_as<Address>(0x30), side * ms);
        CS2M_MoveStoreFloat(mvA + view_as<Address>(0x34), up * ms);
    }
    CS2M_MoveStoreFloat(mvA + view_as<Address>(0x38), ceilSpeed);

    g_iSlideWrites++;
    g_iSlideLastClient = client;
    g_fSlideLastCeil = ceilSpeed;
    g_fSlideLastV0 = g_fSlideV0[client];

    /* Publish the same curve to the replicated crouch cap so the client
     * predicts this tick instead of snapping to its own crouch speed.  This is
     * the ONLY client-side effect of the slide and it touches no mv field. */
    if (CS2M_MoveCrouchSlideClientEnabled())
    {
        g_fSlideClientCeil[client] = g_bSlideActive[client] ? ceilSpeed : 0.0;
        g_fSlideClientTouch[client] = GetGameTime();
    }
    else
    {
        g_fSlideClientCeil[client] = 0.0;
    }
    CS2M_MoveUpdateClientSlide(false);

    if (GetConVarBool(FindConVar("cs2movement_debug")))
        PrintToServer("[CS2Movement] SLIDE client=%d v0=%.2f t=%.3f ceil=%.2f duck=%.2f k=%.2f",
                      client, g_fSlideV0[client], g_fSlideElapsed[client], ceilSpeed,
                      duckTarget, k);
}

public MRESReturn CS2M_MoveOnFrictionPost(Address pThis)
{
    g_iFrictionPostHits++;

    float pre = g_fFrictionPreSpeed;
    int playerAddr = g_iFrictionPrePlayer;
    float preX = g_fFrictionPreX;
    float preY = g_fFrictionPreY;
    float preZ = g_fFrictionPreZ;
    g_fFrictionPreSpeed = -1.0;
    g_iFrictionPrePlayer = 0;

    if (!CS2M_MoveSustainEnabled() && !CS2M_MoveCrouchSlideEnabled())
    {
        g_iSustainReject[0]++;
        return MRES_Ignored;
    }
    if (pre <= 0.0 || playerAddr == 0)           { g_iSustainReject[1]++;  return MRES_Ignored; }
    if (!CS2M_IsSurvivor(CS2M_MoveClientFromPlayerAddress(view_as<Address>(playerAddr))))
    {
        g_iSkipNotSurvivor++;
        return MRES_Ignored;
    }

    Address base = view_as<Address>(pThis);
    int mv = LoadFromAddress(base + view_as<Address>(8), NumberType_Int32);
    if (mv == 0)                                 { g_iSustainReject[2]++;  return MRES_Ignored; }
    Address mvA = view_as<Address>(mv);

    float vx = CS2M_MoveLoadFloat(mvA + view_as<Address>(0x40));
    float vy = CS2M_MoveLoadFloat(mvA + view_as<Address>(0x44));
    float vz = CS2M_MoveLoadFloat(mvA + view_as<Address>(0x48));
    float post = SquareRoot(vx * vx + vy * vy + vz * vz);

    /* Crouch slide first: it must restore the momentum after the duck clamp and
     * Friction, and before WalkMove integrates the position. */
    CS2M_MoveApplyCrouchSlide(playerAddr, mvA, pre, preX, preY, preZ, vx, vy, vz, post);

    if (!CS2M_MoveSustainEnabled())              { g_iSustainReject[0]++;  return MRES_Ignored; }

    /* Friction's only velocity mutation is a uniform 3-axis scale
     * v *= max(|v|-drop, 0)/|v|, so the direction survives -- except when the
     * clamp actually reaches zero, which is the crawl case.  Fall back to the
     * pre-call vector there. */
    float dirX, dirY, dirZ, dirMag;
    if (post > 0.001)
    {
        /* post >= pre means Friction produced no drop at all (ground lost, or
         * the 0x2014 timer is running): nothing to cap. */
        if (post >= pre)                         { g_iSustainReject[3]++;  return MRES_Ignored; }
        dirX = vx;    dirY = vy;    dirZ = vz;    dirMag = post;
    }
    else
    {
        dirX = preX;  dirY = preY;  dirZ = preZ;  dirMag = pre;
    }

    float fwd  = CS2M_MoveLoadFloat(mvA + view_as<Address>(0x2C));
    float side = CS2M_MoveLoadFloat(mvA + view_as<Address>(0x30));
    float up   = CS2M_MoveLoadFloat(mvA + view_as<Address>(0x34));
    float len = SquareRoot(fwd * fwd + side * side + up * up);
    /* No movement input: friction is supposed to bring the player to a stop. */
    if (len < 1.0)                               { g_iSustainReject[4]++;  return MRES_Ignored; }

    float mv38 = CS2M_MoveLoadFloat(mvA + view_as<Address>(0x38));
    float wishspeed = (len < mv38) ? len : mv38;
    if (wishspeed <= 0.0)                        { g_iSustainReject[5]++;  return MRES_Ignored; }

    /* NOTE: there is deliberately no wish-vs-velocity direction gate here.
     * m_flForwardMove/m_flSideMove are in the player's local frame, so testing
     * them against the world-space velocity needs the view yaw and is easy to
     * get wrong; it is also unnecessary.  The `newSpeed <= pre` bound below
     * already restricts the correction to |v| <= wishspeed, so a braking
     * player above the floor is untouched, and a player who released the keys
     * has len == 0 and is rejected above.  The only residual effect is that
     * braking *at or below* the floor is ~(drop - allowed) softer per tick,
     * i.e. about 1.3 u/s per tick at 64 tick, and Accelerate still opposes. */

    float S = (g_cvSVStopspeed != null)    ? GetConVarFloat(g_cvSVStopspeed)    : 0.0;
    float F = (g_cvSVFriction != null)     ? GetConVarFloat(g_cvSVFriction)     : 0.0;
    float A = (g_cvSVAccelerate != null)   ? GetConVarFloat(g_cvSVAccelerate)   : 0.0;
    if (F <= 0.0 || A <= 0.0)                    { g_iSustainReject[7]++;  return MRES_Ignored; }

    /* At or above the sustainability threshold the stock model already holds
     * the wishspeed, so leave vanilla physics completely untouched.  This is
     * what keeps the shipped defaults (duck_speed_min 76.0, i.e. wishspeed 76)
     * bit-identical to 0.4.2: 76 > 75.636, so this hook never acts. */
    if (S > 0.0 && wishspeed >= (S * F / A))     { g_iSustainReject[8]++;  return MRES_Ignored; }

    float sf = CS2M_MoveLoadFloat(view_as<Address>(playerAddr) + view_as<Address>(0x2184));
    if (sf <= 0.0)                               { g_iSustainReject[9]++;  return MRES_Ignored; }

    float dt = GetTickInterval();
    float gain = A * dt * wishspeed * sf;
    float floorSpeed = wishspeed - gain;
    if (floorSpeed <= 0.0)                       { g_iSustainReject[10]++; return MRES_Ignored; }

    /* Target post-friction speed:
     *   - never above what the player actually had (friction may not add speed),
     *   - at least floorSpeed once the player is near the target, so that
     *     Accelerate's min(A*dt*W*sf, W-v) lands exactly on the wishspeed,
     *   - untouched above floorSpeed, i.e. normal deceleration.
     * When the player is far below, floorSpeed > pre, so this restores the
     * speed and friction contributes nothing: a minimum-time ramp-up. */
    float newSpeed = (floorSpeed < pre) ? floorSpeed : pre;
    if (newSpeed <= post + 0.0001)               { g_iSustainReject[11]++; return MRES_Ignored; }

    float scale = newSpeed / dirMag;
    CS2M_MoveStoreFloat(mvA + view_as<Address>(0x40), dirX * scale);
    CS2M_MoveStoreFloat(mvA + view_as<Address>(0x44), dirY * scale);
    CS2M_MoveStoreFloat(mvA + view_as<Address>(0x48), dirZ * scale);

    g_iSustainWrites++;
    g_fSustainLastWish = wishspeed;
    g_fSustainLastPre = pre;
    g_fSustainLastPost = post;
    g_fSustainLastFloor = floorSpeed;
    g_fSustainLastGain = gain;

    if (GetConVarBool(FindConVar("cs2movement_debug")))
    {
        int client = CS2M_MoveClientFromPlayerAddress(view_as<Address>(playerAddr));
        g_iSustainLastClient = client;
        PrintToServer("[CS2Movement] SUSTAIN client=%d wish=%.2f pre=%.2f post=%.2f floor=%.2f new=%.2f gain=%.2f sf=%.3f dt=%.5f",
                      client, wishspeed, pre, post, floorSpeed, newSpeed, gain, sf, dt);
    }

    return MRES_Ignored;
}

stock void CS2M_MoveResetClient(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    g_iMoveJumps[client] = 0;
    g_iMoveLandings[client] = 0;
    g_iMoveLastButtons[client] = 0;
    g_bMoveWasOnGround[client] = false;
    g_bMoveDuckHeld[client] = false;
    g_bMoveDuckPrev[client] = false;
    CS2M_SlideReset(client);
    g_fSlideLastStart[client] = 0.0;
    g_fMoveLastJump[client] = 0.0;
    g_fMoveLastAppliedSpeed[client] = 0.0;
    g_bMoveHasAppliedSpeed[client] = false;
    g_fLastJumpPress[client] = 0.0;
    g_fLastLandTime[client] = 0.0;
    g_bJumpHeld[client] = false;

    /* Engine-layer caches. */
    g_fEngineSpeedTarget[client] = -1.0;
    g_fEngineSpeedTick[client] = -1.0;
    g_bEngineSpeedPropKnown[client] = false;
    g_bEngineSpeedHasProp[client] = false;
    g_bUseNextJumpFactor[client] = false;
    g_iJumpBlocked[client] = 0;
    g_iBhopWindowHits[client] = 0;
    g_iLandingWrites[client] = 0;
    g_iJumpImpulseWrites[client] = 0;
    g_iBhopCaps[client] = 0;
    g_iPlayerAddr[client] = 0;

    /* A disconnecting/slot-changing client must not keep a global crouch cap
     * elevated once its contribution is gone. */
    CS2M_MoveUpdateClientSlide(false);
}

stock void CS2M_MoveOnPlayerJump(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    g_fMoveLastJump[client] = GetGameTime();
    g_iMoveJumps[client]++;

    if (GetConVarBool(FindConVar("cs2movement_debug")))
        PrintToServer("[CS2Movement] JUMP client=%d t=%.3f count=%d", client, g_fMoveLastJump[client], g_iMoveJumps[client]);
}

stock bool CS2M_MoveGetVelocity(int client, float v[3])
{
    if (HasEntProp(client, Prop_Data, "m_vecVelocity"))
    {
        GetEntPropVector(client, Prop_Data, "m_vecVelocity", v);
        return true;
    }
    if (HasEntProp(client, Prop_Send, "m_vecVelocity"))
    {
        GetEntPropVector(client, Prop_Send, "m_vecVelocity", v);
        return true;
    }
    return false;
}

stock bool CS2M_MoveSetVelocity(int client, const float v[3])
{
    if (HasEntProp(client, Prop_Data, "m_vecVelocity"))
    {
        SetEntPropVector(client, Prop_Data, "m_vecVelocity", v);
        return true;
    }
    if (HasEntProp(client, Prop_Send, "m_vecVelocity"))
    {
        SetEntPropVector(client, Prop_Send, "m_vecVelocity", v);
        return true;
    }
    return false;
}

/**
 * Stage 3 (offline skeleton): jump impulse, landing penalty, bhop cap/window,
 * autobhop and jump-spam suppression.  All writes require
 * cs2movement_write_props 1 plus the feature gate.  Default gates are 0.
 *
 * This is intentionally not runtime-calibrated: writing m_vecVelocity can
 * double-apply the engine's own jump/landing logic and can fight client
 * prediction.  Stage 3 runtime tests will decide which sub-features survive.
 */
stock void CS2M_MoveStage3OnRunCmd(int client, int &buttons, bool &changed,
                                   bool wasOnGround, bool onGround)
{
    if (!CS2M_IsSurvivor(client))
    {
        g_iSkipNotSurvivor++;
        return;
    }

    if (!GetConVarBool(FindConVar("cs2movement_write_props")))
        return;

    bool bhop = GetConVarBool(FindConVar("cs2movement_bhop_enable"));
    bool landingEnforce = GetConVarBool(FindConVar("cs2movement_landing_enforce"));
    bool jumpEnforce = GetConVarBool(FindConVar("cs2movement_jump_enforce"));
    bool autobhop = GetConVarBool(FindConVar("cs2movement_autobhop"));

    if (!bhop && !landingEnforce && !jumpEnforce && !autobhop)
        return;

    float now = GetGameTime();
    float spam = CS2M_MoveTargetFloat("cs2movement_jump_spam_penalty", 0.015625);
    float window = CS2M_MoveTargetFloat("cs2movement_bhop_window", 0.0078125);
    float jumpImpulse = CS2M_MoveTargetFloat("cs2movement_jump_impulse", 301.993);
    float landFactor = CS2M_MoveTargetFloat("cs2movement_landing_speed_factor", 0.75);
    float nextFactor = CS2M_MoveTargetFloat("cs2movement_landing_next_factor", 0.88);
    float speedCap = CS2M_MoveTargetFloat("cs2movement_bhop_speed_cap", 286.0);

    bool jumpDown = (buttons & IN_JUMP) != 0;
    bool jumpPressed = jumpDown && !g_bJumpHeld[client];

    if (jumpPressed)
    {
        if (spam > 0.0 && g_fLastJumpPress[client] > 0.0 &&
            (now - g_fLastJumpPress[client]) < spam)
        {
            buttons &= ~IN_JUMP;
            changed = true;
            g_iJumpBlocked[client]++;
            if (GetConVarBool(FindConVar("cs2movement_debug")))
                PrintToServer("[CS2Movement] JUMP-BLOCK client=%d dt=%.4f spam=%.4f count=%d",
                              client, now - g_fLastJumpPress[client], spam, g_iJumpBlocked[client]);
        }
        else
        {
            g_fLastJumpPress[client] = now;
        }
    }

    float v[3];
    bool hasVelocity = CS2M_MoveGetVelocity(client, v);

    if (jumpPressed && onGround && hasVelocity)
    {
        if (g_bUseNextJumpFactor[client])
        {
            v[0] *= nextFactor;
            v[1] *= nextFactor;
            g_bUseNextJumpFactor[client] = false;
        }

        if (jumpEnforce)
        {
            v[2] = jumpImpulse;
            if (CS2M_MoveSetVelocity(client, v))
                g_iJumpImpulseWrites[client]++;
        }
    }

    if (onGround && !wasOnGround)
    {
        g_fLastLandTime[client] = now;

        if (window > 0.0 && g_fLastJumpPress[client] > 0.0 &&
            (now - g_fLastJumpPress[client]) <= window)
        {
            g_iBhopWindowHits[client]++;
        }

        if ((landingEnforce || bhop) && hasVelocity)
        {
            if (landingEnforce)
            {
                v[0] *= landFactor;
                v[1] *= landFactor;
                g_bUseNextJumpFactor[client] = (nextFactor > 0.0 && nextFactor < 1.0);
            }

            if (bhop)
            {
                float horizontal = SquareRoot(v[0] * v[0] + v[1] * v[1]);
                if (horizontal > speedCap && horizontal > 0.0)
                {
                    float scale = speedCap / horizontal;
                    v[0] *= scale;
                    v[1] *= scale;
                    g_iBhopCaps[client]++;
                }
            }

            if (CS2M_MoveSetVelocity(client, v))
                g_iLandingWrites[client]++;
        }

        if (bhop && autobhop && jumpDown)
        {
            buttons |= IN_JUMP;
            changed = true;
        }
    }

    g_bJumpHeld[client] = jumpDown;

    if (GetConVarBool(FindConVar("cs2movement_debug")))
        PrintToServer("[CS2Movement] STAGE3 client=%d ground=%d jump=%d v=(%.1f,%.1f,%.1f) blocked=%d window=%d caps=%d landw=%d jumpw=%d",
                      client, onGround ? 1 : 0, jumpDown ? 1 : 0, v[0], v[1], v[2],
                      g_iJumpBlocked[client], g_iBhopWindowHits[client], g_iBhopCaps[client],
                      g_iLandingWrites[client], g_iJumpImpulseWrites[client]);
}

stock void CS2M_MoveOnPlayerRunCmd(int client, int &buttons, bool &changed)
{
    if (client < 1 || client > MaxClients)
        return;

    bool wasOnGround = g_bMoveWasOnGround[client];
    bool onGround = (GetEntityFlags(client) & FL_ONGROUND) != 0;
    if (onGround && !wasOnGround)
        g_iMoveLandings[client]++;

    /* Cache the raw +duck bit before the move: the CheckParameters hook runs
     * later in the same usercmd and needs it to tell a real crouch (hold duck,
     * keep the crouch maxspeed in the air) from L4D2's automatic jump tuck. */
    bool duckHeld = (buttons & IN_DUCK) != 0;
    bool duckEdge = duckHeld && !g_bMoveDuckPrev[client];
    g_bMoveDuckHeld[client] = duckHeld;
    g_bMoveDuckPrev[client] = duckHeld;

    /* Crouch slide trigger: only a fresh duck press while running on the
     * ground.  The CheckParameters post-hook (same usercmd) captures the
     * pre-move speed and starts the decay.  Releasing duck drops the slide. */
    if (!duckHeld)
    {
        g_bSlideActive[client] = false;
        g_bSlidePending[client] = false;
    }
    else if (duckEdge && onGround && CS2M_MoveCrouchSlideEnabled())
    {
        float sv[3];
        if (CS2M_MoveGetVelocity(client, sv))
        {
            float sp = SquareRoot(sv[0] * sv[0] + sv[1] * sv[1] + sv[2] * sv[2]);
            float minSp = CS2M_MoveTargetFloat("cs2movement_crouch_slide_min_speed", 100.0);
            if (sp >= minSp)
            {
                g_fSlideV0[client] = sp;
                g_bSlidePending[client] = true;
            }
        }
    }

    /* Client-side slide bookkeeping.  A slide only owns the replicated crouch
     * cap while it is actually running on the ground with duck held; anything
     * else drops this client's contribution and lets CS2M_MoveUpdateClientSlide
     * restore the baseline within this same tick (no timer).  The 0.5 s touch
     * guard covers the case where Friction stops running (player came to a stop
     * mid-slide): the stale contribution is dropped instead of leaving a global
     * crouch cap elevated. */
    if (!g_bSlideActive[client] || !duckHeld || !onGround ||
        (g_fSlideClientTouch[client] > 0.0 &&
         GetGameTime() - g_fSlideClientTouch[client] > 0.5))
    {
        g_fSlideClientCeil[client] = 0.0;
    }
    CS2M_MoveUpdateClientSlide(false);

    CS2M_MoveStage3OnRunCmd(client, buttons, changed, wasOnGround, onGround);

    g_bMoveWasOnGround[client] = onGround;
    g_iMoveLastButtons[client] = buttons;

    if (!GetConVarBool(FindConVar("cs2movement_debug")))
        return;

    float v[3];
    v[0] = v[1] = v[2] = 0.0;
    if (!CS2M_MoveGetVelocity(client, v))
        v[0] = v[1] = v[2] = 0.0;

    float target = CS2M_MoveDesiredMaxSpeed(client, buttons);
    PrintToServer("[CS2Movement] CMD client=%d v=(%.1f,%.1f,%.1f) |vxy|=%.1f target=%.1f ground=%d duck=%d jumps=%d lands=%d",
                  client, v[0], v[1], v[2], SquareRoot(v[0] * v[0] + v[1] * v[1]),
                  target, onGround ? 1 : 0,
                  (GetEntityFlags(client) & FL_DUCKING) != 0 ? 1 : 0,
                  g_iMoveJumps[client], g_iMoveLandings[client]);
}

stock void CS2M_MovePrintCvarLine(int client, const char[] engineName, const char[] targetName)
{
    ConVar engineCv = FindConVar(engineName);
    ConVar targetCv = FindConVar(targetName);

    if (engineCv == null)
    {
        ReplyToCommand(client, "[CS2Movement]   %-24s MISSING (target %s)", engineName, targetName);
        return;
    }

    float current = GetConVarFloat(engineCv);
    float target = (targetCv == null) ? -1.0 : GetConVarFloat(targetCv);
    ReplyToCommand(client, "[CS2Movement]   %-24s current=%.4f target=%.4f", engineName, current, target);
}

stock void CS2M_MoveStatus(int client)
{
    ReplyToCommand(client, "[CS2Movement] MOVE global_applied=%d", g_bGlobalApplied ? 1 : 0);
    ReplyToCommand(client, "[CS2Movement]   engine_speed=%d hook_ready=%d calls=%d skip_driven=%d skip_locked=%d",
                   GetConVarInt(FindConVar("cs2movement_engine_speed")),
                   g_bEngineSpeedReady ? 1 : 0, g_iEngineSpeedHits,
                   g_iEngineSpeedSkipDriven, g_iEngineSpeedSkipLocked);
    char reasonBuf[192];
    reasonBuf[0] = '\0';
    for (int r = 0; r < 32; r++)
    {
        if (g_iEngineSpeedSkipReason[r] == 0)
            continue;
        Format(reasonBuf, sizeof(reasonBuf), "%s r%d=%d", reasonBuf, r, g_iEngineSpeedSkipReason[r]);
    }
    if (reasonBuf[0] != '\0')
        ReplyToCommand(client, "[CS2Movement]   engine_speed skips by reason:%s", reasonBuf);
    ReplyToCommand(client, "[CS2Movement]   non-survivor skips=%d", g_iSkipNotSurvivor);
    ReplyToCommand(client, "[CS2Movement]   duck_speed=%d hook_ready=%d hits=%d writes=%d last_orig=%.2f last_target=%.2f",
                   GetConVarInt(FindConVar("cs2movement_duck_speed")),
                   g_bCheckParamsReady ? 1 : 0, g_iCheckParamsHits, g_iDuckCapWrites,
                   g_fDuckLastOrig, g_fDuckLastTarget);
    char clientSlide[96];
    CS2M_MoveSlideClientStatus(clientSlide, sizeof(clientSlide));
    ReplyToCommand(client, "[CS2Movement]   crouch_slide=%d ready=%d duck_layer=%d hook=%d time=%.2f min_speed=%.1f starts=%d writes=%d last client=%d v0=%.2f ceil=%.2f %s",
                   GetConVarInt(FindConVar("cs2movement_crouch_slide")),
                   CS2M_MoveCrouchSlideReady() ? 1 : 0,
                   CS2M_MoveDuckSpeedEnabled() ? 1 : 0,
                   g_bCheckParamsReady ? 1 : 0,
                   GetConVarFloat(FindConVar("cs2movement_crouch_slide_time")),
                   GetConVarFloat(FindConVar("cs2movement_crouch_slide_min_speed")),
                   g_iSlideStarts, g_iSlideWrites, g_iSlideLastClient, g_fSlideLastV0, g_fSlideLastCeil,
                   clientSlide);
    ReplyToCommand(client, "[CS2Movement]   lowspeed_sustain=%d hook_ready=%d pre=%d post=%d writes=%d last client=%d wish=%.2f pre_v=%.2f post_v=%.2f floor=%.2f gain=%.2f",
                   GetConVarInt(FindConVar("cs2movement_lowspeed_sustain")),
                   g_bFrictionReady ? 1 : 0, g_iFrictionHits, g_iFrictionPostHits, g_iSustainWrites,
                   g_iSustainLastClient, g_fSustainLastWish, g_fSustainLastPre,
                   g_fSustainLastPost, g_fSustainLastFloor, g_fSustainLastGain);
    ReplyToCommand(client, "[CS2Movement]   lowspeed_sustain rej: %d=%d %d=%d %d=%d %d=%d %d=%d %d=%d %d=%d %d=%d %d=%d %d=%d %d=%d %d=%d",
                   0, g_iSustainReject[0], 1, g_iSustainReject[1], 2, g_iSustainReject[2],
                   3, g_iSustainReject[3], 4, g_iSustainReject[4], 5, g_iSustainReject[5],
                   6, g_iSustainReject[6], 7, g_iSustainReject[7], 8, g_iSustainReject[8],
                   9, g_iSustainReject[9], 10, g_iSustainReject[10], 11, g_iSustainReject[11]);
    CS2M_MovePrintCvarLine(client, "sv_accelerate", "cs2movement_accelerate");
    CS2M_MovePrintCvarLine(client, "sv_friction", "cs2movement_friction");
    CS2M_MovePrintCvarLine(client, "sv_stopspeed", "cs2movement_stopspeed");
    CS2M_MovePrintCvarLine(client, "sv_airaccelerate", "cs2movement_airaccelerate");
    CS2M_MovePrintCvarLine(client, "sv_gravity", "cs2movement_gravity");
    CS2M_MovePrintCvarLine(client, "sv_maxvelocity", "cs2movement_maxvelocity");

    ReplyToCommand(client, "[CS2Movement]   L4D2 missing (expected): sv_air_max_wishspeed, sv_jump_impulse, sv_timebetweenducks, sv_enablebunnyhopping");

    if (client > 0 && IsClientInGame(client))
    {
        float target = CS2M_MoveDesiredMaxSpeed(client, g_iMoveLastButtons[client]);
        ReplyToCommand(client, "[CS2Movement]   desired_maxspeed client=%d target=%.2f (native=%s)",
                       client, target, target < 0.0 ? "on" : "off");
        ReplyToCommand(client, "[CS2Movement]   applied_maxspeed=%d value=%.2f speed_enforce=%d write_props=%d",
                       g_bMoveHasAppliedSpeed[client] ? 1 : 0,
                       g_fMoveLastAppliedSpeed[client],
                       GetConVarInt(FindConVar("cs2movement_speed_enforce")),
                       GetConVarInt(FindConVar("cs2movement_write_props")));
        ReplyToCommand(client, "[CS2Movement]   jumps=%d landings=%d", g_iMoveJumps[client], g_iMoveLandings[client]);
        ReplyToCommand(client, "[CS2Movement]   stage3 jump_enforce=%d bhop=%d autobhop=%d landing_enforce=%d blocked=%d window=%d caps=%d landw=%d jumpw=%d",
                       GetConVarInt(FindConVar("cs2movement_jump_enforce")),
                       GetConVarInt(FindConVar("cs2movement_bhop_enable")),
                       GetConVarInt(FindConVar("cs2movement_autobhop")),
                       GetConVarInt(FindConVar("cs2movement_landing_enforce")),
                       g_iJumpBlocked[client], g_iBhopWindowHits[client], g_iBhopCaps[client],
                       g_iLandingWrites[client], g_iJumpImpulseWrites[client]);
    }
}
