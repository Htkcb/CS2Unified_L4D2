/**
 * cs2movement_injury.sp -- L4D2 low-health limp slowdown for CS2Movement_L4D2.
 *
 * Why this file exists
 *   L4D2 slows a survivor down once their health drops below
 *   `survivor_limp_health` (40).  The engine implements that as a *lower
 *   m_flMaxspeed*: cs2movement writes m_flMaxspeed every tick for every
 *   survivor (the engine per-player speed layer, 0.4.1+), so the engine's limp
 *   value is overwritten with the CS2 weapon speed and the survivor runs at
 *   full speed on 20 HP.  This layer re-applies the penalty on top of the CS2
 *   target, i.e. it *restores* vanilla behaviour that the speed layer erased.
 *
 * What L4D2 actually does (measured on this machine, 2026-10-31)
 *   `find survivor_limp` on a stock 64 tick dedicated server:
 *       "survivor_limp_health"     = "40"   game cheat replicated
 *       "survivor_limp_walk_speed" = "85"   game cheat replicated
 *       "survivor_speed"           = "210"  (server default, not 220)
 *   and docs/09 already recorded `85` (`0x10628624`) as one of the values
 *   returned by CTerrorPlayer's max-speed function (0x102C9940): the limp cap.
 *   Corroboration from the reference plugin `l4d2_slowdown_control` (Visor et
 *   al.), which computes limp as
 *       health = GetClientHealth() + temp health
 *       RoundToFloor(health) < survivor_limp_health
 *   while exempting `m_bAdrenalineActive` (vanilla: 260 u/s at any health).
 *
 *   NOTE: the community wiki claims 220 -> 150 for L4D2 limping.  The cvar
 *   default on this build is 85 and 85 is the constant baked into the speed
 *   function, so this plugin follows the *engine cvar* rather than a wiki
 *   constant; `cs2movement_injury_speed` exists to override it either way.
 *
 * Two modes
 *   1 (default) ratio       : target = CS2 target * (limp / healthy)
 *     This *is* the vanilla penalty expressed as a proportion.  Measured on the
 *     64 tick rig with the plugin out of the way (2026-11-01, four survivor
 *     bots): m_flMaxspeed is 220.00 at 40 HP and 85.00 at 39 HP, i.e. vanilla
 *     keeps 85/220 = 38.6% of normal speed.  Applying that ratio per weapon
 *     keeps the CS2 weapon spread instead of flattening everyone onto one
 *     number: AK 215 -> 83, M4 225 -> 87, SMG 240 -> 93, AWP 200 -> 77.
 *     A weapon whose CS2 speed is 220 would land on exactly 85.
 *     Cost: client.dll predicts the vanilla 85 for the local player while the
 *     server writes the scaled value, so limping players get a bounded
 *     per-tick positional correction (same class as the duck-speed layer).
 *   0 vanilla cap           : target = min(CS2 target, survivor_limp_walk_speed)
 *     Every limping weapon moves at the same absolute 85 u/s, which is exactly
 *     what the engine's own m_flMaxspeed would be -- so this mode has zero
 *     extra prediction error.  Use it when clients must never disagree with
 *     the server (competitive servers, weak connections).
 *
 * Both modes trigger on the same vanilla threshold: total health (permanent +
 * temporary) below survivor_limp_health, 40 on a stock server -- measured: the
 * engine itself is at 220.00 for 40 HP and 85.00 for 39 HP.
 *
 * Shipped default is NOT vanilla (0.5.1): playtest feedback on 0.5.0 was that
 * vanilla's 85 (38.6% of 220) reads as "cannot move" once the penalty is
 * applied per weapon, so `cs2movement_injury_speed` now defaults to 132, i.e.
 * 60% of the healthy 220 -- AK 215 -> 129, M4 225 -> 135, SMG 240 -> 144,
 * AWP 200 -> 120, melee 250 -> 150.  That is a deliberate deviation from
 * vanilla and it is a single cvar: 85 restores exact vanilla, 0 follows
 * survivor_limp_walk_speed, anything in between is a straight scale.
 *
 * Never speeds a player up: both modes only ever return a value <= the input,
 * and the ratio mode is skipped unless 0 < limp/healthy < 1.
 *
 * Crouch: untouched by design.  L4D2's crouch speed (75) is independent of
 * health, and the crouch layer derives its target from CS2M_MoveEngineTarget(),
 * which this file caps -- so a limping player's crouch target is floored at
 * cs2movement_duck_speed_min and then clamped by the (now lower) run target,
 * exactly like the engine clamps crouch against m_flMaxspeed.
 */

#if defined _cs2movement_injury_included
 #endinput
#endif
#define _cs2movement_injury_included

ConVar g_cvInjuryEnable = null;
ConVar g_cvInjuryMode = null;
ConVar g_cvInjuryHealth = null;
ConVar g_cvInjurySpeed = null;
ConVar g_cvInjuryBase = null;
ConVar g_cvInjuryTempHealth = null;
ConVar g_cvInjuryAdrenaline = null;

/* Engine-measured healthy maxspeed (see CS2M_InjuryBaseSpeed). */
#define CS2M_INJURY_BASE_FALLBACK 220.0

/* Engine cvars that define the vanilla behaviour.  Kept as handles (not
 * values) so a server that changes them with sm_cvar is followed live. */
ConVar g_cvEngineLimpHealth = null;
ConVar g_cvEngineLimpSpeed = null;
ConVar g_cvEngineSurvivorSpeed = null;
ConVar g_cvEnginePillsDecay = null;

/* Telemetry: a silent "the penalty does nothing" must be diagnosable. */
int   g_iInjuryCaps = 0;             /* Apply() calls that lowered a target */
int   g_iInjuryAdrenalineSkips = 0;  /* limp checks skipped for adrenaline */
int   g_iInjuryLastClient = 0;
float g_fInjuryLastHealth = 0.0;
float g_fInjuryLastBase = 0.0;
float g_fInjuryLastApplied = 0.0;
float g_fInjuryLastLimp = 0.0;
float g_fInjuryLastMode = 0.0;
bool  g_bInjuryLimping[MAXPLAYERS + 1];

/* Per-client prop probe cache: HasEntProp() twice per player per tick is the
 * kind of cost that only shows up on a full 30-slot server. */
bool  g_bInjuryPropsKnown[MAXPLAYERS + 1];
bool  g_bInjuryHasBuffer[MAXPLAYERS + 1];
bool  g_bInjuryHasBufferTime[MAXPLAYERS + 1];
bool  g_bInjuryHasAdrenaline[MAXPLAYERS + 1];

stock void CS2M_InjurySetup()
{
    g_cvInjuryEnable = CreateConVar("cs2movement_injury_enable", "1",
        "Re-apply L4D2's low-health limp slowdown on the per-player speed layer. The engine lowers m_flMaxspeed while injured, but cs2movement overwrites that field every tick, so without this a 20 HP survivor runs at the full CS2 weapon speed. 0 = CS2 speed at any health.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvInjuryMode = CreateConVar("cs2movement_injury_mode", "1",
        "1 = ratio (default): CS2 target x cs2movement_injury_speed/cs2movement_injury_base, applied per weapon so the CS2 weapon spread survives (default 132/220 = 60%: AK 215 -> 129, SMG 240 -> 144; vanilla is 85/220 = 38.6%). 0 = absolute cap: every limping weapon is capped at cs2movement_injury_speed itself (132 by default), which is what predicts perfectly on the client when the client and server agree on that number.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvInjuryHealth = CreateConVar("cs2movement_injury_health", "0.0",
        "Limp threshold override. 0 = follow L4D2's survivor_limp_health (40 on a stock server): the penalty starts once total health drops below it. Use this on servers where sv_cheats is off, because the engine cvar is cheat-protected.",
        FCVAR_NOTIFY, true, 0.0, true, 100.0);
    g_cvInjurySpeed = CreateConVar("cs2movement_injury_speed", "132.0",
        "Limp speed (u/s, mode 1 uses it as the ratio numerator over cs2movement_injury_base). 132 = shipped default, 60% of the healthy 220 (AK 215 -> 129, SMG 240 -> 144): vanilla's 85 (38.6%) reads as 'cannot move' once it is applied per weapon. 85 = exact vanilla, 0 = follow the engine's survivor_limp_walk_speed (85).",
        FCVAR_NOTIFY, true, 0.0, true, 500.0);
    g_cvInjuryBase = CreateConVar("cs2movement_injury_base", "220.0",
        "Healthy reference speed for the ratio denominator (mode 1). 220 = what the engine actually reports as m_flMaxspeed for a healthy survivor (measured 2026-11-01, four clients); the engine hard-codes 220 while survivor_speed is 210, so 220 is what makes the ratio match vanilla (85/220 = 38.6%, not 85/210 = 40.5%). 0 = follow survivor_speed instead.",
        FCVAR_NOTIFY, true, 0.0, true, 500.0);
    g_cvInjuryTempHealth = CreateConVar("cs2movement_injury_temp_health", "1",
        "Count temporary health (m_healthBuffer, i.e. pills / revive / adrenaline buffer) toward the limp threshold, like vanilla. 0 = permanent health only.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvInjuryAdrenaline = CreateConVar("cs2movement_injury_adrenaline", "1",
        "Exempt survivors under adrenaline from the limp cap. Vanilla lets adrenaline run at 260 u/s at any health; the plugin's own weapon cap still applies.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    CS2M_InjuryCacheEngineCvars();
}

stock void CS2M_InjuryCacheEngineCvars()
{
    if (g_cvEngineLimpHealth == null)  g_cvEngineLimpHealth = FindConVar("survivor_limp_health");
    if (g_cvEngineLimpSpeed == null)   g_cvEngineLimpSpeed = FindConVar("survivor_limp_walk_speed");
    if (g_cvEngineSurvivorSpeed == null) g_cvEngineSurvivorSpeed = FindConVar("survivor_speed");
    if (g_cvEnginePillsDecay == null)  g_cvEnginePillsDecay = FindConVar("pain_pills_decay_rate");
}

stock bool CS2M_InjuryEnabled()
{
    if (g_cvInjuryEnable == null)
        return false;
    if (!GetConVarBool(g_cvInjuryEnable))
        return false;
    ConVar cvMaster = FindConVar("cs2movement_enable");
    return (cvMaster == null) ? true : GetConVarBool(cvMaster);
}

/** Limp threshold in health points. */
stock float CS2M_InjuryThreshold()
{
    if (g_cvInjuryHealth != null)
    {
        float override = GetConVarFloat(g_cvInjuryHealth);
        if (override > 0.0)
            return override;
    }
    if (g_cvEngineLimpHealth == null)
        CS2M_InjuryCacheEngineCvars();
    if (g_cvEngineLimpHealth != null)
        return GetConVarFloat(g_cvEngineLimpHealth);
    return 40.0;
}

/** Vanilla limping top speed (u/s). */
stock float CS2M_InjuryLimpSpeed()
{
    if (g_cvInjurySpeed != null)
    {
        float override = GetConVarFloat(g_cvInjurySpeed);
        if (override > 0.0)
            return override;
    }
    if (g_cvEngineLimpSpeed == null)
        CS2M_InjuryCacheEngineCvars();
    if (g_cvEngineLimpSpeed != null)
        return GetConVarFloat(g_cvEngineLimpSpeed);
    return 85.0;
}

/**
 * Vanilla healthy top speed, used as the ratio denominator (mode 1).
 *
 * Measured 2026-11-01 on the 64 tick rig with the plugin out of the way
 * (`cs2movement_engine_speed 0`), four survivor bots, weapon_first_aid_kit:
 * m_flMaxspeed is 220.00 at 40 HP and 85.00 at 39 HP.  `survivor_speed` is
 * 210 on the same server, so the engine's healthy number is a hard-coded 220
 * inside GetPlayerMaxSpeed (0x102C9940 returns `220 x healthratio` as one of
 * its branches, docs/09), not the cvar.  Using the cvar as the denominator
 * would understate the vanilla penalty by 5% (85/210 = 0.405 instead of
 * 85/220 = 0.386).  Hence: 0 = follow survivor_speed, default 220.
 */
stock float CS2M_InjuryBaseSpeed()
{
    if (g_cvInjuryBase != null)
    {
        float override = GetConVarFloat(g_cvInjuryBase);
        if (override > 0.0)
            return override;
    }
    if (g_cvEngineSurvivorSpeed == null)
        CS2M_InjuryCacheEngineCvars();
    if (g_cvEngineSurvivorSpeed != null)
        return GetConVarFloat(g_cvEngineSurvivorSpeed);
    return CS2M_INJURY_BASE_FALLBACK;
}

stock void CS2M_InjuryProbeProps(int client)
{
    g_bInjuryPropsKnown[client] = true;
    g_bInjuryHasBuffer[client] = HasEntProp(client, Prop_Send, "m_healthBuffer");
    g_bInjuryHasBufferTime[client] = HasEntProp(client, Prop_Send, "m_healthBufferTime");
    g_bInjuryHasAdrenaline[client] = HasEntProp(client, Prop_Send, "m_bAdrenalineActive");
}

/**
 * Temporary health, decay adjusted.
 *
 * m_healthBuffer is the buffer at m_healthBufferTime; the engine drains it at
 * pain_pills_decay_rate per second (this build: 0.27).  Same arithmetic as
 * left4dhooks' L4D_GetTempHealth, minus the -1: here the value only has to
 * decide "above or below 40", and the reference plugin l4d2_slowdown_control
 * compares RoundToFloor(health) against survivor_limp_health the same way.
 */
stock float CS2M_InjuryTempHealth(int client)
{
    if (!g_bInjuryPropsKnown[client])
        CS2M_InjuryProbeProps(client);
    if (!g_bInjuryHasBuffer[client])
        return 0.0;

    float buffer = GetEntPropFloat(client, Prop_Send, "m_healthBuffer");
    if (buffer <= 0.0)
        return 0.0;

    if (g_cvEnginePillsDecay == null)
        CS2M_InjuryCacheEngineCvars();
    float decay = (g_cvEnginePillsDecay != null) ? GetConVarFloat(g_cvEnginePillsDecay) : 0.27;

    float elapsed = 0.0;
    if (g_bInjuryHasBufferTime[client])
    {
        elapsed = GetGameTime() - GetEntPropFloat(client, Prop_Send, "m_healthBufferTime");
        if (elapsed < 0.0)
            elapsed = 0.0;
    }

    float temp = buffer - elapsed * decay;
    return (temp > 0.0) ? temp : 0.0;
}

/** Effective health: permanent + (optionally) temporary. */
stock float CS2M_InjuryHealth(int client, float &permanent, float &temporary)
{
    permanent = float(GetClientHealth(client));
    temporary = 0.0;
    if (g_cvInjuryTempHealth == null || GetConVarBool(g_cvInjuryTempHealth))
        temporary = CS2M_InjuryTempHealth(client);
    return permanent + temporary;
}

stock bool CS2M_InjuryIsAdrenaline(int client)
{
    if (!g_bInjuryPropsKnown[client])
        CS2M_InjuryProbeProps(client);
    if (!g_bInjuryHasAdrenaline[client])
        return false;
    return GetEntProp(client, Prop_Send, "m_bAdrenalineActive") != 0;
}

/**
 * Is this survivor limping?  Fills health / limpSpeed / baseSpeed so callers
 * (and the status command) do not have to recompute them.
 *
 * Survivor-only and alive-only: the speed layer this feeds is already gated by
 * CS2M_IsSurvivor(), but 0.4.7's lesson was that a new layer forgetting the
 * gate is the bug, so the gate is repeated here instead of trusted.
 */
stock bool CS2M_InjuryLimping(int client, float &health, float &limpSpeed, float &baseSpeed)
{
    health = 0.0;
    limpSpeed = 0.0;
    baseSpeed = 0.0;

    if (client < 1 || client > MaxClients)
        return false;
    if (!CS2M_IsSurvivor(client))
        return false;
    if (!IsPlayerAlive(client))
        return false;

    if ((g_cvInjuryAdrenaline == null || GetConVarBool(g_cvInjuryAdrenaline)) &&
        CS2M_InjuryIsAdrenaline(client))
    {
        g_iInjuryAdrenalineSkips++;
        return false;
    }

    float permanent;
    float temporary;
    health = CS2M_InjuryHealth(client, permanent, temporary);

    if (float(RoundToFloor(health)) >= CS2M_InjuryThreshold())
        return false;

    limpSpeed = CS2M_InjuryLimpSpeed();
    baseSpeed = CS2M_InjuryBaseSpeed();
    return (limpSpeed > 0.0);
}

/**
 * Apply the limp penalty to a CS2 target speed.
 *
 * Returns the input unchanged when the player is healthy, when the layer is
 * disabled, or when the computed penalty would *raise* the speed (a
 * misconfigured injury_speed must never become a speed boost).
 */
stock float CS2M_InjuryApply(int client, float speed)
{
    if (speed <= 0.0)
        return speed;
    if (!CS2M_InjuryEnabled())
        return speed;

    float health;
    float limpSpeed;
    float baseSpeed;
    if (!CS2M_InjuryLimping(client, health, limpSpeed, baseSpeed))
    {
        g_bInjuryLimping[client] = false;
        return speed;
    }

    float adjusted = speed;
    if (g_cvInjuryMode != null && GetConVarInt(g_cvInjuryMode) == 1)
    {
        /* Proportion: limp_speed / healthy_speed.  Default 132/220 = 0.60 (the
         * shipped value, see the header); vanilla is 85/220 = 0.3864.  Only a
         * ratio strictly between 0 and 1 is a slowdown; anything else means the
         * two cvars were configured in a way that cannot be a penalty, and the
         * target is left untouched. */
        float ratio = (baseSpeed > 0.0) ? (limpSpeed / baseSpeed) : 0.0;
        if (ratio > 0.0 && ratio < 1.0)
            adjusted = speed * ratio;
    }
    else if (speed > limpSpeed)
    {
        adjusted = limpSpeed;
    }

    if (adjusted >= speed || adjusted <= 0.0)
        return speed;

    g_iInjuryCaps++;
    g_iInjuryLastClient = client;
    g_fInjuryLastHealth = health;
    g_fInjuryLastBase = speed;
    g_fInjuryLastApplied = adjusted;
    g_fInjuryLastLimp = limpSpeed;
    g_fInjuryLastMode = float(GetConVarInt(g_cvInjuryMode));

    bool wasLimping = g_bInjuryLimping[client];
    g_bInjuryLimping[client] = true;

    if (!wasLimping && GetConVarBool(FindConVar("cs2movement_debug")))
        PrintToServer("[CS2Movement] INJURY client=%d health=%.1f limp=%.1f mode=%d target=%.1f -> %.1f",
                      client, health, limpSpeed, GetConVarInt(g_cvInjuryMode), speed, adjusted);

    return adjusted;
}

stock void CS2M_InjuryResetClient(int client)
{
    if (client < 1 || client > MaxClients)
        return;
    g_bInjuryLimping[client] = false;
    g_bInjuryPropsKnown[client] = false;
    g_bInjuryHasBuffer[client] = false;
    g_bInjuryHasBufferTime[client] = false;
    g_bInjuryHasAdrenaline[client] = false;
}

stock void CS2M_InjuryStatus(int client)
{
    ReplyToCommand(client,
        "[CS2Movement]   injury=%d mode=%d threshold=%.1f limp_speed=%.1f base_speed=%.1f temp_hp=%d adren_exempt=%d caps=%d adren_skips=%d",
        (g_cvInjuryEnable != null) ? GetConVarInt(g_cvInjuryEnable) : -1,
        (g_cvInjuryMode != null) ? GetConVarInt(g_cvInjuryMode) : -1,
        CS2M_InjuryThreshold(),
        CS2M_InjuryLimpSpeed(),
        CS2M_InjuryBaseSpeed(),
        (g_cvInjuryTempHealth != null) ? GetConVarInt(g_cvInjuryTempHealth) : -1,
        (g_cvInjuryAdrenaline != null) ? GetConVarInt(g_cvInjuryAdrenaline) : -1,
        g_iInjuryCaps, g_iInjuryAdrenalineSkips);

    ReplyToCommand(client,
        "[CS2Movement]   injury engine cvars: limp_health=%s limp_walk_speed=%s survivor_speed=%s pills_decay=%s",
        (g_cvEngineLimpHealth != null) ? "found" : "missing",
        (g_cvEngineLimpSpeed != null) ? "found" : "missing",
        (g_cvEngineSurvivorSpeed != null) ? "found" : "missing",
        (g_cvEnginePillsDecay != null) ? "found" : "missing");

    if (client <= 0 || !IsClientInGame(client) || !CS2M_IsSurvivor(client))
        return;

    float permanent;
    float temporary;
    float health = CS2M_InjuryHealth(client, permanent, temporary);
    float limpSpeed;
    float baseSpeed;
    bool limping = CS2M_InjuryLimping(client, health, limpSpeed, baseSpeed);
    ReplyToCommand(client,
        "[CS2Movement]   injury client=%d health=%.1f perm=%.0f temp=%.1f limping=%d adrenaline=%d",
        client, health, permanent, temporary, limping ? 1 : 0,
        CS2M_InjuryIsAdrenaline(client) ? 1 : 0);

    if (g_iInjuryLastClient > 0)
        ReplyToCommand(client,
            "[CS2Movement]   injury last client=%d health=%.1f base=%.1f limp=%.1f applied=%.1f mode=%.0f",
            g_iInjuryLastClient, g_fInjuryLastHealth, g_fInjuryLastBase,
            g_fInjuryLastLimp, g_fInjuryLastApplied, g_fInjuryLastMode);
}
