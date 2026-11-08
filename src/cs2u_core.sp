/**
 * cs2u_core.sp -- unified lifecycle, logging, chat helpers, permissions, status.
 *
 * The unified layer NEVER replaces the upstream feature switches: cs2feel_* and
 * cs2movement_* keep their names, defaults and fail-closed guards. This layer
 * only adds orchestration (menu / config / presets) on top and can be disabled
 * with cs2u_enable 0 without touching either upstream module.
 */

#if defined _cs2u_core_included
 #endinput
#endif
#define _cs2u_core_included

/* All unified globals are declared in cs2u_shared.sp. */

/* ---- logging / replies --------------------------------------------------- */

void CS2U_Log(const char[] fmt, any ...)
{
    char buf[512];
    VFormat(buf, sizeof(buf), fmt, 2);
    LogMessage("%s", buf);
    if (g_cvUDebug != null && GetConVarBool(g_cvUDebug))
        PrintToServer("%s %s", CS2U_PREFIX, buf);
}

void CS2U_ActionLog(const char[] fmt, any ...)
{
    if (g_cvULogActions == null || !GetConVarBool(g_cvULogActions))
        return;
    char buf[512];
    VFormat(buf, sizeof(buf), fmt, 2);
    LogMessage("ACTION %s", buf);
}

void CS2U_Reply(int client, const char[] fmt, any ...)
{
    char buf[512];
    VFormat(buf, sizeof(buf), fmt, 3);
    if (client > 0 && IsClientInGame(client))
        PrintToChat(client, "%s %s", CS2U_PREFIX, buf);
    else
        PrintToServer("%s %s", CS2U_PREFIX, buf);
}

/* ---- permission / state helpers ------------------------------------------ */

bool CS2U_IsEnabled()
{
    return g_cvUEnable != null && GetConVarBool(g_cvUEnable);
}

/**
 * 1.0.13 -- should the feel layers run for this client?
 *
 * The movement layers have been survivor-gated since 0.4.7 (CS2M_IsSurvivor, with
 * a g_iSkipNotSurvivor counter).  The feel layers (recoil / ballistics / spread)
 * never were: they are driven from OnPlayerRunCmd for whoever the engine calls it
 * for.  A special infected fires no bullets, so the layers can only hurt there --
 * the recoil layer keys on the shared IN_ATTACK bit (claw, pounce and tongue all
 * use it) and the spread layer writes the fired player's weapon object.
 *
 * The gate is deliberately "not infected" instead of "is survivor": survivors,
 * spectators and unassigned clients keep byte-identical behaviour, and only the
 * infected team is skipped.  That keeps "保留原有全部效果" true by construction.
 */
bool CS2U_ShouldRunFeel(int client)
{
    if (g_cvUFeelSurvivorOnly == null || !GetConVarBool(g_cvUFeelSurvivorOnly))
        return true;
    if (client < 1 || client > MaxClients)
        return true;
    if (!IsClientInGame(client))
        return true;
    if (GetClientTeam(client) != CS2U_TEAM_INFECTED)
        return true;

    g_iFeelSkipNotSurvivor++;
    return false;
}

bool CS2U_IsAdmin(int client)
{
    if (client == 0)
        return true;
    if (g_bAuthStrict)
    {
        char source[64];
        return CS2U_AuthResolve(client, source, sizeof(source)) >= CS2U_TIER_ADMIN;
    }
    return CheckCommandAccess(client, "sm_cs2u", ADMFLAG_GENERIC);
}

bool CS2U_IsRoot(int client)
{
    if (client == 0)
        return true;
    if (g_bAuthStrict)
    {
        char source[64];
        return CS2U_AuthResolve(client, source, sizeof(source)) >= CS2U_TIER_ROOT;
    }
    return CheckCommandAccess(client, "sm_cs2u_root", ADMFLAG_ROOT);
}

int CS2U_CvInt(const char[] name)
{
    ConVar cv = FindConVar(name);
    return cv == null ? 0 : GetConVarInt(cv);
}

float CS2U_CvFloat(const char[] name)
{
    ConVar cv = FindConVar(name);
    return cv == null ? 0.0 : GetConVarFloat(cv);
}

bool CS2U_CvBool(const char[] name)
{
    ConVar cv = FindConVar(name);
    return cv != null && GetConVarBool(cv);
}

/* ---- lifecycle ----------------------------------------------------------- */

void CS2U_OnPluginStart()
{
    g_cvUVersion = CreateConVar("cs2u_version", CS2U_VERSION,
        "CS2Unified merged plugin version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    g_cvUEnable = CreateConVar("cs2u_enable", "1",
        "Master switch for the unified management layer (menu/config/presets). The upstream feel/movement layers keep their own switches.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvUDebug = CreateConVar("cs2u_debug", "0",
        "Verbose unified-layer logging (0/1).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvUMenuChatAlias = CreateConVar("cs2u_menu_chat_alias", "0",
        "0 = only !cs2u is the chat entry (recommended; SourceMod maps !cs2u to sm_cs2u). 1 = also intercept !menu / !c2u for servers where those names are free.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvULogActions = CreateConVar("cs2u_log_actions", "1",
        "1 = write every menu/config/preset action to the SourceMod log.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvUPreset = CreateConVar("cs2u_preset", "",
        "Name of the last successfully applied preset (informational; persisted in configs/cs2unified/cs2unified.cfg).",
        FCVAR_NOTIFY | FCVAR_DONTRECORD);
    g_cvUBmode = CreateConVar("cs2u_bmode", "0",
        "Trajectory mode: 0 = auto (policy over connected clients), 1 = single (server split, needs the client aim-sync for truthful decals), 2 = multi (matched server), 3 = single climb (server view 0.30 + bullet back to 1.00 so the holes climb above a static crosshair). Persisted in the unified config.",
        FCVAR_NOTIFY, true, 0.0, true, 3.0);
    g_cvUSimpleMode = CreateConVar("cs2u_simple_mode", "0",
        "1 = open the easy menu (plain-language presets) instead of the advanced parameter tree. Persisted in the unified config.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);
    /* 1.0.13: the feel layers are a survivor feature.  1 = do not run recoil /
     * ballistics / spread on the infected team (only the infected are skipped;
     * survivors and spectators are untouched).  0 = the pre-1.0.13 behaviour. */
    g_cvUFeelSurvivorOnly = CreateConVar("cs2u_feel_survivor_only", "1",
        "1 = run the feel layers (recoil / ballistics / spread) for everyone except special infected. 0 = legacy behaviour (no team gate).",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    CS2U_VisualInit();
    CS2U_ParamsInit();
    /* After movement's CS2M_OnPluginStart (dispatched before this one), so the
     * weapon table is already loaded and the page shows real values. */
    CS2U_WeaponInit();
    CS2U_ModesInit();
    CS2U_ConfigInit();
    /* After ConfigInit: the env section must already be parsed before the
     * stored tick profile is re-asserted. */
    CS2U_EnvInit();

    char menuMsg[192];
    CS2U_MenuCfgLoad(true, menuMsg, sizeof(menuMsg));

    CS2U_MenuInit();

    RegConsoleCmd("sm_cs2u", Cmd_Menu, "Open the CS2Unified admin menu (ADMFLAG_GENERIC).");
    RegConsoleCmd("sm_cs2u_menu", Cmd_Menu, "Alias of sm_cs2u.");

    RegAdminCmd("sm_cs2u_status", Cmd_Status, ADMFLAG_GENERIC,
        "Print the unified feel/movement/config status.");
    RegAdminCmd("sm_cs2u_presets", Cmd_ListPresets, ADMFLAG_GENERIC,
        "List available presets.");
    RegAdminCmd("sm_cs2u_set", Cmd_Set, ADMFLAG_GENERIC,
        "Usage: sm_cs2u_set <cvar> <value>  -- change one managed parameter with validation (ROOT-only parameters are still gated per item).");
    RegAdminCmd("sm_cs2u_preset", Cmd_Preset, ADMFLAG_ROOT,
        "Usage: sm_cs2u_preset <name>  -- apply a preset and persist it.");
    RegAdminCmd("sm_cs2u_save", Cmd_Save, ADMFLAG_ROOT,
        "Usage: sm_cs2u_save [preset]  -- save current values as persisted settings, or overwrite a preset.");
    RegAdminCmd("sm_cs2u_reload", Cmd_Reload, ADMFLAG_ROOT,
        "Reload configs/cs2unified/cs2unified.cfg (previous tables are kept on failure).");
    RegAdminCmd("sm_cs2u_rollback", Cmd_Rollback, ADMFLAG_ROOT,
        "Restore the parameter values captured before the last preset application.");
    RegAdminCmd("sm_cs2u_diag", Cmd_Diag, ADMFLAG_ROOT,
        "Run the unified diagnostics (gamedata, signatures, module status).");
    RegAdminCmd("sm_cs2u_menudump", Cmd_MenuDump, ADMFLAG_ROOT,
        "Dump the seven menu pages to the server console (no client needed; static acceptance).");
}

void CS2U_OnConfigsExecuted()
{
    /* cs2movement.cfg and AutoExecConfig execute at/after OnConfigsExecuted;
     * persisted unified settings must land last, so defer by a short timer and
     * re-assert the movement global layer afterwards.
     *
     * The handle is deliberately not stored: TIMER_FLAG_NO_MAPCHANGE closes the
     * timer on a map change, and a retained handle would then be stale. Plugin
     * unload closes any pending plugin timer automatically. */
    CreateTimer(0.50, Timer_UApplyPersisted, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_UApplyPersisted(Handle timer)
{
    if (!CS2U_IsEnabled())
        return Plugin_Stop;

    int applied = CS2U_ApplyPersistedSettings();
    if (applied > 0)
    {
        CS2U_ReconcileMovement();
        /* The persisted table is what turns crouch_slide back on after a map
         * change, so this is the moment an admin would otherwise see slide=1
         * with no slide and no explanation.  The movement helper is latched. */
        CS2M_MoveCheckSlideReadiness("persist-apply");
        CS2U_Log("PERSIST-APPLY params=%d preset=%s", applied, g_sActivePreset);
    }

    /* The tick adaptation lives outside the 39 settings, so it needs its own
     * re-assert here (and only here: an unadapted server logs nothing). */
    CS2U_EnvApplyStored();
    return Plugin_Stop;
}

void CS2U_OnPluginEnd()
{
    CS2U_ConfigShutdown();
}

void CS2U_ReconcileMovement()
{
    if (!CS2U_CvBool("cs2movement_enable"))
        return;
    if (!CS2U_CvBool("cs2movement_apply_global"))
        return;
    CS2M_MoveApplyGlobal();
    CS2M_MoveReassertGlobal();
}

/* ---- chat aliases -------------------------------------------------------- */

Action CS2U_OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
    if (client <= 0 || !CS2U_IsEnabled())
        return Plugin_Continue;
    if (!StrEqual(command, "say") && !StrEqual(command, "say_team"))
        return Plugin_Continue;

    /* Weapon-speed input mode pre-empts the chat aliases: the admin is typing a
     * number into a menu prompt, so the line must be swallowed (not broadcast)
     * even when cs2u_menu_chat_alias is 0. */
    if (CS2U_WeaponHandleInput(client, sArgs))
        return Plugin_Handled;

    if (g_cvUMenuChatAlias == null || !GetConVarBool(g_cvUMenuChatAlias))
        return Plugin_Continue;

    if (StrEqual(sArgs, "!menu", false) || StrEqual(sArgs, "!c2u", false))
    {
        if (!CS2U_AuthCheck(client, "chat-alias"))
            return Plugin_Handled;
        CS2U_MenuOpen(client);
        return Plugin_Handled;
    }
    return Plugin_Continue;
}

/* ---- console commands ---------------------------------------------------- */

public Action Cmd_Menu(int client, int args)
{
    if (client == 0)
    {
        CS2U_Reply(0, "The menu is client-only. From the server console use sm_cs2u_status / sm_cs2u_preset / sm_cs2u_set.");
        return Plugin_Handled;
    }
    if (!CS2U_IsEnabled())
    {
        CS2U_Reply(client, "Management layer is disabled (cs2u_enable 0).");
        return Plugin_Handled;
    }
    if (!CS2U_AuthCheck(client, "command"))
        return Plugin_Handled;
    CS2U_MenuOpen(client);
    return Plugin_Handled;
}

public Action Cmd_Status(int client, int args)
{
    CS2U_PrintStatus(client);
    return Plugin_Handled;
}

public Action Cmd_ListPresets(int client, int args)
{
    CS2U_Reply(client, "预设 / Presets (%d):", CS2U_ModeCount());
    for (int i = 0; i < CS2U_ModeCount(); i++)
    {
        char name[32], label[64];
        CS2U_ModeName(i, name, sizeof(name));
        CS2U_ModeLabelCn(name, label, sizeof(label));
        CS2U_Reply(client, "  %s（%s）%s", label, name,
                   StrEqual(name, g_sActivePreset) ? "  [active]" : "");
    }
    return Plugin_Handled;
}

public Action Cmd_Set(int client, int args)
{
    if (!CS2U_IsEnabled())
    {
        CS2U_Reply(client, "Management layer is disabled (cs2u_enable 0).");
        return Plugin_Handled;
    }
    if (args < 2)
    {
        CS2U_Reply(client, "Usage: sm_cs2u_set <cvar> <value>");
        return Plugin_Handled;
    }
    char cvar[64], value[32], err[192];
    GetCmdArg(1, cvar, sizeof(cvar));
    GetCmdArg(2, value, sizeof(value));

    int idx = CS2U_ParamFind(cvar);
    if (idx < 0)
    {
        CS2U_Reply(client, "Unknown managed parameter '%s'. Use sm_cs2u_status for the list.", cvar);
        return Plugin_Handled;
    }
    if (!CS2U_ParamCanEdit(client, idx))
    {
        CS2U_Reply(client, "Access denied: '%s' requires %s.", cvar,
                   g_iParamAccess[idx] == PARAM_ACCESS_ROOT ? "ADMFLAG_ROOT" : "ADMFLAG_GENERIC");
        return Plugin_Handled;
    }
    if (!CS2U_ParamSet(idx, value, err, sizeof(err)))
    {
        CS2U_Reply(client, "Rejected: %s", err);
        return Plugin_Handled;
    }
    char persistMsg[256];
    if (CS2U_PersistLive(persistMsg, sizeof(persistMsg)))
        CS2U_Reply(client, "OK: %s = %s (persisted)", cvar, value);
    else
        CS2U_Reply(client, "OK: %s = %s, but persistence failed: %s", cvar, value, persistMsg);

    /* cs2u_bmode is a policy value, not just a cvar: the seven structure cvars
     * must move with it.  The menu row did this, the console command did not,
     * which made `sm_cs2u_set cs2u_bmode 3` silently do nothing visible. */
    if (StrEqual(cvar, "cs2u_bmode", false))
    {
        int u = 0;
        int eff = CS2U_BmodeEffective(u);
        char bmsg[192];
        if (CS2U_BmodeApply(eff, bmsg, sizeof(bmsg)))
            CS2U_Reply(client, "结构：%s", bmsg);
        else
            CS2U_Reply(client, "结构应用失败：%s", bmsg);
    }

    CS2U_ActionLog("set cvar=%s value=%s by=%d", cvar, value, client);
    CS2U_ReconcileMovement();
    return Plugin_Handled;
}

public Action Cmd_Preset(int client, int args)
{
    char name[32], msg[256];
    if (args < 1)
    {
        CS2U_Reply(client, "Usage: sm_cs2u_preset <name>");
        return Plugin_Handled;
    }
    GetCmdArg(1, name, sizeof(name));

    if (CS2U_ModeApply(client, name, msg, sizeof(msg)))
        CS2U_Reply(client, "%s", msg);
    else
        CS2U_Reply(client, "Preset failed: %s", msg);
    return Plugin_Handled;
}

public Action Cmd_Save(int client, int args)
{
    if (!CS2U_IsEnabled())
    {
        CS2U_Reply(client, "Management layer is disabled (cs2u_enable 0).");
        return Plugin_Handled;
    }
    char name[32], msg[256];
    name[0] = '\0';
    if (args >= 1) GetCmdArg(1, name, sizeof(name));

    if (CS2U_ConfigSave(client, name, msg, sizeof(msg)))
        CS2U_Reply(client, "%s", msg);
    else
        CS2U_Reply(client, "Save failed: %s", msg);
    return Plugin_Handled;
}

public Action Cmd_Reload(int client, int args)
{
    if (!CS2U_IsEnabled())
    {
        CS2U_Reply(client, "Management layer is disabled (cs2u_enable 0).");
        return Plugin_Handled;
    }
    char msg[256], menuMsg[192];
    bool okCfg = CS2U_ConfigReload(msg, sizeof(msg));
    bool okMenu = CS2U_MenuCfgReload(menuMsg, sizeof(menuMsg));
    CS2U_Reply(client, "%s %s", okCfg ? "OK:" : "Reload failed:", msg);
    CS2U_Reply(client, "%s %s", okMenu ? "OK:" : "Menu config failed:", menuMsg);
    return Plugin_Handled;
}

public Action Cmd_Rollback(int client, int args)
{
    if (!CS2U_IsEnabled())
    {
        CS2U_Reply(client, "Management layer is disabled (cs2u_enable 0).");
        return Plugin_Handled;
    }
    char msg[256];
    if (CS2U_Rollback(msg, sizeof(msg)))
        CS2U_Reply(client, "%s", msg);
    else
        CS2U_Reply(client, "Rollback failed: %s", msg);
    return Plugin_Handled;
}

public Action Cmd_Diag(int client, int args)
{    CS2U_PrintStatus(client);

    /* Slide gate breakdown: the status line says ready=0, this says which gate
     * is the one blocking it (all of them are ANDed in
     * CS2M_MoveDuckSpeedEnabled). */
    CS2U_Reply(client, "slide gates: hook=%d enable=%d duck_speed=%d weapon_speed_mode=%d write_props=%d speed_enforce=%d (all required)",
               g_bCheckParamsReady ? 1 : 0,
               CS2U_CvInt("cs2movement_enable"),
               CS2U_CvInt("cs2movement_duck_speed"),
               CS2U_CvInt("cs2movement_weapon_speed_mode"),
               CS2U_CvInt("cs2movement_write_props"),
               CS2U_CvInt("cs2movement_speed_enforce"));

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "gamedata/l4d2_cs2feel.txt");
    CS2U_Reply(client, "gamedata l4d2_cs2feel.txt: %s", FileExists(path) ? "present" : "MISSING");
    BuildPath(Path_SM, path, sizeof(path), "gamedata/cs2movement.txt");
    CS2U_Reply(client, "gamedata cs2movement.txt: %s", FileExists(path) ? "present" : "MISSING");
    CS2U_ConfigPath(path, sizeof(path));
    CS2U_Reply(client, "config: %s", path);
    CS2U_Reply(client, "feel config: weapons=%d mapped=%d native=%d",
               CS2F_ConfigWeaponCount(), CS2F_ConfigMappedCount(), CS2F_ConfigNativeCount());
    if (!g_bSigReady)
    {
        char sigErr[192];
        strcopy(sigErr, sizeof(sigErr), g_sSigError);
        CS2U_Reply(client, "feel signature error: %s", sigErr);
    }
    return Plugin_Handled;
}

public Action Cmd_MenuDump(int client, int args)
{
    CS2U_MenuDumpAll();
    CS2U_Reply(client, "menu dump: 7 contexts written to the server console");
    return Plugin_Handled;
}

/* ---- status -------------------------------------------------------------- */

void CS2U_PrintStatus(int client)
{
    char version[32];
    GetConVarString(g_cvUVersion, version, sizeof(version));
    CS2U_Reply(client, "== CS2Unified %s ==", version);
    CS2U_Reply(client, "management: enable=%d config=%s preset=%s managed_params=%d",
               CS2U_CvInt("cs2u_enable"),
               g_bUConfigLoaded ? "loaded" : "not-loaded",
               g_sActivePreset[0] ? g_sActivePreset : "(none)",
               CS2U_ParamCount());
    if (g_sUConfigError[0] != '\0')
        CS2U_Reply(client, "config error: %s", g_sUConfigError);
    CS2U_Reply(client, "menu: layout=%s advanced_default=%d auth=%s steamids=%d groups=%d",
               g_bMenuCfgLoaded ? "loaded" : "fallback",
               g_bMenuAdvancedDefault ? 1 : 0,
               g_bAuthStrict ? "strict" : "flag",
               g_iAuthSteamCount, g_iAuthGroupCount);
    if (g_sMenuCfgError[0] != '\0')
        CS2U_Reply(client, "menu config error: %s", g_sMenuCfgError);
    CS2U_Reply(client, "feel: active=%d sig_ready=%d offset=%d weapons=%d mapped=%d",
               g_bActive ? 1 : 0, g_bSigReady ? 1 : 0, g_iSpreadOffset,
               CS2F_ConfigWeaponCount(), CS2F_ConfigMappedCount());
    CS2U_Reply(client, "feel: recoil_mode=%d scale=%.3f view=%.3f ballistics_mode=%d scale=%.3f yaw=%d spread_mode=%d",
               CS2U_CvInt("cs2feel_recoil_mode"),
               CS2U_CvFloat("cs2feel_recoil_scale"),
               CS2U_CvFloat("cs2feel_recoil_view_scale"),
               CS2U_CvInt("cs2feel_ballistics_mode"),
               CS2U_CvFloat("cs2feel_ballistics_scale"),
               CS2U_CvInt("cs2feel_ballistics_yaw"),
               CS2U_CvInt("cs2feel_spread_mode"));
    /* 1.0.13: team scope.  feel_survivor_only=1 is the shipped policy (the
     * infected team is skipped in OnPlayerRunCmd); the two counters are the
     * evidence that the gates are actually firing at runtime. */
    CS2U_Reply(client, "team gate: feel_survivor_only=%d feel_skipped_infected=%d movement_skipped_non_survivor=%d",
               CS2U_CvInt("cs2u_feel_survivor_only"), g_iFeelSkipNotSurvivor, g_iSkipNotSurvivor);
    CS2U_Reply(client, "movement: enable=%d engine=%d duck=%d air_jump=%d sustain=%d slide=%d maxspeed=%.1f",
               CS2U_CvInt("cs2movement_enable"),
               CS2U_CvInt("cs2movement_engine_speed"),
               CS2U_CvInt("cs2movement_duck_speed"),
               CS2U_CvInt("cs2movement_air_jump_speed"),
               CS2U_CvInt("cs2movement_lowspeed_sustain"),
               CS2U_CvInt("cs2movement_crouch_slide"),
               CS2U_CvFloat("cs2movement_maxspeed"));
    /* The one thing that CANNOT be per-team: the engine's own physics cvars.
     * apply_global writes them and every player, infected included, uses them.
     * sv_maxspeed is deliberately absent (0.4.8: it capped the Charger charge).
     * Printed here so "does this touch my specials?" has a factual answer. */
    CS2U_Reply(client, "global physics: apply_global=%d accel=%.2f friction=%.2f stopspeed=%.1f airaccel=%.1f gravity=%.0f maxvel=%.0f (engine-wide -> infected follow these too; sv_maxspeed is never written)",
               CS2U_CvInt("cs2movement_apply_global"),
               CS2U_CvFloat("sv_accelerate"), CS2U_CvFloat("sv_friction"),
               CS2U_CvFloat("sv_stopspeed"), CS2U_CvFloat("sv_airaccelerate"),
               CS2U_CvFloat("sv_gravity"), CS2U_CvFloat("sv_maxvelocity"));

    /* Crouch slide effectiveness: cvar on is not the same as "a slide can
     * start".  ready=0 means the duck layer (CheckParameters post-hook) is not
     * armed, so g_fSlideDuckTarget never updates and starts/writes stay 0.
     * client_slide says whether the replicated survivor_crouch_speed half is
     * also driving the client curve (and missing = engine cvar not found). */
    char clientSlide[96];
    CS2M_MoveSlideClientStatus(clientSlide, sizeof(clientSlide));
    CS2U_Reply(client, "slide: cvar=%d ready=%d duck_layer=%d hook=%d time=%.2f min_speed=%.1f starts=%d writes=%d last_client=%d v0=%.2f ceil=%.2f %s",
               CS2M_MoveCrouchSlideEnabled() ? 1 : 0,
               CS2M_MoveCrouchSlideReady() ? 1 : 0,
               CS2M_MoveDuckSpeedEnabled() ? 1 : 0,
               g_bCheckParamsReady ? 1 : 0,
               CS2U_CvFloat("cs2movement_crouch_slide_time"),
               CS2U_CvFloat("cs2movement_crouch_slide_min_speed"),
               g_iSlideStarts, g_iSlideWrites, g_iSlideLastClient,
               g_fSlideLastV0, g_fSlideLastCeil, clientSlide);

    /* Water depth (movement 0.5.3): "switch on" is not "effect visible", so
     * print the resolved factor table plus the number of times the layer
     * actually lowered a target.  caps=0 with enable=1 means either nobody is
     * wet or the depth prop is missing -- sm_cs2movement_water names which. */
    CS2U_Reply(client, "water: enable=%d slowdown=%.3f ankle=%.3f waist=%.3f eyes=%.3f caps=%d (survivors only, needs weapon_speed_mode 1)",
               CS2U_CvInt("cs2movement_water_enable"),
               CS2U_CvFloat("cs2movement_water_slowdown"),
               CS2M_WaterFactorForLevel(1),
               CS2M_WaterFactorForLevel(2),
               CS2M_WaterFactorForLevel(3),
               g_iWaterCaps);

    CS2U_Reply(client, "visual: tracer=%d simple_mode=%d",
               CS2U_CvInt("cs2u_tracer_enable"),
               CS2U_CvInt("cs2u_simple_mode"));

    /* Tick environment: the measured rate is the only trustworthy input, and
     * the stored adaptation is a separate channel from the 39 settings, so it
     * gets its own line (hz / band / what the profile resolves to / stored). */
    CS2U_EnvProbe();
    CS2U_EnvPlanBuild();
    CS2U_Reply(client, "env: hz=%.2f dedicated=%d maxplayers=%d band=%d profile_cvar=%d profile_resolved=%d stored=%d plan=%d",
               g_fEnvHz + 0.0005, g_bEnvDedicated ? 1 : 0, g_iEnvMaxPlayers, g_iEnvBand,
               g_iEnvProfileCvar, g_iEnvProfileResolved,
               g_bEnvPersist ? g_iEnvPersistProfile : -1,
               CS2U_EnvPlanTotal());
}
