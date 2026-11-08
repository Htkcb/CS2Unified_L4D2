/**
 * cs2unified.sp -- CS2Unified_L4D2 entry point.
 *
 * One .smx that contains:
 *   feel/      cs2feel 0.5.7-m11 modules (config / spread / recoil / ballistics)
 *   movement/  cs2movement 0.5.3 modules (config / injury / water / move / crouch)
 *   cs2u_*     unified management layer (core / params / config / modes / menu)
 *
 * The upstream modules are copied by tools/sync_sources.ps1 and mechanically
 * namespaced (see docs/01_����ӳ���.md). This file owns the ONLY Plugin myinfo
 * and the ONLY public SourceMod callbacks; each upstream module exposes a
 * CS2F_/CS2M_-prefixed entry point that we dispatch to.
 *
 * Callback order is deliberate:
 *   OnPlayerRunCmd : feel first (reads the unmodified IN_ATTACK bit and writes
 *                    cmd angles), movement second (may consume IN_DUCK and
 *                    enforce per-player speed). Do not swap: movement's crouch
 *                    model can clear/modify buttons, and feel's ballistics layer
 *                    keys on the player's fire button.
 *   OnConfigsExecuted : movement first (validate + apply global sv_*), then the
 *                    unified layer schedules a short timer because AutoExecConfig
 *                    and cs2movement.cfg execute after this callback; persisted
 *                    unified settings must win last.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>
#include <menus>

#define CS2U_VERSION "1.0.17"
#define CS2U_PREFIX  "[CS2Unified]"

/* ---- merged upstream modules (generated, do not edit by hand) ------------ */
#include "feel/cs2feel_core.sp"
#include "movement/cs2movement.sp"

/* ---- unified management layer -------------------------------------------- */
#include "cs2u_shared.sp"   /* globals first: SourcePawn has no global forward refs */
#include "cs2u_visual.sp"
#include "cs2u_params.sp"
#include "cs2u_weapon.sp"   /* 1.0.11: per-weapon speed table (menu + chat input) */
#include "cs2u_env.sp"      /* 1.0.12: probe this server's tick + align to it */
#include "cs2u_core.sp"
#include "cs2u_config.sp"
#include "cs2u_modes.sp"
#include "cs2u_menu.sp"

public Plugin myinfo =
{
    name        = "CS2Unified (L4D2)",
    author      = "CS2Unified_L4D2 project",
    description = "Merged CS2 gun feel (data layer + punch) and CS2 movement, with an admin chat menu, presets and config persistence",
    version     = CS2U_VERSION,
    url         = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    return CS2F_AskPluginLoad2(myself, late, error, err_max);
}

public void OnPluginStart()
{
    /* Upstream modules first: they create their ConVars, load gamedata and
     * their own config tables. The unified layer then adds its own ConVars,
     * reads configs/cs2unified/cs2unified.cfg and registers the admin menu. */
    CS2F_OnPluginStart();
    CS2M_OnPluginStart();
    CS2U_OnPluginStart();

    PrintToServer("%s LOAD version=%s feel=%s movement=%s",
                  CS2U_PREFIX, CS2U_VERSION, CS2F_VERSION, CS2M_VERSION);
}

public void OnConfigsExecuted()
{
    CS2M_OnConfigsExecuted();
    CS2U_OnConfigsExecuted();
}

public void OnMapStart()
{
    CS2U_BmodeQueryAllSoon();
    CS2U_OnMapStart();
    /* 1.0.12: re-assert the stored tick adaptation (it is not one of the 39
     * settings, so nothing else puts it back) and report a tick-rate change
     * instead of silently re-adapting. */
    CS2U_EnvOnMapStart();
}

public void OnPluginEnd()
{
    CS2U_OnPluginEnd();
    CS2M_OnPluginEnd();
    CS2F_OnPluginEnd();
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse,
                             float vel[3], float angles[3], int &weapon,
                             int &subtype, int &cmdnum, int &tickcount,
                             int &seed, int mouse[2])
{
    /* 1.0.13: the feel layers are the only per-player path that used to run for
     * every team (movement has been survivor-gated since 0.4.7).  CS2U_ShouldRunFeel
     * skips ONLY the infected team, so survivors / spectators / unassigned clients
     * get exactly the pre-1.0.13 behaviour.  The switch exists so an operator can
     * go back to the ungated version without a rebuild. */
    Action feelResult = Plugin_Continue;
    if (CS2U_ShouldRunFeel(client))
        feelResult = CS2F_OnPlayerRunCmd(client, buttons, impulse, vel, angles,
                                         weapon, subtype, cmdnum, tickcount,
                                         seed, mouse);
    Action moveResult = CS2M_OnPlayerRunCmd(client, buttons, impulse, vel, angles,
                                            weapon, subtype, cmdnum, tickcount,
                                            seed, mouse);

    if (feelResult == Plugin_Changed || moveResult == Plugin_Changed)
        return Plugin_Changed;
    if (feelResult == Plugin_Handled || moveResult == Plugin_Handled)
        return Plugin_Handled;
    return Plugin_Continue;
}

/* Note: there is no SourceMod OnPostThink forward (checked against the 1.12
 * includes). Movement installs SDKHook_PostThink per client inside
 * CS2M_OnClientPutInServer, so no dispatch is needed here. */

public void OnClientPutInServer(int client)
{
    CS2M_OnClientPutInServer(client);
    /* trajectory mode auto policy: ask this client whether it runs the aim-sync
     * module (its own ConVar); the answer feeds CS2U_BmodeEffective(). */
    CS2U_BmodeQuerySoon(client);
}

public void OnClientDisconnect(int client)
{
    CS2M_OnClientDisconnect(client);
    /* A half-typed weapon-speed edit must not survive into the next occupant
     * of this client slot. */
    CS2U_WeaponClearInput(client);
}

/* Chat entry is !cs2u (SourceMod maps it to sm_cs2u). Optional aliases
 * (!menu / !c2u) are opt-in via cs2u_menu_chat_alias 1; default 0 avoids
 * colliding with the many plugins that own !menu. */
public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
    return CS2U_OnClientSayCommand(client, command, sArgs);
}
