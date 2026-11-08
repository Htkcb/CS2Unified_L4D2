/**
 * cs2u_params.sp -- the managed parameter table.
 *
 * Every value the menu may change is declared here exactly once, with its type,
 * range, required admin access and a small candidate list for the menu. All
 * writes go through CS2U_ParamSet(), which validates BEFORE touching the ConVar,
 * so a rejected menu item never leaves a half-applied value behind.
 *
 * Group 0 = feel (cs2feel_*), group 1 = movement (cs2movement_*),
 * group 3 = injury, group 4 = water.  Groups drive menu ordering and header
 * text only; the context a row renders in is decided by cs2u_layout.sp.
 */

#if defined _cs2u_params_included
 #endinput
#endif
#define _cs2u_params_included

/* PARAM_GROUP_* are declared in cs2u_shared.sp. */

void CS2U_ParamsInit()
{
    g_iParamCount = 0;

    /* ---- feel (cs2feel 0.5.7-m11) ---------------------------------------- */
    int p;
    p = CS2U_ParamAdd("cs2feel_enable", "Feel master switch", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_FEEL, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2feel_recoil_mode", "Recoil mode (0 native / 1 CS2 sequence)", PARAM_TYPE_INT, PARAM_ACCESS_ADMIN, PARAM_GROUP_FEEL, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2feel_recoil_scale", "Recoil scale", PARAM_TYPE_FLOAT, PARAM_ACCESS_ADMIN, PARAM_GROUP_FEEL, 0.0, 3.0);
    CS2U_ParamCand(p, "0.5"); CS2U_ParamCand(p, "1.0"); CS2U_ParamCand(p, "1.5"); CS2U_ParamCand(p, "2.4");

    p = CS2U_ParamAdd("cs2feel_recoil_view_scale", "Recoil view (camera) scale", PARAM_TYPE_FLOAT, PARAM_ACCESS_ADMIN, PARAM_GROUP_FEEL, 0.0, 2.0);
    CS2U_ParamCand(p, "0.055"); CS2U_ParamCand(p, "0.1"); CS2U_ParamCand(p, "0.5"); CS2U_ParamCand(p, "1.0");

    p = CS2U_ParamAdd("cs2feel_ballistics_mode", "Ballistics mode (0 native / 1 CS2 pitch)", PARAM_TYPE_INT, PARAM_ACCESS_ADMIN, PARAM_GROUP_FEEL, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2feel_ballistics_scale", "Ballistics scale (negative = split)", PARAM_TYPE_FLOAT, PARAM_ACCESS_ADMIN, PARAM_GROUP_FEEL, -2.0, 3.0);
    CS2U_ParamCand(p, "-0.10"); CS2U_ParamCand(p, "0.0"); CS2U_ParamCand(p, "1.0"); CS2U_ParamCand(p, "2.4");

    p = CS2U_ParamAdd("cs2feel_ballistics_yaw", "Ballistics yaw sway", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_FEEL, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2feel_spread_mode", "Spread mode (0 pass-through / 1 provisional)", PARAM_TYPE_INT, PARAM_ACCESS_ADMIN, PARAM_GROUP_FEEL, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2feel_spread_scale", "Spread scale (mode 1 only)", PARAM_TYPE_FLOAT, PARAM_ACCESS_ADMIN, PARAM_GROUP_FEEL, 0.1, 3.0);
    CS2U_ParamCand(p, "0.5"); CS2U_ParamCand(p, "1.0"); CS2U_ParamCand(p, "1.5");

    p = CS2U_ParamAdd("cs2feel_spread_move", "Spread movement term", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_FEEL, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2feel_spread_posture", "Spread posture term", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_FEEL, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    /* 2026-11-02: trajectory mode.  0 = auto (policy over connected clients),
     * 1 = single-player (server-side split, truthful decals need the client
     * aim-sync), 2 = multiplayer (matched server, the camera split is the
     * client's own Left4Neko knob -> every client sees the same bullets and
     * no client can be "seeing something else than it hits"). */
    p = CS2U_ParamAdd("cs2u_bmode", "Trajectory mode (0 auto / 1 single / 2 multi / 3 climb)", PARAM_TYPE_INT, PARAM_ACCESS_ADMIN, PARAM_GROUP_FEEL, 0.0, 3.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1"); CS2U_ParamCand(p, "2"); CS2U_ParamCand(p, "3");

    /* ---- movement (cs2movement 0.5.3) ------------------------------------ */
    p = CS2U_ParamAdd("cs2movement_enable", "Movement master switch", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_MOVE, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2movement_apply_global", "Apply global sv_* layer", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_MOVE, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2movement_engine_speed", "Per-player engine run speed", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_MOVE, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2movement_duck_speed", "Per-player duck speed", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_MOVE, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2movement_air_jump_speed", "CS2 air speed (opt-in)", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_MOVE, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2movement_lowspeed_sustain", "Low-speed sustain (opt-in)", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_MOVE, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2movement_crouch_slide", "Crouch slide (opt-in)", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_MOVE, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    /* Client half of the slide: writes the REPLICATED survivor_crouch_speed
     * down the same curve so client.dll predicts it too.  Enabled by the two
     * CS2 presets (cs2_competitive / cs2_full), plugin default 0.  The cvar is
     * global, so the implementation gates it to the unambiguous case (one
     * sliding survivor, no other survivor ducking). */
    p = CS2U_ParamAdd("cs2movement_crouch_slide_client", "Client-side slide (global cvar side effect)", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_MOVE, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    /* The two knobs that decide how far a slide travels.  0.20 s is the CS2
     * numeric equivalent (ln(215/73.1)/5.2 = 0.207 s -> 27.3 u); 0.10 is only
     * half of it.  L4D2 has no CS2-style duck transition and the client eats
     * the first tick or two of the slide, so the rendered slide reads shorter
     * than the configured one.  0.45 (59.2 u, 28.8 ticks) was the owner's
     * "feel" tier from 2026-11-03; since 1.0.16 the feel tier is 0.35
     * (46.0 u, 22.4 ticks) and both presets ship it.  0.60 is now the upper
     * bound (0.70 retired from the cycle). */
    p = CS2U_ParamAdd("cs2movement_crouch_slide_time", "Crouch slide decay time (0.20 = CS2 numeric, 0.35 = feel)", PARAM_TYPE_FLOAT, PARAM_ACCESS_ADMIN, PARAM_GROUP_MOVE, 0.02, 2.0);
    CS2U_ParamCand(p, "0.10"); CS2U_ParamCand(p, "0.20"); CS2U_ParamCand(p, "0.30"); CS2U_ParamCand(p, "0.35"); CS2U_ParamCand(p, "0.40"); CS2U_ParamCand(p, "0.45"); CS2U_ParamCand(p, "0.50"); CS2U_ParamCand(p, "0.60");

    p = CS2U_ParamAdd("cs2movement_crouch_slide_min_speed", "Crouch slide minimum start speed", PARAM_TYPE_FLOAT, PARAM_ACCESS_ADMIN, PARAM_GROUP_MOVE, 0.0, 1000.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "50"); CS2U_ParamCand(p, "100"); CS2U_ParamCand(p, "150");

    p = CS2U_ParamAdd("cs2movement_crouch_enable", "Crouch model", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_MOVE, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2movement_maxspeed", "Per-player speed cap (0.4.8)", PARAM_TYPE_FLOAT, PARAM_ACCESS_ROOT, PARAM_GROUP_MOVE, 50.0, 1000.0);
    CS2U_ParamCand(p, "150"); CS2U_ParamCand(p, "215"); CS2U_ParamCand(p, "230"); CS2U_ParamCand(p, "240"); CS2U_ParamCand(p, "320"); CS2U_ParamCand(p, "1000");

    p = CS2U_ParamAdd("cs2movement_weapon_speed_mode", "Weapon speed table (1 CS2 / 0 native)", PARAM_TYPE_INT, PARAM_ACCESS_ROOT, PARAM_GROUP_MOVE, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2movement_duck_speed_min", "Duck speed floor (0 disables)", PARAM_TYPE_FLOAT, PARAM_ACCESS_ADMIN, PARAM_GROUP_MOVE, 0.0, 200.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "76");

    p = CS2U_ParamAdd("cs2movement_base_speed", "Fallback speed (unmapped weapons)", PARAM_TYPE_FLOAT, PARAM_ACCESS_ROOT, PARAM_GROUP_MOVE, 50.0, 400.0);
    CS2U_ParamCand(p, "210"); CS2U_ParamCand(p, "220"); CS2U_ParamCand(p, "230"); CS2U_ParamCand(p, "240"); CS2U_ParamCand(p, "250");

    /* ---- injury slowdown (movement 0.5.1) -------------------------------- */
    p = CS2U_ParamAdd("cs2movement_injury_enable", "Injury slowdown", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_INJURY, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2movement_injury_mode", "Mode (1 ratio / 0 absolute)", PARAM_TYPE_INT, PARAM_ACCESS_ADMIN, PARAM_GROUP_INJURY, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2movement_injury_health", "Limp health threshold (0 engine)", PARAM_TYPE_FLOAT, PARAM_ACCESS_ADMIN, PARAM_GROUP_INJURY, 0.0, 100.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "20"); CS2U_ParamCand(p, "40"); CS2U_ParamCand(p, "60");

    p = CS2U_ParamAdd("cs2movement_injury_speed", "Injury speed (u/s; 0 engine)", PARAM_TYPE_FLOAT, PARAM_ACCESS_ADMIN, PARAM_GROUP_INJURY, 0.0, 500.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "85"); CS2U_ParamCand(p, "100"); CS2U_ParamCand(p, "132");

    p = CS2U_ParamAdd("cs2movement_injury_base", "Healthy base speed (ratio)", PARAM_TYPE_FLOAT, PARAM_ACCESS_ADMIN, PARAM_GROUP_INJURY, 0.0, 500.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "210"); CS2U_ParamCand(p, "220"); CS2U_ParamCand(p, "230");

    p = CS2U_ParamAdd("cs2movement_injury_temp_health", "Count temp health", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_INJURY, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2movement_injury_adrenaline", "Adrenaline exempt", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_INJURY, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    /* ---- water-depth slowdown (movement 0.5.3) --------------------------- */
    /* Two parameters only: depth is a continuous ramp inside the layer
     * (factor = 1 - slowdown * level/3), not three hand-tuned tiers.  Capacity
     * is 40 and this lands on 39, so a third knob would fit -- but it would
     * also have to be re-tuned on every map instead of once. */
    p = CS2U_ParamAdd("cs2movement_water_enable", "Water slowdown", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_WATER, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2movement_water_slowdown", "Water slowdown strength (eye-deep)", PARAM_TYPE_FLOAT, PARAM_ACCESS_ADMIN, PARAM_GROUP_WATER, 0.0, 0.8);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "0.15"); CS2U_ParamCand(p, "0.25"); CS2U_ParamCand(p, "0.35"); CS2U_ParamCand(p, "0.50"); CS2U_ParamCand(p, "0.65");

    /* ---- visual aids (unified layer) ------------------------------------- */
    p = CS2U_ParamAdd("cs2u_tracer_enable", "Tracer / bullet path beam", PARAM_TYPE_BOOL, PARAM_ACCESS_ADMIN, PARAM_GROUP_VISUAL, 0.0, 1.0);
    CS2U_ParamCand(p, "0"); CS2U_ParamCand(p, "1");

    p = CS2U_ParamAdd("cs2u_tracer_width", "Tracer width", PARAM_TYPE_FLOAT, PARAM_ACCESS_ADMIN, PARAM_GROUP_VISUAL, 0.5, 5.0);
    CS2U_ParamCand(p, "0.5"); CS2U_ParamCand(p, "1.0"); CS2U_ParamCand(p, "2.0");

    p = CS2U_ParamAdd("cs2u_tracer_life", "Tracer lifetime (seconds)", PARAM_TYPE_FLOAT, PARAM_ACCESS_ADMIN, PARAM_GROUP_VISUAL, 0.05, 1.0);
    CS2U_ParamCand(p, "0.1"); CS2U_ParamCand(p, "0.2"); CS2U_ParamCand(p, "0.4");
}

int CS2U_ParamAdd(const char[] cvar, const char[] label, int type, int access, int group, float minValue, float maxValue)
{
    if (g_iParamCount >= CS2U_MAX_PARAMS)
        return -1;

    int i = g_iParamCount++;
    strcopy(g_sParamCvar[i], CS2U_CVAR_LEN, cvar);
    strcopy(g_sParamLabel[i], sizeof(g_sParamLabel[]), label);
    g_iParamType[i] = type;
    g_iParamAccess[i] = access;
    g_iParamGroup[i] = group;
    g_fParamMin[i] = minValue;
    g_fParamMax[i] = maxValue;
    g_iParamCandCount[i] = 0;
    return i;
}

void CS2U_ParamCand(int idx, const char[] value)
{
    if (idx < 0 || idx >= g_iParamCount)
        return;
    if (g_iParamCandCount[idx] >= CS2U_MAX_CANDIDATES)
        return;
    strcopy(g_sParamCand[idx][g_iParamCandCount[idx]], 24, value);
    g_iParamCandCount[idx]++;
}

int CS2U_ParamCount()
{
    return g_iParamCount;
}

int CS2U_ParamFind(const char[] cvar)
{
    for (int i = 0; i < g_iParamCount; i++)
        if (StrEqual(g_sParamCvar[i], cvar, false))
            return i;
    return -1;
}

bool CS2U_ParamCanEdit(int client, int idx)
{
    if (idx < 0 || idx >= g_iParamCount)
        return false;
    if (g_iParamAccess[idx] == PARAM_ACCESS_ROOT)
        return CS2U_IsRoot(client);
    return CS2U_IsAdmin(client);
}

bool CS2U_IsNumericString(const char[] value)
{
    int len = strlen(value);
    if (len == 0 || len > CS2U_VALUE_LEN - 1)
        return false;

    bool sawDigit = false;
    bool sawDot = false;
    for (int i = 0; i < len; i++)
    {
        char c = value[i];
        if (c == '-' && i == 0)
            continue;
        if (c == '.' && !sawDot)
        {
            sawDot = true;
            continue;
        }
        if (c < '0' || c > '9')
            return false;
        sawDigit = true;
    }
    return sawDigit;
}

bool CS2U_ParamValidate(int idx, const char[] value, float &parsed, char[] err, int errLen)
{
    parsed = 0.0;
    if (idx < 0 || idx >= g_iParamCount)
    {
        Format(err, errLen, "unknown parameter index");
        return false;
    }
    if (FindConVar(g_sParamCvar[idx]) == null)
    {
        Format(err, errLen, "ConVar %s is not registered", g_sParamCvar[idx]);
        return false;
    }
    if (!CS2U_IsNumericString(value))
    {
        Format(err, errLen, "'%s' is not a number for %s", value, g_sParamCvar[idx]);
        return false;
    }

    parsed = StringToFloat(value);
    if (parsed < g_fParamMin[idx] || parsed > g_fParamMax[idx])
    {
        Format(err, errLen, "%s = %s is outside [%.4f, %.4f]",
               g_sParamCvar[idx], value, g_fParamMin[idx], g_fParamMax[idx]);
        return false;
    }

    if (g_iParamType[idx] == PARAM_TYPE_BOOL && parsed != 0.0 && parsed != 1.0)
    {
        Format(err, errLen, "%s is a 0/1 switch, got %s", g_sParamCvar[idx], value);
        return false;
    }
    if (g_iParamType[idx] == PARAM_TYPE_INT)
    {
        float rounded = float(RoundToNearest(parsed));
        if (FloatAbs(parsed - rounded) > 0.0001)
        {
            Format(err, errLen, "%s is an integer, got %s", g_sParamCvar[idx], value);
            return false;
        }
    }
    return true;
}

bool CS2U_ParamSet(int idx, const char[] value, char[] err, int errLen)
{
    float parsed;
    if (!CS2U_ParamValidate(idx, value, parsed, err, errLen))
        return false;

    ConVar cv = FindConVar(g_sParamCvar[idx]);
    if (cv == null)
    {
        Format(err, errLen, "ConVar %s is missing", g_sParamCvar[idx]);
        return false;
    }

    if (g_iParamType[idx] == PARAM_TYPE_FLOAT)
        SetConVarFloat(cv, parsed);
    else
        SetConVarInt(cv, RoundToNearest(parsed));

    return true;
}

void CS2U_ParamCurrent(int idx, char[] out, int maxlen)
{
    out[0] = '\0';
    if (idx < 0 || idx >= g_iParamCount)
        return;

    ConVar cv = FindConVar(g_sParamCvar[idx]);
    if (cv == null)
    {
        strcopy(out, maxlen, "MISSING");
        return;
    }

    if (g_iParamType[idx] == PARAM_TYPE_FLOAT)
        Format(out, maxlen, "%.3f", GetConVarFloat(cv));
    else
        Format(out, maxlen, "%d", GetConVarInt(cv));
}

/* Human-facing value: 0/1 becomes Off/On, floats keep 3 decimals. */
void CS2U_ParamDisplay(int idx, char[] out, int maxlen)
{
    CS2U_ParamCurrent(idx, out, maxlen);
    if (idx >= 0 && idx < g_iParamCount && g_iParamType[idx] == PARAM_TYPE_BOOL)
        strcopy(out, maxlen, StrEqual(out, "1") ? "On" : "Off");
}

/* Exact stored representation (no display rounding). Used for snapshots,
 * persistence and preset capture, where "%.3f" would silently lose precision. */
void CS2U_ParamRaw(int idx, char[] out, int maxlen)
{
    out[0] = '\0';
    if (idx < 0 || idx >= g_iParamCount)
        return;

    ConVar cv = FindConVar(g_sParamCvar[idx]);
    if (cv == null)
    {
        strcopy(out, maxlen, "MISSING");
        return;
    }
    GetConVarString(cv, out, maxlen);
}

bool CS2U_ParamCandidateIsCurrent(int idx, int cand)
{
    char current[CS2U_VALUE_LEN], candidate[CS2U_VALUE_LEN];
    CS2U_ParamCurrent(idx, current, sizeof(current));
    strcopy(candidate, sizeof(candidate), g_sParamCand[idx][cand]);

    if (g_iParamType[idx] == PARAM_TYPE_FLOAT)
        return FloatAbs(StringToFloat(current) - StringToFloat(candidate)) < 0.0006;
    return StrEqual(current, candidate, false);
}

/* Chinese row label used by the v1.0.5 two-level menu. Falls back to the
 * English label from the parameter table when an index is unknown. */
void CS2U_ParamLabelZh(int idx, char[] out, int maxlen)
{
    if (idx < 0 || idx >= g_iParamCount)
    {
        strcopy(out, maxlen, "(unknown)");
        return;
    }

    char cvar[CS2U_CVAR_LEN];
    strcopy(cvar, sizeof(cvar), g_sParamCvar[idx]);
    if (StrEqual(cvar, "cs2feel_enable"))                       strcopy(out, maxlen, "手感总开关");
    else if (StrEqual(cvar, "cs2feel_recoil_mode"))             strcopy(out, maxlen, "后坐模式（0 原生 / 1 CS2 序列）");
    else if (StrEqual(cvar, "cs2feel_recoil_scale"))            strcopy(out, maxlen, "压枪倍率");
    else if (StrEqual(cvar, "cs2feel_recoil_view_scale"))       strcopy(out, maxlen, "相机倍率");
    else if (StrEqual(cvar, "cs2feel_ballistics_mode"))         strcopy(out, maxlen, "弹道模式（0 原生 / 1 CS2 抬升）");
    else if (StrEqual(cvar, "cs2feel_ballistics_scale"))        strcopy(out, maxlen, "弹道倍率（负值 = 分离）");
    else if (StrEqual(cvar, "cs2feel_ballistics_yaw"))          strcopy(out, maxlen, "弹道垂直摆动");
    else if (StrEqual(cvar, "cs2feel_spread_mode"))             strcopy(out, maxlen, "散布模式（0 直通 / 1 临时）");
    else if (StrEqual(cvar, "cs2feel_spread_scale"))            strcopy(out, maxlen, "散布倍率");
    else if (StrEqual(cvar, "cs2feel_spread_move"))             strcopy(out, maxlen, "散布移动项");
    else if (StrEqual(cvar, "cs2feel_spread_posture"))          strcopy(out, maxlen, "散布姿态项");
    else if (StrEqual(cvar, "cs2u_bmode"))                      strcopy(out, maxlen, "弹道轨迹模式");
    else if (StrEqual(cvar, "cs2movement_enable"))              strcopy(out, maxlen, "移动总开关");
    else if (StrEqual(cvar, "cs2movement_apply_global"))        strcopy(out, maxlen, "全局 sv_* 层");
    else if (StrEqual(cvar, "cs2movement_engine_speed"))        strcopy(out, maxlen, "逐人引擎速度");
    else if (StrEqual(cvar, "cs2movement_duck_speed"))          strcopy(out, maxlen, "逐人蹲速");
    else if (StrEqual(cvar, "cs2movement_air_jump_speed"))      strcopy(out, maxlen, "CS2 空中速度（可选）");
    else if (StrEqual(cvar, "cs2movement_lowspeed_sustain"))    strcopy(out, maxlen, "低速维持（可选）");
    else if (StrEqual(cvar, "cs2movement_crouch_slide"))        strcopy(out, maxlen, "蹲下滑行（可选）");
    else if (StrEqual(cvar, "cs2movement_crouch_slide_client")) strcopy(out, maxlen, "客户端滑行（全局副作用）");
    else if (StrEqual(cvar, "cs2movement_crouch_slide_time"))   strcopy(out, maxlen, "滑行衰减时间");
    else if (StrEqual(cvar, "cs2movement_crouch_slide_min_speed")) strcopy(out, maxlen, "滑行最低启动速度");
    else if (StrEqual(cvar, "cs2movement_crouch_enable"))       strcopy(out, maxlen, "蹲下模型");
    else if (StrEqual(cvar, "cs2movement_maxspeed"))            strcopy(out, maxlen, "逐人速度上限");
    else if (StrEqual(cvar, "cs2movement_weapon_speed_mode"))   strcopy(out, maxlen, "武器速度表（1 CS2 / 0 原生）");
    else if (StrEqual(cvar, "cs2movement_duck_speed_min"))      strcopy(out, maxlen, "蹲速下限（0 关闭）");
    else if (StrEqual(cvar, "cs2movement_base_speed"))          strcopy(out, maxlen, "兜底速度（未映射武器）");
    else if (StrEqual(cvar, "cs2movement_injury_enable"))       strcopy(out, maxlen, "受伤减速");
    else if (StrEqual(cvar, "cs2movement_injury_mode"))         strcopy(out, maxlen, "受伤模式（1 比例 / 0 绝对值）");
    else if (StrEqual(cvar, "cs2movement_injury_health"))       strcopy(out, maxlen, "踉跄血量阈值（0 引擎）");
    else if (StrEqual(cvar, "cs2movement_injury_speed"))        strcopy(out, maxlen, "受伤速度（u/s；0 引擎）");
    else if (StrEqual(cvar, "cs2movement_injury_base"))         strcopy(out, maxlen, "健康基准速度（比例）");
    else if (StrEqual(cvar, "cs2movement_injury_temp_health"))  strcopy(out, maxlen, "计入临时生命");
    else if (StrEqual(cvar, "cs2movement_injury_adrenaline"))   strcopy(out, maxlen, "肾上腺素豁免");
    else if (StrEqual(cvar, "cs2movement_water_enable"))        strcopy(out, maxlen, "水面减速");
    else if (StrEqual(cvar, "cs2movement_water_slowdown"))      strcopy(out, maxlen, "水面减速强度（眼深）");
    else if (StrEqual(cvar, "cs2u_tracer_enable"))              strcopy(out, maxlen, "曳光 / 弹道光束");
    else if (StrEqual(cvar, "cs2u_tracer_width"))               strcopy(out, maxlen, "曳光宽度");
    else if (StrEqual(cvar, "cs2u_tracer_life"))                strcopy(out, maxlen, "曳光存活时间");
    else                                                        strcopy(out, maxlen, g_sParamLabel[idx]);
}

/* Display value with Chinese bools (开/关). */
void CS2U_ParamValueZh(int idx, char[] out, int maxlen)
{
    CS2U_ParamDisplay(idx, out, maxlen);
    if (idx >= 0 && idx < g_iParamCount && g_iParamType[idx] == PARAM_TYPE_BOOL)
        strcopy(out, maxlen, StrEqual(out, "On") ? "开" : "关");
}
