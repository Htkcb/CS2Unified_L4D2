/**
 * cs2movement_crouch.sp -- crouch layer for CS2Movement_L4D2.
 *
 * Stage 1 scope:
 *   - implement the sv_timebetweenducks equivalent (0.4 s) by suppressing a
 *     too-early IN_DUCK press edge in CS2M_OnPlayerRunCmd;
 *   - read (but do not write) L4D2 duck state: m_nDuckTimeMsecs, m_bDucking,
 *     m_bDucked, m_bInDuckJump, m_vecViewOffset, m_flMaxspeed;
 *   - report target duck rate / eye / hull values.
 *
 * Stage 2 (offline implementation, runtime-gated):
 *   - model duck amount at cs2movement_duck_rate;
 *   - optional m_nDuckTimeMsecs / m_bDucking / m_bDucked writes;
 *   - optional m_vecViewOffset write;
 *   - all writes require cs2movement_write_props 1 plus a per-feature gate.
 */

#if defined _cs2movement_crouch_included
 #endinput
#endif
#define _cs2movement_crouch_included

#if !defined IN_DUCK
 #define IN_DUCK (1 << 2)
#endif

bool  g_bDuckHeld[MAXPLAYERS + 1];
float g_fLastDuckPress[MAXPLAYERS + 1];
int   g_iDuckBlocked[MAXPLAYERS + 1];
float g_fDuckAmount[MAXPLAYERS + 1];
float g_fLastCrouchTime[MAXPLAYERS + 1];
int   g_iLastWrittenDuckMsecs[MAXPLAYERS + 1];
bool  g_bCrouchWroteState[MAXPLAYERS + 1];
bool  g_bCrouchWroteView[MAXPLAYERS + 1];

stock bool CS2M_CrouchGetIntProp(int client, const char[] name, int &value)
{
    if (HasEntProp(client, Prop_Data, name))
    {
        value = GetEntProp(client, Prop_Data, name);
        return true;
    }
    if (HasEntProp(client, Prop_Send, name))
    {
        value = GetEntProp(client, Prop_Send, name);
        return true;
    }

    char localName[64];
    Format(localName, sizeof(localName), "m_Local.%s", name);
    if (HasEntProp(client, Prop_Data, localName))
    {
        value = GetEntProp(client, Prop_Data, localName);
        return true;
    }
    if (HasEntProp(client, Prop_Send, localName))
    {
        value = GetEntProp(client, Prop_Send, localName);
        return true;
    }
    return false;
}

stock bool CS2M_CrouchGetFloatProp(int client, const char[] name, float &value)
{
    if (HasEntProp(client, Prop_Data, name))
    {
        value = GetEntPropFloat(client, Prop_Data, name);
        return true;
    }
    if (HasEntProp(client, Prop_Send, name))
    {
        value = GetEntPropFloat(client, Prop_Send, name);
        return true;
    }

    char localName[64];
    Format(localName, sizeof(localName), "m_Local.%s", name);
    if (HasEntProp(client, Prop_Data, localName))
    {
        value = GetEntPropFloat(client, Prop_Data, localName);
        return true;
    }
    if (HasEntProp(client, Prop_Send, localName))
    {
        value = GetEntPropFloat(client, Prop_Send, localName);
        return true;
    }
    return false;
}

stock bool CS2M_CrouchGetVectorProp(int client, const char[] name, float value[3])
{
    if (HasEntProp(client, Prop_Data, name))
    {
        GetEntPropVector(client, Prop_Data, name, value);
        return true;
    }
    if (HasEntProp(client, Prop_Send, name))
    {
        GetEntPropVector(client, Prop_Send, name, value);
        return true;
    }

    char localName[64];
    Format(localName, sizeof(localName), "m_Local.%s", name);
    if (HasEntProp(client, Prop_Data, localName))
    {
        GetEntPropVector(client, Prop_Data, localName, value);
        return true;
    }
    if (HasEntProp(client, Prop_Send, localName))
    {
        GetEntPropVector(client, Prop_Send, localName, value);
        return true;
    }
    return false;
}

stock bool CS2M_CrouchSetIntProp(int client, const char[] name, int value)
{
    if (HasEntProp(client, Prop_Data, name))
    {
        SetEntProp(client, Prop_Data, name, value);
        return true;
    }
    if (HasEntProp(client, Prop_Send, name))
    {
        SetEntProp(client, Prop_Send, name, value);
        return true;
    }

    char localName[64];
    Format(localName, sizeof(localName), "m_Local.%s", name);
    if (HasEntProp(client, Prop_Data, localName))
    {
        SetEntProp(client, Prop_Data, localName, value);
        return true;
    }
    if (HasEntProp(client, Prop_Send, localName))
    {
        SetEntProp(client, Prop_Send, localName, value);
        return true;
    }
    return false;
}

stock bool CS2M_CrouchSetVectorProp(int client, const char[] name, const float value[3])
{
    if (HasEntProp(client, Prop_Data, name))
    {
        SetEntPropVector(client, Prop_Data, name, value);
        return true;
    }
    if (HasEntProp(client, Prop_Send, name))
    {
        SetEntPropVector(client, Prop_Send, name, value);
        return true;
    }

    char localName[64];
    Format(localName, sizeof(localName), "m_Local.%s", name);
    if (HasEntProp(client, Prop_Data, localName))
    {
        SetEntPropVector(client, Prop_Data, localName, value);
        return true;
    }
    if (HasEntProp(client, Prop_Send, localName))
    {
        SetEntPropVector(client, Prop_Send, localName, value);
        return true;
    }
    return false;
}

/**
 * Stage 2: model duck amount and optionally write it into L4D2's CS-style
 * duck fields.  Both gates must be enabled:
 *   cs2movement_write_props 1
 *   cs2movement_crouch_enforce 1
 * View write additionally requires cs2movement_crouch_view 1.
 */
stock void CS2M_CrouchApplyState(int client, int buttons)
{
    if (client < 1 || client > MaxClients)
        return;
    if (!CS2M_IsSurvivor(client))
        return;

    if (!GetConVarBool(FindConVar("cs2movement_write_props")))
        return;
    if (!GetConVarBool(FindConVar("cs2movement_crouch_enforce")))
        return;
    if (!IsPlayerAlive(client))
        return;

    float rate = GetConVarFloat(FindConVar("cs2movement_duck_rate"));
    if (rate <= 0.0)
        return;

    float now = GetGameTime();
    float dt = (g_fLastCrouchTime[client] > 0.0) ? (now - g_fLastCrouchTime[client]) : GetTickInterval();
    if (dt < 0.0)
        dt = 0.0;
    if (dt > 0.2)
        dt = 0.2;
    g_fLastCrouchTime[client] = now;

    bool duckDown = (buttons & IN_DUCK) != 0;
    float step = rate * dt;
    if (duckDown)
        g_fDuckAmount[client] += step;
    else
        g_fDuckAmount[client] -= step;

    if (g_fDuckAmount[client] < 0.0)
        g_fDuckAmount[client] = 0.0;
    if (g_fDuckAmount[client] > 1.0)
        g_fDuckAmount[client] = 1.0;

    float fullMs = 1000.0 / rate;
    int msecs = RoundToZero(g_fDuckAmount[client] * fullMs + 0.5);
    if (msecs < 0)
        msecs = 0;
    if (msecs > RoundToZero(fullMs))
        msecs = RoundToZero(fullMs);

    bool wrote = CS2M_CrouchSetIntProp(client, "m_nDuckTimeMsecs", msecs);
    CS2M_CrouchSetIntProp(client, "m_bDucking", (g_fDuckAmount[client] > 0.0 && g_fDuckAmount[client] < 1.0) ? 1 : 0);
    CS2M_CrouchSetIntProp(client, "m_bDucked", (g_fDuckAmount[client] >= 1.0) ? 1 : 0);

    g_iLastWrittenDuckMsecs[client] = msecs;
    g_bCrouchWroteState[client] = wrote;

    if (GetConVarBool(FindConVar("cs2movement_crouch_view")))
    {
        float view[3];
        if (CS2M_CrouchGetVectorProp(client, "m_vecViewOffset", view))
        {
            float standEye = GetConVarFloat(FindConVar("cs2movement_stand_eye"));
            float duckEye = GetConVarFloat(FindConVar("cs2movement_duck_eye"));
            view[2] = standEye + (duckEye - standEye) * g_fDuckAmount[client];
            g_bCrouchWroteView[client] = CS2M_CrouchSetVectorProp(client, "m_vecViewOffset", view);
        }
    }

    int actualTime = 0;
    int actualDucking = 0;
    int actualDucked = 0;
    CS2M_CrouchGetIntProp(client, "m_nDuckTimeMsecs", actualTime);
    CS2M_CrouchGetIntProp(client, "m_bDucking", actualDucking);
    CS2M_CrouchGetIntProp(client, "m_bDucked", actualDucked);

    if (GetConVarBool(FindConVar("cs2movement_debug")))
        PrintToServer("[CS2Movement] CROUCH-WRITE client=%d amount=%.3f msecs=%d actual_time=%d actual_ducking=%d actual_ducked=%d wrote=%d view=%d",
                      client, g_fDuckAmount[client], msecs, actualTime, actualDucking, actualDucked,
                      wrote ? 1 : 0, g_bCrouchWroteView[client] ? 1 : 0);
}

stock float CS2M_CrouchDuckAmount(int duckTimeMsecs)
{
    float rate = GetConVarFloat(FindConVar("cs2movement_duck_rate"));
    if (rate <= 0.0)
        return 0.0;

    float fullMs = 1000.0 / rate;
    if (fullMs <= 0.0)
        return 0.0;

    float amount = duckTimeMsecs / fullMs;
    if (amount < 0.0)
        amount = 0.0;
    if (amount > 1.0)
        amount = 1.0;
    return amount;
}

stock void CS2M_CrouchResetClient(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    g_bDuckHeld[client] = false;
    g_fLastDuckPress[client] = 0.0;
    g_iDuckBlocked[client] = 0;
    g_fDuckAmount[client] = 0.0;
    g_fLastCrouchTime[client] = 0.0;
    g_iLastWrittenDuckMsecs[client] = 0;
    g_bCrouchWroteState[client] = false;
    g_bCrouchWroteView[client] = false;
}

/**
 * sv_timebetweenducks equivalent.  Only a rising edge (press) is rate-limited;
 * holding the key is untouched.  This is server-side: the client may predict
 * its own duck until the server rejects it, which is a known Stage 2 issue.
 */
stock void CS2M_CrouchOnPlayerRunCmd(int client, int &buttons, bool &changed)
{
    if (client < 1 || client > MaxClients)
        return;

    ConVar cvEnable = FindConVar("cs2movement_crouch_enable");
    if (cvEnable == null || !GetConVarBool(cvEnable))
        return;

    ConVar cvInterval = FindConVar("cs2movement_time_between_ducks");
    if (cvInterval == null)
        return;

    float interval = GetConVarFloat(cvInterval);
    if (interval <= 0.0)
        return;

    bool duckDown = (buttons & IN_DUCK) != 0;
    bool pressed = duckDown && !g_bDuckHeld[client];

    if (pressed)
    {
        float now = GetGameTime();
        if (g_fLastDuckPress[client] > 0.0 && (now - g_fLastDuckPress[client]) < interval)
        {
            buttons &= ~IN_DUCK;
            changed = true;
            g_iDuckBlocked[client]++;

            if (GetConVarBool(FindConVar("cs2movement_debug")))
            {
                PrintToServer("[CS2Movement] DUCK-BLOCK client=%d dt=%.4f interval=%.4f count=%d",
                              client, now - g_fLastDuckPress[client], interval, g_iDuckBlocked[client]);
            }
        }
        else
        {
            g_fLastDuckPress[client] = now;
        }
    }

    g_bDuckHeld[client] = duckDown;
}

stock void CS2M_CrouchStatus(int client)
{
    float rate = GetConVarFloat(FindConVar("cs2movement_duck_rate"));
    float interval = GetConVarFloat(FindConVar("cs2movement_time_between_ducks"));
    float standEye = GetConVarFloat(FindConVar("cs2movement_stand_eye"));
    float duckEye = GetConVarFloat(FindConVar("cs2movement_duck_eye"));
    float standHull = GetConVarFloat(FindConVar("cs2movement_stand_hull"));
    float duckHull = GetConVarFloat(FindConVar("cs2movement_duck_hull"));

    ReplyToCommand(client, "[CS2Movement] CROUCH duck_rate=%.2f/s time_between_ducks=%.3fs eye=%.1f->%.1f hull=%.1f->%.1f",
                   rate, interval, standEye, duckEye, standHull, duckHull);

    if (client <= 0 || !IsClientInGame(client))
    {
        ReplyToCommand(client, "[CS2Movement]   prop check skipped (no client)");
        return;
    }

    int duckTime = 0;
    int ducking = 0;
    int ducked = 0;
    int inDuckJump = 0;
    float view[3];
    float maxspeed = 0.0;

    bool hasDuckTime = CS2M_CrouchGetIntProp(client, "m_nDuckTimeMsecs", duckTime);
    bool hasDucking = CS2M_CrouchGetIntProp(client, "m_bDucking", ducking);
    bool hasDucked = CS2M_CrouchGetIntProp(client, "m_bDucked", ducked);
    bool hasDuckJump = CS2M_CrouchGetIntProp(client, "m_bInDuckJump", inDuckJump);
    bool hasView = CS2M_CrouchGetVectorProp(client, "m_vecViewOffset", view);
    bool hasMaxspeed = CS2M_CrouchGetFloatProp(client, "m_flMaxspeed", maxspeed);

    ReplyToCommand(client,
        "[CS2Movement]   duckTime=%s(%d amount=%.2f) ducking=%s(%d) ducked=%s(%d) inDuckJump=%s(%d)",
        hasDuckTime ? "yes" : "no", duckTime, hasDuckTime ? CS2M_CrouchDuckAmount(duckTime) : 0.0,
        hasDucking ? "yes" : "no", ducking,
        hasDucked ? "yes" : "no", ducked,
        hasDuckJump ? "yes" : "no", inDuckJump);

    ReplyToCommand(client,
        "[CS2Movement]   viewOffset=%s(%.1f,%.1f,%.1f) m_flMaxspeed=%s(%.1f) blocked_ducks=%d",
        hasView ? "yes" : "no", hasView ? view[0] : 0.0, hasView ? view[1] : 0.0, hasView ? view[2] : 0.0,
        hasMaxspeed ? "yes" : "no", maxspeed, g_iDuckBlocked[client]);

    ReplyToCommand(client,
        "[CS2Movement]   model_amount=%.3f last_written_msecs=%d wrote_state=%d wrote_view=%d crouch_enforce=%d write_props=%d",
        g_fDuckAmount[client], g_iLastWrittenDuckMsecs[client],
        g_bCrouchWroteState[client] ? 1 : 0, g_bCrouchWroteView[client] ? 1 : 0,
        GetConVarInt(FindConVar("cs2movement_crouch_enforce")),
        GetConVarInt(FindConVar("cs2movement_write_props")));
}
