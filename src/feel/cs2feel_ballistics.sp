/**
 * cs2feel_ballistics.sp -- MOD-5 (first version): make the server-side BULLET
 * direction follow the CS2 recoil sequence, inside the only allowed runtime callback.
 *
 * WHY THIS FILE EXISTS
 *   TV-29 proved that L4D2's server ballistics ignore m_vecPunchAngle (MOD-3's write is
 *   a view/camera channel only).  TV-34 then measured the missing link: a copyback of
 *   the usercmd `angles` array from CS2F_OnPlayerRunCmd moves the server eye angles AND the
 *   bullet impact direction 1:1 (free-view sweep, slope -1.04).  This module uses that
 *   channel: while the player is holding fire, it adds the CS2 punch angle for the NEXT
 *   shot to the usercmd view angles, so the bullet direction follows the same sequence
 *   that MOD-3 writes into m_vecPunchAngle for the client camera.
 *
 * INDEXING / TIMING (0.5.7-m11: the index is no longer used for the offset)
 *   Until m10 this module kept its own integer shot counter and wrote
 *   scale * table[row], applying row `shotsFired` while attack was held.  That
 *   counter never decayed (MOD-3's TR-35 float index was never ported here), so
 *   after a pause the camera returned to row 0 while this module kept writing the
 *   old row -- a permanent, client-invisible aim bias.  D-044 / docs/evidence/
 *   cal-20261029 measured it (0.23-0.40 deg at a 2 s cadence with s_off=-0.10).
 *   m11 derives the offset from m_vecPunchAngle itself instead:
 *
 *       offset = (ballistics_scale / recoil_scale) * punch
 *
 *   which is zero when the punch is zero, tracks the camera at every instant, and
 *   needs neither the row, the wrap, the curve nor a dt estimate.  The counter is
 *   kept for the M6 log lines only.
 *
 * SCOPE / SAFETY
 *   - both axes by default since TR-49 / 0.5.4-m8: pitch (TV-34) and yaw (TV-36,
 *     per-shot copyback slope 0.96-0.98 = 1:1).  The yaw ConVar stays available as
 *     an escape hatch (0 = pitch only).
 *   - mode 0 does nothing at all (mode 1 is the compiled default since TV-82); only
 *     CS2F_OnPlayerRunCmd; no timers, no OnMapStart; only the local player's own usercmd
 *     angles; no entity writes.
 *   - ASCII only.
 */

#if defined _cs2feel_ballistics_included
 #endinput
#endif
#define _cs2feel_ballistics_included

#define CS2F_BALLISTICS_MODE_OFF 0
#define CS2F_BALLISTICS_MODE_ON  1

int   g_iBallShots[MAXPLAYERS + 1];
int   g_iBallWeaponId[MAXPLAYERS + 1];
int   g_iBallLastClip[MAXPLAYERS + 1];
bool  g_bBallSeen[MAXPLAYERS + 1];

int   g_iBallMode = CS2F_BALLISTICS_MODE_OFF;
float g_fBallScale = 1.0;
bool  g_bBallYaw = false;
bool  g_bBallLog = false;

/* TV-75: the cmd offset may use the SAME curve pre-emphasis as the camera write, so the
   visible crosshair and the impacts move together (the demo showed the client camera =
   the punch only, so the visible mismatch is punch - offset; matching both removes it). */
bool  g_bBallCurve = false;
float g_fBallCurveK = 0.5;
float g_fBallCurveR = 20.0;
float g_fBallCurveMin = 2.0;
float g_fBallLastShot[MAXPLAYERS + 1];

/* TR-53: same ammo-independent source as MOD-3.  sv_infinite_ammo pins m_iClip1, so
   each module counts weapon_fire events instead of clip decreases on such servers;
   the choice is made per command from the server cvar, so no shot is counted twice. */
int   g_iBallFired[MAXPLAYERS + 1];

/* ---- pure helpers (unit-tested) ----------------------------------------- */

/** The pending shot's 0-based sequence row equals the number of shots already fired. */
stock int CS2F_BallisticsPendingRow(int shotsFired)
{
    return shotsFired;
}

stock bool CS2F_BallisticsShouldApply(int row, int count)
{
    return row >= 0 && row < count;
}

stock float CS2F_BallisticsScaled(float value, float scale)
{
    return value * scale;
}

/* ---- lifecycle ----------------------------------------------------------- */

void CS2F_BallisticsInit()
{
    for (int i = 0; i <= MAXPLAYERS; i++)
    {
        g_iBallShots[i] = 0;
        g_iBallWeaponId[i] = 0;
        g_iBallLastClip[i] = -1;
        g_bBallSeen[i] = false;
        g_fBallLastShot[i] = 0.0;
        g_iBallFired[i] = 0;
    }
    HookEventEx("weapon_fire", CS2F_BallisticsOnWeaponFire, EventHookMode_Post);
}

/* TR-53: one event per shot; capped so a stalled command loop cannot accumulate. */
public void CS2F_BallisticsOnWeaponFire(Handle event, const char[] name, bool dontBroadcast)
{
    if (g_iBallMode != CS2F_BALLISTICS_MODE_ON)
        return;
    int userid = GetEventInt(event, "userid");
    int client = (userid > 0) ? GetClientOfUserId(userid) : 0;
    if (client < 1 || client > MaxClients || IsFakeClient(client))
        return;
    if (g_iBallFired[client] < 8)
        g_iBallFired[client]++;
}

void CS2F_BallisticsConfigureCurve(bool on, float k, float r, float floorMag)
{
    g_bBallCurve = on;
    g_fBallCurveK = (k > 0.0) ? k : 0.5;
    g_fBallCurveR = (r >= 0.0) ? r : 20.0;
    g_fBallCurveMin = (floorMag > 0.0) ? floorMag : 2.0;
}

bool CS2F_BallisticsCurveEnabled()
{
    return g_bBallCurve;
}

void CS2F_BallisticsConfigure(int mode, float scale, bool yaw, bool logOn)
{
    g_iBallMode = (mode == CS2F_BALLISTICS_MODE_ON) ? CS2F_BALLISTICS_MODE_ON : CS2F_BALLISTICS_MODE_OFF;
    /* D-046: a NEGATIVE scale is the bullet-correction channel.  The bullet already
       consumes m_vecPunchAngle 1:1 (M-V14 / D-044), so the camera and the bullet are
       the same size unless a second, opposite offset is added here.  With
       s_off = 1.00 - s_cam the bullet flies at 1.00x the table while the camera keeps
       s_cam; s_cam = 1.10 reproduces CS2's own 1.10 / 1.00 structure.  Zero is still
       rejected (a 0.0 scale would be a silent pass-through). */
    g_fBallScale = (scale != 0.0) ? scale : 1.0;
    g_bBallYaw = yaw;
    g_bBallLog = logOn;
}

int CS2F_BallisticsMode()
{
    return g_iBallMode;
}

float CS2F_BallisticsScaleValue()
{
    return g_fBallScale;
}

bool CS2F_BallisticsYawEnabled()
{
    return g_bBallYaw;
}

bool CS2F_BallisticsLogEnabled()
{
    return g_bBallLog;
}

/* ---- runtime path -------------------------------------------------------- */

/**
 * TV-27: the engine decays m_vecPunchAngle once more between this hook and the
 * bullet's own computation, so the field read here is one command stale.  Remove
 * that single step (dlen = 0.016665*len + 0.666680 per command) so that the offset
 * is proportional to the punch the bullet actually consumes.  Validated against
 * docs/evidence/cal-20261029/run-m11: dy / model = 1.03 +- 0.15.
 */
stock void CS2F_BallisticsOneCommandDecay(float v[3])
{
    float mag = SquareRoot(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (mag <= 0.0)
        return;
    float dec = 0.016665 * mag + 0.666680;
    float s = (mag > dec) ? ((mag - dec) / mag) : 0.0;
    v[0] *= s;
    v[1] *= s;
    v[2] *= s;
}

/**
 * Returns true when the usercmd `angles` array was modified.
 * Called after CS2F_RecoilOnRunCmd so the two modules see the same clip state.
 */
bool CS2F_BallisticsOnRunCmd(int client, int &buttons, float angles[3])
{
    if (g_iBallMode != CS2F_BALLISTICS_MODE_ON)
        return false;
    if (client < 1 || client > MaxClients)
        return false;
    if (!IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
        return false;

    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon <= 0 || !IsValidEntity(weapon))
        return false;

    char cls[CS2F_CLASS_LEN];
    GetEdictClassname(weapon, cls, sizeof(cls));
    int id = CS2F_ConfigWeaponIdByClass(cls);
    if (id <= 0)
    {
        g_iBallFired[client] = 0;            /* TR-53: do not leak events into a mapped weapon */
        return false;
    }

    int count = CS2F_ConfigPunchCount(id);
    if (count <= 0)
        return false;

    int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
    if (clip < 0)
        return false;

    if (!g_bBallSeen[client] || g_iBallWeaponId[client] != id)
    {
        g_bBallSeen[client] = true;
        g_iBallWeaponId[client] = id;
        g_iBallShots[client] = 0;
        g_iBallLastClip[client] = clip;
        g_fBallLastShot[client] = 0.0;
        g_iBallFired[client] = 0;
        return false;
    }

    if (clip > g_iBallLastClip[client])
    {
        g_iBallShots[client] = 0;
        g_iBallLastClip[client] = clip;
        g_fBallLastShot[client] = 0.0;
        g_iBallFired[client] = 0;
        return false;
    }

    /* TR-53: one shot source per command (see MOD-3). */
    ConVar cvInfAmmo = FindConVar("sv_infinite_ammo");
    bool eventSource = (cvInfAmmo != null) && (cvInfAmmo.IntValue != 0);

    int fired = 0;
    if (eventSource)
    {
        fired = g_iBallFired[client];
        g_iBallFired[client] = 0;
    }
    else
    {
        g_iBallFired[client] = 0;
        if (clip < g_iBallLastClip[client])
            fired = g_iBallLastClip[client] - clip;
    }

    if (fired > 0)
    {
        for (int i = 0; i < fired; i++)
        {
            g_iBallShots[client]++;
            if (g_bBallLog)
            {
                int rowLogged = CS2F_BallisticsPendingRow(g_iBallShots[client] - 1);
                rowLogged = CS2F_PunchRowWrap(rowLogged, count, CS2F_ConfigPunchCycle(id),
                                              CS2F_RecoilWrapEnabled());
                float lp, ly, lvp, lvy;
                if (CS2F_ConfigGetPunch(id, rowLogged, lp, ly, lvp, lvy))
                {
                    LogBallistics("M6-SHOT client=%d weapon=%s tick=%d shot=%d row=%d tx=%.6f ty=%.6f raw_pitch=%.6f raw_yaw=%.6f",
                                  client, cls, GetGameTickCount(), g_iBallShots[client], rowLogged,
                                  lp, ly, angles[0], angles[1]);
                }
            }
        }
    }
    g_iBallLastClip[client] = clip;

    if (!(buttons & IN_ATTACK) || clip <= 0)
        return false;

    /* ------------------------------------------------------------------------
     * 0.5.7-m11 (D-047): the offset is derived from the punch the camera ACTUALLY
     * shows right now, not from the undecayed table row.
     *
     * Why the old form was wrong (four independent defects, all measured in
     * docs/work/audit/audit-code.md F-01/F-03/F-16 and docs/evidence/cal-20261029):
     *   - g_iBallShots never decays (TR-35 was only applied to MOD-3), so after any
     *     pause the camera's float index recovers to row 0 while this module kept
     *     writing table[row N] -> a permanent, invisible aim bias (0.23-0.40 deg at
     *     a 2 s cadence with s_off=-0.10, growing shot by shot);
     *   - the table row is the WRITE value, not the camera's rendered value: the
     *     engine decays the field between shots, which made bullet/camera depend on
     *     the cadence (0.574 -> 0.900 inside one 12-shot arm);
     *   - the curve pre-emphasis used a different dt than MOD-3 (0.1 s fallback), and
     *     tested the floor on the scaled magnitude, so the two channels could never
     *     be made symmetric;
     *   - the row was one ahead of the punch field by construction.
     *
     * Since the camera renders m_vecPunchAngle and the bullet consumes the same
     * field (D-044), the exact correction for bullet = (1 + s_off/s_cam) * camera is
     * simply an angle offset proportional to the CURRENT punch:
     *
     *     offset = (s_off / s_cam) * punch        (negative s_off => cancels)
     *
     * It is zero when the punch is zero (so nothing survives a ceasefire), has the
     * right magnitude at every instant (so it is cadence independent), and the curve
     * is already baked into the punch it reads (so the curve cvars no longer gate
     * this path; they keep their meaning for MOD-3 only).
     * ---------------------------------------------------------------------- */
    float punch[3];
    GetEntDataVector(client, CS2F_PUNCH_OFFSET, punch);
    CS2F_BallisticsOneCommandDecay(punch);

    float camScale = CS2F_RecoilScaleValue();
    if (camScale <= 0.0)
        camScale = 1.0;

    float offP = (g_fBallScale / camScale) * punch[0];
    float offY = (g_fBallScale / camScale) * punch[1];

    if (offP == 0.0 && offY == 0.0)
        return false;

    angles[0] += offP;
    if (g_bBallYaw)
        angles[1] += offY;

    if (g_bBallLog)
    {
        int rowLogged = CS2F_BallisticsPendingRow(g_iBallShots[client]);
        rowLogged = CS2F_PunchRowWrap(rowLogged, count, CS2F_ConfigPunchCycle(id),
                                      CS2F_RecoilWrapEnabled());
        LogBallistics("M6-APPLY client=%d weapon=%s tick=%d shot=%d row=%d punch=(%.4f,%.4f) off=(%.4f,%.4f) k=%.4f legacy_curve=(%.2f,%.1f,%.1f)",
                      client, cls, GetGameTickCount(), g_iBallShots[client], rowLogged,
                      punch[0], punch[1], offP, offY, g_fBallScale / camScale,
                      g_fBallCurveK, g_fBallCurveR, g_fBallCurveMin);
    }
    g_fBallLastShot[client] = GetGameTime();
    return true;
}

/* ---- deterministic self-test -------------------------------------------- */

int CS2F_BallisticsSelfTest(char[] report, int maxlen)
{
    int checks = 0;
    int fails = 0;
    char detail[256];
    detail[0] = '\0';

    checks++;
    if (CS2F_BallisticsPendingRow(0) != 0 || CS2F_BallisticsPendingRow(5) != 5)
    {
        fails++;
        StrCat(detail, sizeof(detail), "row_pending ");
    }

    checks++;
    if (!CS2F_BallisticsShouldApply(0, 30) || !CS2F_BallisticsShouldApply(29, 30))
    {
        fails++;
        StrCat(detail, sizeof(detail), "row_in_range ");
    }

    checks++;
    if (CS2F_BallisticsShouldApply(30, 30) || CS2F_BallisticsShouldApply(-1, 30))
    {
        fails++;
        StrCat(detail, sizeof(detail), "row_out_of_range ");
    }

    checks++;
    if (CS2F_BallisticsShouldApply(0, 0))
    {
        fails++;
        StrCat(detail, sizeof(detail), "empty_table ");
    }

    checks++;
    if (FloatAbs(CS2F_BallisticsScaled(-0.5, 0.5) + 0.25) > 1.0e-6)
    {
        fails++;
        StrCat(detail, sizeof(detail), "scale ");
    }

    Format(report, maxlen, "BALLISTICSTEST %s checks=%d fails=%d %s",
           (fails == 0) ? "PASS" : "FAIL", checks, fails, detail);
    return fails;
}

void LogBallistics(const char[] fmt, any ...)
{
    char msg[512];
    VFormat(msg, sizeof(msg), fmt, 2);
    PrintToServer("[CS2Feel] %s", msg);
    LogToFileEx("cs2feel_m6.log", "%s", msg);
}
