/**
 * cs2movement_water.sp -- water-depth (wading) slowdown for survivors.
 *
 * Why this file exists
 *   The per-player speed layer (0.4.1+) rewrites m_flMaxspeed for every
 *   survivor every tick, using the CS2 weapon table.  That table has no water
 *   term, and L4D2 ships none either, so a survivor walking chest-deep through
 *   the c5m1 waterfront river moves at the same 215/225/240 u/s as on dry
 *   pavement.  This layer adds the missing term as a multiplier applied
 *   *after* the injury cap, so the two never overwrite each other.
 *
 * How depth is read
 *   `m_nWaterLevel` on the player entity -- the engine's own depth probe:
 *       0 = not in water
 *       1 = feet / ankles
 *       2 = waist (chest deep on a standing survivor)
 *       3 = eyes  (swimming)
 *   It is probed once per client (Prop_Send first, then Prop_Data) and cached,
 *   because HasEntProp() is a prop-tree walk while GetEntProp() is a cached
 *   offset lookup.  A client without the prop gets factor 1.0 forever and one
 *   WATER-NOPROP log line, never a per-tick log flood.
 *
 * The curve
 *   factor(level) = 1 - slowdown * level / 3      (clamped to [0.05, 1.0])
 *
 *   With the shipped slowdown 0.35:
 *       level 0 -> 1.000   level 1 -> 0.883
 *       level 2 -> 0.767   level 3 -> 0.650
 *
 *   Ankle-deep water therefore costs 12%, waist-deep 23%, eye-deep 35% -- one
 *   cvar expresses "how much water slows you" on any map, instead of three
 *   hand-tuned tiers.  `slowdown 0` neutralises the layer without touching
 *   `enable`, which is the switch the menu row flips.
 *
 * Where it is applied
 *   CS2M_MoveEngineTarget()    -- the SetupMove write, crouch derivation and
 *                                 crouch-slide ceiling all read this value;
 *   CS2M_MoveDesiredMaxSpeed() -- the Stage 2 property write and the status
 *                                 readout, kept in step with the engine path.
 *   Both call sites put it after CS2M_InjuryApply(), so a limping survivor in
 *   water is 60% (injury) x 0.767 (waist) of the weapon speed.  Neither layer
 *   can ever raise a speed: the factor is <= 1.0 and the injury cap is <= 1.0.
 *
 * Survivor-only by construction
 *   CS2M_WaterApply() re-checks CS2M_IsSurvivor() and IsPlayerAlive() even
 *   though every caller is already inside a survivor-only path.  0.4.7's
 *   lesson (a new layer that forgot the team gate let infected drift) is the
 *   reason the gate is repeated here instead of trusted.
 *
 * Known boundaries (deliberate, see docs/08)
 *   * cs2movement_weapon_speed_mode 0 -> both target functions return -1.0
 *     before this layer runs, i.e. water does nothing in native-speed mode.
 *     That mode means "the engine owns speed", so we do not take it over.
 *   * Server-side only.  The client predicts the vanilla water speed (it has no
 *     idea we wrote a lower m_flMaxspeed), so a wading player gets the same
 *     class of bounded positional correction as the duck-speed layer.  No
 *     velocity write, no client plugin, no extra prediction surface.
 *   * level 3 (swimming): L4D2 may drive swim movement through its own path
 *     rather than m_flMaxspeed.  The factor is applied anyway; whether it
 *     bites is a runtime question (recorded in tests/results/water-runtime.md)
 *     and the answer is documented instead of assumed.
 */

#if defined _cs2movement_water_included
 #endinput
#endif
#define _cs2movement_water_included

/* Never slow a survivor below 5% of the weapon speed, even with slowdown 1.0
 * (the ConVar max is 0.8, so this is belt-and-braces against a hand-edited
 * config, not a reachable shipped value). */
#define CS2M_WATER_MIN_FACTOR 0.05
#define CS2M_WATER_MAX_LEVEL  3

ConVar g_cvWaterEnable = null;
ConVar g_cvWaterSlowdown = null;

/* Telemetry: "the switch is on but nothing happens" must be diagnosable from
 * sm_cs2movement_status without a debug build. */
int   g_iWaterCaps = 0;              /* Apply() calls that lowered a target   */
int   g_iWaterLastClient = 0;
int   g_iWaterLastLevel = 0;
float g_fWaterLastBase = 0.0;
float g_fWaterLastApplied = 0.0;
float g_fWaterLastFactor = 1.0;
bool  g_bWaterInWater[MAXPLAYERS + 1];

/* Per-client prop probe cache (see "How depth is read" above). */
bool g_bWaterPropKnown[MAXPLAYERS + 1];
bool g_bWaterPropSend[MAXPLAYERS + 1];
bool g_bWaterPropData[MAXPLAYERS + 1];
bool g_bWaterNoPropLogged[MAXPLAYERS + 1];

stock void CS2M_WaterSetup()
{
    g_cvWaterEnable = CreateConVar("cs2movement_water_enable", "1",
        "Slow survivors down in water by depth (m_nWaterLevel 1/2/3 = ankle/waist/eyes). Survivors only: infected, specials and tanks are untouched, and the layer is applied after the injury cap so the two multiply instead of overwriting each other. 0 = water does not change speed.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvWaterSlowdown = CreateConVar("cs2movement_water_slowdown", "0.35",
        "How much eye-deep water costs, as a fraction of the weapon speed: factor = 1 - slowdown * level/3. 0.35 (shipped) = ankle 0.883 / waist 0.767 / eyes 0.650, i.e. AK 215 becomes 190 / 165 / 140 u/s. 0.0 = no effect even with enable 1. Requires cs2movement_water_enable 1 and weapon_speed_mode 1.",
        FCVAR_NOTIFY, true, 0.0, true, 0.8);

    /* Own command: the runtime answer to "is the prop there and what does the
     * curve look like" without needing a client in the water yet. */
    RegAdminCmd("sm_cs2movement_water", CS2M_Cmd_Water, ADMFLAG_ROOT,
                "Print the water layer: config, per-level factors and the caller's m_nWaterLevel.");
}

stock bool CS2M_WaterEnabled()
{
    if (g_cvWaterEnable == null)
        return false;
    if (!GetConVarBool(g_cvWaterEnable))
        return false;
    ConVar cvMaster = FindConVar("cs2movement_enable");
    return (cvMaster == null) ? true : GetConVarBool(cvMaster);
}

/**
 * Depth -> speed multiplier.  Pure function of the cvar and the level, so the
 * status command, the selftest and the hot path all agree by construction.
 */
stock float CS2M_WaterFactorForLevel(int level)
{
    if (level <= 0)
        return 1.0;
    if (level > CS2M_WATER_MAX_LEVEL)
        level = CS2M_WATER_MAX_LEVEL;

    float slowdown = (g_cvWaterSlowdown != null) ? GetConVarFloat(g_cvWaterSlowdown) : 0.0;
    if (slowdown <= 0.0)
        return 1.0;

    float factor = 1.0 - slowdown * (float(level) / float(CS2M_WATER_MAX_LEVEL));
    if (factor < CS2M_WATER_MIN_FACTOR)
        factor = CS2M_WATER_MIN_FACTOR;
    if (factor > 1.0)
        factor = 1.0;
    return factor;
}

stock void CS2M_WaterProbeProps(int client)
{
    g_bWaterPropKnown[client] = true;
    g_bWaterPropSend[client] = HasEntProp(client, Prop_Send, "m_nWaterLevel");
    g_bWaterPropData[client] = HasEntProp(client, Prop_Data, "m_nWaterLevel");
    g_bWaterNoPropLogged[client] = false;
}

/**
 * Raw engine depth (0-3).  Returns 0 when the prop is missing, which makes the
 * layer a no-op instead of guessing from a trace: a wrong trace would slow
 * players on dry ground, and that is worse than doing nothing.
 */
stock int CS2M_WaterLevel(int client)
{
    if (!g_bWaterPropKnown[client])
        CS2M_WaterProbeProps(client);

    if (g_bWaterPropSend[client])
        return GetEntProp(client, Prop_Send, "m_nWaterLevel");
    if (g_bWaterPropData[client])
        return GetEntProp(client, Prop_Data, "m_nWaterLevel");

    if (!g_bWaterNoPropLogged[client])
    {
        g_bWaterNoPropLogged[client] = true;
        PrintToServer("[CS2Movement] WATER-NOPROP client=%d m_nWaterLevel missing on Prop_Send and Prop_Data; water slowdown inactive for this client", client);
    }
    return 0;
}

/**
 * Apply the water penalty to a CS2 target speed.
 *
 * Returns the input unchanged when: the layer is off, the master switch is off,
 * the player is not a living survivor, the player is dry, or the configured
 * slowdown is 0.  Never raises the speed (factor <= 1.0).
 */
stock float CS2M_WaterApply(int client, float speed)
{
    if (speed <= 0.0)
        return speed;
    if (!CS2M_WaterEnabled())
        return speed;
    if (client < 1 || client > MaxClients)
        return speed;
    /* Repeated on purpose: see "Survivor-only by construction". */
    if (!CS2M_IsSurvivor(client) || !IsPlayerAlive(client))
        return speed;

    int level = CS2M_WaterLevel(client);
    if (level <= 0)
    {
        g_bWaterInWater[client] = false;
        return speed;
    }

    float factor = CS2M_WaterFactorForLevel(level);
    if (factor >= 1.0)
    {
        g_bWaterInWater[client] = false;
        return speed;
    }

    float adjusted = speed * factor;
    if (adjusted >= speed || adjusted <= 0.0)
    {
        g_bWaterInWater[client] = false;
        return speed;
    }

    g_iWaterCaps++;
    g_iWaterLastClient = client;
    g_iWaterLastLevel = level;
    g_fWaterLastBase = speed;
    g_fWaterLastApplied = adjusted;
    g_fWaterLastFactor = factor;

    bool was = g_bWaterInWater[client];
    g_bWaterInWater[client] = true;

    if (!was && GetConVarBool(FindConVar("cs2movement_debug")))
        PrintToServer("[CS2Movement] WATER client=%d level=%d factor=%.3f target=%.1f -> %.1f",
                      client, level, factor, speed, adjusted);

    return adjusted;
}

stock void CS2M_WaterResetClient(int client)
{
    if (client < 1 || client > MaxClients)
        return;
    g_bWaterInWater[client] = false;
    g_bWaterPropKnown[client] = false;
    g_bWaterPropSend[client] = false;
    g_bWaterPropData[client] = false;
    g_bWaterNoPropLogged[client] = false;
}

/**
 * Human-readable probe.  Printed by sm_cs2movement_water and by the unified
 * status page, so an admin can tell "switch on, curve sane, prop present, this
 * client is level 0" apart from "nothing works".
 */
stock void CS2M_WaterStatus(int client)
{
    ReplyToCommand(client,
        "[CS2Movement]   water=%d slowdown=%.3f enabled=%d caps=%d last_client=%d last_level=%d base=%.1f applied=%.1f factor=%.3f",
        (g_cvWaterEnable != null) ? GetConVarInt(g_cvWaterEnable) : -1,
        (g_cvWaterSlowdown != null) ? GetConVarFloat(g_cvWaterSlowdown) : -1.0,
        CS2M_WaterEnabled() ? 1 : 0,
        g_iWaterCaps, g_iWaterLastClient, g_iWaterLastLevel,
        g_fWaterLastBase, g_fWaterLastApplied, g_fWaterLastFactor);

    ReplyToCommand(client,
        "[CS2Movement]   water factors: dry=1.000 ankle=%.3f waist=%.3f eyes=%.3f (AK 215 -> %.0f / %.0f / %.0f)",
        CS2M_WaterFactorForLevel(1),
        CS2M_WaterFactorForLevel(2),
        CS2M_WaterFactorForLevel(3),
        215.0 * CS2M_WaterFactorForLevel(1),
        215.0 * CS2M_WaterFactorForLevel(2),
        215.0 * CS2M_WaterFactorForLevel(3));

    /* Console caller: report every connected client instead of nothing.  This
     * is the only way to see the depth prop without a client command, and it is
     * what the runtime evidence in tests/results uses (bots included). */
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        int shown = 0;
        for (int i = 1; i <= MaxClients && shown < 8; i++)
        {
            if (!IsClientInGame(i))
                continue;
            char name[64];
            GetClientName(i, name, sizeof(name));
            ReplyToCommand(client,
                "[CS2Movement]   water client=%d %s%s level=%d prop=send:%d/data:%d in_water=%d",
                i, name, IsFakeClient(i) ? " (bot)" : "",
                CS2M_WaterLevel(i),
                g_bWaterPropSend[i] ? 1 : 0,
                g_bWaterPropData[i] ? 1 : 0,
                g_bWaterInWater[i] ? 1 : 0);
            shown++;
        }
        if (shown == 0)
            ReplyToCommand(client, "[CS2Movement]   water: no clients connected");
        return;
    }

    int level = CS2M_WaterLevel(client);
    ReplyToCommand(client,
        "[CS2Movement]   water client=%d level=%d prop=send:%d/data:%d in_water=%d",
        client, level,
        g_bWaterPropSend[client] ? 1 : 0,
        g_bWaterPropData[client] ? 1 : 0,
        g_bWaterInWater[client] ? 1 : 0);
}

public Action CS2M_Cmd_Water(int client, int args)
{
    /* sm_cs2movement_water [level] -- with an argument, print the factor that
     * level would get; without one, print the live state for the caller. */
    if (args >= 1)
    {
        char arg[8];
        GetCmdArg(1, arg, sizeof(arg));
        int level = StringToInt(arg);
        ReplyToCommand(client,
            "[CS2Movement] water level=%d factor=%.4f (slowdown=%.2f)",
            level, CS2M_WaterFactorForLevel(level),
            (g_cvWaterSlowdown != null) ? GetConVarFloat(g_cvWaterSlowdown) : -1.0);
    }

    CS2M_WaterStatus(client);
    return Plugin_Handled;
}
