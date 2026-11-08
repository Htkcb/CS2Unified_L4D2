/**
 * cs2feel_spread.sp -- MOD-2: AL-2 spread state machine.
 *
 * WHAT THIS FILE IS
 *   The M4 skeleton's authoritative spread layer.  It owns one float state per
 *   weapon entity and, when enabled, writes that state into the L4D2 accumulator
 *   at [weapon + 0x17EC] (TV-18: bare offset, engine consumes it; NOT a datamap
 *   field, NOT a netprop).  In the default mode it writes nothing at all.
 *
 * MODES (cs2feel_spread_mode)
 *   0 = PASSTHROUGH (default, M4 exit criterion)
 *       No reads, no writes, no state changes.  The plugin must not perturb the
 *       native spread trajectory; tools/m4_probe proves bit-identical values
 *       against the archived native run.
 *   1 = PROFILE (CS2-profile state machine, calibrated by TV-41)
 *       The plugin computes its own spread:
 *         floor  = config inaccuracy_stand
 *         on shot: s = min(cap, s + inaccuracy_fire * spread_scale)
 *         per cmd: s = floor + (s - floor) * exp(-ln2 * dt / t50)
 *         clamp:   floor <= s <= cap
 *
 *       UNITS (TR-27, TV-41 -- read this before touching weapons.cfg):
 *       every value this module reads, keeps and writes is in L4D2 **field
 *       units**, i.e. the native scale of [weapon + 0x17EC] (measured native
 *       range 0.29 .. 2.50, TV-29/TV-22).  CS2's VData/penalty numbers are in a
 *       different unit; the measured conversion is k = 45.5 field units per
 *       CS2 penalty unit (TV-41, 95% band 39.2 .. 58.3).  The M4 first version
 *       pasted CS2 units straight into the field, so mode 1 produced ~0.006 ..
 *       0.05 field units instead of ~0.18 deg of spread -- a 45.5x error
 *       (TR-27).  Do NOT paste CS2 inaccuracy_* numbers here again.
 *
 *       t50 is the TV-14 measured half-life (0.28125 s).  The increment is a
 *       constant fit to the 30-shot CS2 trajectory (TV-41: 0.1744 field units,
 *       MAPE 3.2%); CS2's own per-shot increment is not constant, so a scalar
 *       increment cannot match both the first shot and saturation exactly.
 *       Do not describe mode 1 as "CS2-equivalent" in any report.
 *       Only weapons with a verified config mapping are written; unmapped
 *       weapons stay native (getter returns "not found" -> no write).
 *
 *
 * POSTURE TERM (cs2feel_spread_posture, TR-28; default 0 = off)
 *   When enabled, the floor written by mode 1 is scaled per posture:
 *     stand -> 1.0, duck -> cs2feel_spread_duck_floor_scale,
 *     air/fall/jump -> cs2feel_spread_air_floor_scale.
 *   Posture comes from the client's own FL_ONGROUND / FL_DUCKING bits, the same
 *   flags the TV-47 probe used as its acceptance condition.
 *   Why a FLOOR scale and not a value scale: the engine consumes the written
 *   field through an AFFINE law, s_eff = 0.776 * w + b_posture (TV-53; it is NOT
 *   a pure multiplier), so a CS2 per-posture inaccuracy floor has to be mapped
 *   through that law -- the accumulated fire penalty must keep its standing
 *   weight.  K_posture is solved so the engine-consumed total equals
 *   J * floor_stand + accum (TV-55: duck 1.81, air 23.74 for the AK-47).  The
 *   default scale is 1.0, so the TV-45 mode-1 calibration is untouched until a
 *   run sets the ConVars.
 *
 * MOVEMENT TERM (cs2feel_spread_move, TR-29 / TV-57; default 0 = off)
 *   TV-57 measured that mode 1 leaves only 3.4% of the native speed-induced
 *   yaw variance; at 173 u/s the spread is 17.6% of the CS2 TV-20 target.
 *   When enabled, the floor is multiplied by a speed ramp: 1.0 at/below the
 *   onset (default 73 u/s), `step` just above it, `max` at full speed (default
 *   215 u/s).  This is a FLOOR scale, like the posture term: the shared
 *   accumulated fire increment is not scaled.  Speed comes from the datamap
 *   m_vecVelocity (L4D2 has no send-prop variant, TV-57).  Disabled -> 1.0,
 *   so the TV-45 standing calibration is bit-identical.
 *
 * TICKRATE PROFILE (cs2feel_spread_tick_profile, TR-31 / TV-60..TV-62; default 0)
 *   The 30 Hz calibration does NOT transfer to 60 Hz: TV-60 measured stand
 *   -14.44%, duck +35.44% and a reversed posture order at 60 tick, because the
 *   engine's affine consumption law (TV-53) has A bound to the shot cadence.
 *   TV-61/TV-62 re-calibrated the 60 Hz profile to K_duck 0.43 / K_air 18.8 with
 *   the floor AND increment scaled by 1.17, landing within 1.6% of the 30 Hz
 *   absolute targets.  This module carries both calibrated profiles:
 *     30 Hz: floor x1.00, increment x1.00, duck 1.81,  air 23.74  (TV-56)
 *     60 Hz: floor x1.17, increment x1.17, duck 0.43,  air 18.80  (TV-62)
 *   Selection (cs2feel_spread_tick_profile):
 *     0 = off   -- use the ConVars exactly as before (bit-identical default path)
 *     1 = auto  -- resolve from GetTickInterval(); ONLY 30 and 60 Hz are known
 *     2 = force 30-tick profile
 *     3 = force 60-tick profile
 *   AUTO deliberately refuses every other rate (64/100 Hz included): 100 tick is
 *   unmeasured on this machine (TV-60 limitation), so guessing a profile would be
 *   worse than leaving the operator's ConVars in place.  The profile only affects
 *   mode 1; in mode 0 nothing is read and nothing is written.
 *
 * SAFETY / TIMING
 *   All work happens inside CS2F_OnPlayerRunCmd (the only callback shape that survived
 *   map load, pitfall M21 / TV-31).  No timers, no OnMapStart, no entity caching
 *   across ticks; every write re-validates the entity and only touches the local
 *   player's own weapon.  Entity index arrays are reset when a weapon entity is
 *   first seen, when the active weapon changes, or when the clip increases
 *   (reload), so a recycled edict cannot inherit stale state.
 *
 * ASCII only on purpose.
 */

#if defined _cs2feel_spread_included
 #endinput
#endif
#define _cs2feel_spread_included

#define CS2F_SPREAD_OFFSET     6124          /* 0x17EC, IM-41 gamedata */
#define CS2F_SPREAD_MAXENTS    2048          /* L4D2 edict budget */
#define CS2F_SPREAD_MODE_OFF   0
#define CS2F_SPREAD_MODE_ON    1
#define CS2F_SPREAD_DEFAULT_T50 0.28125      /* TV-14 measured, seconds */

/* Posture indices (TV-47..TV-52 / TR-28).  AIR is chosen whenever FL_ONGROUND
   is clear, which deliberately also covers jumping and falling. */
#define CS2F_SPREAD_POSTURE_STAND  0
#define CS2F_SPREAD_POSTURE_DUCK   1
#define CS2F_SPREAD_POSTURE_AIR    2

/* Tickrate profile selector (TR-31 / TV-60..TV-62).  The selector values are
   operator-facing (cs2feel_spread_tick_profile); the profile values are the
   resolved profile carried by the module (0 = none). */
#define CS2F_PROFILE_SELECT_OFF   0
#define CS2F_PROFILE_SELECT_AUTO  1
#define CS2F_PROFILE_SELECT_30    2
#define CS2F_PROFILE_SELECT_60    3
#define CS2F_PROFILE_SELECT_64    4
#define CS2F_PROFILE_NONE         0
#define CS2F_PROFILE_30           30
#define CS2F_PROFILE_60           60
#define CS2F_PROFILE_64           64

float g_fSpreadValue[CS2F_SPREAD_MAXENTS];
float g_fSpreadLastTime[CS2F_SPREAD_MAXENTS];
int   g_iSpreadLastClip[CS2F_SPREAD_MAXENTS];
int   g_iSpreadWeaponId[CS2F_SPREAD_MAXENTS];
bool  g_bSpreadSeen[CS2F_SPREAD_MAXENTS];

int   g_iSpreadMode = CS2F_SPREAD_MODE_OFF;
float g_fSpreadScale = 1.0;
float g_fSpreadT50 = CS2F_SPREAD_DEFAULT_T50;

/* Posture term (TR-28).  Disabled by default: the whole posture path is a no-op
   unless cs2feel_spread_posture is 1, so mode 1 keeps its TV-45 behaviour. */
bool  g_bSpreadPosture = false;
float g_fSpreadDuckFloorScale = 1.0;
float g_fSpreadAirFloorScale = 1.0;

/* Movement term (TR-29, TV-57).  The engine's native speed -> spread term is
   almost entirely replaced by our written floor, so MOD-2 restores it as a
   speed-dependent floor multiplier:
       speed <= onset          -> 1.0 (standing calibration untouched)
       onset < speed < full    -> step + f*(max - step), f=(speed-onset)/(full-onset)
       speed >= full           -> max
   This is a FLOOR scale, like the posture term: the per-shot increment (the
   shared accumulated fire penalty) is not scaled.  Disabled by default. */
bool  g_bSpreadMove = false;
float g_fSpreadMoveStep = 1.0;
float g_fSpreadMoveMax = 1.0;
float g_fSpreadMoveOnset = 73.0;
float g_fSpreadMoveFull = 215.0;

/* Tickrate profile (TR-31).  g_iSpreadProfile is 0 (off), 30 or 60; the four
   scalars are the profile's calibrated values.  A negative duck/air scale means
   "no profile override" -> the ConVar value is used (profile off). */
int   g_iSpreadProfile = CS2F_PROFILE_NONE;
float g_fSpreadProfileFloorScale = 1.0;
float g_fSpreadProfileIncScale = 1.0;
float g_fSpreadProfileDuckScale = -1.0;
float g_fSpreadProfileAirScale = -1.0;

/* ---- pure model (unit-tested by sm_cs2feel_spreadtest) -------------------- */

/**
 * One shot: additive increment, clamped at the cap.
 * Returns the new value; a negative/zero increment still clamps to cap.
 */
stock float CS2F_SpreadModel_OnShot(float value, float increment, float cap)
{
    value += increment;
    if (value > cap)
        value = cap;
    return value;
}

/**
 * One command of exponential recovery toward the floor, half-life t50 seconds.
 * dt <= 0 is a no-op; t50 <= 0 snaps to the floor.  Never goes below the floor.
 */
stock float CS2F_SpreadModel_Decay(float value, float floor, float dt, float t50)
{
    if (dt <= 0.0)
        return (value < floor) ? floor : value;

    if (t50 <= 0.0)
        return floor;

    value = floor + (value - floor) * Exponential(-0.6931471805599453 * dt / t50);
    if (value < floor)
        value = floor;
    return value;
}

stock float CS2F_SpreadModel_Clamp(float value, float floor, float cap)
{
    if (value < floor)
        value = floor;
    if (value > cap)
        value = cap;
    return value;
}

stock bool CS2F_SpreadModel_Writes(int mode)
{
    return mode == CS2F_SPREAD_MODE_ON;
}

/**
 * Posture selector, identical to the probe's acceptance flags (on_ground /
 * ducking, TV-47).  No ground contact at all is AIR: jumping and falling both
 * take the air floor, so a jump cannot read as STAND between two commands.
 */
stock int CS2F_SpreadPostureFromFlags(int flags)
{
    if ((flags & FL_ONGROUND) == 0)
        return CS2F_SPREAD_POSTURE_AIR;
    if ((flags & FL_DUCKING) != 0)
        return CS2F_SPREAD_POSTURE_DUCK;
    return CS2F_SPREAD_POSTURE_STAND;
}

/**
 * Floor multiplier for one posture.  Disabled -> 1.0 (bit-identical TV-45 path).
 * Non-positive configured scales are ignored (never invert the floor).
 */
stock float CS2F_SpreadPostureFloorScale(int posture, bool enabled, float duckScale, float airScale)
{
    if (!enabled)
        return 1.0;
    if (posture == CS2F_SPREAD_POSTURE_DUCK)
        return (duckScale > 0.0) ? duckScale : 1.0;
    if (posture == CS2F_SPREAD_POSTURE_AIR)
        return (airScale > 0.0) ? airScale : 1.0;
    return 1.0;
}

/**
 * Movement floor multiplier for one horizontal speed.  Disabled (or at/below
 * the onset) -> 1.0, so the TV-45 standing calibration is untouched.  The ramp
 * starts at `step` just above the onset and reaches `maxScale` at `full`.
 * out-of-range inputs are sanitized; the result is never below 1.0.
 */
stock float CS2F_SpreadMoveFloorScale(float speed, bool enabled,
                                      float step, float maxScale,
                                      float onset, float full)
{
    if (!enabled)
        return 1.0;
    if (speed <= onset)
        return 1.0;

    float span = (full > onset) ? (full - onset) : 1.0;
    float f = (speed - onset) / span;
    if (f > 1.0)
        f = 1.0;
    if (f < 0.0)
        f = 0.0;

    float scale = step + f * (maxScale - step);
    if (scale < 1.0)
        scale = 1.0;
    return scale;
}

/**
 * Resolve the operator selector against the measured tick rate.  Three rates
 * have a calibrated profile: 30 Hz (TV-56), 60 Hz (TV-62) and 64 Hz (TR-51 /
 * 2026-10-25, calibrated against the L7 weapon-script fire rate).  AUTO returns
 * NONE for every other rate on purpose: 100 tick is unmeasured, so the module
 * must keep the operator's ConVars instead of inventing a profile.
 */
stock int CS2F_SpreadProfileResolve(float tickrate, int requested)
{
    if (requested == CS2F_PROFILE_SELECT_30)
        return CS2F_PROFILE_30;
    if (requested == CS2F_PROFILE_SELECT_60)
        return CS2F_PROFILE_60;
    if (requested == CS2F_PROFILE_SELECT_64)
        return CS2F_PROFILE_64;
    if (requested != CS2F_PROFILE_SELECT_AUTO)
        return CS2F_PROFILE_NONE;

    if (tickrate >= 28.5 && tickrate <= 31.5)
        return CS2F_PROFILE_30;
    if (tickrate > 63.5 && tickrate <= 65.5)
        return CS2F_PROFILE_64;
    if (tickrate >= 57.0 && tickrate <= 63.5)
        return CS2F_PROFILE_60;
    return CS2F_PROFILE_NONE;
}

/**
 * The two calibrated profiles.  Values are the measured ones: 30 Hz from
 * TV-56 (floor/increment untouched, K_duck 1.81 / K_air 23.74) and 60 Hz from
 * TV-62 (floor AND increment x1.17, K_duck 0.43 / K_air 18.8).  NONE returns
 * neutral scales and negative K overrides, i.e. the pre-profile behaviour.
 */
stock void CS2F_SpreadProfileValues(int profile, float &floorScale, float &incScale,
                                    float &duckScale, float &airScale)
{
    if (profile == CS2F_PROFILE_30)
    {
        floorScale = 1.0;
        incScale = 1.0;
        duckScale = 1.81;
        airScale = 23.74;
        return;
    }
    if (profile == CS2F_PROFILE_60)
    {
        floorScale = 1.17;
        incScale = 1.17;
        duckScale = 0.43;
        airScale = 18.8;
        return;
    }
    if (profile == CS2F_PROFILE_64)
    {
        /* TR-51: measured at 64 Hz with the L7 weapon-script fire rate
           (CycleTime 0.1 s -> 6 ticks at 64 Hz).  Calibrated 2026-10-25. */
        floorScale = 1.085;
        incScale = 1.085;
        duckScale = 0.96;
        airScale = 19.1;
        return;
    }
    floorScale = 1.0;
    incScale = 1.0;
    duckScale = -1.0;
    airScale = -1.0;
}

/* ---- module lifecycle ---------------------------------------------------- */

void CS2F_SpreadInit()
{
    for (int i = 0; i < CS2F_SPREAD_MAXENTS; i++)
    {
        g_fSpreadValue[i] = 0.0;
        g_fSpreadLastTime[i] = 0.0;
        g_iSpreadLastClip[i] = -1;
        g_iSpreadWeaponId[i] = 0;
        g_bSpreadSeen[i] = false;
    }
}

void CS2F_SpreadConfigure(int mode, float scale, float t50)
{
    g_iSpreadMode = (mode == CS2F_SPREAD_MODE_ON) ? CS2F_SPREAD_MODE_ON : CS2F_SPREAD_MODE_OFF;
    g_fSpreadScale = (scale > 0.0) ? scale : 1.0;
    g_fSpreadT50 = (t50 > 0.0) ? t50 : CS2F_SPREAD_DEFAULT_T50;
}

int CS2F_SpreadMode()
{
    return g_iSpreadMode;
}

float CS2F_SpreadT50()
{
    return g_fSpreadT50;
}

void CS2F_SpreadConfigurePosture(bool enabled, float duckScale, float airScale)
{
    g_bSpreadPosture = enabled;
    g_fSpreadDuckFloorScale = (duckScale > 0.0) ? duckScale : 1.0;
    g_fSpreadAirFloorScale = (airScale > 0.0) ? airScale : 1.0;
}

bool CS2F_SpreadPostureOn()
{
    return g_bSpreadPosture;
}

float CS2F_SpreadDuckFloorScale()
{
    return g_fSpreadDuckFloorScale;
}

float CS2F_SpreadAirFloorScale()
{
    return g_fSpreadAirFloorScale;
}

void CS2F_SpreadConfigureMove(bool enabled, float step, float maxScale,
                              float onset, float full)
{
    g_bSpreadMove = enabled;
    g_fSpreadMoveStep = (step >= 1.0) ? step : 1.0;
    g_fSpreadMoveMax = (maxScale >= 1.0) ? maxScale : 1.0;
    g_fSpreadMoveOnset = (onset >= 0.0) ? onset : 0.0;
    g_fSpreadMoveFull = (full > g_fSpreadMoveOnset) ? full : (g_fSpreadMoveOnset + 1.0);
}

bool CS2F_SpreadMoveOn()
{
    return g_bSpreadMove;
}

float CS2F_SpreadMoveStep()
{
    return g_fSpreadMoveStep;
}

float CS2F_SpreadMoveMax()
{
    return g_fSpreadMoveMax;
}

float CS2F_SpreadMoveOnset()
{
    return g_fSpreadMoveOnset;
}

float CS2F_SpreadMoveFull()
{
    return g_fSpreadMoveFull;
}

/* Profile lifecycle (TR-31).  The core resolves the selector + tick rate and
   hands the resolved profile (0 / 30 / 60) to the module. */
void CS2F_SpreadConfigureProfile(int profile)
{
    g_iSpreadProfile = profile;
    CS2F_SpreadProfileValues(profile,
                             g_fSpreadProfileFloorScale, g_fSpreadProfileIncScale,
                             g_fSpreadProfileDuckScale, g_fSpreadProfileAirScale);
}

int CS2F_SpreadProfile()
{
    return g_iSpreadProfile;
}

float CS2F_SpreadProfileFloorScale()
{
    return g_fSpreadProfileFloorScale;
}

float CS2F_SpreadProfileIncScale()
{
    return g_fSpreadProfileIncScale;
}

float CS2F_SpreadProfileDuckScale()
{
    return g_fSpreadProfileDuckScale;
}

float CS2F_SpreadProfileAirScale()
{
    return g_fSpreadProfileAirScale;
}

/* ---- runtime path -------------------------------------------------------- */

/**
 * Called from the core's CS2F_OnPlayerRunCmd for every client command.  In mode 0 it
 * returns immediately (that is the whole M4 regression requirement).
 */
void CS2F_SpreadOnRunCmd(int client)
{
    if (g_iSpreadMode != CS2F_SPREAD_MODE_ON)
        return;

    if (!IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
        return;

    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon <= 0 || weapon >= CS2F_SPREAD_MAXENTS || !IsValidEntity(weapon))
        return;

    char cls[CS2F_CLASS_LEN];
    GetEdictClassname(weapon, cls, sizeof(cls));
    if (StrContains(cls, "weapon_") != 0)
        return;

    int id = CS2F_ConfigWeaponIdByClass(cls);
    if (id <= 0)
        return;                              /* unmapped -> leave native alone */

    float params[CS2F_Param_Count];
    float paramsAlt[CS2F_Param_Count];
    int recoilSeed = 0;
    int spreadSeed = 0;
    if (!CS2F_ConfigGetParams(id, params, paramsAlt, recoilSeed, spreadSeed))
        return;

    int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
    if (clip < 0)
        return;

    float now = GetGameTime();

    /* Posture term (TR-28): the engine consumes our written field through its
       own posture factor, measured as a multiplier on the written value
       (TV-48 duck 0.751 / air 1.997; TV-53 quantifies the consumption model).
       The plugin therefore counter-scales the FLOOR only, which is what a CS2
       per-posture inaccuracy floor is: the accumulated fire penalty must keep
       its standing weight.  Disabled -> scale 1.0 for every posture. */
    int flags = GetEntityFlags(client);
    /* Tickrate profile (TR-31): when a calibrated profile is active it owns the
       duck/air K values; otherwise the ConVars do (negative override = none). */
    float duckScale = (g_fSpreadProfileDuckScale > 0.0)
        ? g_fSpreadProfileDuckScale : g_fSpreadDuckFloorScale;
    float airScale = (g_fSpreadProfileAirScale > 0.0)
        ? g_fSpreadProfileAirScale : g_fSpreadAirFloorScale;
    float postureScale = CS2F_SpreadPostureFloorScale(
        CS2F_SpreadPostureFromFlags(flags),
        g_bSpreadPosture, duckScale, airScale);

    /* Movement term (TR-29).  L4D2 has no Prop_Send m_vecVelocity; the datamap
       variant is the one that exists (TV-57, velmode=2).  Missing the prop only
       disables the term (scale 1.0), never writes a guessed value. */
    float v[3] = {0.0, 0.0, 0.0};
    float speed = 0.0;
    if (HasEntProp(client, Prop_Data, "m_vecVelocity"))
    {
        GetEntPropVector(client, Prop_Data, "m_vecVelocity", v);
        speed = SquareRoot(v[0] * v[0] + v[1] * v[1]);
    }
    /* Ground only: the air floor is already the posture term's K_air (23.74);
       multiplying the two would double-count and explode (TR-29). */
    float moveScale = ((flags & FL_ONGROUND) != 0)
        ? CS2F_SpreadMoveFloorScale(speed, g_bSpreadMove,
                                    g_fSpreadMoveStep, g_fSpreadMoveMax,
                                    g_fSpreadMoveOnset, g_fSpreadMoveFull)
        : 1.0;

    float floorValue = params[CS2F_Param_InaccuracyStand] * postureScale * moveScale
                       * g_fSpreadProfileFloorScale;
    if (floorValue < 0.000001)
        floorValue = 0.000001;

    float cap = 30.0;                        /* native MaxSpread ceiling, v4 3.1 */

    if (!g_bSpreadSeen[weapon] || g_iSpreadWeaponId[weapon] != id)
    {
        g_bSpreadSeen[weapon] = true;
        g_iSpreadWeaponId[weapon] = id;
        /* TV-41: start at OUR floor.  Copying the native accumulator instead
           (the M4 behaviour) lets a weapon first seen mid-burst start hot, and
           the first shots then carry the previous owner's spread. */
        g_fSpreadValue[weapon] = floorValue;
        g_fSpreadLastTime[weapon] = now;
        g_iSpreadLastClip[weapon] = clip;
        return;
    }

    float dt = now - g_fSpreadLastTime[weapon];
    if (dt < 0.0)
        dt = 0.0;

    if (clip > g_iSpreadLastClip[weapon])
    {
        /* reload: back to the floor */
        g_fSpreadValue[weapon] = floorValue;
    }
    else
    {
        g_fSpreadValue[weapon] = CS2F_SpreadModel_Decay(g_fSpreadValue[weapon], floorValue, dt, g_fSpreadT50);
        if (clip < g_iSpreadLastClip[weapon])
        {
            float increment = params[CS2F_Param_InaccuracyFire] * g_fSpreadScale
                              * g_fSpreadProfileIncScale;
            g_fSpreadValue[weapon] = CS2F_SpreadModel_OnShot(g_fSpreadValue[weapon], increment, cap);
        }
    }

    g_fSpreadValue[weapon] = CS2F_SpreadModel_Clamp(g_fSpreadValue[weapon], floorValue, cap);
    g_fSpreadLastTime[weapon] = now;
    g_iSpreadLastClip[weapon] = clip;

    SetEntDataFloat(weapon, CS2F_SPREAD_OFFSET, g_fSpreadValue[weapon], true);
}

/* ---- deterministic self-test (unit tests for the pure model) ------------- */

void CS2F_SelfTestAppend(char[] buffer, int maxlen, const char[] fmt, any ...)
{
    char part[128];
    VFormat(part, sizeof(part), fmt, 4);
    StrCat(buffer, maxlen, part);
}



/**
 * sm_cs2feel_spreadtest -- runs fixed vectors through the pure model and prints
 * one SPREADTEST line.  No entity access, no config dependency, deterministic.
 * Returns the number of failures (0 = pass).
 */
int CS2F_SpreadSelfTest(char[] report, int maxlen)
{
    const float FLOOR = 0.0064;
    const float T50 = 0.28;
    const float EPS = 1.0e-6;

    int checks = 0;
    int fails = 0;
    char detail[512];
    detail[0] = '\0';

    /* 1: three additive shots */
    float s = FLOOR;
    for (int i = 0; i < 3; i++)
        s = CS2F_SpreadModel_OnShot(s, 0.01, 1.0);
    checks++;
    if (FloatAbs(s - (FLOOR + 0.03)) > EPS)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "shot_add(%.6f) ", s);
    }

    /* 2: cap */
    checks++;
    s = CS2F_SpreadModel_OnShot(0.99, 0.02, 1.0);
    if (FloatAbs(s - 1.0) > EPS)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "cap(%.6f) ", s);
    }

    /* 3: one half-life halves the distance to the floor */
    checks++;
    s = CS2F_SpreadModel_Decay(FLOOR + 0.03, FLOOR, T50, T50);
    if (FloatAbs(s - (FLOOR + 0.015)) > EPS)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "t50(%.6f) ", s);
    }

    /* 4: long decay reaches the floor (not below) */
    checks++;
    s = CS2F_SpreadModel_Decay(FLOOR + 0.03, FLOOR, 60.0, T50);
    if (FloatAbs(s - FLOOR) > EPS)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "floor(%.9f) ", s);
    }

    /* 5: dt <= 0 is a no-op */
    checks++;
    s = CS2F_SpreadModel_Decay(0.5, FLOOR, 0.0, T50);
    if (FloatAbs(s - 0.5) > EPS)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "dt0(%.6f) ", s);
    }

    /* 6: t50 <= 0 snaps to the floor */
    checks++;
    s = CS2F_SpreadModel_Decay(0.5, FLOOR, 0.1, 0.0);
    if (FloatAbs(s - FLOOR) > EPS)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "t50zero(%.6f) ", s);
    }

    /* 7: clamp below floor */
    checks++;
    s = CS2F_SpreadModel_Clamp(0.001, FLOOR, 1.0);
    if (FloatAbs(s - FLOOR) > EPS)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "clamp_lo(%.6f) ", s);
    }

    /* 8: clamp above cap */
    checks++;
    s = CS2F_SpreadModel_Clamp(2.0, FLOOR, 1.0);
    if (FloatAbs(s - 1.0) > EPS)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "clamp_hi(%.6f) ", s);
    }

    /* 9: scale enters through the caller (increment is already scaled) */
    checks++;
    s = CS2F_SpreadModel_OnShot(FLOOR, 0.01 * 0.5, 1.0);
    if (FloatAbs(s - (FLOOR + 0.005)) > EPS)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "scale(%.6f) ", s);
    }

    /* 10: mode gate */
    checks++;
    if (CS2F_SpreadModel_Writes(CS2F_SPREAD_MODE_OFF) || !CS2F_SpreadModel_Writes(CS2F_SPREAD_MODE_ON))
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "mode_gate ");
    }

    Format(report, maxlen, "SPREADTEST %s checks=%d fails=%d %s",
           (fails == 0) ? "PASS" : "FAIL", checks, fails, detail);
    return fails;
}

/**
 * sm_cs2feel_spreadtest also runs this: the posture selector and the floor-scale
 * gate, deterministic, no entity/config access.  Kept separate from SPREADTEST so
 * the archived M4 count (checks=10) stays a valid regression anchor.
 */
int CS2F_SpreadPostureSelfTest(char[] report, int maxlen)
{
    int checks = 0;
    int fails = 0;
    char detail[512];
    detail[0] = '\0';

    /* 1: no ground contact -> AIR */
    checks++;
    if (CS2F_SpreadPostureFromFlags(0) != CS2F_SPREAD_POSTURE_AIR)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "flags_air ");
    }

    /* 2: grounded, not ducking -> STAND */
    checks++;
    if (CS2F_SpreadPostureFromFlags(FL_ONGROUND) != CS2F_SPREAD_POSTURE_STAND)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "flags_stand ");
    }

    /* 3: grounded + ducking -> DUCK */
    checks++;
    if (CS2F_SpreadPostureFromFlags(FL_ONGROUND | FL_DUCKING) != CS2F_SPREAD_POSTURE_DUCK)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "flags_duck ");
    }

    /* 4: air wins over ducking (jump while holding duck) */
    checks++;
    if (CS2F_SpreadPostureFromFlags(FL_DUCKING) != CS2F_SPREAD_POSTURE_AIR)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "flags_air_duck ");
    }

    /* 5: disabled -> 1.0 for every posture */
    checks++;
    if (FloatAbs(CS2F_SpreadPostureFloorScale(CS2F_SPREAD_POSTURE_STAND, false, 4.0, 9.0) - 1.0) > 1.0e-6
        || FloatAbs(CS2F_SpreadPostureFloorScale(CS2F_SPREAD_POSTURE_DUCK, false, 4.0, 9.0) - 1.0) > 1.0e-6
        || FloatAbs(CS2F_SpreadPostureFloorScale(CS2F_SPREAD_POSTURE_AIR, false, 4.0, 9.0) - 1.0) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "disabled ");
    }

    /* 6: enabled stand stays 1.0 */
    checks++;
    if (FloatAbs(CS2F_SpreadPostureFloorScale(CS2F_SPREAD_POSTURE_STAND, true, 2.0, 9.0) - 1.0) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "stand_one ");
    }

    /* 7: enabled duck uses the duck scale, not the air one */
    checks++;
    if (FloatAbs(CS2F_SpreadPostureFloorScale(CS2F_SPREAD_POSTURE_DUCK, true, 2.0, 9.0) - 2.0) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "duck_scale ");
    }

    /* 8: enabled air uses the air scale, not the duck one */
    checks++;
    if (FloatAbs(CS2F_SpreadPostureFloorScale(CS2F_SPREAD_POSTURE_AIR, true, 2.0, 9.0) - 9.0) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "air_scale ");
    }

    /* 9: non-positive duck scale sanitizes to 1.0 */
    checks++;
    if (FloatAbs(CS2F_SpreadPostureFloorScale(CS2F_SPREAD_POSTURE_DUCK, true, 0.0, 9.0) - 1.0) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "duck_bad ");
    }

    /* 10: negative air scale sanitizes to 1.0 */
    checks++;
    if (FloatAbs(CS2F_SpreadPostureFloorScale(CS2F_SPREAD_POSTURE_AIR, true, 2.0, -5.0) - 1.0) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "air_bad ");
    }

    Format(report, maxlen, "POSTURETEST %s checks=%d fails=%d %s",
           (fails == 0) ? "PASS" : "FAIL", checks, fails, detail);
    return fails;
}

/**
 * sm_cs2feel_spreadtest also runs this: the movement floor ramp, deterministic,
 * no entity/config access.  Eight fixed vectors; kept separate from SPREADTEST
 * and POSTURETEST so their archived check counts stay valid regression anchors.
 */
int CS2F_SpreadMoveSelfTest(char[] report, int maxlen)
{
    int checks = 0;
    int fails = 0;
    char detail[512];
    detail[0] = '\0';

    /* 1: disabled -> 1.0 everywhere */
    checks++;
    if (FloatAbs(CS2F_SpreadMoveFloorScale(180.0, false, 2.0, 10.0, 100.0, 200.0) - 1.0) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "disabled ");
    }

    /* 2: exactly at the onset -> 1.0 */
    checks++;
    if (FloatAbs(CS2F_SpreadMoveFloorScale(100.0, true, 2.0, 10.0, 100.0, 200.0) - 1.0) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "onset ");
    }

    /* 3: below the onset -> 1.0 */
    checks++;
    if (FloatAbs(CS2F_SpreadMoveFloorScale(50.0, true, 2.0, 10.0, 100.0, 200.0) - 1.0) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "below ");
    }

    /* 4: midpoint -> step + 0.5*(max-step) = 6.0 */
    checks++;
    if (FloatAbs(CS2F_SpreadMoveFloorScale(150.0, true, 2.0, 10.0, 100.0, 200.0) - 6.0) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "mid ");
    }

    /* 5: at full speed -> max */
    checks++;
    if (FloatAbs(CS2F_SpreadMoveFloorScale(200.0, true, 2.0, 10.0, 100.0, 200.0) - 10.0) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "full ");
    }

    /* 6: above full -> max (no overshoot) */
    checks++;
    if (FloatAbs(CS2F_SpreadMoveFloorScale(400.0, true, 2.0, 10.0, 100.0, 200.0) - 10.0) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "over ");
    }

    /* 7: maxScale = 1 -> 1.0 (a move term can never tighten the floor) */
    checks++;
    if (FloatAbs(CS2F_SpreadMoveFloorScale(180.0, true, 1.0, 1.0, 100.0, 200.0) - 1.0) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "one ");
    }

    /* 8: onset >= full is sanitized to full=onset+1 (f clamps to 1) */
    checks++;
    if (FloatAbs(CS2F_SpreadMoveFloorScale(250.0, true, 2.0, 6.0, 200.0, 100.0) - 6.0) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "span ");
    }

    Format(report, maxlen, "MOVETEST %s checks=%d fails=%d %s",
           (fails == 0) ? "PASS" : "FAIL", checks, fails, detail);
    return fails;
}

/**
 * sm_cs2feel_spreadtest also runs this: the tickrate profile selector and the
 * two calibrated value sets (TR-31 / TV-60..TV-62).  Deterministic, no entity or
 * ConVar access.  Kept separate from SPREADTEST/POSTURETEST/MOVETEST so their
 * archived check counts stay valid regression anchors.
 */
int CS2F_SpreadProfileSelfTest(char[] report, int maxlen)
{
    int checks = 0;
    int fails = 0;
    char detail[512];
    detail[0] = '\0';

    /* 1: AUTO at 30 Hz -> 30-tick profile */
    checks++;
    if (CS2F_SpreadProfileResolve(30.0, CS2F_PROFILE_SELECT_AUTO) != CS2F_PROFILE_30)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "auto30 ");
    }

    /* 2: AUTO at 60 Hz -> 60-tick profile */
    checks++;
    if (CS2F_SpreadProfileResolve(60.0, CS2F_PROFILE_SELECT_AUTO) != CS2F_PROFILE_60)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "auto60 ");
    }

    /* 3: AUTO at 100 Hz -> none (unmeasured, never guess) */
    checks++;
    if (CS2F_SpreadProfileResolve(100.0, CS2F_PROFILE_SELECT_AUTO) != CS2F_PROFILE_NONE)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "auto100 ");
    }

    /* 4: AUTO at 64 Hz -> 64-tick profile (TR-51, calibrated with the L7 fire rate) */
    checks++;
    if (CS2F_SpreadProfileResolve(64.0, CS2F_PROFILE_SELECT_AUTO) != CS2F_PROFILE_64)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "auto64 ");
    }

    /* 5: forced 60 wins over the measured 30 Hz */
    checks++;
    if (CS2F_SpreadProfileResolve(30.0, CS2F_PROFILE_SELECT_60) != CS2F_PROFILE_60)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "force60 ");
    }

    /* 6: off -> none even at 60 Hz */
    checks++;
    if (CS2F_SpreadProfileResolve(60.0, CS2F_PROFILE_SELECT_OFF) != CS2F_PROFILE_NONE)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "off ");
    }

    /* 7: 60-tick values are the TV-62 calibration */
    float f60, i60, d60, a60;
    CS2F_SpreadProfileValues(CS2F_PROFILE_60, f60, i60, d60, a60);
    checks++;
    if (FloatAbs(f60 - 1.17) > 1.0e-6 || FloatAbs(i60 - 1.17) > 1.0e-6
        || FloatAbs(d60 - 0.43) > 1.0e-6 || FloatAbs(a60 - 18.8) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "values60 ");
    }

    /* 8: 30-tick values are the TV-56 calibration */
    float f30, i30, d30, a30;
    CS2F_SpreadProfileValues(CS2F_PROFILE_30, f30, i30, d30, a30);
    checks++;
    if (FloatAbs(f30 - 1.0) > 1.0e-6 || FloatAbs(i30 - 1.0) > 1.0e-6
        || FloatAbs(d30 - 1.81) > 1.0e-6 || FloatAbs(a30 - 23.74) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "values30 ");
    }

    /* 9: NONE is neutral (1.0 scales, negative overrides -> ConVars) */
    float f0, i0, d0, a0;
    CS2F_SpreadProfileValues(CS2F_PROFILE_NONE, f0, i0, d0, a0);
    checks++;
    if (FloatAbs(f0 - 1.0) > 1.0e-6 || FloatAbs(i0 - 1.0) > 1.0e-6
        || d0 >= 0.0 || a0 >= 0.0)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "values_none ");
    }

    /* 10: 60-tick floor scale x 0.2917 reproduces TV-62's deployed 0.341289 */
    checks++;
    if (FloatAbs(0.2917 * f60 - 0.341289) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "floor60 ");
    }

    /* 11: forced 64 wins over the measured 30 Hz */
    checks++;
    if (CS2F_SpreadProfileResolve(30.0, CS2F_PROFILE_SELECT_64) != CS2F_PROFILE_64)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "force64 ");
    }

    /* 12: 64-tick values are the TR-51 calibration */
    float f64, i64, d64, a64;
    CS2F_SpreadProfileValues(CS2F_PROFILE_64, f64, i64, d64, a64);
    checks++;
    if (FloatAbs(f64 - 1.085) > 1.0e-6 || FloatAbs(i64 - 1.085) > 1.0e-6
        || FloatAbs(d64 - 0.96) > 1.0e-6 || FloatAbs(a64 - 19.1) > 1.0e-6)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "values64 ");
    }

    /* 13: 64 Hz band edges: 63.6 -> 64 (E), 66.0 -> none */
    checks++;
    if (CS2F_SpreadProfileResolve(63.6, CS2F_PROFILE_SELECT_AUTO) != CS2F_PROFILE_64
        || CS2F_SpreadProfileResolve(66.0, CS2F_PROFILE_SELECT_AUTO) != CS2F_PROFILE_NONE)
    {
        fails++;
        CS2F_SelfTestAppend(detail, sizeof(detail), "band64 ");
    }

    Format(report, maxlen, "TICKTEST %s checks=%d fails=%d %s",
           (fails == 0) ? "PASS" : "FAIL", checks, fails, detail);
    return fails;
}
