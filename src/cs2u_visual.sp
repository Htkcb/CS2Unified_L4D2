/**
 * cs2u_visual.sp -- server-side visual aids.
 *
 * Currently one aid: a tracer beam drawn from the shooter's eye to the bullet
 * impact point. It exists so players who do not read spread tables can SEE
 * where a burst is going (the "CS2 recoil + tracer" easy preset enables it).
 *
 * Notes / boundaries:
 *   - The beam is a temp entity sent to all clients; it is visual only and does
 *     not change hit registration.
 *   - bullet_impact fires per pellet; a 50 ms per-client throttle keeps a
 *     shotgun blast from spawning a dozen beams.
 *   - Off by default (cs2u_tracer_enable 0); the sprite is precached on map
 *     start and the feature degrades to a no-op if precache fails.
 */

#if defined _cs2u_visual_included
 #endinput
#endif
#define _cs2u_visual_included

#define CS2U_TRACER_SPRITE "materials/sprites/laserbeam.vmt"

void CS2U_VisualInit()
{
    g_cvUTracerEnable = CreateConVar("cs2u_tracer_enable", "0",
        "1 = draw a server-side tracer beam from the shooter to each bullet impact (visual aid; off by default).",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvUTracerWidth = CreateConVar("cs2u_tracer_width", "1.0",
        "Tracer beam width.", FCVAR_NOTIFY, true, 0.5, true, 5.0);
    g_cvUTracerLife = CreateConVar("cs2u_tracer_life", "0.20",
        "Tracer beam lifetime in seconds.", FCVAR_NOTIFY, true, 0.05, true, 1.0);
    g_cvUTracerAlpha = CreateConVar("cs2u_tracer_alpha", "110",
        "Tracer beam alpha 0-255 (higher = more opaque; 110 is visible but not view-blocking).",
        FCVAR_NOTIFY, true, 0.0, true, 255.0);

    HookEvent("bullet_impact", Event_BulletImpact, EventHookMode_Post);
}

void CS2U_OnMapStart()
{
    g_iTracerSprite = PrecacheModel(CS2U_TRACER_SPRITE);
    for (int i = 0; i <= MaxClients; i++)
        g_fTracerLast[i] = 0.0;
    if (g_iTracerSprite <= 0)
        CS2U_Log("TRACER-SPRITE-MISSING %s", CS2U_TRACER_SPRITE);
}

public Action Event_BulletImpact(Event event, const char[] name, bool dontBroadcast)
{
    if (g_cvUTracerEnable == null || !GetConVarBool(g_cvUTracerEnable))
        return Plugin_Continue;
    if (g_iTracerSprite <= 0)
        return Plugin_Continue;

    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
        return Plugin_Continue;
    if (IsFakeClient(client) || GetClientTeam(client) != 2)
        return Plugin_Continue;

    /* Shotguns emit one impact per pellet; draw at most one beam per 50 ms so
     * the tracer stays readable and cheap. */
    float now = GetGameTime();
    if (now - g_fTracerLast[client] < 0.05)
        return Plugin_Continue;
    g_fTracerLast[client] = now;

    float start[3], end[3];
    GetClientEyePosition(client, start);
    end[0] = GetEventFloat(event, "x");
    end[1] = GetEventFloat(event, "y");
    end[2] = GetEventFloat(event, "z");

    int color[4] = {255, 210, 100, 110};
    color[3] = GetConVarInt(g_cvUTracerAlpha);
    TE_SetupBeamPoints(start, end, g_iTracerSprite, 0, 0, 0,
                       GetConVarFloat(g_cvUTracerLife),
                       GetConVarFloat(g_cvUTracerWidth),
                       GetConVarFloat(g_cvUTracerWidth),
                       1, 0.0, color, 0);
    TE_SendToAll();
    return Plugin_Continue;
}
