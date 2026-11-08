/**
 * cs2u_modes.sp -- built-in presets and atomic application.
 *
 * A preset is a validated list of managed cvar/value pairs. Application is
 * atomic in the sense that matters to an admin:
 *   1. every entry is validated before anything is written;
 *   2. the pre-apply values are snapshotted (sm_cs2u_rollback);
 *   3. if persisting the new state fails, the snapshot is restored and the
 *      preset reports failure instead of leaving an unreproducible state.
 *
 * Note on the VScript data layer: the weapon-script VPK (spread shape) is a
 * load-time asset and CANNOT be hot-swapped by SourceMod. Presets therefore
 * only manage the runtime ConVar surface; the data layer is a deploy-time
 * choice (see docs/04_部署与回滚.md).
 */

#if defined _cs2u_modes_included
 #endinput
#endif
#define _cs2u_modes_included

int CS2U_ModeAdd(const char[] name)
{
    if (g_iPresetCount >= CS2U_MAX_PRESETS)
        return -1;
    int m = g_iPresetCount++;
    strcopy(g_sPresetName[m], CS2U_NAME_LEN, name);
    g_iPresetEntries[m] = 0;
    return m;
}

void CS2U_ModeEntry(int mode, const char[] cvar, const char[] value)
{
    if (mode < 0 || mode >= g_iPresetCount)
        return;
    int e = g_iPresetEntries[mode];
    if (e >= CS2U_MAX_ENTRIES)
        return;
    strcopy(g_sPresetCvar[mode][e], CS2U_CVAR_LEN, cvar);
    strcopy(g_sPresetValue[mode][e], CS2U_VALUE_LEN, value);
    g_iPresetEntries[mode] = e + 1;
}

void CS2U_ModeSetEntry(int mode, const char[] cvar, const char[] value)
{
    if (mode < 0 || mode >= g_iPresetCount)
        return;
    for (int e = 0; e < g_iPresetEntries[mode]; e++)
    {
        if (StrEqual(g_sPresetCvar[mode][e], cvar, false))
        {
            strcopy(g_sPresetValue[mode][e], CS2U_VALUE_LEN, value);
            return;
        }
    }
    CS2U_ModeEntry(mode, cvar, value);
}

bool CS2U_ModeHasEntry(int mode, const char[] cvar)
{
    if (mode < 0 || mode >= g_iPresetCount)
        return false;
    for (int e = 0; e < g_iPresetEntries[mode]; e++)
        if (StrEqual(g_sPresetCvar[mode][e], cvar, false))
            return true;
    return false;
}

int CS2U_ModeClone(const char[] dstName, const char[] srcName)
{
    int src = CS2U_ModeFind(srcName);
    if (src < 0 || g_iPresetCount >= CS2U_MAX_PRESETS)
        return -1;

    int m = CS2U_ModeAdd(dstName);
    if (m < 0)
        return -1;

    int entries = g_iPresetEntries[src];
    if (entries > CS2U_MAX_ENTRIES)
        entries = CS2U_MAX_ENTRIES;
    for (int e = 0; e < entries; e++)
    {
        strcopy(g_sPresetCvar[m][e], CS2U_CVAR_LEN, g_sPresetCvar[src][e]);
        strcopy(g_sPresetValue[m][e], CS2U_VALUE_LEN, g_sPresetValue[src][e]);
    }
    g_iPresetEntries[m] = entries;
    return m;
}

/* Existing deployments ship a config without cs2_tracer; add it in memory so
 * the easy menu always offers the "CS2 recoil + tracer" preset. */
void CS2U_ModesEnsureTracer()
{
    if (CS2U_ModeFind("cs2_tracer") < 0)
    {
        int m = CS2U_ModeClone("cs2_tracer", "cs2_matched");
        if (m >= 0)
            CS2U_ModeSetEntry(m, "cs2u_tracer_enable", "1");
    }

    /* Older configs do not carry cs2u_tracer_enable in every preset. Normalize
     * them so a tracer preset cannot leak the beam into the next preset. */
    for (int i = 0; i < g_iPresetCount; i++)
    {
        if (StrEqual(g_sPresetName[i], "cs2_tracer", false))
            CS2U_ModeSetEntry(i, "cs2u_tracer_enable", "1");
        else
            CS2U_ModeSetEntry(i, "cs2u_tracer_enable", "0");
    }
}

/* Full CS2 simulation: every managed value is written explicitly, so the preset
 * is deterministic even if the server config previously changed some of them.
 * Data-layer spread stays with cs2feel_spread_mode 0 (the VPK owns those keys);
 * the tracer is off because CS2 has no such beam (use cs2_tracer if you want
 * the visual aid). */
int CS2U_ModesBuildFull()
{
    int m = CS2U_ModeFind("cs2_full");
    if (m < 0)
        m = CS2U_ModeAdd("cs2_full");
    else
        g_iPresetEntries[m] = 0;   /* normalize stale/truncated definitions */
    if (m < 0)
        return -1;

    /* feel: single-player TR-40 look (cs2u_bmode 1).  Camera 1.00 x table,
     * bullet +1.20 on top -> the holes climb ~5 deg above the crosshair
     * (measured 4.98 deg vs the TR-40 rig's 5.225).  The client half is
     * cs2feel_aimsync.ini ratio = 1.200000; the menu prints that hint when the
     * preset is applied. */
    CS2U_ModeEntry(m, "cs2feel_enable", "1");
    CS2U_ModeEntry(m, "cs2feel_recoil_mode", "1");
    CS2U_ModeEntry(m, "cs2feel_recoil_scale", "1.0");
    CS2U_ModeEntry(m, "cs2feel_recoil_view_scale", "1.0");
    CS2U_ModeEntry(m, "cs2feel_ballistics_mode", "1");
    CS2U_ModeEntry(m, "cs2feel_ballistics_scale", "1.20");
    CS2U_ModeEntry(m, "cs2feel_ballistics_yaw", "1");
    CS2U_ModeEntry(m, "cs2feel_spread_mode", "0");
    CS2U_ModeEntry(m, "cs2feel_spread_scale", "1.0");
    CS2U_ModeEntry(m, "cs2feel_spread_move", "0");
    CS2U_ModeEntry(m, "cs2feel_spread_posture", "0");

    /* movement: all CS2 layers, including the opt-ins */
    CS2U_ModeEntry(m, "cs2movement_enable", "1");
    CS2U_ModeEntry(m, "cs2movement_apply_global", "1");
    CS2U_ModeEntry(m, "cs2movement_engine_speed", "1");
    CS2U_ModeEntry(m, "cs2movement_duck_speed", "1");
    CS2U_ModeEntry(m, "cs2movement_air_jump_speed", "1");
    CS2U_ModeEntry(m, "cs2movement_lowspeed_sustain", "1");
    CS2U_ModeEntry(m, "cs2movement_crouch_slide", "1");
    /* Two-sided slide (0.5.2): the client half drives the replicated
     * survivor_crouch_speed down the same curve, so client.dll predicts the
     * slide instead of snapping to its own crouch speed (measured: 2 frames
     * hard stop -> 12-13 frames decay, zero rubber-band).  The cvar is
     * global: while a slide runs, any OTHER crouching survivor briefly gets a
     * higher crouch cap (<= 0.2 s).  Set 0 to fall back to server-only. */
    CS2U_ModeEntry(m, "cs2movement_crouch_slide_client", "1");
    /* CS2 numeric would be ln(215/73.1)/5.2 = 0.207 s; the preset ships the
     * 0.45 s FEEL tier (the long-slide end of the menu cycle, user-tuned
     * 2026-11-03).  Keep min_speed 100 so a standing duck press stays inert. */
    CS2U_ModeEntry(m, "cs2movement_crouch_slide_time", "0.45");
    CS2U_ModeEntry(m, "cs2movement_crouch_slide_min_speed", "100");
    CS2U_ModeEntry(m, "cs2movement_crouch_enable", "1");
    CS2U_ModeEntry(m, "cs2movement_maxspeed", "1000");
    CS2U_ModeEntry(m, "cs2movement_weapon_speed_mode", "1");
    CS2U_ModeEntry(m, "cs2movement_duck_speed_min", "0");
    CS2U_ModeEntry(m, "cs2movement_base_speed", "250");

    CS2U_ModeEntry(m, "cs2movement_injury_enable", "1");
    CS2U_ModeEntry(m, "cs2movement_injury_mode", "1");
    CS2U_ModeEntry(m, "cs2movement_injury_health", "0.0");
    CS2U_ModeEntry(m, "cs2movement_injury_speed", "132.0");
    CS2U_ModeEntry(m, "cs2movement_injury_base", "220.0");
    CS2U_ModeEntry(m, "cs2movement_injury_temp_health", "1");
    CS2U_ModeEntry(m, "cs2movement_injury_adrenaline", "1");
    /* movement 0.5.3 water-depth slowdown: one cvar pair, linear in depth.
     * 0.35 = ankle 0.883 / waist 0.767 / eyes 0.650 of the weapon speed. */
    CS2U_ModeEntry(m, "cs2movement_water_enable", "1");
    CS2U_ModeEntry(m, "cs2movement_water_slowdown", "0.35");
    /* visual: CS2 has no server tracer */
    CS2U_ModeEntry(m, "cs2u_tracer_enable", "0");
    CS2U_ModeEntry(m, "cs2u_tracer_width", "1.0");
    CS2U_ModeEntry(m, "cs2u_tracer_life", "0.2");
    CS2U_ModeEntry(m, "cs2u_bmode", "1");
    return m;
}

void CS2U_ModesEnsureFull()
{
    /* Always rebuild: an old config may contain a truncated cs2_full (the
     * 24-entry capacity bug), and built-in presets are code-owned. */
    CS2U_ModesBuildFull();
}

/* Old configs stored movement_only without explicit recoil-zero values. Make
 * the built-in preset mean exactly: movement on, CS2 recoil/ballistics off. */
void CS2U_ModesEnsureMovementOnly()
{
    int m = CS2U_ModeFind("movement_only");
    if (m < 0)
        return;
    CS2U_ModeSetEntry(m, "cs2feel_enable", "0");
    CS2U_ModeSetEntry(m, "cs2feel_recoil_mode", "0");
    CS2U_ModeSetEntry(m, "cs2feel_recoil_scale", "0.0");
    CS2U_ModeSetEntry(m, "cs2feel_ballistics_mode", "0");
    CS2U_ModeSetEntry(m, "cs2feel_ballistics_scale", "0.0");
    CS2U_ModeSetEntry(m, "cs2feel_ballistics_yaw", "0");
    CS2U_ModeSetEntry(m, "cs2feel_spread_mode", "0");
    CS2U_ModeSetEntry(m, "cs2movement_injury_enable", "1");
    CS2U_ModeSetEntry(m, "cs2movement_injury_mode", "1");
    CS2U_ModeSetEntry(m, "cs2movement_injury_health", "0.0");
    CS2U_ModeSetEntry(m, "cs2movement_injury_speed", "132.0");
    CS2U_ModeSetEntry(m, "cs2movement_injury_base", "220.0");
    CS2U_ModeSetEntry(m, "cs2movement_injury_temp_health", "1");
    CS2U_ModeSetEntry(m, "cs2movement_injury_adrenaline", "1");
}

/* Competitive movement = all movement layers on, CS2 recoil explicitly zero.
 * Every managed value is written so split/matched residue cannot leak in. */
int CS2U_ModesBuildCompetitive()
{
    int m = CS2U_ModeFind("cs2_competitive");
    if (m < 0)
        m = CS2U_ModeAdd("cs2_competitive");
    else
        g_iPresetEntries[m] = 0;
    if (m < 0)
        return -1;

    CS2U_ModeEntry(m, "cs2feel_enable", "0");
    CS2U_ModeEntry(m, "cs2feel_recoil_mode", "0");
    CS2U_ModeEntry(m, "cs2feel_recoil_scale", "0.0");
    CS2U_ModeEntry(m, "cs2feel_recoil_view_scale", "1.0");
    CS2U_ModeEntry(m, "cs2feel_ballistics_mode", "0");
    CS2U_ModeEntry(m, "cs2feel_ballistics_scale", "0.0");
    CS2U_ModeEntry(m, "cs2feel_ballistics_yaw", "0");
    CS2U_ModeEntry(m, "cs2feel_spread_mode", "0");
    CS2U_ModeEntry(m, "cs2feel_spread_scale", "1.0");
    CS2U_ModeEntry(m, "cs2feel_spread_move", "0");
    CS2U_ModeEntry(m, "cs2feel_spread_posture", "0");

    CS2U_ModeEntry(m, "cs2movement_enable", "1");
    CS2U_ModeEntry(m, "cs2movement_apply_global", "1");
    CS2U_ModeEntry(m, "cs2movement_engine_speed", "1");
    CS2U_ModeEntry(m, "cs2movement_duck_speed", "1");
    CS2U_ModeEntry(m, "cs2movement_air_jump_speed", "1");
    CS2U_ModeEntry(m, "cs2movement_lowspeed_sustain", "1");
    CS2U_ModeEntry(m, "cs2movement_crouch_slide", "1");
    /* Two-sided slide (0.5.2): the client half drives the replicated
     * survivor_crouch_speed down the same curve, so client.dll predicts the
     * slide instead of snapping to its own crouch speed (measured: 2 frames
     * hard stop -> 12-13 frames decay, zero rubber-band).  The cvar is
     * global: while a slide runs, any OTHER crouching survivor briefly gets a
     * higher crouch cap (<= 0.2 s).  Set 0 to fall back to server-only. */
    CS2U_ModeEntry(m, "cs2movement_crouch_slide_client", "1");
    /* CS2 equivalent: ln(215/73.1)/5.2 = 0.207 s (~27.3 u at AK speed).  The
     * old 0.10 s default was half of CS2, which is why "same value as CS2"
     * still looked short; min_speed 100 keeps standing duck presses inert. */
    CS2U_ModeEntry(m, "cs2movement_crouch_slide_time", "0.45");
    CS2U_ModeEntry(m, "cs2movement_crouch_slide_min_speed", "100");
    CS2U_ModeEntry(m, "cs2movement_crouch_enable", "1");
    CS2U_ModeEntry(m, "cs2movement_maxspeed", "1000");
    CS2U_ModeEntry(m, "cs2movement_weapon_speed_mode", "1");
    CS2U_ModeEntry(m, "cs2movement_duck_speed_min", "0");
    CS2U_ModeEntry(m, "cs2movement_base_speed", "250");

    CS2U_ModeEntry(m, "cs2movement_injury_enable", "1");
    CS2U_ModeEntry(m, "cs2movement_injury_mode", "1");
    CS2U_ModeEntry(m, "cs2movement_injury_health", "0.0");
    CS2U_ModeEntry(m, "cs2movement_injury_speed", "132.0");
    CS2U_ModeEntry(m, "cs2movement_injury_base", "220.0");
    CS2U_ModeEntry(m, "cs2movement_injury_temp_health", "1");
    CS2U_ModeEntry(m, "cs2movement_injury_adrenaline", "1");
    /* movement 0.5.3 water-depth slowdown (same pair as cs2_full). */
    CS2U_ModeEntry(m, "cs2movement_water_enable", "1");
    CS2U_ModeEntry(m, "cs2movement_water_slowdown", "0.35");
    CS2U_ModeEntry(m, "cs2u_tracer_enable", "0");
    CS2U_ModeEntry(m, "cs2u_tracer_width", "1.0");
    CS2U_ModeEntry(m, "cs2u_tracer_life", "0.2");
    CS2U_ModeEntry(m, "cs2u_bmode", "0");
    return m;
}

void CS2U_ModesEnsureCompetitive()
{
    CS2U_ModesBuildCompetitive();
}

/* 0.4.8: cs2movement_maxspeed is a per-player clamp, not sv_maxspeed.  Keep
 * built-in presets on the upstream default 1000 so no hidden 320 hard cap
 * survives in old configs. */
void CS2U_ModesEnsureMaxspeed()
{
    for (int i = 0; i < g_iPresetCount; i++)
    {
        for (int e = 0; e < g_iPresetEntries[i]; e++)
        {
            if (StrEqual(g_sPresetCvar[i][e], "cs2movement_maxspeed", false))
                strcopy(g_sPresetValue[i][e], CS2U_VALUE_LEN, "1000");
        }
    }
}

/* cs2u_bmode is a managed parameter, so a preset that omits it leaves the
 * previous trajectory mode in place while rewriting the seven structure cvars
 * -- the status page would then report a mode the cvars do not implement.
 * Add 0 (auto) only when the entry is absent, so a config owner can still pin
 * a per-preset value explicitly. */
void CS2U_ModesEnsureBmode()
{
    for (int i = 0; i < g_iPresetCount; i++)
    {
        if (!CS2U_ModeHasEntry(i, "cs2u_bmode"))
            CS2U_ModeSetEntry(i, "cs2u_bmode", "0");
    }
}

/* Same class of bug as EnsureBmode: a preset written by an older build has no
 * water keys, so applying it leaves whatever the previous preset set behind
 * while the status page still claims a preset is active.  Fill the pair in;
 * vanilla is the one preset that must keep the movement layer silent, so it
 * gets enable 0 (its cs2movement_enable 0 already makes the layer inert -- this
 * just keeps the stored value honest). */
void CS2U_ModesEnsureWater()
{
    for (int i = 0; i < g_iPresetCount; i++)
    {
        bool vanilla = StrEqual(g_sPresetName[i], "vanilla", false);
        if (!CS2U_ModeHasEntry(i, "cs2movement_water_enable"))
            CS2U_ModeSetEntry(i, "cs2movement_water_enable", vanilla ? "0" : "1");
        if (!CS2U_ModeHasEntry(i, "cs2movement_water_slowdown"))
            CS2U_ModeSetEntry(i, "cs2movement_water_slowdown", "0.35");
    }
}

void CS2U_ModesInit()
{
    g_iPresetCount = 0;
    int m;

    /* ---- vanilla: both plugins off, engine behaviour untouched ----------- */
    m = CS2U_ModeAdd("vanilla");
    CS2U_ModeEntry(m, "cs2feel_enable", "0");
    CS2U_ModeEntry(m, "cs2feel_recoil_mode", "0");
    CS2U_ModeEntry(m, "cs2feel_recoil_scale", "1.0");
    CS2U_ModeEntry(m, "cs2feel_recoil_view_scale", "1.0");
    CS2U_ModeEntry(m, "cs2feel_ballistics_mode", "0");
    CS2U_ModeEntry(m, "cs2feel_ballistics_scale", "0.0");
    CS2U_ModeEntry(m, "cs2feel_ballistics_yaw", "0");
    CS2U_ModeEntry(m, "cs2feel_spread_mode", "0");
    CS2U_ModeEntry(m, "cs2movement_enable", "0");
    CS2U_ModeEntry(m, "cs2movement_apply_global", "0");
    CS2U_ModeEntry(m, "cs2movement_engine_speed", "0");
    CS2U_ModeEntry(m, "cs2movement_duck_speed", "0");
    CS2U_ModeEntry(m, "cs2movement_air_jump_speed", "0");
    CS2U_ModeEntry(m, "cs2movement_lowspeed_sustain", "0");
    CS2U_ModeEntry(m, "cs2movement_crouch_slide", "0");
    CS2U_ModeEntry(m, "cs2u_bmode", "0");
    /* vanilla means "both plugins off": the water keys exist so a preset switch
     * cannot leave them at another preset's value, but enable 0 keeps the
     * stored intent explicit. */
    CS2U_ModeEntry(m, "cs2movement_water_enable", "0");
    CS2U_ModeEntry(m, "cs2movement_water_slowdown", "0.35");

    /* ---- cs2_matched: project defaults (recoil 1.0, ballistics pass) ----- */
    m = CS2U_ModeAdd("cs2_matched");
    CS2U_ModeEntry(m, "cs2feel_enable", "1");
    CS2U_ModeEntry(m, "cs2feel_recoil_mode", "1");
    CS2U_ModeEntry(m, "cs2feel_recoil_scale", "1.0");
    CS2U_ModeEntry(m, "cs2feel_recoil_view_scale", "1.0");
    CS2U_ModeEntry(m, "cs2feel_ballistics_mode", "0");
    CS2U_ModeEntry(m, "cs2feel_ballistics_scale", "0.0");
    CS2U_ModeEntry(m, "cs2feel_ballistics_yaw", "0");
    CS2U_ModeEntry(m, "cs2feel_spread_mode", "0");
    CS2U_ModeEntry(m, "cs2movement_enable", "1");
    CS2U_ModeEntry(m, "cs2movement_apply_global", "1");
    CS2U_ModeEntry(m, "cs2movement_engine_speed", "1");
    CS2U_ModeEntry(m, "cs2movement_duck_speed", "1");
    CS2U_ModeEntry(m, "cs2movement_air_jump_speed", "0");
    CS2U_ModeEntry(m, "cs2movement_lowspeed_sustain", "0");
    CS2U_ModeEntry(m, "cs2movement_crouch_slide", "0");
    CS2U_ModeEntry(m, "cs2movement_crouch_enable", "1");
    CS2U_ModeEntry(m, "cs2movement_maxspeed", "1000");
    CS2U_ModeEntry(m, "cs2movement_weapon_speed_mode", "1");
    CS2U_ModeEntry(m, "cs2u_bmode", "0");

    /* ---- cs2_split: two-channel recoil (camera 1.10 / bullet -0.10) ------ */
    m = CS2U_ModeAdd("cs2_split");
    CS2U_ModeEntry(m, "cs2feel_enable", "1");
    CS2U_ModeEntry(m, "cs2feel_recoil_mode", "1");
    CS2U_ModeEntry(m, "cs2feel_recoil_scale", "1.10");
    CS2U_ModeEntry(m, "cs2feel_recoil_view_scale", "1.0");
    CS2U_ModeEntry(m, "cs2feel_ballistics_mode", "1");
    CS2U_ModeEntry(m, "cs2feel_ballistics_scale", "-0.10");
    CS2U_ModeEntry(m, "cs2feel_ballistics_yaw", "1");
    CS2U_ModeEntry(m, "cs2feel_spread_mode", "0");
    CS2U_ModeEntry(m, "cs2movement_enable", "1");
    CS2U_ModeEntry(m, "cs2movement_apply_global", "1");
    CS2U_ModeEntry(m, "cs2movement_engine_speed", "1");
    CS2U_ModeEntry(m, "cs2movement_duck_speed", "1");
    CS2U_ModeEntry(m, "cs2movement_air_jump_speed", "0");
    CS2U_ModeEntry(m, "cs2movement_lowspeed_sustain", "0");
    CS2U_ModeEntry(m, "cs2movement_crouch_slide", "0");
    CS2U_ModeEntry(m, "cs2movement_crouch_enable", "1");
    CS2U_ModeEntry(m, "cs2movement_maxspeed", "1000");
    CS2U_ModeEntry(m, "cs2movement_weapon_speed_mode", "1");
    CS2U_ModeEntry(m, "cs2u_bmode", "0");

    /* ---- movement_only: CS2 movement, native gun feel -------------------- */
    m = CS2U_ModeAdd("movement_only");
    CS2U_ModeEntry(m, "cs2feel_enable", "0");
    CS2U_ModeEntry(m, "cs2feel_recoil_mode", "0");
    CS2U_ModeEntry(m, "cs2feel_recoil_scale", "0.0");
    CS2U_ModeEntry(m, "cs2feel_ballistics_mode", "0");
    CS2U_ModeEntry(m, "cs2feel_ballistics_scale", "0.0");
    CS2U_ModeEntry(m, "cs2feel_ballistics_yaw", "0");
    CS2U_ModeEntry(m, "cs2feel_spread_mode", "0");
    CS2U_ModeEntry(m, "cs2movement_enable", "1");
    CS2U_ModeEntry(m, "cs2movement_apply_global", "1");
    CS2U_ModeEntry(m, "cs2movement_engine_speed", "1");
    CS2U_ModeEntry(m, "cs2movement_duck_speed", "1");
    CS2U_ModeEntry(m, "cs2movement_air_jump_speed", "0");
    CS2U_ModeEntry(m, "cs2movement_lowspeed_sustain", "0");
    CS2U_ModeEntry(m, "cs2movement_crouch_slide", "0");
    CS2U_ModeEntry(m, "cs2movement_crouch_enable", "1");
    CS2U_ModeEntry(m, "cs2movement_maxspeed", "1000");
    CS2U_ModeEntry(m, "cs2movement_weapon_speed_mode", "1");

    CS2U_ModeEntry(m, "cs2movement_injury_enable", "1");
    CS2U_ModeEntry(m, "cs2movement_injury_mode", "1");
    CS2U_ModeEntry(m, "cs2movement_injury_health", "0.0");
    CS2U_ModeEntry(m, "cs2movement_injury_speed", "132.0");
    CS2U_ModeEntry(m, "cs2movement_injury_base", "220.0");
    CS2U_ModeEntry(m, "cs2movement_injury_temp_health", "1");
    CS2U_ModeEntry(m, "cs2movement_injury_adrenaline", "1");
    CS2U_ModeEntry(m, "cs2movement_water_enable", "1");
    CS2U_ModeEntry(m, "cs2movement_water_slowdown", "0.35");
    CS2U_ModeEntry(m, "cs2u_bmode", "0");

    /* ---- cs2_competitive: all movement layers, CS2 recoil zero ----------- */
    CS2U_ModesBuildCompetitive();

    /* ---- cs2_full: every managed value at its CS2-closest setting --------- */
    CS2U_ModesBuildFull();

    /* Every non-tracer preset explicitly turns the tracer off, so switching
     * from cs2_tracer back to cs2_matched/vanilla cannot leave beams enabled. */
    for (int i = 0; i < g_iPresetCount; i++)
        CS2U_ModeSetEntry(i, "cs2u_tracer_enable", "0");

    /* ---- cs2_tracer: cs2_matched + server-side tracer beam --------------- */
    int tracer = CS2U_ModeClone("cs2_tracer", "cs2_matched");
    if (tracer >= 0)
        CS2U_ModeSetEntry(tracer, "cs2u_tracer_enable", "1");

    /* Every preset carries the trajectory mode (0 = auto) so applying one is
     * deterministic for all 39 managed values. */
    CS2U_ModesEnsureBmode();
    CS2U_ModesEnsureWater();
}

/* Display name for a preset.  The internal key stays ASCII: the config keys,
 * menu.cfg order entries and `sm_cs2u_preset <name>` all use it, so only the
 * rows/chat are localised.  Unknown keys fall through unchanged. */
void CS2U_ModeLabelCn(const char[] name, char[] out, int maxlen)
{
    if (StrEqual(name, "cs2_full", false))             strcopy(out, maxlen, "CS2 完全仿真");
    else if (StrEqual(name, "cs2_competitive", false)) strcopy(out, maxlen, "CS2 竞技移动");
    else if (StrEqual(name, "cs2_matched", false))     strcopy(out, maxlen, "CS2 匹配");
    else if (StrEqual(name, "cs2_split", false))       strcopy(out, maxlen, "CS2 原生分离");
    else if (StrEqual(name, "cs2_tracer", false))      strcopy(out, maxlen, "CS2 匹配 + 曳光");
    else if (StrEqual(name, "movement_only", false))   strcopy(out, maxlen, "仅移动");
    else if (StrEqual(name, "vanilla", false))         strcopy(out, maxlen, "原版");
    else if (StrEqual(name, "diy_advanced", false))    strcopy(out, maxlen, "DIY 高级");
    else if (StrEqual(name, "diy_simple", false))      strcopy(out, maxlen, "DIY 简单");
    else if (StrEqual(name, "cs2_maxspeed", false))    strcopy(out, maxlen, "速度上限");
    else strcopy(out, maxlen, name);
}

int CS2U_ModeCount()
{
    return g_iPresetCount;
}

void CS2U_ModeName(int index, char[] out, int maxlen)
{
    out[0] = '\0';
    if (index < 0 || index >= g_iPresetCount)
        return;
    strcopy(out, maxlen, g_sPresetName[index]);
}

int CS2U_ModeFind(const char[] name)
{
    for (int i = 0; i < g_iPresetCount; i++)
        if (StrEqual(g_sPresetName[i], name, false))
            return i;
    return -1;
}

bool CS2U_ModeApply(int client, const char[] name, char[] msg, int msgLen)
{
    if (!CS2U_IsEnabled())
    {
        Format(msg, msgLen, "management layer disabled (cs2u_enable 0)");
        return false;
    }

    int mode = CS2U_ModeFind(name);
    if (mode < 0)
    {
        Format(msg, msgLen, "unknown preset '%s' (use sm_cs2u_presets)", name);
        return false;
    }

    /* Dry run: a preset containing one bad entry is rejected whole. */
    char err[160];
    float parsed;
    for (int e = 0; e < g_iPresetEntries[mode]; e++)
    {
        int idx = CS2U_ParamFind(g_sPresetCvar[mode][e]);
        if (idx < 0)
        {
            CS2U_Log("PRESET-SKIP unknown managed cvar %s in preset %s",
                     g_sPresetCvar[mode][e], name);
            continue;
        }
        if (!CS2U_ParamValidate(idx, g_sPresetValue[mode][e], parsed, err, sizeof(err)))
        {
            Format(msg, msgLen, "preset '%s' rejected: %s", name, err);
            return false;
        }
    }

    CS2U_Snapshot();

    int applied = 0;
    for (int e = 0; e < g_iPresetEntries[mode]; e++)
    {
        int idx = CS2U_ParamFind(g_sPresetCvar[mode][e]);
        if (idx < 0)
            continue;
        if (CS2U_ParamSet(idx, g_sPresetValue[mode][e], err, sizeof(err)))
            applied++;
        else
            CS2U_Log("PRESET-SET-FAILED %s=%s: %s",
                     g_sPresetCvar[mode][e], g_sPresetValue[mode][e], err);
    }

    strcopy(g_sActivePreset, sizeof(g_sActivePreset), name);
    if (g_cvUPreset != null)
        SetConVarString(g_cvUPreset, g_sActivePreset);
    CS2U_ReconcileMovement();

    char persistMsg[256];
    if (!CS2U_ConfigWriteInternal(name, true, persistMsg, sizeof(persistMsg)))
    {
        CS2U_Rollback(msg, msgLen);
        Format(msg, msgLen, "preset '%s' could not be persisted (%s); rolled back", name, persistMsg);
        CS2U_Log("PRESET-PERSIST-FAILED name=%s %s", name, persistMsg);
        return false;
    }

    CS2U_CapturePersisted();
    CS2U_ActionLog("preset name=%s params=%d by=%d", name, applied, client);
    Format(msg, msgLen, "Applied preset '%s' (%d parameters); persisted", name, applied);
    CS2U_PresetClientHint(client, name);
    return true;
}

/* Client-side half of a preset.  The server can never set these (they are
 * client ConVars / files), so the only useful thing it can do is say them out
 * loud at the moment the preset lands. */
void CS2U_PresetClientHint(int client, const char[] preset)
{
    if (client <= 0 || !IsClientInGame(client))
        return;

    bool tr40 = false;
    int m = CS2U_ModeFind(preset);
    if (m >= 0)
    {
        for (int e = 0; e < g_iPresetEntries[m]; e++)
        {
            if (!StrEqual(g_sPresetCvar[m][e], "cs2u_bmode", false))
                continue;
            tr40 = StrEqual(g_sPresetValue[m][e], "1", false);
        }
    }

    if (tr40)
    {
        PrintToChat(client, "\x04[CS2Unified]\x01 预设 %s = 单人·TR-40，客户端需要这样设置：", preset);
        PrintToChat(client, "  1) bin\\neko\\plugins\\cs2feel_aimsync.ini → ratio = 1.200000，enable = 1，yaw = 1");
        PrintToChat(client, "  2) Left4Neko：l4n_view_punch_scale 保持 1.0（不要 1.10，会叠加）");
        PrintToChat(client, "  3) 没装 cs2feel_aimsync 也能玩：子弹/命中不受影响，只是看不到弹孔爬升");
    }
    else
    {
        PrintToChat(client, "\x04[CS2Unified]\x01 预设 %s 已应用；该预设不要求客户端设置（aim-sync ratio 用 0.0 即可）", preset);
    }
}
