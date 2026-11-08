/**
 * cs2u_env.sp -- "one click to match this machine" (1.0.12).
 *
 * The problem this solves is not laziness: every tick-dependent conclusion in
 * this project was measured on a specific tick rate, but nothing in the plugin
 * ever told an operator WHICH one it is running on.  cs2feel_spread_tick_profile
 * defaults to 0 (off) and, at 0, the spread module applies the 30 Hz
 * calibration to a 64 Hz server -- it runs, it just is not right.
 *
 * This module makes the premise explicit:
 *   probe  -> what this server actually is (hz / form / slots / players / band)
 *   plan   -> which tick-dependent values disagree with that, and why
 *   apply  -> only after a preview, only the items in the preview, atomically
 *   undo   -> put back exactly what the last apply overwrote (memory + disk)
 *
 * Boundaries, deliberately:
 *   - Nothing is auto-applied on map start.  A tick change is REPORTED
 *     (ENV-CHANGED), never silently patched -- the same fail-loud policy as
 *     MENU-CONFIG-FALLBACK.
 *   - No sv_* is ever written.  sv_maxupdaterate is printed as a suggestion
 *     because it is a whole-server value and "one click for the env" is not a
 *     mandate to change it (docs/09 §5.2).
 *   - cs2feel_spread_tick_profile is NOT a managed parameter (the table is at
 *     39/40 and the presets are at 39/40 entries); it travels on its own path:
 *     FindConVar + SetConVarInt, persisted in the config's "env" section.
 *     That is why sm_cs2u_set cannot change it and why it never appears in a
 *     preset -- both by design, see docs/09 §5.1.
 *
 * The probe's only trustworthy input is GetTickInterval(); tickrate_enabler /
 * L4DToolZ are Metamod plugins and invisible to SourceMod, so the wording is
 * always "measured 64 Hz => inferred", never "detected tickrate_enabler".
 */

#if defined _cs2u_env_included
 #endinput
#endif
#define _cs2u_env_included

#define CS2U_ENV_CVAR_PROFILE "cs2feel_spread_tick_profile"

/* Selector values of cs2feel_spread_tick_profile (mirrored from
 * include/cs2feel_spread.inc constants; verify.ps1 asserts the two files agree
 * on the numbers, because a silent divergence here would make the advice lie). */
#define CS2U_ENV_SEL_OFF   0
#define CS2U_ENV_SEL_AUTO  1
#define CS2U_ENV_SEL_30    2
#define CS2U_ENV_SEL_60    3
#define CS2U_ENV_SEL_64    4

/* ---- probe --------------------------------------------------------------- */

/* Same bands as CS2F_SpreadProfileResolve().  Kept here as a copy on purpose:
 * that function takes a tick rate, this one takes the live one, and the plan
 * must be derivable without touching the feel module's state. */
int CS2U_EnvBandFor(float hz)
{
    if (hz >= 28.5 && hz <= 31.5)
        return 30;
    if (hz > 63.5 && hz <= 65.5)
        return 64;
    if (hz >= 57.0 && hz <= 63.5)
        return 60;
    return 0;
}

/* Re-derivation of the module's selector -> profile rule. */
int CS2U_EnvResolveProfile(float hz, int requested)
{
    if (requested == CS2U_ENV_SEL_30)
        return 30;
    if (requested == CS2U_ENV_SEL_60)
        return 60;
    if (requested == CS2U_ENV_SEL_64)
        return 64;
    if (requested != CS2U_ENV_SEL_AUTO)
        return 0;
    return CS2U_EnvBandFor(hz);
}

void CS2U_EnvBandName(int band, char[] out, int maxlen)
{
    if (band == 30)
        strcopy(out, maxlen, "30 Hz（标定 TV-56）");
    else if (band == 60)
        strcopy(out, maxlen, "60 Hz（标定 TV-62）");
    else if (band == 64)
        strcopy(out, maxlen, "64 Hz（标定 TR-51）");
    else
        strcopy(out, maxlen, "未标定（保持关闭）");
}

void CS2U_EnvProfileText(int selector, char[] out, int maxlen)
{
    if (selector == CS2U_ENV_SEL_AUTO)      Format(out, maxlen, "自动（%d）", selector);
    else if (selector == CS2U_ENV_SEL_30)   Format(out, maxlen, "强制 30（%d）", selector);
    else if (selector == CS2U_ENV_SEL_60)   Format(out, maxlen, "强制 60（%d）", selector);
    else if (selector == CS2U_ENV_SEL_64)   Format(out, maxlen, "强制 64（%d）", selector);
    else                                    Format(out, maxlen, "关（%d）", selector);
}

/* Fill every g_*Env probe field.  Always called live: an admin can change the
 * tick rate between maps with sm_cvar, and a cached probe would then lie. */
void CS2U_EnvProbe()
{
    g_fEnvInterval = GetTickInterval();
    g_fEnvHz = (g_fEnvInterval > 0.0) ? (1.0 / g_fEnvInterval) : 0.0;
    g_bEnvDedicated = IsDedicatedServer();
    /* MaxClients (the variable), not GetMaxClients(): the native is deprecated
     * in 1.12 and a warning fails the strict build. */
    g_iEnvMaxPlayers = MaxClients;

    g_iEnvPlayers = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
            g_iEnvPlayers++;
    }

    g_iEnvProfileCvar = CS2U_CvInt(CS2U_ENV_CVAR_PROFILE);
    g_iEnvProfileResolved = CS2U_EnvResolveProfile(g_fEnvHz, g_iEnvProfileCvar);
    g_iEnvProfileCarried = CS2F_SpreadProfile();
    g_iEnvBand = CS2U_EnvBandFor(g_fEnvHz);
    CS2U_EnvBandName(g_iEnvBand, g_sEnvBandName, sizeof(g_sEnvBandName));
}

/* What the selector should be on this machine, given the measured band.
 *
 * 64 / 60 Hz: force the calibrated profile of that band.  "Off" is wrong
 *             there (TV-60 measured -14.4% stand / +35.4% duck at 60 Hz).
 * 30 Hz:     OFF is already the 30 Hz calibration (TV-45/TV-56 calibrated the
 *            default ConVars), so the honest recommendation is 0 -- forcing 2
 *            would override the operator's duck/air values for no gain.
 * otherwise: 0 (uncalibrated: never guess, TV-60 limitation). */
int CS2U_EnvWantProfile()
{
    if (g_iEnvBand == 60)
        return CS2U_ENV_SEL_60;
    if (g_iEnvBand == 64)
        return CS2U_ENV_SEL_64;
    return CS2U_ENV_SEL_OFF;
}

/* ---- plan ---------------------------------------------------------------- */

int CS2U_EnvPlanTotal()
{
    return g_iEnvPlanItems + (g_bEnvPlanProfile ? 1 : 0);
}

void CS2U_EnvPlanAdd(int idx, const char[] value, const char[] why)
{
    if (idx < 0 || g_iEnvPlanItems >= CS2U_ENV_MAX_PLAN)
        return;

    char current[CS2U_VALUE_LEN];
    CS2U_ParamRaw(idx, current, CS2U_VALUE_LEN);
    if (StrEqual(current, value, false))
        return;   /* already at the recommendation: no diff, no write, no log */

    int i = g_iEnvPlanItems++;
    strcopy(g_sEnvPlanCvar[i], CS2U_CVAR_LEN, g_sParamCvar[idx]);
    strcopy(g_sEnvPlanValue[i], CS2U_VALUE_LEN, value);
    strcopy(g_sEnvPlanOld[i], CS2U_VALUE_LEN, current);
    strcopy(g_sEnvPlanWhy[i], CS2U_ENV_NOTE_LEN, why);
}

/**
 * Build the diff between "what this server is" and "what the tick-dependent
 * values say".  Idempotent: an already-aligned server produces 0 items.
 */
void CS2U_EnvPlanBuild()
{
    g_iEnvPlanItems = 0;
    g_bEnvPlanProfile = false;

    CS2U_EnvProbe();

    /* 1. spread tick profile (independent channel).
     *    Emitted only when the module is genuinely resolving to the wrong
     *    profile: at 64 Hz with selector 1 (auto) the resolution IS 64, so
     *    proposing 4 would be a cosmetic write with no effect. */
    int want = CS2U_EnvWantProfile();
    if (g_iEnvProfileResolved != g_iEnvBand && g_iEnvProfileCvar != want)
    {
        g_bEnvPlanProfile = true;
        g_iEnvPlanProfileOld = g_iEnvProfileCvar;
        g_iEnvPlanProfileNew = want;
    }

    /* 2. air_jump_speed: only ever measured at 64 Hz.  The plan never turns a
     *    feature ON (that is a gameplay decision), it only refuses to leave a
     *    value in place that the measurements do not cover. */
    if (g_iEnvBand != 64)
    {
        CS2U_EnvPlanAdd(CS2U_ParamFind("cs2movement_air_jump_speed"), "0",
                        "只在 64 tick 量过（D10），本机不是 64");
        CS2U_EnvPlanAdd(CS2U_ParamFind("cs2movement_lowspeed_sustain"), "0",
                        "逐帧修正的代价只在 64 tick 量过（D9）");
    }
}

/* ---- text output --------------------------------------------------------- */

/* Remember what the last env action did, for the page title.  Chat output alone
 * was invisible enough that four working buttons looked broken (1.0.13). */
void CS2U_EnvNote(int client, const char[] fmt, any ...)
{
    if (client < 0 || client > MaxClients)
        return;
    VFormat(g_sEnvLastMsg[client], sizeof(g_sEnvLastMsg[]), fmt, 3);
}

/* Compact host line for the menu row: "64.00 Hz ｜ 专用服 ｜ 32 槽 ｜ 0 人" */
void CS2U_EnvHostLine(char[] out, int maxlen)
{
    Format(out, maxlen, "%.2f Hz ｜ %s ｜ %d 槽 ｜ %d 人",
           g_fEnvHz + 0.0005,
           g_bEnvDedicated ? "专用服" : "listen server",
           g_iEnvMaxPlayers, g_iEnvPlayers);
}

/* Compact profile line: "spread 关（0）→ 建议 强制 64（4）" */
void CS2U_EnvProfileLine(char[] out, int maxlen)
{
    char now[32], want[32];
    CS2U_EnvProfileText(g_iEnvProfileCvar, now, sizeof(now));
    CS2U_EnvProfileText(CS2U_EnvWantProfile(), want, sizeof(want));
    Format(out, maxlen, "spread %s → 建议 %s", now, want);
}

/* Full probe block.  Every line names its source, because the whole point of
 * this page is that the operator can tell measured facts from inference. */
void CS2U_EnvPrintDetail(int client)
{
    CS2U_EnvProbe();

    char now[32], want[32];
    CS2U_EnvProfileText(g_iEnvProfileCvar, now, sizeof(now));
    CS2U_EnvProfileText(CS2U_EnvWantProfile(), want, sizeof(want));

    CS2U_Reply(client, "== 环境探测 ==");
    CS2U_Reply(client, "hz: %.2f（实测 1/GetTickInterval()，interval=%.6f）",
               g_fEnvHz + 0.0005, g_fEnvInterval);
    CS2U_Reply(client, "形态: %s（IsDedicatedServer）｜%d 槽（MaxClients）｜%d 人在线",
               g_bEnvDedicated ? "专用服" : "listen server", g_iEnvMaxPlayers, g_iEnvPlayers);

    if (g_iEnvBand != 0)
        CS2U_Reply(client, "tick 增强: 原版约 30 Hz，实测 %.2f Hz → 推断 L4DToolZ / tickrate_enabler 生效（它们都是 Metamod 插件，SourceMod 查不到）",
                   g_fEnvHz + 0.0005);
    else
        CS2U_Reply(client, "tick 增强: 实测 %.2f Hz，不在已标定的 30/60/64 档内（不猜测）",
                   g_fEnvHz + 0.0005);

    CS2U_Reply(client, "标定档: %s", g_sEnvBandName);
    CS2U_Reply(client, "spread: 档位=%s ｜ 规则解析=%d ｜ 模块携带=%d（来源 cs2feel_spread_tick_profile + cs2feel 的 TICKPROFILE 口径）",
               now, g_iEnvProfileResolved, g_iEnvProfileCarried);
    CS2U_Reply(client, "spread 建议: %s", want);

    CS2U_Reply(client, "受管项现值: air_jump_speed=%d ｜ lowspeed_sustain=%d ｜ duck_speed_min=%.1f",
               CS2U_CvInt("cs2movement_air_jump_speed"),
               CS2U_CvInt("cs2movement_lowspeed_sustain"),
               CS2U_CvFloat("cs2movement_duck_speed_min"));

    if (CS2U_CvInt("cs2feel_spread_mode") == 0)
        CS2U_Reply(client, "提示: cs2feel_spread_mode=0，tick 档位只在 spread 模式 1 时被读取（现在写了也不影响手感）");
    if (CS2U_CvInt("cs2movement_lowspeed_sustain") != 0
     && CS2U_CvFloat("cs2movement_duck_speed_min") > 0.5)
        CS2U_Reply(client, "警告: lowspeed_sustain 与 duck_speed_min>0 同时开着（D9）—— 二者需二选一，本页不会替你选");

    int rate = RoundToNearest(g_fEnvHz) + 1;
    if (rate < 20) rate = 20;
    if (rate > 100) rate = 100;
    CS2U_Reply(client, "建议（全服 rate，本插件从不写）: sv_maxupdaterate %d ｜ sv_maxrate 0（不限）", rate);

    if (g_bEnvPersist)
        CS2U_Reply(client, "已存适配: profile=%d ｜ 适配时 %.2f Hz ｜ %s",
                   g_iEnvPersistProfile, g_fEnvPersistHz, g_sEnvPersistAt);
    else
        CS2U_Reply(client, "已存适配: 无（还没应用过，或已撤销）");

    CS2U_EnvPlanBuild();
    CS2U_EnvPrintPlan(client);
}

void CS2U_EnvPrintPlan(int client)
{
    int total = CS2U_EnvPlanTotal();
    if (total == 0)
    {
        CS2U_Reply(client, "适配计划: 无需改动（%s 已是该环境的推荐组合）", g_sEnvBandName);
        return;
    }

    CS2U_Reply(client, "适配计划（%s）: 将改 %d 项，确认前一个值都不动", g_sEnvBandName, total);
    int n = 1;
    if (g_bEnvPlanProfile)
    {
        char oldText[32], newText[32];
        CS2U_EnvProfileText(g_iEnvPlanProfileOld, oldText, sizeof(oldText));
        CS2U_EnvProfileText(g_iEnvPlanProfileNew, newText, sizeof(newText));
        CS2U_Reply(client, "  %d) %s %s → %s  ← 未受管，走独立通道（%s）",
                   n, CS2U_ENV_CVAR_PROFILE, oldText, newText, g_sEnvBandName);
        n++;
    }
    for (int i = 0; i < g_iEnvPlanItems; i++)
    {
        CS2U_Reply(client, "  %d) %s %s → %s  ← %s",
                   n, g_sEnvPlanCvar[i], g_sEnvPlanOld[i], g_sEnvPlanValue[i], g_sEnvPlanWhy[i]);
        n++;
    }
}

/* ---- preview / apply / undo ---------------------------------------------- */

void CS2U_EnvPreview(int client)
{
    CS2U_EnvProbe();
    CS2U_EnvPlanBuild();

    int total = CS2U_EnvPlanTotal();
    CS2U_EnvPrintPlan(client);

    g_bEnvPreviewOk[client] = true;
    g_fEnvPreviewAt[client] = GetGameTime();
    g_iEnvPreviewItems[client] = total;

    /* No ACTION line for a zero-item preview: "nothing to do" is not an edit,
     * and E-7 wants a second click to leave no trace. */
    if (total > 0)
        CS2U_ActionLog("env-preview items=%d hz=%.2f profile=%d->%d by=%d",
                       total, g_fEnvHz, g_iEnvPlanProfileOld, g_iEnvPlanProfileNew, client);
}

/* Write the env section fields, call PersistLive, and roll everything back if
 * the disk write fails: a half-applied environment is exactly the state this
 * feature exists to avoid. */
bool CS2U_EnvCommit(char[] msg, int msgLen)
{
    int profileNew = g_iEnvProfileCvar;
    ConVar cv = FindConVar(CS2U_ENV_CVAR_PROFILE);

    CS2U_EnvProbe();
    CS2U_EnvPlanBuild();

    /* Snapshot for undo (memory + previous env section) before anything moves. */
    g_iEnvUndoItems = 0;
    for (int i = 0; i < g_iEnvPlanItems; i++)
    {
        strcopy(g_sEnvUndoCvar[i], CS2U_CVAR_LEN, g_sEnvPlanCvar[i]);
        strcopy(g_sEnvUndoValue[i], CS2U_VALUE_LEN, g_sEnvPlanOld[i]);
        g_iEnvUndoItems++;
    }
    g_bEnvUndoProfile = g_bEnvPlanProfile;
    g_iEnvUndoProfileValue = g_iEnvPlanProfileOld;
    g_bEnvUndoPersist = g_bEnvPersist;
    g_iEnvUndoPersistProfile = g_iEnvPersistProfile;
    g_fEnvUndoPersistHz = g_fEnvPersistHz;
    strcopy(g_sEnvUndoPersistAt, sizeof(g_sEnvUndoPersistAt), g_sEnvPersistAt);
    g_bEnvUndoValid = true;

    /* 1. managed items through the normal validated path (clamp + telemetry) */
    char err[160];
    for (int i = 0; i < g_iEnvPlanItems; i++)
    {
        int idx = CS2U_ParamFind(g_sEnvPlanCvar[i]);
        if (idx < 0 || !CS2U_ParamSet(idx, g_sEnvPlanValue[i], err, sizeof(err)))
        {
            CS2U_EnvRestoreUndo();
            g_bEnvUndoValid = false;
            Format(msg, msgLen, "写入被拒，已全部还原：%s", idx < 0 ? "参数表里找不到该项" : err);
            return false;
        }
    }

    /* 2. spread tick profile through its own channel */
    if (g_bEnvPlanProfile)
    {
        if (cv == null)
        {
            CS2U_EnvRestoreUndo();
            g_bEnvUndoValid = false;
            Format(msg, msgLen, "%s 未注册（cs2feel 没加载？），已全部还原", CS2U_ENV_CVAR_PROFILE);
            return false;
        }
        SetConVarInt(cv, g_iEnvPlanProfileNew);
        profileNew = g_iEnvPlanProfileNew;
    }

    /* 3. persist: settings (39) + the env section, one write */
    bool prevPersist = g_bEnvPersist;
    int prevProfile = g_iEnvPersistProfile;
    float prevHz = g_fEnvPersistHz;
    char prevAt[CS2U_ENV_AT_LEN];
    strcopy(prevAt, sizeof(prevAt), g_sEnvPersistAt);

    g_bEnvPersist = true;
    g_iEnvPersistProfile = profileNew;
    g_fEnvPersistHz = g_fEnvHz;
    FormatTime(g_sEnvPersistAt, sizeof(g_sEnvPersistAt), "%Y-%m-%d %H:%M", -1);

    char persistMsg[192];
    if (!CS2U_PersistLive(persistMsg, sizeof(persistMsg)))
    {
        CS2U_EnvRestoreUndo();
        g_bEnvPersist = prevPersist;
        g_iEnvPersistProfile = prevProfile;
        g_fEnvPersistHz = prevHz;
        strcopy(g_sEnvPersistAt, sizeof(g_sEnvPersistAt), prevAt);
        g_bEnvUndoValid = false;
        Format(msg, msgLen, "写盘失败，已全部还原：%s", persistMsg);
        return false;
    }

    CS2U_EnvPlanBuild();   /* recompute so the page shows "no change" now */
    g_bEnvDriftNotified = false;
    CS2U_ReconcileMovement();

    /* "受管值 N 个" is the count of the 39-table writes; the profile travels on
     * its own channel, so it is reported separately instead of being folded
     * into a number that would then disagree with the config's settings block. */
    Format(msg, msgLen, "已适配 %s：spread 档位 %d，受管值 %d 个，已写盘（可撤销）",
           g_sEnvBandName, profileNew, g_iEnvUndoItems);
    return true;
}

/* Put back exactly the last apply (used both by undo and by a failed apply). */
void CS2U_EnvRestoreUndo()
{
    char err[160];
    for (int i = 0; i < g_iEnvUndoItems; i++)
    {
        int idx = CS2U_ParamFind(g_sEnvUndoCvar[i]);
        if (idx < 0)
            continue;
        if (!CS2U_ParamSet(idx, g_sEnvUndoValue[i], err, sizeof(err)))
            CS2U_Log("ENV-UNDO-SET-FAILED %s=%s: %s", g_sEnvUndoCvar[i], g_sEnvUndoValue[i], err);
    }

    if (g_bEnvUndoProfile)
    {
        ConVar cv = FindConVar(CS2U_ENV_CVAR_PROFILE);
        if (cv != null)
            SetConVarInt(cv, g_iEnvUndoProfileValue);
    }
}

bool CS2U_EnvApply(int client, char[] msg, int msgLen)
{
    if (!g_bEnvPreviewOk[client]
     || GetGameTime() - g_fEnvPreviewAt[client] > CS2U_ENV_PREVIEW_TTL)
    {
        Format(msg, msgLen, "请先预览（菜单「预览适配」/ sm_cs2u_env preview），预览 %.0f 秒内有效",
               CS2U_ENV_PREVIEW_TTL);
        return false;
    }
    g_bEnvPreviewOk[client] = false;

    CS2U_EnvProbe();
    CS2U_EnvPlanBuild();
    int total = CS2U_EnvPlanTotal();

    /* The preview is a contract: if the world moved in between (someone
     * changed a value, tick changed), refuse instead of applying a diff the
     * admin never saw. */
    if (total != g_iEnvPreviewItems[client])
    {
        Format(msg, msgLen, "预览之后已经有变化（预览 %d 项 / 现在 %d 项），请重新预览",
               g_iEnvPreviewItems[client], total);
        return false;
    }

    if (total == 0)
    {
        Format(msg, msgLen, "无需改动：%s 已是推荐组合（未写盘、未记录）", g_sEnvBandName);
        return true;
    }

    if (!CS2U_EnvCommit(msg, msgLen))
    {
        CS2U_ActionLog("env-apply-failed by=%d", client);
        return false;
    }

    /* Read the counters Commit just filled: those are what undo will restore.
     * items counts both channels, so a profile-only adaptation does not log
     * "items=0" while it did change something. */
    CS2U_ActionLog("env-apply hz=%.2f band=%d items=%d profile=%d by=%d",
                   g_fEnvHz, g_iEnvBand,
                   g_iEnvUndoItems + (g_bEnvUndoProfile ? 1 : 0),
                   g_bEnvUndoProfile ? g_iEnvPersistProfile : g_iEnvProfileCvar, client);
    return true;
}

bool CS2U_EnvUndo(int client, char[] msg, int msgLen)
{
    if (!g_bEnvUndoValid)
    {
        Format(msg, msgLen, "没有可撤销的适配（本会话还没应用过，或已经撤销过）");
        return false;
    }

    /* Count both channels: a profile-only adaptation restored exactly one
     * value (the spread tick profile), and the old message claimed "0 values"
     * for it -- found by replaying apply->undo through sm_cs2u_menusel (1.0.15). */
    int items = g_iEnvUndoItems + (g_bEnvUndoProfile ? 1 : 0);
    CS2U_EnvRestoreUndo();

    /* Restore the env section as it was: an undo that leaves the config saying
     * "adapted" would be re-applied on the next map and silently undo itself. */
    g_bEnvPersist = g_bEnvUndoPersist;
    g_iEnvPersistProfile = g_iEnvUndoPersistProfile;
    g_fEnvPersistHz = g_fEnvUndoPersistHz;
    strcopy(g_sEnvPersistAt, sizeof(g_sEnvPersistAt), g_sEnvUndoPersistAt);

    char persistMsg[192];
    if (!CS2U_PersistLive(persistMsg, sizeof(persistMsg)))
    {
        Format(msg, msgLen, "已还原 %d 个值，但写盘失败（换图后可能被旧设置覆盖）：%s", items, persistMsg);
        g_bEnvUndoValid = false;
        return false;
    }

    g_bEnvUndoValid = false;
    CS2U_ReconcileMovement();
    CS2U_ActionLog("env-undo items=%d by=%d", items, client);
    Format(msg, msgLen, "已撤销上次适配：%d 个值回到适配前%s", items,
           g_bEnvPersist ? "" : "，env 段已清除");
    return true;
}

/* ---- persistence hook (called by cs2u_config.sp) ------------------------- */

/* Soft read: an unreadable/hostile env section must never reject the whole
 * config (the 39 managed settings are more important than this), so it is
 * logged and ignored instead of fail-closed. */
void CS2U_EnvLoadFromConfig(KeyValues kv)
{
    g_bEnvPersist = false;
    g_iEnvPersistProfile = 0;
    g_fEnvPersistHz = 0.0;
    g_sEnvPersistAt[0] = '\0';

    kv.Rewind();
    if (!kv.JumpToKey("env"))
        return;

    char buf[CS2U_VALUE_LEN];
    kv.GetString("spread_tick_profile", buf, sizeof(buf), "");
    int profile = -1;
    if (buf[0] != '\0')
    {
        if (!CS2U_IsNumericString(buf))
        {
            CS2U_Log("ENV-BAD-PROFILE '%s' (ignored)", buf);
        }
        else
        {
            profile = StringToInt(buf);
            if (profile < 0 || profile > CS2U_ENV_SEL_64)
            {
                CS2U_Log("ENV-BAD-PROFILE %d outside 0..%d (ignored)", profile, CS2U_ENV_SEL_64);
                profile = -1;
            }
        }
    }

    char hz[CS2U_VALUE_LEN];
    kv.GetString("adapted_hz", hz, sizeof(hz), "0");
    kv.GetString("adapted_at", g_sEnvPersistAt, sizeof(g_sEnvPersistAt), "");

    if (profile >= 0)
    {
        g_bEnvPersist = true;
        g_iEnvPersistProfile = profile;
        g_fEnvPersistHz = CS2U_IsNumericString(hz) ? StringToFloat(hz) : 0.0;
    }

    kv.Rewind();
}

/* Re-assert the stored profile (map change / reload / late load).  The value
 * is not in the 39 settings, so nothing else puts it back. */
void CS2U_EnvApplyStored()
{
    if (!g_bEnvPersist)
        return;

    ConVar cv = FindConVar(CS2U_ENV_CVAR_PROFILE);
    if (cv == null)
    {
        CS2U_Log("ENV-STORED-MISSING %s (feel module not loaded?)", CS2U_ENV_CVAR_PROFILE);
        return;
    }

    int now = GetConVarInt(cv);
    if (now != g_iEnvPersistProfile)
    {
        SetConVarInt(cv, g_iEnvPersistProfile);
        CS2U_Log("ENV-PROFILE-RECLAIM %d -> %d (stored adaptation)", now, g_iEnvPersistProfile);
    }
    CS2U_Log("ENV-APPLY profile=%d adapted_hz=%.2f at=%s managed=39",
             g_iEnvPersistProfile, g_fEnvPersistHz,
             g_sEnvPersistAt[0] ? g_sEnvPersistAt : "(unknown)");
}

/* Report, never patch: if the tick rate moved since the adaptation, say so
 * (log + ROOT admins online) instead of silently re-adapting. */
void CS2U_EnvCheckDrift()
{
    CS2U_EnvProbe();
    if (!g_bEnvPersist || g_fEnvPersistHz <= 0.0)
        return;
    if (FloatAbs(g_fEnvHz - g_fEnvPersistHz) < 2.0)
        return;

    CS2U_Log("ENV-CHANGED adapted_hz=%.2f now_hz=%.2f band=%d -- adaptation is stale, run sm_cs2u_env again",
             g_fEnvPersistHz, g_fEnvHz, g_iEnvBand);

    if (g_bEnvDriftNotified)
        return;
    g_bEnvDriftNotified = true;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;
        if (g_iClientTier[i] < CS2U_TIER_ROOT)
            continue;
        CS2U_Reply(i, "tick 变了：适配时 %.2f Hz，现在 %.2f Hz（已失效）。!cs2u → 移动与受伤 → 环境适配。",
                   g_fEnvPersistHz, g_fEnvHz);
    }
}

/* ---- lifecycle / console ------------------------------------------------- */

void CS2U_EnvOnMapStart()
{
    CS2U_EnvApplyStored();
    CS2U_EnvCheckDrift();
}

void CS2U_EnvInit()
{
    RegAdminCmd("sm_cs2u_env", Cmd_Env, ADMFLAG_ROOT,
                "Usage: sm_cs2u_env [status|preview|apply|undo|clear]  -- probe this server's tick environment and align the tick-dependent values (preview is mandatory before apply).");
    /* Regression surface: feeds a raw menu row id through the SAME dispatcher the
     * menu uses.  1.0.13 shipped a dispatcher that split "env.preview:0" by ':'
     * and silently did nothing for every action row; without a client there was
     * no way to catch it. */
    RegAdminCmd("sm_cs2u_menusel", Cmd_MenuSel, ADMFLAG_ROOT,
                "Usage: sm_cs2u_menusel <env.detail|env.preview|env.apply|env.undo>[:page]  -- run one menu row through the menu dispatcher (no client needed).");

    CS2U_EnvProbe();
    CS2U_Log("ENV-PROBE hz=%.2f interval=%.6f dedicated=%d maxplayers=%d players=%d band=%d profile_cvar=%d profile_resolved=%d profile_carried=%d",
             g_fEnvHz, g_fEnvInterval, g_bEnvDedicated ? 1 : 0, g_iEnvMaxPlayers, g_iEnvPlayers,
             g_iEnvBand, g_iEnvProfileCvar, g_iEnvProfileResolved, g_iEnvProfileCarried);

    /* Late load / fresh start: the stored adaptation must be in effect before
     * the first map, not 0.5 s after the first cfg executes. */
    CS2U_EnvApplyStored();
}

public Action Cmd_MenuSel(int client, int args)
{
    if (!CS2U_IsEnabled())
    {
        CS2U_Reply(client, "Management layer is disabled (cs2u_enable 0).");
        return Plugin_Handled;
    }
    if (!CS2U_AuthCheck(client, "menusel"))
        return Plugin_Handled;

    if (args < 1)
    {
        CS2U_Reply(client, "用法 / Usage: sm_cs2u_menusel <env.detail|env.preview|env.apply|env.undo>[:page]");
        return Plugin_Handled;
    }

    char info[64];
    GetCmdArg(1, info, sizeof(info));

    if (!CS2U_EnvAction(client, info, false))
        CS2U_Reply(client, "没有这一行 / unknown row: '%s'（目前只支持 env.* 行）", info);
    return Plugin_Handled;
}

public Action Cmd_Env(int client, int args)
{    if (!CS2U_IsEnabled())
    {
        CS2U_Reply(client, "Management layer is disabled (cs2u_enable 0).");
        return Plugin_Handled;
    }
    if (!CS2U_AuthCheck(client, "env"))
        return Plugin_Handled;

    char sub[24];
    sub[0] = '\0';
    if (args >= 1)
        GetCmdArg(1, sub, sizeof(sub));

    if (sub[0] == '\0' || StrEqual(sub, "status", false) || StrEqual(sub, "detail", false))
    {
        CS2U_EnvPrintDetail(client);
        return Plugin_Handled;
    }

    char msg[256];
    if (StrEqual(sub, "preview", false))
    {
        CS2U_EnvPreview(client);
        return Plugin_Handled;
    }
    if (StrEqual(sub, "apply", false))
    {
        if (CS2U_EnvApply(client, msg, sizeof(msg)))
            CS2U_Reply(client, "%s", msg);
        else
            CS2U_Reply(client, "Apply refused: %s", msg);
        return Plugin_Handled;
    }
    if (StrEqual(sub, "undo", false))
    {
        if (CS2U_EnvUndo(client, msg, sizeof(msg)))
            CS2U_Reply(client, "%s", msg);
        else
            CS2U_Reply(client, "Undo refused: %s", msg);
        return Plugin_Handled;
    }
    if (StrEqual(sub, "clear", false))
    {
        /* Drop the stored adaptation marker without touching the live values.
         * Normal flow does this through undo; this exists for "I like the
         * values, I just do not want them re-asserted on every map" and for
         * leaving the server in a defined state after a test run. */
        if (!g_bEnvPersist)
        {
            CS2U_Reply(client, "没有已存适配，无需清除。");
            return Plugin_Handled;
        }
        g_bEnvPersist = false;
        g_iEnvPersistProfile = 0;
        g_fEnvPersistHz = 0.0;
        g_sEnvPersistAt[0] = '\0';
        g_bEnvUndoValid = false;   /* the snapshot described the cleared state */

        char pmsg[192];
        if (CS2U_PersistLive(pmsg, sizeof(pmsg)))
        {
            CS2U_ActionLog("env-clear by=%d", client);
            CS2U_Reply(client, "已清除「已存适配」标记：当前值不变，换图后不再自动回填。");
        }
        else
        {
            CS2U_Reply(client, "清除失败：%s", pmsg);
        }
        return Plugin_Handled;
    }

    CS2U_Reply(client, "用法 / Usage: sm_cs2u_env [status|preview|apply|undo|clear]");
    return Plugin_Handled;
}
