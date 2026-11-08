/**
 * cs2u_layout.sp -- menu.cfg loader, validation and built-in default layout.
 *
 * The menu is still defined in code (stable item keys); the config only owns
 * grouping order, basic-view visibility, page permissions, telemetry and the
 * auth lists. That keeps every key statically checkable and lets a bad file
 * fall back to the built-in layout without leaving a half-rendered menu.
 *
 * File: addons/sourcemod/configs/cs2unified/menu.cfg
 *
 *   "CS2UnifiedMenu"
 *   {
 *       "schema" "1"
 *       "menu"
 *       {
 *           "advanced_default" "0"
 *           "default_preset" "cs2_full"
 *           "order.presets" "preset:cs2_full,preset:cs2_tracer,..."
 *           "order.feel"    "act:recoil,act:bmode,cvar:cs2feel_enable,..."
 *           "order.move"    "act:slide_tier,cvar:cs2movement_crouch_slide,..."
 *           "order.visual"  "cvar:cs2u_tracer_enable,...,act:camera_detect"
 *           "order.status"  "act:status_full,act:status_plain,act:auth_log,..."
 *           "order.config"  "act:save,act:save_custom,act:reload,act:rollback,act:path,act:menu_reset"
 *           "visible.basic" "presets,feel,move,visual,status"
 *           "perm.config" "root"
 *           "perm.diy"    "root"
 *           "perm.diag"   "root"
 *           "confirm_destructive" "0"
 *           "telemetry" "1"
 *       }
 *       "auth"
 *       {
 *           "priority" "steamid"
 *           "steamids" { "0" "STEAM_1:0:xxxxxx root" }
 *           "groups"   { "0" "Full Admins root" }
 *       }
 *   }
 *
 * Fail-closed: parse error, unknown/duplicate item key, empty order list,
 * priority != steamid, or more than 20 configurable keys rejects the whole
 * layout and restores the built-in default (MENU-CONFIG-FALLBACK); the auth
 * lists are cleared too, so a bad file falls back to SourceMod flags instead
 * of locking every admin out.
 */

#if defined _cs2u_layout_included
 #endinput
#endif
#define _cs2u_layout_included

#define CS2U_MENU_CFG_ABSENT "\x01"
#define CS2U_MENU_CFG_MAX_KEYS 20

void CS2U_MenuCfgPath(char[] path, int maxlen)
{
    BuildPath(Path_SM, path, maxlen, "configs/cs2unified/menu.cfg");
}

void CS2U_CtxName(int ctx, char[] out, int maxlen)
{
    switch (ctx)
    {
        case CS2U_CTX_PRESETS: strcopy(out, maxlen, "presets");
        case CS2U_CTX_FEEL:    strcopy(out, maxlen, "feel");
        case CS2U_CTX_MOVE:    strcopy(out, maxlen, "move");
        case CS2U_CTX_VISUAL:  strcopy(out, maxlen, "visual");
        case CS2U_CTX_STATUS:  strcopy(out, maxlen, "status");
        case CS2U_CTX_CONFIG:  strcopy(out, maxlen, "config");
        default:               strcopy(out, maxlen, "root");
    }
}

bool CS2U_OrderHas(int ctx, const char[] key)
{
    for (int i = 0; i < g_iOrderCount[ctx]; i++)
        if (StrEqual(g_sOrder[ctx][i], key, false))
            return true;
    return false;
}

bool CS2U_OrderPush(int ctx, const char[] key)
{
    if (g_iOrderCount[ctx] >= CS2U_MAX_ORDER)
        return false;
    strcopy(g_sOrder[ctx][g_iOrderCount[ctx]], CS2U_ITEM_KEY_LEN, key);
    g_iOrderCount[ctx]++;
    return true;
}

void CS2U_PushCvar(int ctx, const char[] cvar)
{
    char key[CS2U_ITEM_KEY_LEN];
    Format(key, sizeof(key), "cvar:%s", cvar);
    CS2U_OrderPush(ctx, key);
}

void CS2U_PushAct(int ctx, const char[] id)
{
    char key[CS2U_ITEM_KEY_LEN];
    Format(key, sizeof(key), "act:%s", id);
    CS2U_OrderPush(ctx, key);
}

void CS2U_PushPreset(int ctx, const char[] name)
{
    char key[CS2U_ITEM_KEY_LEN];
    Format(key, sizeof(key), "preset:%s", name);
    CS2U_OrderPush(ctx, key);
}

/* Which page owns an action id; also the allow-list for "act:" keys. */
int CS2U_ActionCtx(const char[] id)
{
    if (StrEqual(id, "recoil") || StrEqual(id, "bmode")
     || StrEqual(id, "clientinfo") || StrEqual(id, "facts"))
        return CS2U_CTX_FEEL;
    if (StrEqual(id, "slide_tier"))
        return CS2U_CTX_MOVE;
    if (StrEqual(id, "weapon_speeds"))
        return CS2U_CTX_MOVE;
    /* 1.0.12: the tick-environment page hangs off movement.  It is code-owned
     * like weapon_speeds (no CS2U_CTX_* of its own: the seven-context contract
     * is what menu.cfg is allowed to order, and this page has no order). */
    if (StrEqual(id, "env_adapt"))
        return CS2U_CTX_MOVE;
    if (StrEqual(id, "camera_detect") || StrEqual(id, "camera_zero")
     || StrEqual(id, "camera_off") || StrEqual(id, "camera_note"))
        return CS2U_CTX_VISUAL;
    if (StrEqual(id, "status_full") || StrEqual(id, "status_plain")
     || StrEqual(id, "auth_log")
     || StrEqual(id, "diag_verify") || StrEqual(id, "diag_move")
     || StrEqual(id, "diag_gamedata") || StrEqual(id, "diag_l4n"))
        return CS2U_CTX_STATUS;
    if (StrEqual(id, "save") || StrEqual(id, "save_custom")
     || StrEqual(id, "reload") || StrEqual(id, "rollback")
     || StrEqual(id, "path") || StrEqual(id, "menu_reset"))
        return CS2U_CTX_CONFIG;
    return -1;
}

bool CS2U_ItemKnown(int ctx, const char[] key)
{
    if (StrContains(key, "cvar:", false) == 0)
        return CS2U_ParamFind(key[5]) >= 0;
    if (StrContains(key, "preset:", false) == 0)
        return ctx == CS2U_CTX_PRESETS && CS2U_ModeFind(key[7]) >= 0;
    if (StrContains(key, "act:", false) == 0)
        return CS2U_ActionCtx(key[4]) == ctx;
    return false;
}

/* Built-in layout. Preset order follows the 2026-10/11 ACTION-log ranking;
 * slide first inside movement; tracer first inside visual. */
void CS2U_MenuCfgDefaults()
{
    for (int c = 0; c < CS2U_CTX_COUNT; c++)
    {
        g_iOrderCount[c] = 0;
        g_bBasicVisible[c] = false;
    }
    g_bBasicVisible[CS2U_CTX_PRESETS] = true;
    g_bBasicVisible[CS2U_CTX_FEEL] = true;
    g_bBasicVisible[CS2U_CTX_MOVE] = true;
    g_bBasicVisible[CS2U_CTX_VISUAL] = true;
    g_bBasicVisible[CS2U_CTX_STATUS] = true;
    g_bBasicVisible[CS2U_CTX_CONFIG] = false;

    g_bMenuAdvancedDefault = false;
    g_bMenuTelemetry = true;
    g_bMenuConfirmDestructive = false;
    g_bPermConfig = true;
    g_bPermDiy = true;
    g_bPermDiag = true;

    /* presets: measured frequency first, then any remaining stored preset. */
    char preferred[7][CS2U_NAME_LEN] = {
        "cs2_full", "cs2_tracer", "cs2_matched", "cs2_competitive",
        "movement_only", "cs2_split", "vanilla"
    };
    for (int i = 0; i < 7; i++)
        if (CS2U_ModeFind(preferred[i]) >= 0)
            CS2U_PushPreset(CS2U_CTX_PRESETS, preferred[i]);
    for (int i = 0; i < g_iPresetCount; i++)
    {
        char key[CS2U_ITEM_KEY_LEN];
        Format(key, sizeof(key), "preset:%s", g_sPresetName[i]);
        if (!CS2U_OrderHas(CS2U_CTX_PRESETS, key))
            CS2U_OrderPush(CS2U_CTX_PRESETS, key);
    }

    /* feel: structure decisions first, then the raw parameters. */
    CS2U_PushAct(CS2U_CTX_FEEL, "recoil");
    CS2U_PushAct(CS2U_CTX_FEEL, "bmode");
    CS2U_PushAct(CS2U_CTX_FEEL, "clientinfo");
    CS2U_PushAct(CS2U_CTX_FEEL, "facts");
    for (int i = 0; i < g_iParamCount; i++)
    {
        if (g_iParamGroup[i] != PARAM_GROUP_FEEL)
            continue;
        if (StrEqual(g_sParamCvar[i], "cs2u_bmode", false))
            continue;   /* represented by act:bmode */
        CS2U_PushCvar(CS2U_CTX_FEEL, g_sParamCvar[i]);
    }

    /* move: slide group (highest measured frequency), then injury, then water,
     * then speed. */
    CS2U_PushAct(CS2U_CTX_MOVE, "slide_tier");
    CS2U_PushCvar(CS2U_CTX_MOVE, "cs2movement_crouch_slide");
    CS2U_PushCvar(CS2U_CTX_MOVE, "cs2movement_crouch_slide_client");
    CS2U_PushCvar(CS2U_CTX_MOVE, "cs2movement_crouch_slide_min_speed");
    for (int i = 0; i < g_iParamCount; i++)
        if (g_iParamGroup[i] == PARAM_GROUP_INJURY)
            CS2U_PushCvar(CS2U_CTX_MOVE, g_sParamCvar[i]);
    for (int i = 0; i < g_iParamCount; i++)
        if (g_iParamGroup[i] == PARAM_GROUP_WATER)
            CS2U_PushCvar(CS2U_CTX_MOVE, g_sParamCvar[i]);
    for (int i = 0; i < g_iParamCount; i++)
    {
        if (g_iParamGroup[i] != PARAM_GROUP_MOVE)
            continue;
        if (StrEqual(g_sParamCvar[i], "cs2movement_crouch_slide", false)
         || StrEqual(g_sParamCvar[i], "cs2movement_crouch_slide_client", false)
         || StrEqual(g_sParamCvar[i], "cs2movement_crouch_slide_time", false)
         || StrEqual(g_sParamCvar[i], "cs2movement_crouch_slide_min_speed", false))
            continue;
        CS2U_PushCvar(CS2U_CTX_MOVE, g_sParamCvar[i]);
    }

    /* 1.0.11: entry to the per-weapon speed table.  Last on the page on
     * purpose -- it is a read-mostly table, not a knob you touch every round. */
    CS2U_PushAct(CS2U_CTX_MOVE, "weapon_speeds");

    /* 1.0.12: environment adaptation.  After the table: it is a "set up once
     * per server" action, not part of a round's tuning. */
    CS2U_PushAct(CS2U_CTX_MOVE, "env_adapt");

    /* visual: tracer parameters, then the client-side camera guide rows. */
    for (int i = 0; i < g_iParamCount; i++)
        if (g_iParamGroup[i] == PARAM_GROUP_VISUAL)
            CS2U_PushCvar(CS2U_CTX_VISUAL, g_sParamCvar[i]);
    CS2U_PushAct(CS2U_CTX_VISUAL, "camera_detect");
    CS2U_PushAct(CS2U_CTX_VISUAL, "camera_zero");
    CS2U_PushAct(CS2U_CTX_VISUAL, "camera_off");
    CS2U_PushAct(CS2U_CTX_VISUAL, "camera_note");

    /* status / diagnostics. */
    CS2U_PushAct(CS2U_CTX_STATUS, "status_full");
    CS2U_PushAct(CS2U_CTX_STATUS, "status_plain");
    CS2U_PushAct(CS2U_CTX_STATUS, "auth_log");
    CS2U_PushAct(CS2U_CTX_STATUS, "diag_verify");
    CS2U_PushAct(CS2U_CTX_STATUS, "diag_move");
    CS2U_PushAct(CS2U_CTX_STATUS, "diag_gamedata");
    CS2U_PushAct(CS2U_CTX_STATUS, "diag_l4n");

    /* config page. */
    CS2U_PushAct(CS2U_CTX_CONFIG, "save");
    CS2U_PushAct(CS2U_CTX_CONFIG, "save_custom");
    CS2U_PushAct(CS2U_CTX_CONFIG, "reload");
    CS2U_PushAct(CS2U_CTX_CONFIG, "rollback");
    CS2U_PushAct(CS2U_CTX_CONFIG, "path");
    CS2U_PushAct(CS2U_CTX_CONFIG, "menu_reset");
}

/* A menu.cfg written before a managed parameter existed must not hide that
 * parameter.  deploy.ps1 installs menu.cfg with onlyIfMissing, so an upgraded
 * server keeps its old file -- and would then render no row for the new water
 * pair while the cvar itself works and is settable from sm_cs2u_set.  Append
 * (never reorder, never duplicate) every managed parameter that belongs to a
 * context but has no key in the stored order. */
void CS2U_OrderAppendMissing(int ctx)
{
    if (ctx == CS2U_CTX_PRESETS)
    {
        for (int i = 0; i < g_iPresetCount; i++)
        {
            char key[CS2U_ITEM_KEY_LEN];
            Format(key, sizeof(key), "preset:%s", g_sPresetName[i]);
            if (!CS2U_OrderHas(ctx, key))
                CS2U_OrderPush(ctx, key);
        }
        return;
    }

    bool feelCtx   = (ctx == CS2U_CTX_FEEL);
    bool moveCtx   = (ctx == CS2U_CTX_MOVE);
    bool visualCtx = (ctx == CS2U_CTX_VISUAL);
    if (!feelCtx && !moveCtx && !visualCtx)
        return;

    /* cs2u_bmode is represented by act:bmode when that row is present. */
    bool bmodeIsAction = feelCtx && CS2U_OrderHas(ctx, "act:bmode");

    for (int i = 0; i < g_iParamCount; i++)
    {
        int group = g_iParamGroup[i];
        bool belongs;
        if (feelCtx)        belongs = (group == PARAM_GROUP_FEEL);
        else if (visualCtx) belongs = (group == PARAM_GROUP_VISUAL);
        else                belongs = (group == PARAM_GROUP_MOVE
                                    || group == PARAM_GROUP_INJURY
                                    || group == PARAM_GROUP_WATER);
        if (!belongs)
            continue;
        if (bmodeIsAction && StrEqual(g_sParamCvar[i], "cs2u_bmode", false))
            continue;

        char key[CS2U_ITEM_KEY_LEN];
        Format(key, sizeof(key), "cvar:%s", g_sParamCvar[i]);
        if (!CS2U_OrderHas(ctx, key))
            CS2U_OrderPush(ctx, key);
    }

    /* Code-owned feature entry (1.0.11).  A menu.cfg written before the
     * weapon-speed page existed has no act:weapon_speeds, and without this the
     * table would be unreachable from the menu on every upgraded server. */
    if (moveCtx && !CS2U_OrderHas(ctx, "act:weapon_speeds"))
        CS2U_OrderPush(ctx, "act:weapon_speeds");

    /* Same trap, second time (1.0.12): an upgraded server keeps its old
     * menu.cfg, so the environment page needs the same fallback or it is
     * permanently hidden while sm_cs2u_env works fine. */
    if (moveCtx && !CS2U_OrderHas(ctx, "act:env_adapt"))
        CS2U_OrderPush(ctx, "act:env_adapt");
}

void CS2U_MenuCfgFallback(const char[] reason)
{
    CS2U_MenuCfgDefaults();
    CS2U_AuthClear();
    strcopy(g_sMenuCfgError, sizeof(g_sMenuCfgError), reason);
    g_bMenuCfgLoaded = true;
    g_bMenuTelemetry = false;
    CS2U_Log("MENU-CONFIG-FALLBACK reason=%s", reason);
}

bool CS2U_MenuCfgParseOrder(int ctx, const char[] keyName, const char[] raw,
                            char[] err, int errLen)
{
    char ctxName[16];
    CS2U_CtxName(ctx, ctxName, sizeof(ctxName));

    char parts[CS2U_MAX_ORDER][CS2U_ITEM_KEY_LEN];
    int n = ExplodeString(raw, ",", parts, CS2U_MAX_ORDER, CS2U_ITEM_KEY_LEN);
    if (n <= 0)
    {
        Format(err, errLen, "%s is empty", keyName);
        return false;
    }
    if (n >= CS2U_MAX_ORDER)
    {
        Format(err, errLen, "%s has too many items (>=%d)", keyName, CS2U_MAX_ORDER);
        return false;
    }

    char tmp[CS2U_MAX_ORDER][CS2U_ITEM_KEY_LEN];
    int tn = 0;
    for (int i = 0; i < n; i++)
    {
        TrimString(parts[i]);
        if (parts[i][0] == '\0')
            continue;
        if (!CS2U_ItemKnown(ctx, parts[i]))
        {
            Format(err, errLen, "%s: unknown item '%s'", keyName, parts[i]);
            return false;
        }
        for (int j = 0; j < tn; j++)
        {
            if (StrEqual(tmp[j], parts[i], false))
            {
                Format(err, errLen, "%s: duplicate item '%s'", keyName, parts[i]);
                return false;
            }
        }
        strcopy(tmp[tn], CS2U_ITEM_KEY_LEN, parts[i]);
        tn++;
    }
    if (tn == 0)
    {
        Format(err, errLen, "%s is empty after trimming", keyName);
        return false;
    }

    g_iOrderCount[ctx] = tn;
    for (int i = 0; i < tn; i++)
        strcopy(g_sOrder[ctx][i], CS2U_ITEM_KEY_LEN, tmp[i]);
    return true;
}

int CS2U_KvCount(KeyValues kv)
{
    int n = 0;
    if (kv.GotoFirstSubKey(false))
    {
        do
        {
            n++;
        }
        while (kv.GotoNextKey(false));
        kv.GoBack();
    }
    return n;
}

void CS2U_Trim(char[] s)
{
    TrimString(s);
}

/* Entry value is "<identity> <tier>" with the tier as the LAST token, so a
 * group name may contain spaces ("Full Admins root"). */
bool CS2U_ParseAuthEntry(const char[] value, bool isGroup, const char[] keyName)
{
    char work[128];
    strcopy(work, sizeof(work), value);
    CS2U_Trim(work);
    if (work[0] == '\0')
    {
        CS2U_Log("MENU-CONFIG-AUTH-SKIP %s empty", keyName);
        return false;
    }

    int len = strlen(work);
    int sp = -1;
    for (int i = len - 1; i >= 0; i--)
    {
        if (work[i] == ' ')
        {
            sp = i;
            break;
        }
    }
    if (sp <= 0 || sp >= len - 1)
    {
        CS2U_Log("MENU-CONFIG-AUTH-SKIP %s='%s' (need '<identity> <tier>')", keyName, value);
        return false;
    }

    char identity[96];
    strcopy(identity, sizeof(identity), work);
    identity[sp] = '\0';
    CS2U_Trim(identity);

    char tierStr[16];
    int t = 0;
    for (int i = sp + 1; i < len && t < sizeof(tierStr) - 1; i++)
        tierStr[t++] = work[i];
    tierStr[t] = '\0';
    CS2U_Trim(tierStr);

    int tier = CS2U_TIER_NONE;
    if (StrEqual(tierStr, "root", false))
        tier = CS2U_TIER_ROOT;
    else if (StrEqual(tierStr, "admin", false))
        tier = CS2U_TIER_ADMIN;

    if (identity[0] == '\0' || tier == CS2U_TIER_NONE)
    {
        CS2U_Log("MENU-CONFIG-AUTH-SKIP %s='%s' (bad identity/tier)", keyName, value);
        return false;
    }

    if (isGroup)
        return CS2U_AuthAddGroup(identity, tier);
    return CS2U_AuthAddSteam(identity, tier);
}

bool CS2U_PermValue(const char[] value, bool &visible)
{
    if (StrEqual(value, "root", false))
    {
        visible = true;
        return true;
    }
    if (StrEqual(value, "hidden", false))
    {
        visible = false;
        return true;
    }
    return false;
}

bool CS2U_MenuCfgLoad(bool initial, char[] msg, int msgLen)
{
    CS2U_MenuCfgDefaults();
    CS2U_AuthClear();
    g_sMenuCfgError[0] = '\0';
    g_bMenuCfgLoaded = true;

    char path[PLATFORM_MAX_PATH];
    CS2U_MenuCfgPath(path, sizeof(path));

    if (!FileExists(path))
    {
        Format(msg, msgLen, "menu.cfg absent, built-in layout in use: %s", path);
        CS2U_Log("MENU-CONFIG-DEFAULT path=%s", path);
        return true;
    }

    KeyValues kv = new KeyValues("CS2UnifiedMenu");
    if (!kv.ImportFromFile(path))
    {
        delete kv;
        CS2U_MenuCfgFallback("parse");
        Format(msg, msgLen, "menu.cfg parse failed, default layout restored");
        return false;
    }

    int keys = 0;
    bool haveMenu = kv.JumpToKey("menu");
    if (haveMenu)
    {
        keys = CS2U_KvCount(kv);

        char buf[2048], err[192];
        err[0] = '\0';

        kv.GetString("advanced_default", buf, sizeof(buf), "0");
        g_bMenuAdvancedDefault = (StringToInt(buf) != 0);
        kv.GetString("confirm_destructive", buf, sizeof(buf), "0");
        g_bMenuConfirmDestructive = (StringToInt(buf) != 0);
        kv.GetString("telemetry", buf, sizeof(buf), "1");
        g_bMenuTelemetry = (StringToInt(buf) != 0);

        kv.GetString("perm.config", buf, sizeof(buf), "root");
        if (!CS2U_PermValue(buf, g_bPermConfig))
        {
            delete kv;
            CS2U_MenuCfgFallback("perm.config");
            Format(msg, msgLen, "menu.cfg rejected: perm.config must be root|hidden");
            return false;
        }
        kv.GetString("perm.diy", buf, sizeof(buf), "root");
        if (!CS2U_PermValue(buf, g_bPermDiy))
        {
            delete kv;
            CS2U_MenuCfgFallback("perm.diy");
            Format(msg, msgLen, "menu.cfg rejected: perm.diy must be root|hidden");
            return false;
        }
        kv.GetString("perm.diag", buf, sizeof(buf), "root");
        if (!CS2U_PermValue(buf, g_bPermDiag))
        {
            delete kv;
            CS2U_MenuCfgFallback("perm.diag");
            Format(msg, msgLen, "menu.cfg rejected: perm.diag must be root|hidden");
            return false;
        }

        char orderKeys[6][24] = {
            "order.presets", "order.feel", "order.move",
            "order.visual", "order.status", "order.config"
        };
        int orderCtx[6] = {
            CS2U_CTX_PRESETS, CS2U_CTX_FEEL, CS2U_CTX_MOVE,
            CS2U_CTX_VISUAL, CS2U_CTX_STATUS, CS2U_CTX_CONFIG
        };
        for (int i = 0; i < 6; i++)
        {
            char raw[2048];
            kv.GetString(orderKeys[i], raw, sizeof(raw), CS2U_MENU_CFG_ABSENT);
            if (StrEqual(raw, CS2U_MENU_CFG_ABSENT))
                continue;
            if (!CS2U_MenuCfgParseOrder(orderCtx[i], orderKeys[i], raw, err, sizeof(err)))
            {
                delete kv;
                CS2U_MenuCfgFallback(err);
                Format(msg, msgLen, "menu.cfg rejected: %s", err);
                return false;
            }
        }

        /* Forward compatibility: an order list that predates a managed
         * parameter still gets a row for it (appended, never reordered). */
        for (int c = 0; c < CS2U_CTX_COUNT; c++)
            CS2U_OrderAppendMissing(c);

        char visible[256];
        kv.GetString("visible.basic", visible, sizeof(visible), CS2U_MENU_CFG_ABSENT);
        if (!StrEqual(visible, CS2U_MENU_CFG_ABSENT))
        {
            for (int c = 0; c < CS2U_CTX_COUNT; c++)
                g_bBasicVisible[c] = false;
            char parts[CS2U_CTX_COUNT][24];
            int n = ExplodeString(visible, ",", parts, CS2U_CTX_COUNT, 24);
            for (int i = 0; i < n; i++)
            {
                CS2U_Trim(parts[i]);
                if (StrEqual(parts[i], "presets", false))      g_bBasicVisible[CS2U_CTX_PRESETS] = true;
                else if (StrEqual(parts[i], "feel", false))    g_bBasicVisible[CS2U_CTX_FEEL] = true;
                else if (StrEqual(parts[i], "move", false))    g_bBasicVisible[CS2U_CTX_MOVE] = true;
                else if (StrEqual(parts[i], "visual", false))  g_bBasicVisible[CS2U_CTX_VISUAL] = true;
                else if (StrEqual(parts[i], "status", false))  g_bBasicVisible[CS2U_CTX_STATUS] = true;
                else if (StrEqual(parts[i], "config", false))
                {
                    delete kv;
                    Format(err, sizeof(err), "visible.basic: config is advanced-only");
                    CS2U_MenuCfgFallback(err);
                    Format(msg, msgLen, "menu.cfg rejected: %s", err);
                    return false;
                }
                else
                {
                    delete kv;
                    Format(err, sizeof(err), "visible.basic: unknown context '%s'", parts[i]);
                    CS2U_MenuCfgFallback(err);
                    Format(msg, msgLen, "menu.cfg rejected: %s", err);
                    return false;
                }
            }
        }
    }

    int authKeys = 0;
    kv.Rewind();
    if (kv.JumpToKey("auth"))
    {
        authKeys = CS2U_KvCount(kv);

        char prio[32];
        kv.GetString("priority", prio, sizeof(prio), "steamid");
        if (!StrEqual(prio, "steamid", false))
        {
            delete kv;
            CS2U_MenuCfgFallback("auth.priority");
            Format(msg, msgLen, "menu.cfg rejected: auth.priority must be steamid");
            return false;
        }

        kv.Rewind();
        if (kv.JumpToKey("auth") && kv.JumpToKey("steamids"))
        {
            if (kv.GotoFirstSubKey(false))
            {
                do
                {
                    char keyName[24], value[128];
                    kv.GetSectionName(keyName, sizeof(keyName));
                    kv.GetString(NULL_STRING, value, sizeof(value), "");
                    CS2U_ParseAuthEntry(value, false, keyName);
                }
                while (kv.GotoNextKey(false));
                kv.GoBack();
            }
            kv.GoBack();
        }

        kv.Rewind();
        if (kv.JumpToKey("auth") && kv.JumpToKey("groups"))
        {
            if (kv.GotoFirstSubKey(false))
            {
                do
                {
                    char keyName[24], value[128];
                    kv.GetSectionName(keyName, sizeof(keyName));
                    kv.GetString(NULL_STRING, value, sizeof(value), "");
                    CS2U_ParseAuthEntry(value, true, keyName);
                }
                while (kv.GotoNextKey(false));
                kv.GoBack();
            }
            kv.GoBack();
        }
    }
    delete kv;

    if (keys + authKeys > CS2U_MENU_CFG_MAX_KEYS)
    {
        char reason[96];
        Format(reason, sizeof(reason), "too_many_keys %d>%d", keys + authKeys, CS2U_MENU_CFG_MAX_KEYS);
        CS2U_MenuCfgFallback(reason);
        Format(msg, msgLen, "menu.cfg rejected: %s", reason);
        return false;
    }

    g_bMenuCfgLoaded = true;
    CS2U_Log("MENU-CONFIG-OK initial=%d keys=%d steamids=%d groups=%d",
             initial ? 1 : 0, keys + authKeys, g_iAuthSteamCount, g_iAuthGroupCount);
    CS2U_Log("AUTH-RELOAD steamids=%d groups=%d strict=%d",
             g_iAuthSteamCount, g_iAuthGroupCount, g_bAuthStrict ? 1 : 0);
    Format(msg, msgLen, "menu.cfg loaded: keys=%d steamids=%d groups=%d",
           keys + authKeys, g_iAuthSteamCount, g_iAuthGroupCount);
    return true;
}

bool CS2U_MenuCfgReload(char[] msg, int msgLen)
{
    return CS2U_MenuCfgLoad(false, msg, msgLen);
}

void CS2U_MenuCfgNotify(int client)
{
    if (client <= 0 || client > MaxClients)
        return;
    if (g_sMenuCfgError[0] == '\0' || g_bClientCfgNotified[client])
        return;
    g_bClientCfgNotified[client] = true;
    CS2U_Reply(client, "[CS2Unified] 菜单配置校验失败，已回退默认布局（%s）。详见日志 MENU-CONFIG-FALLBACK。", g_sMenuCfgError);
}
