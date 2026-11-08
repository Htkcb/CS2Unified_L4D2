/**
 * cs2movement_config.sp -- configuration validation for CS2Movement_L4D2.
 *
 * Stage 1: every ConVar is range-checked and clamped.  The include deliberately
 * looks ConVars up by name so it stays independent from the orchestrator's
 * handle globals; this makes it safe to compile before the core include.
 */

#if defined _cs2movement_config_included
 #endinput
#endif
#define _cs2movement_config_included

stock void CS2M_ConfigValidateFloat(const char[] name, float minValue, float maxValue)
{
    ConVar cv = FindConVar(name);
    if (cv == null)
    {
        PrintToServer("[CS2Movement] CONFIG-MISSING %s", name);
        return;
    }

    float value = GetConVarFloat(cv);
    if (value < minValue)
    {
        SetConVarFloat(cv, minValue);
        PrintToServer("[CS2Movement] CONFIG-CLAMP %s %.6f -> %.6f (min)", name, value, minValue);
    }
    else if (value > maxValue)
    {
        SetConVarFloat(cv, maxValue);
        PrintToServer("[CS2Movement] CONFIG-CLAMP %s %.6f -> %.6f (max)", name, value, maxValue);
    }
}

stock void CS2M_ConfigValidateInt(const char[] name, int minValue, int maxValue)
{
    ConVar cv = FindConVar(name);
    if (cv == null)
    {
        PrintToServer("[CS2Movement] CONFIG-MISSING %s", name);
        return;
    }

    int value = GetConVarInt(cv);
    if (value < minValue)
    {
        SetConVarInt(cv, minValue);
        PrintToServer("[CS2Movement] CONFIG-CLAMP %s %d -> %d (min)", name, value, minValue);
    }
    else if (value > maxValue)
    {
        SetConVarInt(cv, maxValue);
        PrintToServer("[CS2Movement] CONFIG-CLAMP %s %d -> %d (max)", name, value, maxValue);
    }
}

stock void CS2M_ConfigValidateAll()
{
    CS2M_ConfigValidateInt("cs2movement_enable", 0, 1);
    CS2M_ConfigValidateInt("cs2movement_debug", 0, 1);
    CS2M_ConfigValidateInt("cs2movement_mode", 0, 3);
    CS2M_ConfigValidateInt("cs2movement_apply_global", 0, 1);

    CS2M_ConfigValidateFloat("cs2movement_accelerate", 0.1, 20.0);
    CS2M_ConfigValidateFloat("cs2movement_friction", 0.1, 20.0);
    CS2M_ConfigValidateFloat("cs2movement_stopspeed", 0.0, 500.0);
    CS2M_ConfigValidateFloat("cs2movement_airaccelerate", 0.0, 100.0);
    CS2M_ConfigValidateFloat("cs2movement_air_max_wishspeed", 0.0, 200.0);
    CS2M_ConfigValidateFloat("cs2movement_gravity", 100.0, 2000.0);
    CS2M_ConfigValidateFloat("cs2movement_maxspeed", 50.0, 1000.0);
    CS2M_ConfigValidateFloat("cs2movement_maxvelocity", 500.0, 10000.0);
    CS2M_ConfigValidateFloat("cs2movement_jump_impulse", 100.0, 500.0);
    CS2M_ConfigValidateFloat("cs2movement_jump_height", 20.0, 100.0);
    CS2M_ConfigValidateFloat("cs2movement_base_speed", 50.0, 400.0);
    CS2M_ConfigValidateInt("cs2movement_weapon_speed_mode", 0, 1);
    CS2M_ConfigValidateFloat("cs2movement_walk_multiplier", 0.1, 1.0);
    CS2M_ConfigValidateFloat("cs2movement_duck_multiplier", 0.1, 1.0);

    CS2M_ConfigValidateInt("cs2movement_bhop_enable", 0, 1);
    CS2M_ConfigValidateInt("cs2movement_autobhop", 0, 1);
    CS2M_ConfigValidateFloat("cs2movement_bhop_speed_cap", 100.0, 500.0);
    CS2M_ConfigValidateFloat("cs2movement_bhop_window", 0.0, 0.2);
    CS2M_ConfigValidateFloat("cs2movement_jump_spam_penalty", 0.0, 0.2);
    CS2M_ConfigValidateInt("cs2movement_landing_penalty", 0, 1);
    CS2M_ConfigValidateFloat("cs2movement_landing_speed_factor", 0.0, 1.0);
    CS2M_ConfigValidateFloat("cs2movement_landing_next_factor", 0.0, 1.0);
    CS2M_ConfigValidateInt("cs2movement_landing_enforce", 0, 1);
    CS2M_ConfigValidateInt("cs2movement_jump_enforce", 0, 1);

    CS2M_ConfigValidateInt("cs2movement_crouch_enable", 0, 1);
    CS2M_ConfigValidateFloat("cs2movement_duck_rate", 1.0, 20.0);
    CS2M_ConfigValidateFloat("cs2movement_time_between_ducks", 0.0, 2.0);
    CS2M_ConfigValidateFloat("cs2movement_stand_eye", 40.0, 100.0);
    CS2M_ConfigValidateFloat("cs2movement_duck_eye", 20.0, 80.0);
    CS2M_ConfigValidateFloat("cs2movement_stand_hull", 40.0, 100.0);
    CS2M_ConfigValidateFloat("cs2movement_duck_hull", 30.0, 80.0);
    CS2M_ConfigValidateFloat("cs2movement_air_crouch_shift", 0.0, 30.0);
    CS2M_ConfigValidateInt("cs2movement_crouch_jump", 0, 1);
    CS2M_ConfigValidateInt("cs2movement_crouch_view", 0, 1);

    CS2M_ConfigValidateInt("cs2movement_client_sync", 0, 1);
    CS2M_ConfigValidateInt("cs2movement_write_props", 0, 1);
    CS2M_ConfigValidateInt("cs2movement_speed_enforce", 0, 1);
    CS2M_ConfigValidateInt("cs2movement_crouch_enforce", 0, 1);
    CS2M_ConfigValidateInt("cs2movement_write_timing", 0, 1);
    CS2M_ConfigValidateInt("cs2movement_lowspeed_sustain", 0, 1);

    /* 0.4.5 crouch slide.  Registered with the same bounds as the ConVars; a
     * bad hand-edit would otherwise slip through silently (the cvar clamps). */
    CS2M_ConfigValidateInt("cs2movement_crouch_slide", 0, 1);
    CS2M_ConfigValidateInt("cs2movement_crouch_slide_client", 0, 1);
    CS2M_ConfigValidateFloat("cs2movement_crouch_slide_time", 0.02, 2.0);
    CS2M_ConfigValidateFloat("cs2movement_crouch_slide_min_speed", 0.0, 1000.0);

    /* 0.5.0 low-health limp layer.  Health/speed overrides are 0 = follow the
     * engine cvar (survivor_limp_health 40 / survivor_limp_walk_speed 85). */
    CS2M_ConfigValidateInt("cs2movement_injury_enable", 0, 1);
    CS2M_ConfigValidateInt("cs2movement_injury_mode", 0, 1);
    CS2M_ConfigValidateFloat("cs2movement_injury_health", 0.0, 100.0);
    CS2M_ConfigValidateFloat("cs2movement_injury_speed", 0.0, 500.0);
    CS2M_ConfigValidateFloat("cs2movement_injury_base", 0.0, 500.0);
    CS2M_ConfigValidateInt("cs2movement_injury_temp_health", 0, 1);
    CS2M_ConfigValidateInt("cs2movement_injury_adrenaline", 0, 1);
    /* 0.5.3 water-depth slowdown.  Registered with the same bounds as the
     * ConVars; a hand-edited cfg would otherwise be silently clamped.
     * slowdown 0 is a valid value (= no effect), enable 0 is the off
     * switch. */
    CS2M_ConfigValidateInt("cs2movement_water_enable", 0, 1);
    CS2M_ConfigValidateFloat("cs2movement_water_slowdown", 0.0, 0.8);

    PrintToServer("[CS2Movement] CONFIG-VALIDATE done");
}

stock bool CS2M_ConfigFileExists()
{    /* SourceMod runs with the game directory as its working directory; the
       generated config lives at left4dead2/cfg/sourcemod/cs2movement.cfg. */
    return FileExists("cfg/sourcemod/cs2movement.cfg");
}

/* L4D2 teams: 1 = observer, 2 = survivor, 3 = infected.
 *
 * Every movement write in this plugin is a survivor feature, and special
 * infected must behave exactly as L4D2 ships them.  Keeping the test in one
 * predicate is intentional: a new layer that forgets it is the bug we are
 * fixing (0.4.7), so the gate lives here, not at each call site. */
#define CS2M_TEAM_SURVIVOR 2

stock bool CS2M_IsSurvivor(int client)
{
    if (client < 1 || client > MaxClients)
        return false;
    if (!IsClientInGame(client))
        return false;
    return GetClientTeam(client) == CS2M_TEAM_SURVIVOR;
}