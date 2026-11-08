/**
 * cs2feel_recoil.sp -- MOD-3: per-shot recoil / punch application.
 *
 * WHAT THIS FILE IS
 *   The M5 server-side recoil layer.  It maps the L4D2 shot counter to the archived
 *   CS2 per-shot punch sequence (configs/cs2feel/punch_sequences.cfg) and writes the
 *   corresponding aim-punch vector into the local player's m_vecPunchAngle
 *   (server offset 0x1AB4, TV-27) at the shot event only.
 *
 * WHY AN ABSOLUTE, EVENT-POINT WRITE
 *   TV-28 measured that the native engine adds exactly -VerticalPunch degrees to
 *   m_vecPunchAngle.x on every shot (spread-independent).  The port therefore has to
 *   replace that kick, not add to it: each shot writes the absolute CS2 target for
 *   that shot index, which both cancels the native kick and is idempotent (v4 4.10:
 *   event-point, low-frequency, idempotent writes; never a per-tick fight).  The
 *   engine's own decay is left alone (TV-27) - the client layer is responsible for
 *   presentation (v4 4.9), and R4/client consistency still needs a human client.
 *
 * DUAL-CHANNEL CONTEXT (TV-24 G / TV-81)
 *   CS2 keeps an authoritative aim punch (AimPunchServices) and a camera-supplied
 *   view punch.  TV-81 resolved the 0.055 semantics: the view punch is a per-shot
 *   impulse accumulator (V_n = V_{n-1}*exp(-18*dt) - 0.055*M_n), not 0.055x the
 *   cumulative aim; its steady state for the AK is about 1.2-1.6 deg.  CS2's client
 *   camera adds ONLY that decayed view punch to the eye angles (no aim punch), while
 *   the aim channel (eye + aim punch) drives the shot direction.  L4D2 has only one
 *   punch field and TV-81's human rounds showed the visible bullet decals follow it
 *   (the camera channel), so a server-side cmd offset is INVISIBLE and the plan-B
 *   split (camera 0.055x, bullets 1.0x) was rejected: "seen != hit".  The 0.5.2-m8
 *   compiled defaults are the matched 1.0 pair (TV-82: CS2 aim amplitude anchor;
 *   2.4 was the TV-76 perceptual exaggeration); cs2feel_recoil_view_scale remains a
 *   neutral experimental knob (default 1.0).  This structural mismatch is recorded
 *   in TV-33/TV-81; do not describe the server write as client-equivalent.
 *
 * INDEXING / BOUNDARY
 *   The CS2 spray index is the float m_flRecoilIndex, not an integer shot number: TV-71 measured
 *   that it recovers exponentially after a stop-fire dead time (0.0720 per CS2 tick = 4.61/s,
 *   dead time 7 CS2 ticks = 0.109 s) and that the pattern row is the TRUNCATED float (TV-21
 *   cvttss2si).  A 15 s pause therefore decays the index to 0 and the next shot uses row 0 -- the
 *   legacy integer counter instead continued at row 15 (TR-35, TV-70 G6 FAIL).  This module keeps
 *   a float index: +1.0 per shot, exponential recovery while not firing, row = RoundToZero(index).
 *   The dead time is a ConVar because L4D2 is 30 Hz: its own first fire intervals are 2/4 ticks
 *   (TV-56), so the default 0.133 s (= 4/30 tick) keeps a sustained spray on rows 0..n with no
 *   recovery while still decaying any real pause.
 *
 *   Shot n (1-based, counted from the first clip decrease after deploy/reload) logs as shot n; the
 *   row may differ from (n - 1) after a pause.  Beyond the table the module stops writing and
 *   leaves the native kick alone (no fabricated continuation).  A reload (clip increase) or a
 *   weapon change resets the counter and the index.
 *
 * SAFETY
 *   Only CS2F_OnPlayerRunCmd; no timers, no OnMapStart; only the local player's own punch
 *   field; mode 0 (default) does nothing at all.
 *
 * ASCII only on purpose.
 */

#if defined _cs2feel_recoil_included
 #endinput
#endif
#define _cs2feel_recoil_included

#define CS2F_PUNCH_OFFSET   0x1AB4   /* server: m_vecPunchAngle (TV-27) */
#define CS2F_RECOIL_MODE_OFF 0
#define CS2F_RECOIL_MODE_ON  1

int   g_iRecoilShot[MAXPLAYERS + 1];
int   g_iRecoilWeaponId[MAXPLAYERS + 1];
int   g_iRecoilLastClip[MAXPLAYERS + 1];
bool  g_bRecoilSeen[MAXPLAYERS + 1];

/* TR-35 / TV-71: the CS2 float m_flRecoilIndex and its recovery state. */
float g_fRecoilIndex[MAXPLAYERS + 1];
float g_fRecoilLastShot[MAXPLAYERS + 1];
float g_fRecoilLastUpdate[MAXPLAYERS + 1];

int   g_iRecoilMode = CS2F_RECOIL_MODE_OFF;
float g_fRecoilScale = 1.0;
/* TV-24 / plan B: camera(view) punch scale applied AFTER scale and curve compensation.
   1.0 is the neutral legacy behaviour (0.5.0-m8); 0.055 is the CS2 view punch. */
float g_fRecoilViewScale = 1.0;
bool  g_bRecoilLog = false;
bool  g_bRecoilDecay = true;
float g_fRecoilDecayRate = 4.605;     /* 1/s; CS2 measured 0.0720 per 64 Hz tick (TV-71) */
float g_fRecoilDecayDelay = 0.1334;   /* s; CS2 0.109 s, raised to 4/30 tick for L4D2 (TV-71) */

/* TR-24 camera curve: the L4D2 engine decays the written punch between shots, so an
   absolute per-shot write renders as a spike instead of the CS2 cumulative climb.
   Curve mode pre-emphasises the write so the RENDERED mean over one shot interval
   equals the target (TV-73).  Constants from TV-27: dL/dt = -k*L - r. */
bool  g_bRecoilCurve = false;
float g_fRecoilCurveK = 0.5;    /* 1/s  */
float g_fRecoilCurveR = 20.0;   /* deg/s */
float g_fRecoilCurveMin = 2.0;  /* deg: below this the write stays raw (no spurious kick) */

/* TR-49 / TV-95: replay the measured 64-shot steady cycle under infinite ammo.
   0 keeps the plain row=(shot-1) write (stops past the table, the pre-TR-49 path).
   Default is ON since MT-14 / TV-100: the two-segment table plus the ammo-independent
   shot source (TR-53) make >64 shots replay the CS2 steady cycle; a 30-round magazine
   never reaches row 64, so the normal path is unchanged. */
bool  g_bRecoilWrap = true;

/* TR-53: ammo-independent shot source.  L4D2's sv_infinite_ammo 1 pins m_iClip1
   (TV-96: one value, 30, across 4000 commands), so the clip-decrease detector is
   blind on exactly the servers that need the >64 wrap.  weapon_fire is exact per
   shot (TV-96: 490 events == 490 m_flNextPrimaryAttack edges == IMPACT/2).  The
   source is chosen per command from the server cvar, so the two paths can never
   double count; the clip path stays authoritative on normal servers. */
int   g_iRecoilFired[MAXPLAYERS + 1];   /* weapon_fire events since the last command */

/* ---- pure mapping helpers (unit-tested) --------------------------------- */

/** Shot numbers are 1-based; sequence rows are 0-based. */
stock int CS2F_RecoilRowForShot(int shot)
{
    return shot - 1;
}

stock bool CS2F_RecoilShouldWrite(int row, int count)
{
    return row >= 0 && row < count;
}

stock float CS2F_RecoilScale(float value, float scale)
{
    return value * scale;
}

/** TV-24: the camera(view) channel factor.  1.0 keeps the legacy write bit-identical. */
stock float CS2F_RecoilViewApply(float value, float viewScale)
{
    return value * viewScale;
}

/** CS2 uses cvttss2si on m_flRecoilIndex, i.e. truncation toward zero (TV-21). */
stock int CS2F_RecoilIndexToRow(float index)
{
    if (index <= 0.0)
        return 0;
    return RoundToZero(index);
}

/** One exponential recovery step over dt seconds of decayable (post-delay) time. */
stock float CS2F_RecoilDecay(float index, float dt, float rate)
{
    if (index <= 0.0 || dt <= 0.0 || rate <= 0.0)
        return (index > 0.0) ? index : 0.0;
    float v = index * Exponential(-rate * dt);
    return (v < 0.0001) ? 0.0 : v;
}

/**
 * Decayable time that elapsed between two observations anchored on the last shot.
 * Returns 0 until (observation - lastShot) exceeds the dead time, and only the increment
 * beyond the dead time afterwards (so repeated calls never double-count).
 */
stock float CS2F_RecoilDecayWindow(float lastShot, float lastUpdate, float now, float delay)
{
    float dNow = now - lastShot - delay;
    float dPrev = lastUpdate - lastShot - delay;
    if (dNow <= 0.0)
        return 0.0;
    if (dPrev < 0.0)
        dPrev = 0.0;
    return dNow - dPrev;
}

/** Mean of e^(-k t) over [0, dt] divided by dt (1.0 when there is no decay time). */
stock float CS2F_RecoilCurveMean(float dt, float k)
{
    if (dt <= 0.0 || k <= 0.0)
        return 1.0;
    float x = k * dt;
    if (x < 0.000001)
        return 1.0;
    return (1.0 - Exponential(-x)) / x;
}

/**
 * TR-24 camera curve: pre-emphasised write so the rendered mean over one shot interval
 * equals target.  Decay model (TV-27): L(t) = (L0 + r/k)e^(-k t) - r/k, so the mean is
 * (L0 + r/k)*m - r/k with m = mean factor.  Never writes less than the target (small
 * targets would need a positive offset, which would be a spurious upward punch).
 */
stock float CS2F_RecoilCurveCompensate(float target, float dt, float k, float r, float floorMag)
{
    if (target == 0.0)
        return 0.0;
    if (dt <= 0.0 || k <= 0.0)
        return target;
    float m = CS2F_RecoilCurveMean(dt, k);
    if (m <= 0.0 || m > 1.0)
        return target;
    float eq = r / k;
    float mag = FloatAbs(target);
    if (mag < floorMag)
        return target;
    float comp = (mag + eq) / m - eq;
    if (comp < mag)
        comp = mag;
    float cap = mag * 3.0 + 4.0;
    if (comp > cap)
        comp = cap;
    return (target < 0.0) ? -comp : comp;
}

/* ---- module lifecycle ---------------------------------------------------- */

void CS2F_RecoilInit()
{
    for (int i = 0; i <= MAXPLAYERS; i++)
    {
        g_iRecoilShot[i] = 0;
        g_iRecoilWeaponId[i] = 0;
        g_iRecoilLastClip[i] = -1;
        g_bRecoilSeen[i] = false;
        g_fRecoilIndex[i] = 0.0;
        g_fRecoilLastShot[i] = 0.0;
        g_fRecoilLastUpdate[i] = 0.0;
        g_iRecoilFired[i] = 0;
    }
    HookEventEx("weapon_fire", CS2F_RecoilOnWeaponFire, EventHookMode_Post);
}

/* TR-53: one event per shot; capped so a stalled command loop cannot accumulate. */
public void CS2F_RecoilOnWeaponFire(Handle event, const char[] name, bool dontBroadcast)
{
    if (g_iRecoilMode != CS2F_RECOIL_MODE_ON)
        return;
    int userid = GetEventInt(event, "userid");
    int client = (userid > 0) ? GetClientOfUserId(userid) : 0;
    if (client < 1 || client > MaxClients || IsFakeClient(client))
        return;
    if (g_iRecoilFired[client] < 8)
        g_iRecoilFired[client]++;
}

void CS2F_RecoilConfigure(int mode, float scale, bool logOn, bool decayOn, float rate, float delay,
                          float viewScale)
{
    g_iRecoilMode = (mode == CS2F_RECOIL_MODE_ON) ? CS2F_RECOIL_MODE_ON : CS2F_RECOIL_MODE_OFF;
    g_fRecoilScale = (scale > 0.0) ? scale : 1.0;
    g_fRecoilViewScale = (viewScale >= 0.0) ? viewScale : 1.0;
    g_bRecoilLog = logOn;
    g_bRecoilDecay = decayOn;
    g_fRecoilDecayRate = (rate > 0.0) ? rate : 4.605;
    g_fRecoilDecayDelay = (delay >= 0.0) ? delay : 0.1334;
}

int CS2F_RecoilMode()
{
    return g_iRecoilMode;
}

float CS2F_RecoilScaleValue()
{
    return g_fRecoilScale;
}

float CS2F_RecoilViewScaleValue()
{
    return g_fRecoilViewScale;
}

bool CS2F_RecoilLogEnabled()
{
    return g_bRecoilLog;
}

bool CS2F_RecoilDecayEnabled()
{
    return g_bRecoilDecay;
}

float CS2F_RecoilDecayRateValue()
{
    return g_fRecoilDecayRate;
}

float CS2F_RecoilDecayDelayValue()
{
    return g_fRecoilDecayDelay;
}

void CS2F_RecoilConfigureCurve(bool on, float k, float r, float floorMag)
{
    g_bRecoilCurve = on;
    g_fRecoilCurveK = (k > 0.0) ? k : 0.5;
    g_fRecoilCurveR = (r >= 0.0) ? r : 20.0;
    g_fRecoilCurveMin = (floorMag > 0.0) ? floorMag : 2.0;
}

bool CS2F_RecoilCurveEnabled()
{
    return g_bRecoilCurve;
}

/* TR-49: replay the measured steady cycle instead of stopping past the table. */
void CS2F_RecoilConfigureWrap(bool wrap)
{
    g_bRecoilWrap = wrap;
}

bool CS2F_RecoilWrapEnabled()
{
    return g_bRecoilWrap;
}

float CS2F_RecoilCurveKValue()
{
    return g_fRecoilCurveK;
}

float CS2F_RecoilCurveRValue()
{
    return g_fRecoilCurveR;
}

float CS2F_RecoilCurveMinValue()
{
    return g_fRecoilCurveMin;
}

/* ---- runtime path -------------------------------------------------------- */

void CS2F_RecoilDecayTick(int client, float now)
{
    if (!g_bRecoilDecay || g_fRecoilIndex[client] <= 0.0)
    {
        g_fRecoilLastUpdate[client] = now;
        return;
    }
    float dt = CS2F_RecoilDecayWindow(g_fRecoilLastShot[client], g_fRecoilLastUpdate[client],
                                      now, g_fRecoilDecayDelay);
    if (dt > 0.0)
        g_fRecoilIndex[client] = CS2F_RecoilDecay(g_fRecoilIndex[client], dt, g_fRecoilDecayRate);
    g_fRecoilLastUpdate[client] = now;
}

void CS2F_RecoilOnRunCmd(int client)
{
    if (g_iRecoilMode != CS2F_RECOIL_MODE_ON)
        return;

    if (client < 1 || client > MaxClients)
        return;
    if (!IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
        return;

    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon <= 0 || !IsValidEntity(weapon))
        return;

    char cls[CS2F_CLASS_LEN];
    GetEdictClassname(weapon, cls, sizeof(cls));
    if (StrContains(cls, "weapon_") != 0)
        return;

    int id = CS2F_ConfigWeaponIdByClass(cls);
    if (id <= 0)
    {
        g_iRecoilFired[client] = 0;          /* TR-53: do not leak events into a mapped weapon */
        return;                              /* unmapped -> native kick remains */
    }

    int count = CS2F_ConfigPunchCount(id);
    if (count <= 0)
    {
        g_iRecoilFired[client] = 0;
        return;                              /* no sequence -> native kick remains */
    }

    int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
    if (clip < 0)
        return;

    float now = GetGameTime();

    if (!g_bRecoilSeen[client] || g_iRecoilWeaponId[client] != id)
    {
        g_bRecoilSeen[client] = true;
        g_iRecoilWeaponId[client] = id;
        g_iRecoilShot[client] = 0;
        g_fRecoilIndex[client] = 0.0;
        g_fRecoilLastShot[client] = now;
        g_fRecoilLastUpdate[client] = now;
        g_iRecoilLastClip[client] = clip;
        g_iRecoilFired[client] = 0;
        return;
    }

    if (clip > g_iRecoilLastClip[client])
    {
        /* reload: next shot starts the sequence again */
        g_iRecoilShot[client] = 0;
        g_fRecoilIndex[client] = 0.0;
        g_fRecoilLastShot[client] = now;
        g_fRecoilLastUpdate[client] = now;
        g_iRecoilLastClip[client] = clip;
        g_iRecoilFired[client] = 0;
        return;
    }

    /* TR-35: recover the float index while no shot is being fired */
    CS2F_RecoilDecayTick(client, now);

    /* TR-53: exactly one shot source per command.  On an infinite-ammo server the
       clip is pinned, so count weapon_fire events; otherwise the clip decrease is
       authoritative (unchanged pre-TR-53 behaviour). */
    ConVar cvInfAmmo = FindConVar("sv_infinite_ammo");
    bool eventSource = (cvInfAmmo != null) && (cvInfAmmo.IntValue != 0);

    int shots = 0;
    if (eventSource)
    {
        shots = g_iRecoilFired[client];
        g_iRecoilFired[client] = 0;
    }
    else
    {
        g_iRecoilFired[client] = 0;          /* never mix sources */
        if (clip < g_iRecoilLastClip[client])
            shots = g_iRecoilLastClip[client] - clip;
    }

    if (shots > 0)
    {
        float dt = now - g_fRecoilLastShot[client];
        if (dt < 0.04 || dt > 0.30)
            dt = 0.1;                        /* fall back to the 600 RPM cadence */
        CS2F_RecoilApplyBatch(client, id, cls, count, shots, dt);
        g_fRecoilLastShot[client] = now;
        g_fRecoilLastUpdate[client] = now;
    }

    g_iRecoilLastClip[client] = clip;
}

/* TR-53: apply a batch of detected shots (clip decrease or weapon_fire events). */
void CS2F_RecoilApplyBatch(int client, int id, const char[] cls, int count, int shots, float dt)
{
    for (int i = 0; i < shots; i++)
    {
        g_iRecoilShot[client]++;
        int rawRow = CS2F_RecoilIndexToRow(g_fRecoilIndex[client]);
        int cycle = CS2F_ConfigPunchCycle(id);
        int row = CS2F_PunchRowWrap(rawRow, count, cycle, g_bRecoilWrap);
        if (g_bRecoilLog)
        {
            LogRecoil("M5-CYCLE client=%d weapon=%s shot=%d raw_row=%d row=%d count=%d cycle=%d wrap=%d",
                      client, cls, g_iRecoilShot[client], rawRow, row, count, cycle,
                      g_bRecoilWrap ? 1 : 0);
        }
        CS2F_RecoilApply(client, id, cls, g_iRecoilShot[client], row, count, dt);
        g_fRecoilIndex[client] += 1.0;
    }
}

void CS2F_RecoilApply(int client, int id, const char[] cls, int shot, int row, int count, float dt)
{
    if (!CS2F_RecoilShouldWrite(row, count))
        return;

    float pitch, yaw, velPitch, velYaw;
    if (!CS2F_ConfigGetPunch(id, row, pitch, yaw, velPitch, velYaw))
        return;

    float vec[3];
    vec[0] = CS2F_RecoilScale(pitch, g_fRecoilScale);
    vec[1] = CS2F_RecoilScale(yaw, g_fRecoilScale);
    if (g_bRecoilCurve)
    {
        vec[0] = CS2F_RecoilCurveCompensate(vec[0], dt, g_fRecoilCurveK, g_fRecoilCurveR, g_fRecoilCurveMin);
        vec[1] = CS2F_RecoilCurveCompensate(vec[1], dt, g_fRecoilCurveK, g_fRecoilCurveR, g_fRecoilCurveMin);
    }
    /* TV-24 / TV-81: camera(view) channel, applied LAST and unconditionally.  At the
       neutral 1.0 this multiply is an exact IEEE identity, so the legacy matched write
       is bit-identical.  0.055 is EXPERIMENTAL: TV-81 measured that CS2's view punch is
       a per-shot impulse accumulator (~1.2-1.6 deg, 18/s decay), not 0.055x this
       cumulative aim, and L4D2's client-visible decals follow this camera field. */
    vec[0] = CS2F_RecoilViewApply(vec[0], g_fRecoilViewScale);
    vec[1] = CS2F_RecoilViewApply(vec[1], g_fRecoilViewScale);
    vec[2] = 0.0;

    SetEntDataVector(client, CS2F_PUNCH_OFFSET, vec, true);

    if (g_bRecoilLog)
    {
        float back[3];
        GetEntDataVector(client, CS2F_PUNCH_OFFSET, back);
        LogRecoil("M5-INDEX client=%d shot=%d index=%.5f row=%d dt=%.4f",
                  client, shot, g_fRecoilIndex[client], row, dt);
        LogRecoil("M5-WRITE client=%d weapon=%s shot=%d row=%d tx=%.6f ty=%.6f rx=%.6f ry=%.6f",
                  client, cls, shot, row, vec[0], vec[1], back[0], back[1]);
    }
}

/* ---- deterministic self-test -------------------------------------------- */

int CS2F_RecoilSelfTest(char[] report, int maxlen)
{
    int checks = 0;
    int fails = 0;
    char detail[256];
    detail[0] = '\0';

    checks++;
    if (CS2F_RecoilRowForShot(1) != 0 || CS2F_RecoilRowForShot(5) != 4)
    {
        fails++;
        StrCat(detail, sizeof(detail), "row_map ");
    }

    checks++;
    if (!CS2F_RecoilShouldWrite(0, 30) || !CS2F_RecoilShouldWrite(29, 30))
    {
        fails++;
        StrCat(detail, sizeof(detail), "write_in_range ");
    }

    checks++;
    if (CS2F_RecoilShouldWrite(30, 30) || CS2F_RecoilShouldWrite(-1, 30))
    {
        fails++;
        StrCat(detail, sizeof(detail), "write_out_of_range ");
    }

    checks++;
    if (CS2F_RecoilShouldWrite(0, 0))
    {
        fails++;
        StrCat(detail, sizeof(detail), "empty_table ");
    }

    checks++;
    if (FloatAbs(CS2F_RecoilScale(-0.5, 0.5) + 0.25) > 1.0e-6)
    {
        fails++;
        StrCat(detail, sizeof(detail), "scale ");
    }

    checks++;
    /* TV-24: 3.0 * 0.055 = 0.165 */
    if (FloatAbs(CS2F_RecoilViewApply(3.0, 0.055) - 0.165) > 1.0e-6)
    {
        fails++;
        StrCat(detail, sizeof(detail), "view_apply_small ");
    }

    checks++;
    /* TV-24: 26.0 * 0.055 = 1.43 */
    if (FloatAbs(CS2F_RecoilViewApply(26.0, 0.055) - 1.43) > 1.0e-6)
    {
        fails++;
        StrCat(detail, sizeof(detail), "view_apply_large ");
    }

    checks++;
    /* neutral 1.0 must be exactly the identity (bit-identical legacy write) */
    if (CS2F_RecoilViewApply(3.0, 1.0) != 3.0
        || CS2F_RecoilViewApply(-2.5, 1.0) != -2.5
        || CS2F_RecoilViewApply(0.0, 1.0) != 0.0)
    {
        fails++;
        StrCat(detail, sizeof(detail), "view_identity ");
    }

    Format(report, maxlen, "RECOILTEST %s checks=%d fails=%d %s",
           (fails == 0) ? "PASS" : "FAIL", checks, fails, detail);
    return fails;
}

/**
 * TR-49 / TV-95: the two-segment wrap mapping.  Reported as a separate WRAPTEST line
 * so the historical RECOILTEST/BALLISTICSTEST check counts (asserted by the older
 * bench runners) stay untouched.
 */
int CS2F_RecoilWrapSelfTest(char[] report, int maxlen)
{
    int checks = 0;
    int fails = 0;
    char detail[256];
    detail[0] = '\0';

    /* inside the table the wrap is the identity (rows 0..127 for count=128, cycle=64) */
    checks++;
    if (CS2F_PunchRowWrap(0, 128, 64, true) != 0
        || CS2F_PunchRowWrap(63, 128, 64, true) != 63
        || CS2F_PunchRowWrap(64, 128, 64, true) != 64
        || CS2F_PunchRowWrap(127, 128, 64, true) != 127)
    {
        fails++;
        StrCat(detail, sizeof(detail), "inside ");
    }

    /* beyond the table the row folds back into the measured steady cycle */
    checks++;
    if (CS2F_PunchRowWrap(128, 128, 64, true) != 64
        || CS2F_PunchRowWrap(129, 128, 64, true) != 65
        || CS2F_PunchRowWrap(191, 128, 64, true) != 127
        || CS2F_PunchRowWrap(192, 128, 64, true) != 64
        || CS2F_PunchRowWrap(255, 128, 64, true) != 127
        || CS2F_PunchRowWrap(256, 128, 64, true) != 64)
    {
        fails++;
        StrCat(detail, sizeof(detail), "fold ");
    }

    /* wrap off / single-segment table = legacy identity */
    checks++;
    if (CS2F_PunchRowWrap(128, 128, 64, false) != 128
        || CS2F_PunchRowWrap(70, 64, 0, true) != 70
        || CS2F_PunchRowWrap(70, 64, 64, true) != 70)
    {
        fails++;
        StrCat(detail, sizeof(detail), "identity ");
    }

    checks++;
    /* the generated table must actually be a 128-row two-segment table */
    bool sawCycle = false;
    for (int i = 1; i <= CS2F_ConfigWeaponCount(); i++)
    {
        if (CS2F_ConfigPunchCount(i) == 128 && CS2F_ConfigPunchCycle(i) == 64)
            sawCycle = true;
    }
    if (!sawCycle)
    {
        fails++;
        StrCat(detail, sizeof(detail), "table_shape ");
    }

    checks++;
    /* every punch table must declare the same 64-row steady cycle */
    for (int i = 1; i <= CS2F_ConfigWeaponCount(); i++)
    {
        if (CS2F_ConfigPunchCount(i) <= 0)
            continue;
        if (CS2F_ConfigPunchCycle(i) != 64)
        {
            fails++;
            StrCat(detail, sizeof(detail), "cycle_value ");
            break;
        }
    }

    Format(report, maxlen, "WRAPTEST %s checks=%d fails=%d %s",
           (fails == 0) ? "PASS" : "FAIL", checks, fails, detail);
    return fails;
}

/** TR-35 / TV-71: float index -> row truncation and the exponential recovery law. */
int CS2F_RecoilDecaySelfTest(char[] report, int maxlen)
{
    int checks = 0;
    int fails = 0;
    char detail[256];
    detail[0] = '\0';

    checks++;
    if (CS2F_RecoilIndexToRow(5.9999) != 5 || CS2F_RecoilIndexToRow(6.0) != 6
        || CS2F_RecoilIndexToRow(0.5) != 0 || CS2F_RecoilIndexToRow(0.0) != 0)
    {
        fails++;
        StrCat(detail, sizeof(detail), "row_trunc ");
    }

    checks++;
    if (FloatAbs(CS2F_RecoilDecay(6.0, 0.0, 4.605) - 6.0) > 1.0e-6)
    {
        fails++;
        StrCat(detail, sizeof(detail), "no_dt ");
    }

    checks++;
    /* 6 * exp(-4.605 * 0.2) = 2.3887 */
    if (FloatAbs(CS2F_RecoilDecay(6.0, 0.2, 4.605) - 2.3887) > 1.0e-3)
    {
        fails++;
        StrCat(detail, sizeof(detail), "exp_step ");
    }

    checks++;
    /* 6 * exp(-4.605 * 3.0) = 6.0e-6 -> the 1e-4 clamp makes this exactly 0 */
    if (CS2F_RecoilDecay(6.0, 3.0, 4.605) != 0.0)
    {
        fails++;
        StrCat(detail, sizeof(detail), "clamp_zero ");
    }

    checks++;
    if (!(CS2F_RecoilDecay(6.0, 0.1, 4.605) > CS2F_RecoilDecay(6.0, 0.2, 4.605)))
    {
        fails++;
        StrCat(detail, sizeof(detail), "monotone ");
    }

    checks++;
    /* dead time: nothing decays before lastShot + delay */
    if (CS2F_RecoilDecayWindow(10.0, 10.0, 10.1, 0.1334) != 0.0)
    {
        fails++;
        StrCat(detail, sizeof(detail), "delay_hold ");
    }

    checks++;
    /* only the part beyond the dead time counts, and it never double-counts */
    if (FloatAbs(CS2F_RecoilDecayWindow(10.0, 10.0, 10.2, 0.13) - 0.07) > 1.0e-4
        || FloatAbs(CS2F_RecoilDecayWindow(10.0, 10.2, 10.3, 0.13) - 0.10) > 1.0e-4)
    {
        fails++;
        StrCat(detail, sizeof(detail), "delay_window ");
    }

    checks++;
    /* configuration accessors must expose the measured constants (does NOT assert the
       on/off state: the control run sets decay 0 deliberately) */
    if (!(CS2F_RecoilDecayRateValue() > 0.0) || CS2F_RecoilDecayDelayValue() < 0.0)
    {
        fails++;
        StrCat(detail, sizeof(detail), "decay_constants ");
    }

    Format(report, maxlen, "RECOILDECAYTEST %s checks=%d fails=%d %s",
           (fails == 0) ? "PASS" : "FAIL", checks, fails, detail);
    return fails;
}

/** TR-24 / TV-73: camera-curve pre-emphasis (pure functions only, M58). */
int CS2F_RecoilCurveSelfTest(char[] report, int maxlen)
{
    int checks = 0;
    int fails = 0;
    char detail[256];
    detail[0] = '\0';

    checks++;
    /* mean of e^(-0.5 t) over 0.1 s = (1 - e^-0.05)/0.05 = 0.975412 */
    if (FloatAbs(CS2F_RecoilCurveMean(0.1, 0.5) - 0.975412) > 1.0e-4)
    {
        fails++;
        StrCat(detail, sizeof(detail), "mean ");
    }

    checks++;
    /* (5.5 + 40)/0.975412 - 40 = 6.6469 */
    if (FloatAbs(CS2F_RecoilCurveCompensate(5.5, 0.1, 0.5, 20.0, 2.0) - 6.6469) > 1.0e-3)
    {
        fails++;
        StrCat(detail, sizeof(detail), "comp ");
    }

    checks++;
    if (CS2F_RecoilCurveCompensate(0.0, 0.1, 0.5, 20.0, 2.0) != 0.0)
    {
        fails++;
        StrCat(detail, sizeof(detail), "zero ");
    }

    checks++;
    if (FloatAbs(CS2F_RecoilCurveCompensate(-5.5, 0.1, 0.5, 20.0, 2.0) + 6.6469) > 1.0e-3)
    {
        fails++;
        StrCat(detail, sizeof(detail), "sign ");
    }

    checks++;
    if (CS2F_RecoilCurveCompensate(2.0, 0.1, 0.5, 20.0, 2.0) < 2.0)
    {
        fails++;
        StrCat(detail, sizeof(detail), "never_less ");
    }

    checks++;
    /* below the floor the write stays raw (no spurious upward kick on the early rows) */
    if (FloatAbs(CS2F_RecoilCurveCompensate(1.0, 0.1, 0.5, 20.0, 2.0) - 1.0) > 1.0e-6)
    {
        fails++;
        StrCat(detail, sizeof(detail), "floor ");
    }

    Format(report, maxlen, "RECOILCURVETEST %s checks=%d fails=%d %s",
           (fails == 0) ? "PASS" : "FAIL", checks, fails, detail);
    return fails;
}

void LogRecoil(const char[] fmt, any ...)
{
    char msg[512];
    VFormat(msg, sizeof(msg), fmt, 2);
    PrintToServer("[CS2Feel] %s", msg);
    LogToFileEx("cs2feel_m5.log", "%s", msg);
}
