/**
 * cs2u_menu.sp -- two-level admin menu (常用 / 高级), v1.0.5.
 *
 * Layout contract (checked by tools/verify.ps1):
 *   - at most 7 content rows per page; #8 back/previous, #9 next;
 *   - exactly seven page contexts: root / presets / feel / move / visual /
 *     status / config; no third level (values are cycled in place);
 *   - group header rows are ITEMDRAW_DISABLED (the only non-default style a
 *     paginated menu may use) and never end a page on their own;
 *   - the advanced view is root-tier only; ROOT rows are never rendered for
 *     an admin-tier caller, so no dead item is shown;
 *   - every select re-resolves identity (SteamID list > admin group) and logs
 *     AUTH-* / MENU-SELECT; a denied caller never sees a menu.
 */

#if defined _cs2u_menu_included
 #endinput
#endif
#define _cs2u_menu_included

#include "cs2u_auth.sp"
#include "cs2u_layout.sp"

#define CS2U_MENU_ROWS      7
#define CS2U_MENU_MAX_ROWS 64
#define CS2U_MENU_INFO_LEN 64
#define CS2U_MENU_DISP_LEN 192
#define CS2U_PREV_LABEL "上一页 / Previous"
#define CS2U_NEXT_LABEL "下一页 / Next"
#define CS2U_BACK_LABEL "返回 / Back"
#define CS2U_PAD_LABEL  " "

#define CS2U_L4N_CVAR     "l4n_view_punch_scale"
#define CS2U_BMODE_AUTO   0
/* 1 = single-player TR-40 look: camera 1.00 x table, bullet +1.20 on top
 * (measured 2026-11-03: gaps 4.92 / 4.92 / 5.11 deg, mean 4.98 vs TR-40's
 * 5.225).  This replaces the old "single" CS2-native split, which nobody used:
 * it put the holes BELOW the crosshair and still needed the client module for
 * truthful decals.  The CS2-exact structure has not gone away -- the
 * recoil-structure row and the cs2_split preset still own it. */
#define CS2U_BMODE_TR40   1
#define CS2U_BMODE_MULTI  2
/* Retired value from the 1.0.4/1.0.5 builds (the weak +0.30 climb).  Kept only
 * so an old persisted config keeps working: CS2U_BmodeBase migrates it to TR40. */
#define CS2U_BMODE_LEGACY_CLIMB 3

char g_sRowInfo[CS2U_MENU_MAX_ROWS][CS2U_MENU_INFO_LEN];
char g_sRowDisp[CS2U_MENU_MAX_ROWS][CS2U_MENU_DISP_LEN];
int  g_iRowStyle[CS2U_MENU_MAX_ROWS];
bool g_bRowHeader[CS2U_MENU_MAX_ROWS];
int  g_iRowCount = 0;
bool g_bMenuDump = false;   /* sm_cs2u_menudump: build pages without a client */

int  g_iPageStart[16];
int  g_iPageEnd[16];
int  g_iPageCount = 0;

/* Trajectory-mode observation state (used by the aim-sync query callbacks). */
bool g_bAimAnswered[MAXPLAYERS + 1];
bool g_bAimInstalled[MAXPLAYERS + 1];
bool g_bBmodePrompted = false;

void CS2U_MenuInit()
{
    /* Commands are registered in cs2u_core.sp; nothing to allocate here. */
}

bool CS2U_MenuClientOk(int client)
{
    if (g_bMenuDump && client == 0)
        return true;
    return client > 0 && IsClientInGame(client);
}

/* ---- row buffer ---------------------------------------------------------- */

void CS2U_RowReset()
{
    g_iRowCount = 0;
}

void CS2U_RowAdd(const char[] info, const char[] disp, int style = ITEMDRAW_DEFAULT)
{
    if (g_iRowCount >= CS2U_MENU_MAX_ROWS)
        return;
    strcopy(g_sRowInfo[g_iRowCount], CS2U_MENU_INFO_LEN, info);
    strcopy(g_sRowDisp[g_iRowCount], CS2U_MENU_DISP_LEN, disp);
    g_iRowStyle[g_iRowCount] = style;
    g_bRowHeader[g_iRowCount] = false;
    g_iRowCount++;
}

void CS2U_RowHeader(const char[] name)
{
    char disp[CS2U_MENU_DISP_LEN];
    Format(disp, sizeof(disp), "「%s」", name);
    CS2U_RowAdd("hdr", disp, ITEMDRAW_DISABLED);
    g_bRowHeader[g_iRowCount - 1] = true;
}

/* Page boundaries: never let a group header end a page. A group that spans a
 * page boundary simply continues without repeating the header. */
void CS2U_PackPages()
{
    g_iPageCount = 0;
    int start = 0;
    while (start < g_iRowCount && g_iPageCount < 15)
    {
        int end = start + CS2U_MENU_ROWS;
        if (end > g_iRowCount)
            end = g_iRowCount;
        if (end - start > 1 && g_bRowHeader[end - 1])
            end--;
        if (end <= start)
            break;
        g_iPageStart[g_iPageCount] = start;
        g_iPageEnd[g_iPageCount] = end;
        g_iPageCount++;
        start = end;
    }
    if (g_iPageCount == 0)
    {
        g_iPageStart[0] = 0;
        g_iPageEnd[0] = 0;
        g_iPageCount = 1;
    }
}

void CS2U_SetTitle(Menu m, const char[] base, int page)
{
    if (g_iPageCount > 1)
        SetMenuTitle(m, "%s\n第 %d/%d 页", base, page + 1, g_iPageCount);
    else
        SetMenuTitle(m, "%s", base);
}

bool CS2U_InfoNeedsPage(const char[] info)
{
    return StrContains(info, "cyc:", false) == 0
        || StrContains(info, "act:", false) == 0
        || StrContains(info, "preset:", false) == 0
        || StrContains(info, "wpn:", false) == 0
        || StrContains(info, "env.", false) == 0
        || StrContains(info, "diy.", false) == 0;
}

void CS2U_MenuEmit(int client, Menu m, int page, const char[] ctx)
{
    if (g_bMenuDump)
    {
        PrintToServer("[MENU-DUMP] ctx=%s pages=%d rows=%d", ctx, g_iPageCount, g_iRowCount);
        for (int p = 0; p < g_iPageCount; p++)
        {
            PrintToServer("[MENU-DUMP]   page %d/%d rows=%d", p + 1, g_iPageCount,
                          g_iPageEnd[p] - g_iPageStart[p]);
            for (int row = g_iPageStart[p]; row < g_iPageEnd[p]; row++)
                PrintToServer("[MENU-DUMP]     %-24s | %s", g_sRowInfo[row], g_sRowDisp[row]);
        }
        delete m;
        return;
    }

    if (page < 0)
        page = 0;
    if (page >= g_iPageCount)
        page = g_iPageCount - 1;

    SetMenuPagination(m, MENU_NO_PAGINATION);

    int start = g_iPageStart[page];
    int end = g_iPageEnd[page];
    int shown = 0;
    for (int row = start; row < end; row++)
    {
        char info[CS2U_MENU_INFO_LEN];
        strcopy(info, sizeof(info), g_sRowInfo[row]);
        if (CS2U_InfoNeedsPage(info))
            Format(info, sizeof(info), "%s:%d", g_sRowInfo[row], page);
        m.AddItem(info, g_sRowDisp[row], g_iRowStyle[row]);
        shown++;
    }
    for (; shown < CS2U_MENU_ROWS; shown++)
        m.AddItem("pad", CS2U_PAD_LABEL, ITEMDRAW_DISABLED);

    char info[CS2U_MENU_INFO_LEN];
    if (page > 0)
    {
        Format(info, sizeof(info), "prev:%s:%d", ctx, page - 1);
        m.AddItem(info, CS2U_PREV_LABEL);
    }
    else
    {
        m.AddItem("back", CS2U_BACK_LABEL);
    }

    if (page + 1 < g_iPageCount)
    {
        Format(info, sizeof(info), "next:%s:%d", ctx, page + 1);
        m.AddItem(info, CS2U_NEXT_LABEL);
    }

    SetMenuExitButton(m, true);
    m.Display(client, 30);
}

/* ---- pager / dispatch ---------------------------------------------------- */

bool CS2U_MenuPager(int client, const char[] info)
{
    char parts[3][CS2U_MENU_INFO_LEN];
    if (ExplodeString(info, ":", parts, 3, sizeof(parts[])) < 3)
        return false;
    if (!StrEqual(parts[0], "prev") && !StrEqual(parts[0], "next"))
        return false;
    /* "weapons" is the weapon-speed sub-page, not a layout context: it has no
     * menu.cfg order and no CS2U_CTX_* id, so it is routed here instead of in
     * CS2U_MenuByCtx (which stays exactly seven contexts).  "env" is the same
     * shape (1.0.12). */
    if (StrEqual(parts[1], "weapons"))
        CS2U_MenuWeapon(client, StringToInt(parts[2]));
    else if (StrEqual(parts[1], "env"))
        CS2U_MenuEnv(client, StringToInt(parts[2]));
    else
        CS2U_MenuByCtx(client, parts[1], StringToInt(parts[2]));
    return true;
}

void CS2U_MenuByCtx(int client, const char[] ctx, int page)
{
    if (StrEqual(ctx, "root"))         { CS2U_MenuRoot(client, page);         return; }
    if (StrEqual(ctx, "presets"))      { CS2U_MenuPresets(client, page);      return; }
    if (StrEqual(ctx, "feel"))         { CS2U_MenuFeel(client, page);         return; }
    if (StrEqual(ctx, "move"))         { CS2U_MenuMove(client, page);         return; }
    if (StrEqual(ctx, "visual"))       { CS2U_MenuVisual(client, page);       return; }
    if (StrEqual(ctx, "status"))       { CS2U_MenuStatus(client, page);       return; }
    if (StrEqual(ctx, "config"))       { CS2U_MenuConfig(client, page);       return; }
    CS2U_MenuRoot(client, 0);
}

void CS2U_MenuOpen(int client)
{
    if (client <= 0 || !IsClientInGame(client))
        return;
    if (!CS2U_AuthCheck(client, "open"))
        return;

    CS2U_AuthLogOpen(client);
    CS2U_MenuCfgNotify(client);

    if (!g_bAdvInit[client])
    {
        g_bAdvInit[client] = true;
        g_bClientAdv[client] = g_bMenuAdvancedDefault
            && g_iClientTier[client] >= CS2U_TIER_ROOT;
    }
    if (g_bClientAdv[client] && g_iClientTier[client] < CS2U_TIER_ROOT)
        g_bClientAdv[client] = false;

    CS2U_MenuRoot(client, 0);
}

/* Static acceptance helper: build and print all seven pages without a client.
 * Used by sm_cs2u_menudump; MenuEmit deletes the synthetic Menu in dump mode. */
void CS2U_MenuDumpAll()
{
    g_bMenuDump = true;
    g_iClientTier[0] = CS2U_TIER_ROOT;
    strcopy(g_sClientAuthSource[0], sizeof(g_sClientAuthSource[]), "dump");
    g_bClientAdv[0] = true;

    char ctxs[7][16] = {
        "root", "presets", "feel", "move", "visual", "status", "config"
    };
    for (int i = 0; i < 7; i++)
        CS2U_MenuByCtx(0, ctxs[i], 0);

    /* The weapon-speed sub-page is not one of the seven contexts, so dump it
     * explicitly: an admin verifying "the table is reachable" reads one line. */
    CS2U_MenuWeapon(0, 0);
    /* 1.0.12: same for the environment page. */
    CS2U_MenuEnv(0, 0);

    /* Second pass: the basic view (no DIY rows, no diagnostics/config, no
     * ROOT parameters) so both root row counts are verifiable. */
    g_bClientAdv[0] = false;
    CS2U_MenuByCtx(0, "root", 0);
    CS2U_MenuByCtx(0, "presets", 0);
    CS2U_MenuByCtx(0, "status", 0);

    g_bMenuDump = false;
    g_bClientAdv[0] = false;
    g_iClientTier[0] = CS2U_TIER_ROOT;
    strcopy(g_sClientAuthSource[0], sizeof(g_sClientAuthSource[]), "console");
}

/* ---- shared labels ------------------------------------------------------- */

void CS2U_GroupName(int ctx, int group, char[] out, int maxlen)
{
    if (ctx == CS2U_CTX_FEEL)
        strcopy(out, maxlen, group == 0 ? "结构" : "参数");
    else if (ctx == CS2U_CTX_MOVE)
    {
        if (group == 0)      strcopy(out, maxlen, "滑行");
        else if (group == 1) strcopy(out, maxlen, "受伤减速");
        else if (group == 2) strcopy(out, maxlen, "水面减速");
        else if (group == 4) strcopy(out, maxlen, "详细移动数值");
        else if (group == 5) strcopy(out, maxlen, "环境适配");
        else                 strcopy(out, maxlen, "速度与模型");
    }
    else if (ctx == CS2U_CTX_VISUAL)
        strcopy(out, maxlen, group == 0 ? "曳光" : "相机（客户端 Left4Neko）");
    else if (ctx == CS2U_CTX_STATUS)
        strcopy(out, maxlen, group == 0 ? "状态" : "诊断");
    else
        strcopy(out, maxlen, "配置与保存");
}

int CS2U_KeyGroup(int ctx, const char[] key)
{
    if (ctx == CS2U_CTX_FEEL)
        return StrContains(key, "act:", false) == 0 ? 0 : 1;

    if (ctx == CS2U_CTX_MOVE)
    {
        if (StrEqual(key, "act:slide_tier"))
            return 0;
        if (StrEqual(key, "act:weapon_speeds"))
            return 4;
        if (StrEqual(key, "act:env_adapt"))
            return 5;
        if (StrContains(key, "cvar:", false) == 0)
        {
            char cvar[CS2U_CVAR_LEN];
            strcopy(cvar, sizeof(cvar), key[5]);
            if (StrEqual(cvar, "cs2movement_crouch_slide")
             || StrEqual(cvar, "cs2movement_crouch_slide_client")
             || StrEqual(cvar, "cs2movement_crouch_slide_min_speed"))
                return 0;
            if (StrContains(cvar, "cs2movement_injury_", false) == 0)
                return 1;
            if (StrContains(cvar, "cs2movement_water_", false) == 0)
                return 2;
        }
        return 3;
    }

    if (ctx == CS2U_CTX_VISUAL)
        return StrContains(key, "act:camera", false) == 0 ? 1 : 0;

    if (ctx == CS2U_CTX_STATUS)
        return (StrContains(key, "act:diag_", false) == 0
             || StrEqual(key, "act:auth_log")) ? 1 : 0;

    return 0;
}

void CS2U_BmodeName(int mode, char[] out, int maxlen)
{
    if (mode == CS2U_BMODE_TR40)        strcopy(out, maxlen, "单人·TR-40");
    else if (mode == CS2U_BMODE_MULTI)  strcopy(out, maxlen, "多人");

    else                                strcopy(out, maxlen, "自动");
}

/* Actual structure read back from the live cvars: camera scale vs bullet scale.
 * This is the number the player can compare with the decals; the base mode in
 * cs2u_bmode alone does not prove a preset did not overwrite the seven values. */
void CS2U_BmodeScales(char[] out, int maxlen)
{
    float cam = CS2U_CvFloat("cs2feel_recoil_scale") * CS2U_CvFloat("cs2feel_recoil_view_scale");
    float bullet = cam;
    if (CS2U_CvInt("cs2feel_ballistics_mode") != 0)
        bullet = cam + CS2U_CvFloat("cs2feel_ballistics_scale");
    /* %.2f truncates on SourcePawn floats (1.299999 -> 1.29); nudge so the row
     * agrees with the chat text and with the documented 1.30. */
    Format(out, maxlen, "相机 %.2f / 弹道 %.2f", cam + 0.0005, bullet + 0.0005);
}

/* Compact "1.00/1.30" for menu rows (the client truncates long CJK rows). */
void CS2U_BmodeScalesShort(char[] out, int maxlen)
{
    float cam = CS2U_CvFloat("cs2feel_recoil_scale") * CS2U_CvFloat("cs2feel_recoil_view_scale");
    float bullet = cam;
    if (CS2U_CvInt("cs2feel_ballistics_mode") != 0)
        bullet = cam + CS2U_CvFloat("cs2feel_ballistics_scale");
    Format(out, maxlen, "%.2f/%.2f", cam + 0.0005, bullet + 0.0005);
}

/* The aim-sync ratio this structure expects: (bullet - camera) / recoil_scale,
 * i.e. ballistics_scale / recoil_scale.  Covers matched (0), split (-0.0826 for
 * single's 1.21/-0.10, -0.0909 for the 1.10 structure) and climb (+0.30). */
void CS2U_BmodeExpectedRatio(char[] out, int maxlen)
{
    float cam = CS2U_CvFloat("cs2feel_recoil_scale");
    float expected = 0.0;
    if (CS2U_CvInt("cs2feel_ballistics_mode") != 0 && FloatAbs(cam) > 0.000001)
        expected = CS2U_CvFloat("cs2feel_ballistics_scale") / cam;
    Format(out, maxlen, "%.6f", expected);
}

/* What the cvars currently implement (as opposed to what cs2u_bmode asks for). */
void CS2U_BmodeActualName(char[] out, int maxlen)
{
    if (!CS2U_RecoilIsOn())
        strcopy(out, maxlen, "关闭");
    else if (CS2U_RecoilIsClimb())
        strcopy(out, maxlen, "爬升");
    else if (CS2U_RecoilIsSplit())
        strcopy(out, maxlen, "分离");
    else
        strcopy(out, maxlen, "匹配");
}

void CS2U_SlideTier(char[] out, int maxlen)
{
    int idx = CS2U_ParamFind("cs2movement_crouch_slide_time");
    char cur[32];
    strcopy(cur, sizeof(cur), "?");
    if (idx >= 0)
        CS2U_ParamCurrent(idx, cur, sizeof(cur));
    strcopy(out, maxlen, cur);
}

/* ---- applicability / group headers --------------------------------------- */

bool CS2U_Advanced(int client)
{
    return g_bClientAdv[client] && g_iClientTier[client] >= CS2U_TIER_ROOT;
}

bool CS2U_KeyApplicable(int client, int ctx, const char[] key)
{
    if (StrContains(key, "cvar:", false) == 0)
    {
        int idx = CS2U_ParamFind(key[5]);
        if (idx < 0)
            return false;
        if (g_iParamAccess[idx] == PARAM_ACCESS_ROOT && g_iClientTier[client] < CS2U_TIER_ROOT)
            return false;
        return true;
    }

    if (StrContains(key, "act:", false) == 0)
    {
        char id[32];
        strcopy(id, sizeof(id), key[4]);
        if (CS2U_ActionCtx(id) != ctx)
            return false;
        if (StrContains(id, "diag_", false) == 0 || StrEqual(id, "auth_log"))
            return CS2U_Advanced(client) && g_bPermDiag;
        if (ctx == CS2U_CTX_CONFIG)
            return CS2U_Advanced(client) && g_bPermConfig;
        if (StrEqual(id, "slide_tier"))
            return g_iClientTier[client] >= CS2U_TIER_ADMIN;
        /* 1.0.12: E-8 -- a GENERIC admin must not even SEE this row, not just
         * bounce off the page.  Same tier the page and the command enforce. */
        if (StrEqual(id, "env_adapt"))
            return g_iClientTier[client] >= CS2U_TIER_ROOT;
        return true;
    }

    return false;
}

/* ---- row renderers ------------------------------------------------------- */

void CS2U_RenderCvarRow(int idx)
{
    char label[96], value[32], disp[CS2U_MENU_DISP_LEN], info[CS2U_MENU_INFO_LEN];
    CS2U_ParamLabelZh(idx, label, sizeof(label));
    CS2U_ParamValueZh(idx, value, sizeof(value));
    Format(disp, sizeof(disp), "%s：%s（点此切换）%s", label, value,
           g_iParamAccess[idx] == PARAM_ACCESS_ROOT ? " [ROOT]" : "");
    Format(info, sizeof(info), "cyc:%d", idx);
    CS2U_RowAdd(info, disp);
}

void CS2U_RenderActRow(const char[] id)
{
    char disp[CS2U_MENU_DISP_LEN], info[CS2U_MENU_INFO_LEN];

    if (StrEqual(id, "recoil"))
    {
        char label[96];
        CS2U_RecoilLabel(label, sizeof(label));
        Format(disp, sizeof(disp), "后坐结构：%s（点此切换）", label);
    }
    else if (StrEqual(id, "bmode"))
    {
        char baseName[32], actualName[32], scales[32];
        int base = CS2U_BmodeBase();
        CS2U_BmodeName(base, baseName, sizeof(baseName));
        CS2U_BmodeActualName(actualName, sizeof(actualName));
        CS2U_BmodeScalesShort(scales, sizeof(scales));
        bool same = (base == CS2U_BMODE_MULTI && StrEqual(actualName, "匹配"))
                 || (base == CS2U_BMODE_TR40  && StrEqual(actualName, "爬升"));
        if (same)
            Format(disp, sizeof(disp), "弹道模式：%s（%s，点此切换）", baseName, scales);
        else
            Format(disp, sizeof(disp), "弹道模式：%s（实际 %s；%s，点此切换）",
                   baseName, actualName, scales);
    }
    else if (StrEqual(id, "clientinfo"))
        strcopy(disp, sizeof(disp), "客户端 aim-sync：查看装法（聊天输出）");
    else if (StrEqual(id, "facts"))
        strcopy(disp, sizeof(disp), "实测数字：查看依据（聊天输出）");
    else if (StrEqual(id, "slide_tier"))
    {
        char tier[16];
        CS2U_SlideTier(tier, sizeof(tier));
        Format(disp, sizeof(disp), "滑行档位：%s（点此切换 0.20 / 0.35 / 0.40 / 0.45 / 0.50）", tier);
    }
    else if (StrEqual(id, "weapon_speeds"))
        strcopy(disp, sizeof(disp), "详细移动数值：18 件武器（点此进入）");
    else if (StrEqual(id, "env_adapt"))
    {
        /* Live probe on the row itself: the admin should not have to open the
         * page to learn that this box is not the tick rate the values assume. */
        CS2U_EnvProbe();
        CS2U_EnvPlanBuild();
        int pending = CS2U_EnvPlanTotal();
        Format(disp, sizeof(disp), "环境适配：%.0f Hz / %s / %s（点此进入）",
               g_fEnvHz + 0.5,
               g_bEnvDedicated ? "专用服" : "listen",
               pending > 0 ? "有建议待确认" : "已对齐");
    }
    else if (StrEqual(id, "camera_detect"))
        strcopy(disp, sizeof(disp), "检测我的 Left4Neko");
    else if (StrEqual(id, "camera_zero"))
        strcopy(disp, sizeof(disp), "推荐 0：相机冻结");
    else if (StrEqual(id, "camera_off"))
        strcopy(disp, sizeof(disp), "关闭：1.0");
    else if (StrEqual(id, "camera_note"))
        strcopy(disp, sizeof(disp), "说明：服务器改不了这个 cvar");
    else if (StrEqual(id, "status_full"))
        strcopy(disp, sizeof(disp), "输出完整状态（聊天）");
    else if (StrEqual(id, "status_plain"))
        strcopy(disp, sizeof(disp), "当前效果（白话，聊天）");
    else if (StrEqual(id, "auth_log"))
        strcopy(disp, sizeof(disp), "鉴权记录：当前来源与名单规模 [ROOT]");
    else if (StrEqual(id, "diag_verify"))
        strcopy(disp, sizeof(disp), "重扫手感签名 [ROOT]");
    else if (StrEqual(id, "diag_move"))
        strcopy(disp, sizeof(disp), "移动静态自检 [ROOT]");
    else if (StrEqual(id, "diag_gamedata"))
        strcopy(disp, sizeof(disp), "检查 gamedata [ROOT]");
    else if (StrEqual(id, "diag_l4n"))
        strcopy(disp, sizeof(disp), "检测客户端 Left4Neko [ROOT]");
    else if (StrEqual(id, "save"))
        strcopy(disp, sizeof(disp), "保存当前设置 [ROOT]");
    else if (StrEqual(id, "save_custom"))
        strcopy(disp, sizeof(disp), "保存为预设 custom [ROOT]");
    else if (StrEqual(id, "reload"))
        strcopy(disp, sizeof(disp), "从磁盘重载（参数 + 菜单）[ROOT]");
    else if (StrEqual(id, "rollback"))
        strcopy(disp, sizeof(disp), "回滚到上一稳定状态 [ROOT]");
    else if (StrEqual(id, "path"))
        strcopy(disp, sizeof(disp), "显示配置文件路径 [ROOT]");
    else if (StrEqual(id, "menu_reset"))
        strcopy(disp, sizeof(disp), "恢复默认菜单布局 [ROOT]");
    else
        return;

    Format(info, sizeof(info), "act:%s", id);
    CS2U_RowAdd(info, disp);
}

void CS2U_AddOrderRows(int client, int ctx)
{
    int lastGroup = -1;
    for (int i = 0; i < g_iOrderCount[ctx]; i++)
    {
        char key[CS2U_ITEM_KEY_LEN];
        strcopy(key, sizeof(key), g_sOrder[ctx][i]);
        if (!CS2U_KeyApplicable(client, ctx, key))
            continue;

        int group = CS2U_KeyGroup(ctx, key);
        if (group != lastGroup)
        {
            char groupName[48];
            CS2U_GroupName(ctx, group, groupName, sizeof(groupName));
            CS2U_RowHeader(groupName);
            lastGroup = group;
        }

        if (StrContains(key, "cvar:", false) == 0)
        {
            CS2U_RenderCvarRow(CS2U_ParamFind(key[5]));
        }
        else
        {
            char id[32];
            strcopy(id, sizeof(id), key[4]);
            CS2U_RenderActRow(id);
        }
    }
}

/* ---- root ---------------------------------------------------------------- */

void CS2U_RootTitle(char[] out, int maxlen)
{
    char feel[8], move[8], tracer[8];
    strcopy(feel, sizeof(feel), CS2U_CvBool("cs2feel_enable") ? "开" : "关");
    strcopy(move, sizeof(move), CS2U_CvBool("cs2movement_enable") ? "开" : "关");
    strcopy(tracer, sizeof(tracer), CS2U_CvBool("cs2u_tracer_enable") ? "开" : "关");
    Format(out, maxlen,
           "CS2Unified v%s\n预设: %s ｜ 手感 %s ｜ 移动 %s ｜ 曳光 %s",
           CS2U_VERSION,
           g_sActivePreset[0] ? g_sActivePreset : "(none)",
           feel, move, tracer);
}

void CS2U_MenuRoot(int client, int page)
{
    if (!CS2U_MenuClientOk(client))
        return;

    CS2U_RowReset();

    bool root = g_iClientTier[client] >= CS2U_TIER_ROOT;
    bool adv = CS2U_Advanced(client);

    if (adv)
    {
        CS2U_RowAdd("nav:presets", "预设与模式 / Presets");
        CS2U_RowAdd("nav:feel",    "手感 / Feel");
        CS2U_RowAdd("nav:move",    "移动与受伤 / Movement & Injury");
        CS2U_RowAdd("nav:visual",  "视觉与准星 / Visual & Crosshair");
        CS2U_RowAdd("nav:status",  "状态与诊断 / Status & Diagnostics");
        if (g_bPermConfig)
            CS2U_RowAdd("nav:config", "配置与保存 / Config & Save [ROOT]");
        CS2U_RowAdd("adv.off", "退出高级模式 / Exit advanced");
    }
    else
    {
        if (root && g_bBasicVisible[CS2U_CTX_PRESETS])
            CS2U_RowAdd("nav:presets", "预设与模式 / Presets");
        if (g_bBasicVisible[CS2U_CTX_FEEL])
            CS2U_RowAdd("nav:feel",    "手感 / Feel");
        if (g_bBasicVisible[CS2U_CTX_MOVE])
            CS2U_RowAdd("nav:move",    "移动与受伤 / Movement & Injury");
        if (g_bBasicVisible[CS2U_CTX_VISUAL])
            CS2U_RowAdd("nav:visual",  "视觉与准星 / Visual & Crosshair");
        if (g_bBasicVisible[CS2U_CTX_STATUS])
            CS2U_RowAdd("nav:status",  "状态 / Status");
        if (root)
            CS2U_RowAdd("adv.on", "高级模式 / Advanced mode [ROOT]");
    }

    if (g_iRowCount == 0)
        CS2U_RowAdd("pad", "(menu layout has no visible item)", ITEMDRAW_DISABLED);

    CS2U_PackPages();

    char base[160], title[192];
    CS2U_RootTitle(base, sizeof(base));
    if (adv)
        Format(title, sizeof(title), "%s\n高级视图", base);
    else
        strcopy(title, sizeof(title), base);

    Menu m = new Menu(MenuHandler_Root);
    CS2U_SetTitle(m, title, page);
    CS2U_MenuEmit(client, m, page, "root");
}

/* ---- presets ------------------------------------------------------------- */

void CS2U_MenuPresets(int client, int page)
{
    if (!CS2U_MenuClientOk(client))
        return;
    if (g_iClientTier[client] < CS2U_TIER_ROOT)
    {
        CS2U_AuthRequire(client, CS2U_TIER_ROOT, "预设应用");
        CS2U_MenuRoot(client, 0);
        return;
    }

    CS2U_RowReset();
    for (int i = 0; i < g_iOrderCount[CS2U_CTX_PRESETS]; i++)
    {
        char key[CS2U_ITEM_KEY_LEN];
        strcopy(key, sizeof(key), g_sOrder[CS2U_CTX_PRESETS][i]);
        if (StrContains(key, "preset:", false) != 0)
            continue;
        int idx = CS2U_ModeFind(key[7]);
        if (idx < 0)
            continue;
        char name[CS2U_NAME_LEN], label[64], disp[CS2U_MENU_DISP_LEN], info[CS2U_MENU_INFO_LEN];
        strcopy(name, sizeof(name), g_sPresetName[idx]);
        CS2U_ModeLabelCn(name, label, sizeof(label));
        /* The Chinese label is what the player reads; the internal key stays in
         * the tooltip-less second field so admins can still see which preset
         * the command line would take. */
        Format(disp, sizeof(disp), "%s（%s）%s", label, name,
               StrEqual(name, g_sActivePreset, false) ? "  [active]" : "");
        Format(info, sizeof(info), "preset:%d", idx);
        CS2U_RowAdd(info, disp);
    }

    if (CS2U_Advanced(client) && g_bPermDiy)
    {
        CS2U_RowHeader("DIY 自定义");
        char label[96], disp[CS2U_MENU_DISP_LEN];
        for (int w = 0; w < 2; w++)
        {
            char name[CS2U_NAME_LEN];
            CS2U_DiyName(w, name, sizeof(name));
            int slot = CS2U_ModeFind(name);
            if (w == 0) strcopy(label, sizeof(label), "高级");
            else        strcopy(label, sizeof(label), "简易");
            Format(disp, sizeof(disp), "DIY %s：应用此预设%s", label,
                   slot >= 0 ? "" : "（尚未保存）");
            char info[CS2U_MENU_INFO_LEN];
            Format(info, sizeof(info), "diy.apply.%d", w);
            CS2U_RowAdd(info, disp);

            Format(disp, sizeof(disp), "DIY %s：用当前设置覆盖保存", label);
            Format(info, sizeof(info), "diy.save.%d", w);
            CS2U_RowAdd(info, disp);
        }
    }

    if (g_iRowCount == 0)
        CS2U_RowAdd("pad", "(no presets loaded)", ITEMDRAW_DISABLED);

    CS2U_PackPages();

    char title[160];
    Format(title, sizeof(title), "预设与模式 / Presets\n当前：%s",
           g_sActivePreset[0] ? g_sActivePreset : "(none)");
    Menu m = new Menu(MenuHandler_Presets);
    CS2U_SetTitle(m, title, page);
    CS2U_MenuEmit(client, m, page, "presets");
}

/* ---- feel / move / visual / status / config pages ------------------------ */

void CS2U_MenuFeel(int client, int page)
{
    if (!CS2U_MenuClientOk(client))
        return;
    CS2U_RowReset();
    CS2U_AddOrderRows(client, CS2U_CTX_FEEL);
    CS2U_PackPages();
    Menu m = new Menu(MenuHandler_Feel);
    CS2U_SetTitle(m, "手感 / Feel", page);
    CS2U_MenuEmit(client, m, page, "feel");
}

void CS2U_MenuMove(int client, int page)
{
    if (!CS2U_MenuClientOk(client))
        return;
    CS2U_RowReset();
    CS2U_AddOrderRows(client, CS2U_CTX_MOVE);
    CS2U_PackPages();
    Menu m = new Menu(MenuHandler_Move);
    CS2U_SetTitle(m, "移动与受伤 / Movement & Injury", page);
    CS2U_MenuEmit(client, m, page, "move");
}

/* 1.0.11: per-weapon speed page.  Reached from the move page's
 * "详细移动数值" row; it is the only third-level page in the menu (root ->
 * 移动与受伤 -> 武器明细).  It is deliberately NOT a CS2U_CTX_* context: the
 * seven contexts are the menu.cfg-driveable pages, while this one is generated
 * from the weapon table and has no order of its own.  Clicking a row arms the
 * chat input (CS2U_WeaponBeginInput) instead of cycling a value, because 18
 * speeds cannot be expressed as a candidate list. */
void CS2U_MenuWeapon(int client, int page)
{
    if (!CS2U_MenuClientOk(client))
        return;
    if (g_iClientTier[client] < CS2U_TIER_ROOT)
    {
        CS2U_AuthRequire(client, CS2U_TIER_ROOT, "武器速度");
        CS2U_MenuMove(client, 0);
        return;
    }

    CS2U_RowReset();
    CS2U_WeaponRefresh();
    CS2U_RowHeader("各武器移动速度（u/s，* = 已改）");
    for (int i = 0; i < CS2U_WEAPON_COUNT; i++)
    {
        char info[CS2U_MENU_INFO_LEN], disp[CS2U_MENU_DISP_LEN], num[16];
        float speed = CS2U_WeaponSpeed(i);
        CS2U_WeaponFormatSpeed(speed, num, sizeof(num));
        Format(info, sizeof(info), "wpn:%d", i);
        Format(disp, sizeof(disp), "%s：%s%s", g_sWpnLabel[i], num,
               FloatAbs(speed - g_fWpnDefault[i]) > 0.0005 ? " *" : "");
        CS2U_RowAdd(info, disp);
    }
    CS2U_RowHeader("恢复");
    CS2U_RowAdd("wpn:reset", "恢复默认数值（18 件，立即写盘）");

    CS2U_PackPages();

    char title[192];
    Format(title, sizeof(title),
           "详细移动数值 / Weapon speeds\n点一行后在聊天栏输入新速度（%.0f–%.0f）",
           CS2U_WEAPON_MIN_SPEED, CS2U_WEAPON_MAX_SPEED);
    Menu m = new Menu(MenuHandler_Weapon);
    CS2U_SetTitle(m, title, page);
    CS2U_MenuEmit(client, m, page, "weapons");
}

/* 1.0.12: environment adaptation page.  Reached from the move page's
 * "环境适配" row; like the weapon table it is NOT a CS2U_CTX_* context (the
 * seven contexts are the menu.cfg-driveable pages, this one has no order).
 *
 * Shape: three read-only rows (host / profile) then the three actions.  The
 * apply row is deliberately always visible: an admin who clicks it before
 * previewing gets a refusal that says how, which is friendlier than a row that
 * appears out of nowhere. */
void CS2U_MenuEnv(int client, int page)
{
    if (!CS2U_MenuClientOk(client))
        return;
    if (g_iClientTier[client] < CS2U_TIER_ROOT)
    {
        CS2U_AuthRequire(client, CS2U_TIER_ROOT, "环境适配");
        CS2U_MenuMove(client, 0);
        return;
    }

    CS2U_EnvProbe();
    CS2U_EnvPlanBuild();

    CS2U_RowReset();

    char disp[CS2U_MENU_DISP_LEN], line[96];
    CS2U_RowHeader("本机环境（只读）");
    CS2U_EnvHostLine(line, sizeof(line));
    CS2U_RowAdd("env.info.host", line, ITEMDRAW_DISABLED);
    CS2U_EnvProfileLine(line, sizeof(line));
    CS2U_RowAdd("env.info.profile", line, ITEMDRAW_DISABLED);

    CS2U_RowAdd("env.detail", "查看完整探测（聊天输出，含每项来源）");

    int total = CS2U_EnvPlanTotal();
    if (total == 0)
        strcopy(disp, sizeof(disp), "预览适配：无需改动（已是推荐组合）");
    else
        Format(disp, sizeof(disp), "预览适配：%d 项（点此列出 旧 → 新）", total);
    CS2U_RowAdd("env.preview", disp);

    Format(disp, sizeof(disp), "确认应用：%d 项（须先预览，120 秒内有效）", total);
    CS2U_RowAdd("env.apply", disp);

    if (g_bEnvUndoValid)
        Format(disp, sizeof(disp), "撤销上次适配：%d 项",
               g_iEnvUndoItems + (g_bEnvUndoProfile ? 1 : 0));
    else
        strcopy(disp, sizeof(disp), "撤销上次适配：无快照");
    CS2U_RowAdd("env.undo", disp);

    CS2U_PackPages();

    char title[256];
    Format(title, sizeof(title), "环境适配 / This machine\n%s ｜ %s",
           g_sEnvBandName, g_bEnvPersist ? "已存适配" : "未适配");
    /* Feedback inside the panel: every action used to answer in chat only, and
     * the page re-renders identically, which read as "nothing happens". */
    if (client > 0 && g_sEnvLastMsg[client][0] != '\0')
    {
        char withNote[256];
        Format(withNote, sizeof(withNote), "%s\n上次：%s", title, g_sEnvLastMsg[client]);
        strcopy(title, sizeof(title), withNote);
    }
    Menu m = new Menu(MenuHandler_Env);
    CS2U_SetTitle(m, title, page);
    CS2U_MenuEmit(client, m, page, "env");
}

void CS2U_MenuVisual(int client, int page)
{
    if (!CS2U_MenuClientOk(client))
        return;
    CS2U_RowReset();
    CS2U_AddOrderRows(client, CS2U_CTX_VISUAL);
    CS2U_PackPages();
    Menu m = new Menu(MenuHandler_Visual);
    CS2U_SetTitle(m, "视觉与准星 / Visual & Crosshair", page);
    CS2U_MenuEmit(client, m, page, "visual");
}
void CS2U_MenuStatus(int client, int page)
{
    if (!CS2U_MenuClientOk(client))
        return;
    CS2U_RowReset();
    CS2U_AddOrderRows(client, CS2U_CTX_STATUS);
    CS2U_PackPages();
    Menu m = new Menu(MenuHandler_Status);
    CS2U_SetTitle(m, "状态 / Status", page);
    CS2U_MenuEmit(client, m, page, "status");
}

void CS2U_MenuConfig(int client, int page)
{
    if (!CS2U_MenuClientOk(client))
        return;
    if (!CS2U_Advanced(client) || !g_bPermConfig)
    {
        CS2U_AuthRequire(client, CS2U_TIER_ROOT, "配置管理");
        CS2U_MenuRoot(client, 0);
        return;
    }
    CS2U_RowReset();
    CS2U_AddOrderRows(client, CS2U_CTX_CONFIG);
    if (g_iRowCount == 0)
        CS2U_RowAdd("pad", "(no config action)", ITEMDRAW_DISABLED);
    CS2U_PackPages();
    Menu m = new Menu(MenuHandler_Config);
    CS2U_SetTitle(m, "配置与保存 / Config & Save", page);
    CS2U_MenuEmit(client, m, page, "config");
}

/* ---- telemetry / auth helpers -------------------------------------------- */

void CS2U_MenuSelectLog(int client, const char[] ctx, const char[] info)
{
    if (!g_bMenuTelemetry)
        return;
    char steam[CS2U_AUTH_ID_LEN];
    steam[0] = '\0';
    GetClientAuthId(client, AuthId_Steam2, steam, sizeof(steam), false);
    CS2U_Log("MENU-SELECT client=%d steamid=%s tier=%d ctx=%s info=%s",
             client, steam, g_iClientTier[client], ctx, info);
}

/* ---- parameter cycle ----------------------------------------------------- */

void CS2U_ApplyParamCycle(int client, int idx)
{
    if (!CS2U_AuthCheck(client, "cycle"))
        return;
    if (!CS2U_ParamCanEdit(client, idx))
    {
        CS2U_Reply(client, "权限不足 / Access denied — 该参数需要 ROOT。");
        return;
    }
    if (g_iParamCandCount[idx] <= 0)
        return;

    int cur = -1;
    for (int c = 0; c < g_iParamCandCount[idx]; c++)
    {
        if (CS2U_ParamCandidateIsCurrent(idx, c))
        {
            cur = c;
            break;
        }
    }
    int next = (cur + 1) % g_iParamCandCount[idx];

    if (g_bMenuConfirmDestructive && g_iParamAccess[idx] == PARAM_ACCESS_ROOT)
    {
        float now = GetGameTime();
        if (g_iConfirmIdx[client] != idx || now - g_fConfirmAt[client] > 5.0)
        {
            g_iConfirmIdx[client] = idx;
            g_fConfirmAt[client] = now;
            CS2U_Reply(client, "ROOT 参数：再次点击同一项确认修改 %s → %s。",
                       g_sParamCvar[idx], g_sParamCand[idx][next]);
            return;
        }
        g_iConfirmIdx[client] = -1;
    }

    char err[160], value[24], persistMsg[256];
    strcopy(value, sizeof(value), g_sParamCand[idx][next]);
    if (!CS2U_ParamSet(idx, value, err, sizeof(err)))
    {
        CS2U_Reply(client, "Rejected: %s", err);
        return;
    }

    if (CS2U_PersistLive(persistMsg, sizeof(persistMsg)))
        CS2U_Reply(client, "OK: %s = %s (persisted)", g_sParamCvar[idx], value);
    else
        CS2U_Reply(client, "OK: %s = %s, but persistence failed: %s",
                   g_sParamCvar[idx], value, persistMsg);

    CS2U_ActionLog("menu-set cvar=%s value=%s by=%d", g_sParamCvar[idx], value, client);
    CS2U_ReconcileMovement();
}

/* ---- actions ------------------------------------------------------------- */

void CS2U_ActionRecoil(int client)
{
    bool split = CS2U_RecoilIsSplit();
    bool climb = CS2U_RecoilIsClimb();
    bool targetSplit = (!split && !climb);   /* matched -> split; split/climb -> matched */
    char msg[256], ratio[32];
    bool ok = CS2U_ApplyRecoil(targetSplit, msg, sizeof(msg));
    CS2U_Reply(client, "%s %s", ok ? "OK:" : "注意:", msg);

    /* The structure row is a manual override.  Once it moves the seven cvars,
     * cs2u_bmode must not keep claiming single/climb: otherwise the bmode row
     * and the structure row disagree after this click. */
    char err[64], persistMsg[128];
    if (!CS2U_ParamSetValue("cs2u_bmode", "0", err, sizeof(err)))
        CS2U_Reply(client, "模式基值未重置：%s", err);
    else
    {
        if (!CS2U_PersistLive(persistMsg, sizeof(persistMsg)))
            CS2U_Reply(client, "模式基值已回自动，但保存失败：%s", persistMsg);
    }

    if (climb)
        CS2U_Reply(client, "已退出爬升，回到匹配；客户端 ini 改回 ratio = 0.0。");
    else if (targetSplit)
    {
        CS2U_RecoilRatio(ratio, sizeof(ratio));
        CS2U_Reply(client, "分离已应用。客户端 ini ratio 建议 %s。", ratio);
        QueryClientConVar(client, CS2U_L4N_CVAR, OnL4NQuery, 2);
    }
    else
        CS2U_Reply(client, "回到匹配。客户端 ini 建议改回 ratio = 0.0。");
    CS2U_ActionLog("menu-recoil split=%d climb_exit=%d by=%d", targetSplit, climb, client);
}

void CS2U_ActionBmode(int client)
{
    int base = CS2U_BmodeBase();
    int next = (base + 1) % 3;
    char err[64], msg[192], req[192], scales[64];
    if (!CS2U_ParamSetValue("cs2u_bmode", next == 0 ? "0" : (next == 1 ? "1" : "2"),
                            err, sizeof(err)))
    {
        CS2U_Reply(client, "切换失败：%s", err);
        return;
    }

    int u = 0;
    int eff = CS2U_BmodeEffective(u);
    bool ok = CS2U_BmodeApply(eff, msg, sizeof(msg));
    CS2U_Reply(client, "%s %s", ok ? "OK:" : "注意:", msg);
    CS2U_BmodeRequirements(eff, req, sizeof(req));
    CS2U_Reply(client, "%s", req);
    CS2U_BmodeScales(scales, sizeof(scales));
    CS2U_Reply(client, "服务器结构：%s", scales);
    QueryClientConVar(client, "cs2feel_aimsync", OnAimsyncQuery, 3);
    CS2U_ActionLog("menu-bmode base=%d effective=%d by=%d", next, eff, client);
}

void CS2U_ActionSlideTier(int client)
{
    char tiers[5][8] = { "0.20", "0.35", "0.40", "0.45", "0.50" };
    int idxTime = CS2U_ParamFind("cs2movement_crouch_slide_time");    int idxSlide = CS2U_ParamFind("cs2movement_crouch_slide");
    if (idxTime < 0 || idxSlide < 0)
    {
        CS2U_Reply(client, "设置失败：滑行参数不在受管参数表中");
        return;
    }
    if (!CS2U_ParamCanEdit(client, idxTime))
    {
        CS2U_Reply(client, "权限不足 / Access denied — 滑行档位需要 ADMIN。");
        return;
    }

    char cur[32];
    CS2U_ParamCurrent(idxTime, cur, sizeof(cur));
    int next = 0;
    for (int i = 0; i < 5; i++)
    {
        if (FloatAbs(StringToFloat(cur) - StringToFloat(tiers[i])) < 0.001)
        {
            next = (i + 1) % 5;
            break;
        }
    }

    char err[160], persistMsg[256];
    CS2U_ParamSet(idxSlide, "1", err, sizeof(err));
    if (!CS2U_ParamSet(idxTime, tiers[next], err, sizeof(err)))
    {
        CS2U_Reply(client, "设置失败：%s", err);
        return;
    }
    if (CS2U_PersistLive(persistMsg, sizeof(persistMsg)))
        CS2U_Reply(client, "蹲下滑行：%s s（已开启并保存）", tiers[next]);
    else
        CS2U_Reply(client, "已切换为 %s s，但保存失败：%s", tiers[next], persistMsg);

    CS2U_ActionLog("easy-slide-tier value=%s by=%d", tiers[next], client);
    CS2U_ReconcileMovement();
}

void CS2U_ActionConfig(int client, const char[] id)
{
    if (!CS2U_AuthRequire(client, CS2U_TIER_ROOT, "配置管理"))
        return;
    char msg[256];
    if (StrEqual(id, "save"))
    {
        if (CS2U_ConfigSave(client, "", msg, sizeof(msg)))
            CS2U_Reply(client, "%s", msg);
        else
            CS2U_Reply(client, "Save failed: %s", msg);
    }
    else if (StrEqual(id, "save_custom"))
    {
        if (CS2U_ConfigSave(client, "custom", msg, sizeof(msg)))
            CS2U_Reply(client, "%s", msg);
        else
            CS2U_Reply(client, "Save failed: %s", msg);
    }
    else if (StrEqual(id, "reload"))
    {
        bool okCfg = CS2U_ConfigReload(msg, sizeof(msg));
        CS2U_Reply(client, "%s", msg);
        bool okMenu = CS2U_MenuCfgReload(msg, sizeof(msg));
        CS2U_Reply(client, "%s%s", okCfg && okMenu ? "OK: " : "注意: ", msg);
    }
    else if (StrEqual(id, "rollback"))
    {
        if (CS2U_Rollback(msg, sizeof(msg)))
            CS2U_Reply(client, "%s", msg);
        else
            CS2U_Reply(client, "Rollback failed: %s", msg);
    }
    else if (StrEqual(id, "path"))
    {
        char path[PLATFORM_MAX_PATH];
        CS2U_ConfigPath(path, sizeof(path));
        CS2U_Reply(client, "Config: %s (%s)", path, FileExists(path) ? "present" : "missing");
        CS2U_MenuCfgPath(path, sizeof(path));
        CS2U_Reply(client, "Menu: %s (%s)", path, FileExists(path) ? "present" : "missing");
    }
    else if (StrEqual(id, "menu_reset"))
    {
        char path[PLATFORM_MAX_PATH], bak[PLATFORM_MAX_PATH];
        CS2U_MenuCfgPath(path, sizeof(path));
        Format(bak, sizeof(bak), "%s.bak", path);
        if (FileExists(path))
        {
            DeleteFile(bak);
            RenameFile(bak, path);
        }
        CS2U_MenuCfgReload(msg, sizeof(msg));
        CS2U_Reply(client, "已恢复默认菜单布局；%s", msg);
    }
}

void CS2U_ActionStatus(int client, const char[] id)
{
    if (StrContains(id, "diag_", false) == 0 || StrEqual(id, "auth_log"))
    {
        if (!CS2U_AuthRequire(client, CS2U_TIER_ROOT, "诊断"))
            return;
    }
    if (StrEqual(id, "status_full"))
        CS2U_PrintStatus(client);
    else if (StrEqual(id, "status_plain"))
        CS2U_PrintSimpleStatus(client);
    else if (StrEqual(id, "auth_log"))
    {
        CS2U_Reply(client, "鉴权：source=%s tier=%d；名单 steamids=%d groups=%d strict=%d",
                   g_sClientAuthSource[client], g_iClientTier[client],
                   g_iAuthSteamCount, g_iAuthGroupCount, g_bAuthStrict ? 1 : 0);
        CS2U_Reply(client, "日志标签：AUTH-OK / AUTH-DENIED / AUTH-CONFLICT / MENU-CONFIG-FALLBACK");
    }
    else if (StrEqual(id, "diag_verify"))
    {
        CS2F_VerifySignatures();
        CS2U_Reply(client, "Feel signature guard re-run: ready=%d offset=%d error=%s",
                   g_bSigReady ? 1 : 0, g_iSpreadOffset,
                   g_sSigError[0] ? g_sSigError : "(none)");
    }
    else if (StrEqual(id, "diag_move"))
    {
        CS2M_Cmd_SelfTest(client, 0);
        CS2U_Reply(client, "Movement self-test output is in the server console.");
    }
    else if (StrEqual(id, "diag_gamedata"))
    {
        char path[PLATFORM_MAX_PATH];
        BuildPath(Path_SM, path, sizeof(path), "gamedata/l4d2_cs2feel.txt");
        CS2U_Reply(client, "l4d2_cs2feel.txt: %s", FileExists(path) ? "present" : "MISSING");
        BuildPath(Path_SM, path, sizeof(path), "gamedata/cs2movement.txt");
        CS2U_Reply(client, "cs2movement.txt: %s", FileExists(path) ? "present" : "MISSING");
    }
    else if (StrEqual(id, "diag_l4n"))
    {
        QueryClientConVar(client, CS2U_L4N_CVAR, OnL4NQuery, 1);
    }
}

void CS2U_ActionCamera(int client, const char[] id)
{
    if (StrEqual(id, "camera_detect"))
    {
        QueryClientConVar(client, CS2U_L4N_CVAR, OnL4NQuery, 1);
    }
    else if (StrEqual(id, "camera_zero"))
    {
        /* Actually send it: the row used to only print the command, so clicking
         * "推荐 0" did nothing.  ClientCommand sets the client cvar for this
         * session; the client may still write 1.0 back into config.cfg later. */
        ClientCommand(client, "l4n_view_punch_scale 0");
        CS2U_Reply(client, "已向客户端发送 l4n_view_punch_scale 0（相机冻结，弹道整条爬升）。");
        CS2U_Reply(client, "若未生效，请在控制台手动执行：l4n_view_punch_scale 0；退出游戏时可能被写回 1.0。");
        QueryClientConVar(client, CS2U_L4N_CVAR, OnL4NQuery, 1);
    }
    else if (StrEqual(id, "camera_off"))
    {
        ClientCommand(client, "l4n_view_punch_scale 1.0");
        CS2U_Reply(client, "已向客户端发送 l4n_view_punch_scale 1.0（恢复相机随动）。");
        QueryClientConVar(client, CS2U_L4N_CVAR, OnL4NQuery, 1);
    }
    else if (StrEqual(id, "camera_note"))
    {
        CS2U_Reply(client, "这个 cvar 由客户端 Left4Neko 注册；服务器用 ClientCommand 代设只对本次会话生效，游戏退出可能写回 config.cfg。没装 L4N 的客户端保持 matched，子弹/命中/弹道完全不受影响。");
    }
}

/* ---- shared select dispatcher -------------------------------------------- */

int CS2U_HandleSelect(Menu menu, MenuAction action, int client, int item, int ctx)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }
    if (action != MenuAction_Select)
        return 0;

    if (!CS2U_AuthCheck(client, "select"))
        return 0;

    char info[CS2U_MENU_INFO_LEN];
    menu.GetItem(item, info, sizeof(info));

    char ctxName[16];
    CS2U_CtxName(ctx, ctxName, sizeof(ctxName));
    CS2U_MenuSelectLog(client, ctxName, info);

    if (CS2U_MenuPager(client, info))
        return 0;

    if (StrEqual(info, "back"))
    {
        CS2U_MenuRoot(client, 0);
        return 0;
    }

    char parts[3][CS2U_MENU_INFO_LEN];
    int n = ExplodeString(info, ":", parts, 3, sizeof(parts[]));
    int page = (n >= 3) ? StringToInt(parts[2]) : 0;

    char id[32];
    if (n >= 2)
        strcopy(id, sizeof(id), parts[1]);

    if (StrContains(info, "cyc:", false) == 0 && n >= 2)
        CS2U_ApplyParamCycle(client, StringToInt(parts[1]));
    else if (StrContains(info, "act:", false) == 0 && n >= 2)
    {
        if (StrEqual(id, "recoil"))            CS2U_ActionRecoil(client);
        else if (StrEqual(id, "bmode"))        CS2U_ActionBmode(client);
        else if (StrEqual(id, "slide_tier"))   CS2U_ActionSlideTier(client);
        else if (StrEqual(id, "weapon_speeds"))
        {
            /* Opens its own page; returning here keeps the generic
             * "re-render the move page" tail from replacing it. */
            CS2U_MenuWeapon(client, 0);
            return 0;
        }
        else if (StrEqual(id, "env_adapt"))
        {
            CS2U_MenuEnv(client, 0);
            return 0;
        }
        else if (StrContains(id, "camera_", false) == 0) CS2U_ActionCamera(client, id);
        else if (StrContains(id, "diag_", false) == 0 || StrEqual(id, "auth_log")
              || StrContains(id, "status_", false) == 0) CS2U_ActionStatus(client, id);
        else if (StrContains(id, "save", false) == 0 || StrEqual(id, "reload")
              || StrEqual(id, "rollback") || StrEqual(id, "path")
              || StrEqual(id, "menu_reset")) CS2U_ActionConfig(client, id);
        else if (StrEqual(id, "clientinfo"))
        {
            CS2U_Reply(client, "客户端文件：bin\\neko\\plugins\\cs2feel_aimsync.ini，内容 [aimsync] enable=1 ratio=<derived> yaw=1");
            CS2U_Reply(client, "只放 ini 不放 dll 没有效果；只放 dll 也没有副作用（ratio 默认 0）。");
        }
        else if (StrEqual(id, "facts"))
        {
            CS2U_Reply(client, "双通道实测：相机 1.10 倍表值 / 弹道 1.00 倍表值，实测比例 0.913（目标 0.909）。");
            CS2U_Reply(client, "AK 满自动 punch 约 5.9 度时，弹着比准星低约 0.53 度（1280x720 下约 7 像素）。");
        }
    }

    /* A reload (act:reload / menu_reset) clears the cached auth tier; re-resolve
     * once before rebuilding, otherwise the reopened page hides ROOT rows and
     * looks like the admin lost access for one click. */
    if (g_iClientTier[client] == CS2U_TIER_NONE)
        CS2U_AuthCheck(client, ctxName);

    CS2U_MenuByCtx(client, ctxName, page);
    return 0;
}

/* ---- handlers ------------------------------------------------------------ */

public int MenuHandler_Root(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }
    if (action != MenuAction_Select)
        return 0;

    int client = param1;
    if (!CS2U_AuthCheck(client, "root"))
        return 0;

    char info[CS2U_MENU_INFO_LEN];
    menu.GetItem(param2, info, sizeof(info));
    CS2U_MenuSelectLog(client, "root", info);

    if (CS2U_MenuPager(client, info))
        return 0;

    if (StrEqual(info, "back"))
        return 0;   /* root is the top: close the menu */

    if (StrEqual(info, "adv.on"))
    {
        if (g_iClientTier[client] >= CS2U_TIER_ROOT)
        {
            g_bClientAdv[client] = true;
            CS2U_MenuRoot(client, 0);
        }
        return 0;
    }
    if (StrEqual(info, "adv.off"))
    {
        g_bClientAdv[client] = false;
        CS2U_MenuRoot(client, 0);
        return 0;
    }
    if (StrContains(info, "nav:", false) == 0)
    {
        char navCtx[16];
        strcopy(navCtx, sizeof(navCtx), info[4]);
        CS2U_MenuByCtx(client, navCtx, 0);
        return 0;
    }
    return 0;
}

public int MenuHandler_Presets(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }
    if (action != MenuAction_Select)
        return 0;

    int client = param1;
    if (!CS2U_AuthCheck(client, "presets"))
        return 0;

    char info[CS2U_MENU_INFO_LEN];
    menu.GetItem(param2, info, sizeof(info));
    CS2U_MenuSelectLog(client, "presets", info);

    if (CS2U_MenuPager(client, info))
        return 0;
    if (StrEqual(info, "back"))
    {
        CS2U_MenuRoot(client, 0);
        return 0;
    }

    char parts[3][CS2U_MENU_INFO_LEN];
    int n = ExplodeString(info, ":", parts, 3, sizeof(parts[]));
    /* preset rows carry TWO fields (preset:<idx>:<page>); DIY rows carry one
     * field plus the page suffix (diy.apply.0:<page>), so their page is parts[1]. */
    int page = 0;
    if (StrContains(info, "preset:", false) == 0)
        page = (n >= 3) ? StringToInt(parts[2]) : 0;
    else
        page = (n >= 2) ? StringToInt(parts[1]) : 0;

    if (StrContains(info, "preset:", false) == 0 && n >= 2)
    {
        CS2U_ApplyPresetByIndex(client, StringToInt(parts[1]));
    }
    else if (StrContains(info, "diy.apply.", false) == 0)
    {
        int which = info[10] - '0';
        char name[CS2U_NAME_LEN], msg[256];
        CS2U_DiyName(which, name, sizeof(name));
        if (CS2U_ModeFind(name) < 0)
            CS2U_Reply(client, "DIY 预设 '%s' 尚未保存：请先点“用当前设置覆盖保存”。", name);
        else if (CS2U_ModeApply(client, name, msg, sizeof(msg)))
            CS2U_Reply(client, "%s", msg);
        else
            CS2U_Reply(client, "Preset failed: %s", msg);
    }
    else if (StrContains(info, "diy.save.", false) == 0)
    {
        int which = info[9] - '0';
        char name[CS2U_NAME_LEN], msg[256];
        CS2U_DiyName(which, name, sizeof(name));
        if (CS2U_ConfigSave(client, name, msg, sizeof(msg)))
            CS2U_Reply(client, "%s", msg);
        else
            CS2U_Reply(client, "Save failed: %s", msg);
    }

    CS2U_MenuPresets(client, page);
    return 0;
}

public int MenuHandler_Feel(Menu menu, MenuAction action, int param1, int param2)
{
    return CS2U_HandleSelect(menu, action, param1, param2, CS2U_CTX_FEEL);
}

public int MenuHandler_Move(Menu menu, MenuAction action, int param1, int param2)
{
    return CS2U_HandleSelect(menu, action, param1, param2, CS2U_CTX_MOVE);
}

public int MenuHandler_Weapon(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }
    if (action != MenuAction_Select)
        return 0;

    if (!CS2U_AuthCheck(client, "select"))
        return 0;

    char info[CS2U_MENU_INFO_LEN];
    menu.GetItem(item, info, sizeof(info));
    CS2U_MenuSelectLog(client, "weapons", info);

    if (CS2U_MenuPager(client, info))
        return 0;

    if (StrEqual(info, "back"))
    {
        CS2U_MenuMove(client, 0);
        return 0;
    }

    char parts[3][CS2U_MENU_INFO_LEN];
    int n = ExplodeString(info, ":", parts, 3, sizeof(parts[]));
    int page = (n >= 3) ? StringToInt(parts[2]) : 0;

    if (n >= 2 && StrEqual(parts[0], "wpn"))
    {
        if (StrEqual(parts[1], "reset"))
        {
            char msg[192];
            CS2U_WeaponResetAll(msg, sizeof(msg));
            CS2U_Reply(client, "%s", msg);
            CS2U_ActionLog("weapon-speed reset by=%d", client);
            CS2U_MenuWeapon(client, page);
        }
        else
        {
            /* The value arrives on the next chat line; the page is reopened by
             * CS2U_WeaponHandleInput once it is applied. */
            CS2U_WeaponBeginInput(client, StringToInt(parts[1]));
        }
    }
    return 0;
}

public int MenuHandler_Visual(Menu menu, MenuAction action, int param1, int param2)
{
    return CS2U_HandleSelect(menu, action, param1, param2, CS2U_CTX_VISUAL);
}

/* Environment page (1.0.12).  Four actions, no value cycling: the page is a
 * read-then-confirm flow, and apply itself refuses unless this client previewed
 * first (CS2U_EnvApply owns that gate, not the handler). */
public int MenuHandler_Env(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }
    if (action != MenuAction_Select)
        return 0;

    if (!CS2U_AuthCheck(client, "select"))
        return 0;

    char info[CS2U_MENU_INFO_LEN];
    menu.GetItem(item, info, sizeof(info));
    CS2U_MenuSelectLog(client, "env", info);

    if (CS2U_MenuPager(client, info))
        return 0;

    if (StrEqual(info, "back"))
    {
        CS2U_MenuMove(client, 0);
        return 0;
    }

    CS2U_EnvAction(client, info, true);
    return 0;
}

/**
 * One env row was chosen: "env.<action>" with MenuEmit's ":<page>" suffix.
 *
 * 1.0.13 split this by ':' only and read parts[1] -- but the row ids use a DOT
 * between "env" and the action, so "env.preview:0" exploded into
 * ["env.preview", "0"] and parts[1] was "0".  Every action row (detail /
 * preview / apply / undo) silently did nothing; only "back" worked, because its
 * id has no suffix.  Found by the owner clicking them on a listen server
 * (MENU-SELECT in the log proved the click arrived).  Strip the page by the
 * colon, compare the key whole -- and `sm_cs2u_menusel` feeds this same function
 * from RCON so the regression can be tested without a client.
 */
bool CS2U_EnvAction(int client, const char[] info, bool reRender)
{
    if (StrContains(info, "env.", false) != 0)
        return false;

    char key[CS2U_MENU_INFO_LEN];
    strcopy(key, sizeof(key), info);

    int page = 0;
    int colon = StrContains(key, ":");
    if (colon >= 0)
    {
        page = StringToInt(info[colon + 1]);
        key[colon] = '\0';
    }

    char msg[256];
    if (StrEqual(key, "env.detail"))
    {
        CS2U_EnvPrintDetail(client);
        CS2U_EnvNote(client, "探测已输出到聊天");
    }
    else if (StrEqual(key, "env.preview"))
    {
        CS2U_EnvPreview(client);
        int total = CS2U_EnvPlanTotal();
        if (total == 0)
            CS2U_EnvNote(client, "预览：无需改动");
        else
            CS2U_EnvNote(client, "预览 %d 项，差异见聊天", total);
    }
    else if (StrEqual(key, "env.apply"))
    {
        if (CS2U_EnvApply(client, msg, sizeof(msg)))
        {
            CS2U_Reply(client, "%s", msg);
            CS2U_EnvNote(client, "%s", msg);
        }
        else
        {
            CS2U_Reply(client, "未应用：%s", msg);
            CS2U_EnvNote(client, "未应用：%s", msg);
        }
    }
    else if (StrEqual(key, "env.undo"))
    {
        if (CS2U_EnvUndo(client, msg, sizeof(msg)))
        {
            CS2U_Reply(client, "%s", msg);
            CS2U_EnvNote(client, "%s", msg);
        }
        else
        {
            CS2U_Reply(client, "未撤销：%s", msg);
            CS2U_EnvNote(client, "未撤销：%s", msg);
        }
    }
    else
    {
        return false;
    }

    if (reRender)
        CS2U_MenuEnv(client, page);
    return true;
}

public int MenuHandler_Status(Menu menu, MenuAction action, int param1, int param2)
{
    return CS2U_HandleSelect(menu, action, param1, param2, CS2U_CTX_STATUS);
}

public int MenuHandler_Config(Menu menu, MenuAction action, int param1, int param2)
{
    return CS2U_HandleSelect(menu, action, param1, param2, CS2U_CTX_CONFIG);
}

/* ---- presets application ------------------------------------------------- */

void CS2U_ApplyPresetByIndex(int client, int idx)
{
    if (idx < 0 || idx >= g_iPresetCount)
        return;
    if (g_iClientTier[client] < CS2U_TIER_ROOT)
    {
        CS2U_AuthRequire(client, CS2U_TIER_ROOT, "应用预设");
        return;
    }

    char name[CS2U_NAME_LEN], label[64], msg[256];
    CS2U_ModeName(idx, name, sizeof(name));
    CS2U_ModeLabelCn(name, label, sizeof(label));
    if (CS2U_ModeApply(client, name, msg, sizeof(msg)))
        CS2U_Reply(client, "%s", msg);
    else
        CS2U_Reply(client, "Preset failed: %s", msg);

    if (StrEqual(name, "cs2_split", false))
        QueryClientConVar(client, CS2U_L4N_CVAR, OnL4NQuery, 2);
}

/* ---- simple (plain language) status -------------------------------------- */

void CS2U_PrintSimpleStatus(int client)
{
    bool feelOn = CS2U_CvBool("cs2feel_enable");
    bool moveOn = CS2U_CvBool("cs2movement_enable");
    bool tracer = CS2U_CvBool("cs2u_tracer_enable");
    bool ballistics = CS2U_CvInt("cs2feel_ballistics_mode") != 0;

    CS2U_Reply(client, "当前效果（白话）：");
    if (feelOn)
    {
        if (ballistics)
            CS2U_Reply(client, "- 枪械：CS2 双通道（压枪 + 弹道修正）");
        else
            CS2U_Reply(client, "- 枪械：CS2 后坐力（压枪量 %.2f 倍）",
                       CS2U_CvFloat("cs2feel_recoil_scale"));
    }
    else
    {
        CS2U_Reply(client, "- 枪械：原生（CS2 手感关闭）");
    }
    CS2U_Reply(client, "- 移动：%s", moveOn ? "CS2 移动已开启" : "原生/关闭");
    CS2U_Reply(client, "- 弹道曳光：%s", tracer ? "开（服务器画子弹轨迹）" : "关");
    CS2U_Reply(client, "- 当前预设：%s", g_sActivePreset[0] ? g_sActivePreset : "(未应用)");
    CS2U_Reply(client, "要逐项微调，请点“手感 / 移动与受伤”。");
}

/* ---- recoil structure ---------------------------------------------------- */

bool CS2U_RecoilIsSplit()
{
    return CS2U_RecoilIsOn()
        && CS2U_CvInt("cs2feel_ballistics_mode") != 0
        && CS2U_CvFloat("cs2feel_ballistics_scale") < -0.000001;
}

/* Climb is NOT split: ballistics_mode 1 with a POSITIVE scale means the bullet
 * eats more punch than the camera.  Treating it as split made the structure row
 * print the wrong label and, worse, clicking it silently overwrote the climb
 * structure while cs2u_bmode stayed 3. */
bool CS2U_RecoilIsClimb()
{
    return CS2U_RecoilIsOn()
        && CS2U_CvInt("cs2feel_ballistics_mode") != 0
        && CS2U_CvFloat("cs2feel_ballistics_scale") > 0.000001;
}

bool CS2U_RecoilIsOn()
{
    return CS2U_CvBool("cs2feel_enable") && (CS2U_CvInt("cs2feel_recoil_mode") != 0);
}

void CS2U_RecoilLabel(char[] out, int maxlen)
{
    char scales[32];
    CS2U_BmodeScalesShort(scales, sizeof(scales));
    if (!CS2U_RecoilIsOn())
        strcopy(out, maxlen, "关闭（cs2feel 未启用）");
    else if (CS2U_RecoilIsClimb())
        Format(out, maxlen, "爬升 %s", scales);
    else if (CS2U_RecoilIsSplit())
        Format(out, maxlen, "分离 %s", scales);
    else
        Format(out, maxlen, "匹配 %s", scales);
}

void CS2U_RecoilRatio(char[] out, int maxlen)
{
    float cam = CS2U_CvFloat("cs2feel_recoil_scale");
    float off = CS2U_CvFloat("cs2feel_ballistics_scale");
    if (!CS2U_RecoilIsSplit() || FloatAbs(cam) < 0.000001)
        strcopy(out, maxlen, "0.0");
    else
        Format(out, maxlen, "%.6f", off / cam);
}

bool CS2U_ParamSetValue(const char[] cvar, const char[] value, char[] err, int errLen)
{
    int idx = CS2U_ParamFind(cvar);
    if (idx < 0)
    {
        Format(err, errLen, "%s is not a managed parameter", cvar);
        return false;
    }
    return CS2U_ParamSet(idx, value, err, errLen);
}

bool CS2U_ApplyRecoil(bool split, char[] msg, int maxlen)
{
    char err[128], persistMsg[128];
    err[0] = '\0';

    if (!CS2U_ParamSetValue("cs2feel_enable", "1", err, sizeof(err))
     || !CS2U_ParamSetValue("cs2feel_recoil_mode", "1", err, sizeof(err))
     || !CS2U_ParamSetValue("cs2feel_recoil_view_scale", "1.0", err, sizeof(err))
     || !CS2U_ParamSetValue("cs2feel_recoil_scale", split ? "1.10" : "1.0", err, sizeof(err))
     || !CS2U_ParamSetValue("cs2feel_ballistics_mode", split ? "1" : "0", err, sizeof(err))
     || !CS2U_ParamSetValue("cs2feel_ballistics_scale", split ? "-0.10" : "0.0", err, sizeof(err))
     || !CS2U_ParamSetValue("cs2feel_ballistics_yaw", split ? "1" : "0", err, sizeof(err)))
    {
        Format(msg, maxlen, "rejected: %s", err);
        return false;
    }

    if (!CS2U_PersistLive(persistMsg, sizeof(persistMsg)))
    {
        Format(msg, maxlen, "applied, but writing the config failed: %s", persistMsg);
        return false;
    }

    if (split)
        strcopy(msg, maxlen, "已切到 CS2 原生：相机 1.10 / 弹道 1.00 倍表值");
    else
        strcopy(msg, maxlen, "已切到匹配：相机与弹道同一个场（所见即所中）");
    return true;
}

/* ---- trajectory mode ----------------------------------------------------- */

int CS2U_BmodeBase()
{
    int m = (g_cvUBmode != null) ? GetConVarInt(g_cvUBmode) : CS2U_CvInt("cs2u_bmode");
    if (m == CS2U_BMODE_LEGACY_CLIMB)
        m = CS2U_BMODE_TR40;                 /* old weak climb -> the measured one */
    if (m < CS2U_BMODE_AUTO || m > CS2U_BMODE_MULTI)
        m = CS2U_BMODE_AUTO;
    return m;
}

float CS2U_BmodeUninstalled(int &total, int &miss)
{
    total = 0;
    miss = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;
        total++;
        if (!g_bAimAnswered[i] || !g_bAimInstalled[i])
            miss++;
    }
    if (total == 0)
        return -1.0;
    return float(miss) / float(total);
}

int CS2U_BmodeEffective(int &uPercent)
{
    int base = CS2U_BmodeBase();
    int total = 0, miss = 0;
    float u = CS2U_BmodeUninstalled(total, miss);
    uPercent = (u < 0.0) ? 100 : RoundToNearest(u * 100.0);

    if (base == CS2U_BMODE_TR40 || base == CS2U_BMODE_MULTI)
        return base;
    if (u < 0.0 || u > 0.50)
        return CS2U_BMODE_MULTI;
    return CS2U_BMODE_TR40;
}

void CS2U_BmodeRequirements(int mode, char[] out, int maxlen)
{
    if (mode == CS2U_BMODE_TR40)
        Format(out, maxlen, "客户端：Left4Neko 保持 1.0 + 装 cs2feel_aimsync（ini ratio = 1.200000）；弹孔爬在准星上方约 5°");
    else
        Format(out, maxlen, "客户端：可选 l4n_view_punch_scale 1.10；不装任何插件也完全一致");
}

bool CS2U_BmodeApply(int mode, char[] msg, int maxlen)
{
    char err[128], persistMsg[128];
    err[0] = '\0';
    bool climb = (mode == CS2U_BMODE_TR40);

    if (climb)
    {
        if (!CS2U_ParamSetValue("cs2feel_enable", "1", err, sizeof(err))
         || !CS2U_ParamSetValue("cs2feel_recoil_mode", "1", err, sizeof(err))
         || !CS2U_ParamSetValue("cs2feel_recoil_view_scale", "1.0", err, sizeof(err))
         || !CS2U_ParamSetValue("cs2feel_recoil_scale", "1.0", err, sizeof(err))
         || !CS2U_ParamSetValue("cs2feel_ballistics_mode", "1", err, sizeof(err))
         || !CS2U_ParamSetValue("cs2feel_ballistics_scale", "1.20", err, sizeof(err))
         || !CS2U_ParamSetValue("cs2feel_ballistics_yaw", "1", err, sizeof(err)))
        {
            Format(msg, maxlen, "rejected: %s", err);
            return false;
        }
        if (!CS2U_PersistLive(persistMsg, sizeof(persistMsg)))
        {
            Format(msg, maxlen, "applied, but writing the config failed: %s", persistMsg);
            return false;
        }
        strcopy(msg, maxlen, "已切到单人·TR-40：相机 1.00 / 弹道 2.20（实测弹孔比准星高约 5°，客户端 ini ratio 1.200000）");
        return true;
    }

    if (!CS2U_ParamSetValue("cs2feel_enable", "1", err, sizeof(err))
     || !CS2U_ParamSetValue("cs2feel_recoil_mode", "1", err, sizeof(err))
     || !CS2U_ParamSetValue("cs2feel_recoil_view_scale", "1.0", err, sizeof(err))
     || !CS2U_ParamSetValue("cs2feel_recoil_scale", "1.21", err, sizeof(err))
     || !CS2U_ParamSetValue("cs2feel_ballistics_mode", "0", err, sizeof(err))
     || !CS2U_ParamSetValue("cs2feel_ballistics_scale", "0.0", err, sizeof(err))
     || !CS2U_ParamSetValue("cs2feel_ballistics_yaw", "0", err, sizeof(err)))
    {
        Format(msg, maxlen, "rejected: %s", err);
        return false;
    }
    if (!CS2U_PersistLive(persistMsg, sizeof(persistMsg)))
    {
        Format(msg, maxlen, "applied, but writing the config failed: %s", persistMsg);
        return false;
    }
    strcopy(msg, maxlen, "已切到多人模式：服务器 matched（相机 = 弹道）");
    return true;
}

public void OnAimsyncQuery(QueryCookie cookie, int client, ConVarQueryResult result,
                            const char[] cvarName, const char[] cvarValue, any data)
{
    if (client <= 0 || client > MaxClients)
        return;
    g_bAimAnswered[client] = true;
    g_bAimInstalled[client] = (result == ConVarQuery_Okay);
    CS2U_Log("[aimsync] client=%d installed=%d value=%s", client,
             g_bAimInstalled[client] ? 1 : 0, cvarValue);

    /* data == 3: menu "弹道模式" readout -- tell the admin exactly what ratio
     * the client module is applying, so a mismatch with the server structure is
     * visible instead of guessed. */
    if (data == 3)
    {
        char expected[32];
        CS2U_BmodeExpectedRatio(expected, sizeof(expected));
        if (result == ConVarQuery_Okay)
            CS2U_Reply(client, "客户端 aim-sync：ratio = %s（当前结构应 %s）", cvarValue, expected);
        else if (result == ConVarQuery_NotFound)
            CS2U_Reply(client, "客户端 aim-sync：未安装（装饰性弹孔不会跟随服务器弹道）");
        else
            CS2U_Reply(client, "客户端 aim-sync：查询失败（%d）", view_as<int>(result));
        return;
    }

    if (g_bBmodePrompted || CS2U_BmodeBase() == CS2U_BMODE_MULTI)
        return;
    int total = 0, miss = 0;
    float u = CS2U_BmodeUninstalled(total, miss);
    if (u >= 0.20 && u <= 0.50 && miss > 0)
    {
        g_bBmodePrompted = true;
        PrintToChatAll("[CS2Unified] 弹道模式 auto：%d/%d 位玩家未装客户端 aim-sync。", miss, total);
    }
}

public Action Timer_BmodeQueryOne(Handle timer, any client)
{
    if (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client))
        QueryClientConVar(client, "cs2feel_aimsync", OnAimsyncQuery, 0);
    return Plugin_Stop;
}

public Action Timer_BmodeQueryAll(Handle timer, any data)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;
        QueryClientConVar(i, "cs2feel_aimsync", OnAimsyncQuery, 0);
    }
    return Plugin_Stop;
}

void CS2U_BmodeQuerySoon(int client)
{
    CreateTimer(5.0, Timer_BmodeQueryOne, client, TIMER_FLAG_NO_MAPCHANGE);
}

void CS2U_BmodeQueryAllSoon()
{
    CreateTimer(12.0, Timer_BmodeQueryAll, 0, TIMER_FLAG_NO_MAPCHANGE);
}

/* Async answer for QueryClientConVar. data == 1 -> status readout; data == 2
 * -> the "cs2_split was just applied" warning. */
public void OnL4NQuery(QueryCookie cookie, int client, ConVarQueryResult result,
                       const char[] cvarName, const char[] cvarValue, any data)
{
    if (client <= 0 || !IsClientInGame(client))
        return;

    bool installed = (result == ConVarQuery_Okay);
    bool missing   = (result == ConVarQuery_NotFound);

    if (data == 2)
    {
        if (!StrEqual(g_sActivePreset, "cs2_split", false))
            return;
        if (installed && FloatAbs(StringToFloat(cvarValue) - 1.0) > 0.001)
            CS2U_Reply(client, "[cs2_split] 检测到你装了 Left4Neko 且 l4n_view_punch_scale=%s：会与服务器侧分离叠加。建议先设为 1.0。", cvarValue);
        else if (installed)
            CS2U_Reply(client, "[cs2_split] 已应用；客户端 L4N = 1.0，不叠加。弹孔要跟随命中，请装客户端 aim-sync。");
        else
            CS2U_Reply(client, "[cs2_split] 已应用；未检测到 Left4Neko。弹孔要跟随命中，请装客户端 aim-sync。");
        return;
    }

    if (missing)
        CS2U_Reply(client, "Left4Neko：未安装。要分离请安装 Left4Neko 后执行 l4n_view_punch_scale 1.10。");
    else if (installed)
        CS2U_Reply(client, "Left4Neko：已安装，l4n_view_punch_scale = %s（0 = 最强分离；1.0 = matched）", cvarValue);
    else
        CS2U_Reply(client, "Left4Neko：查询失败（%d）。", view_as<int>(result));
}

/* ---- DIY helpers --------------------------------------------------------- */

#define CS2U_DIY_ADVANCED "diy_advanced"
#define CS2U_DIY_SIMPLE   "diy_simple"

void CS2U_DiyName(int which, char[] out, int maxlen)
{
    if (which == 0)
        strcopy(out, maxlen, CS2U_DIY_ADVANCED);
    else
        strcopy(out, maxlen, CS2U_DIY_SIMPLE);
}
