/**
 * cs2u_weapon.sp -- the per-weapon ground speed table, editable from the menu.
 *
 * Why a separate module and not 18 managed parameters
 *   CS2U_MAX_PARAMS is 40 and the unified layer is already at 39 (water was the
 *   last slot).  The weapon table is also a different kind of value: it is a
 *   *file-backed map* owned by cs2movement (configs/cs2movement_weapons.cfg,
 *   loaded by CS2M_MoveLoadWeaponTable into g_mWeaponSpeeds), not a ConVar.
 *   Forcing 18 entries into the parameter table would need a capacity bump in
 *   three places plus a new preset column, for values nobody switches per
 *   preset.  So this module keeps its own ordered table and writes the same
 *   file cs2movement reads.
 *
 * Why an ordered table in code
 *   g_mWeaponSpeeds is a StringMap: no order, no labels.  The menu needs a
 *   stable list, so the class order and the Chinese labels live here, and
 *   g_fWpnDefault carries the shipped CS2 reference value for
 *   "restore defaults".  The file stays the source of truth at boot; this table
 *   is the fallback for a missing entry and the definition of "default".
 *
 * Persistence
 *   Every edit rewrites configs/cs2movement_weapons.cfg immediately (tmp file ->
 *   .bak -> rename), because a map change or `sm_cs2movement_reload` re-reads
 *   that file and would otherwise silently revert the value.  The in-memory
 *   StringMap is updated first, so the change is already live for the next tick
 *   even if the write fails -- in that case the caller reports the write error
 *   instead of pretending it persisted.
 */

#if defined _cs2u_weapon_included
 #endinput
#endif
#define _cs2u_weapon_included

#define CS2U_WEAPON_COUNT        18
#define CS2U_WEAPON_CLASS_LEN    64
#define CS2U_WEAPON_LABEL_LEN    48
#define CS2U_WEAPON_MIN_SPEED    50.0
#define CS2U_WEAPON_MAX_SPEED    1000.0
#define CS2U_WEAPON_INPUT_TIMEOUT 60.0

/* Order matters: it is the menu order and the order written back to the file.
 * Grouped by weapon family so the page reads like the game's loadout. */
char g_sWpnClass[CS2U_WEAPON_COUNT][CS2U_WEAPON_CLASS_LEN] = {
    "weapon_rifle",            /* M16 */
    "weapon_rifle_ak47",
    "weapon_rifle_desert",     /* SCAR */
    "weapon_rifle_sg552",
    "weapon_smg",
    "weapon_smg_silenced",
    "weapon_smg_mp5",
    "weapon_pistol",
    "weapon_pistol_magnum",
    "weapon_hunting_rifle",
    "weapon_sniper_scout",
    "weapon_sniper_military",
    "weapon_sniper_awp",
    "weapon_shotgun_chrome",
    "weapon_shotgun_spas",
    "weapon_pumpshotgun",
    "weapon_melee",
    "weapon_chainsaw"
};

char g_sWpnLabel[CS2U_WEAPON_COUNT][CS2U_WEAPON_LABEL_LEN] = {
    "M16 步枪",
    "AK-47",
    "沙漠步枪 SCAR",
    "SG552",
    "Uzi 冲锋枪",
    "消音冲锋枪",
    "MP5",
    "手枪",
    "马格南手枪",
    "猎枪（木狙）",
    "Scout 轻狙",
    "军用狙击",
    "AWP",
    "铬合金霰弹",
    "SPAS 霰弹",
    "泵动霰弹",
    "近战武器",
    "电锯"
};

/* Shipped CS2 reference values -- identical to configs/cs2movement_weapons.cfg
 * and to the inline fallbacks in CS2M_MoveWeaponSpeed().  "Restore defaults"
 * writes these back. */
float g_fWpnDefault[CS2U_WEAPON_COUNT] = {
    215.0, 215.0, 225.0, 225.0,
    240.0, 240.0, 240.0,
    240.0, 230.0,
    230.0, 230.0, 230.0, 200.0,
    230.0, 230.0, 230.0,
    250.0, 250.0
};

float g_fWpnCurrent[CS2U_WEAPON_COUNT];

/* Chat input state: the menu row only says "which weapon"; the value arrives on
 * the next `say`.  0 = no pending edit for that slot. */
bool  g_bWpnInput[MAXPLAYERS + 1];
int   g_iWpnInput[MAXPLAYERS + 1];
float g_fWpnInputAt[MAXPLAYERS + 1];

int   g_iWpnEdits = 0;   /* telemetry: edits written this session */

void CS2U_WeaponInit()
{
    for (int i = 0; i < CS2U_WEAPON_COUNT; i++)
        g_fWpnCurrent[i] = g_fWpnDefault[i];
    CS2U_WeaponRefresh();

    /* Console surface for the same table: an admin on RCON cannot click a menu,
     * and the runtime tests need a scriptable entry point. */
    RegAdminCmd("sm_cs2u_weapons", Cmd_Weapons, ADMFLAG_ROOT,
                "List / set the per-weapon ground speed table (sm_cs2u_weapons [<class|index>] [<speed>] | reset).");
}

/* Pull the live values out of the movement StringMap.  Called on init and
 * after every write/reload, so the page never shows a stale number. */
void CS2U_WeaponRefresh()
{
    for (int i = 0; i < CS2U_WEAPON_COUNT; i++)
    {
        char value[32];
        if (g_mWeaponSpeeds != null
         && g_mWeaponSpeeds.GetString(g_sWpnClass[i], value, sizeof(value)))
            g_fWpnCurrent[i] = StringToFloat(value);
        else
            g_fWpnCurrent[i] = g_fWpnDefault[i];
    }
}

float CS2U_WeaponSpeed(int idx)
{
    if (idx < 0 || idx >= CS2U_WEAPON_COUNT)
        return 0.0;
    return g_fWpnCurrent[idx];
}

int CS2U_WeaponFind(const char[] token)
{
    if (token[0] == '\0')
        return -1;
    /* Accept the list index as well as the class name: typing
     * `sm_cs2u_weapons 3 220` is shorter than the full class. */
    if (CS2U_IsNumericString(token))
    {
        int idx = StringToInt(token);
        return (idx >= 0 && idx < CS2U_WEAPON_COUNT) ? idx : -1;
    }
    for (int i = 0; i < CS2U_WEAPON_COUNT; i++)
        if (StrEqual(g_sWpnClass[i], token, false))
            return i;
    return -1;
}

/**
 * Set one weapon speed: memory first (takes effect on the next tick), then the
 * file (survives map changes and reloads).  Returns false only for a bad range
 * or a failed write; the message says which.
 */
bool CS2U_WeaponSet(int idx, float speed, char[] msg, int msgLen)
{
    if (idx < 0 || idx >= CS2U_WEAPON_COUNT)
    {
        Format(msg, msgLen, "weapon index %d out of range", idx);
        return false;
    }
    if (speed < CS2U_WEAPON_MIN_SPEED || speed > CS2U_WEAPON_MAX_SPEED)
    {
        Format(msg, msgLen, "%s 超出范围 %.0f–%.0f u/s",
               g_sWpnLabel[idx], CS2U_WEAPON_MIN_SPEED, CS2U_WEAPON_MAX_SPEED);
        return false;
    }

    if (g_mWeaponSpeeds == null)
        g_mWeaponSpeeds = new StringMap();

    char value[32];
    Format(value, sizeof(value), "%.4f", speed);
    g_mWeaponSpeeds.SetString(g_sWpnClass[idx], value);
    g_fWpnCurrent[idx] = speed;
    g_iWpnEdits++;

    char err[192];
    if (!CS2U_WeaponWriteFile(err, sizeof(err)))
    {
        Format(msg, msgLen, "%s = %.0f（内存已生效，但写盘失败：%s）",
               g_sWpnLabel[idx], speed, err);
        return false;
    }

    Format(msg, msgLen, "%s（%s）= %.0f u/s，已写盘",
           g_sWpnLabel[idx], g_sWpnClass[idx], speed);
    return true;
}

/* Put every entry back to the shipped CS2 value and write once. */
bool CS2U_WeaponResetAll(char[] msg, int msgLen)
{
    if (g_mWeaponSpeeds == null)
        g_mWeaponSpeeds = new StringMap();

    char value[32];
    for (int i = 0; i < CS2U_WEAPON_COUNT; i++)
    {
        Format(value, sizeof(value), "%.4f", g_fWpnDefault[i]);
        g_mWeaponSpeeds.SetString(g_sWpnClass[i], value);
        g_fWpnCurrent[i] = g_fWpnDefault[i];
    }
    g_iWpnEdits++;

    char err[192];
    if (!CS2U_WeaponWriteFile(err, sizeof(err)))
    {
        Format(msg, msgLen, "已恢复 %d 件武器的默认值（内存），但写盘失败：%s",
               CS2U_WEAPON_COUNT, err);
        return false;
    }

    Format(msg, msgLen, "已恢复 %d 件武器的默认速度并写盘", CS2U_WEAPON_COUNT);
    return true;
}

void CS2U_WeaponPath(char[] path, int maxlen)
{
    BuildPath(Path_SM, path, maxlen, "configs/cs2movement_weapons.cfg");
}

/* Format a speed the way a human writes it: 215, not 215.0000. */
void CS2U_WeaponFormatSpeed(float speed, char[] out, int maxlen)
{
    if (FloatAbs(speed - float(RoundToNearest(speed))) < 0.0005)
        Format(out, maxlen, "%.0f", speed);
    else
        Format(out, maxlen, "%.3f", speed);
}

/**
 * Rewrite configs/cs2movement_weapons.cfg in the exact nested shape
 * CS2M_MoveLoadWeaponTable() expects:
 *
 *     "CS2MovementWeapons"
 *     {
 *         "weapon_rifle"
 *         {
 *             "speed" "215"
 *         }
 *     }
 *
 * tmp -> (old -> .bak) -> rename: a crash mid-write leaves either the old file
 * or a complete new one, never a half table.  Comments are regenerated (the
 * KeyValues writer cannot preserve them).
 */
bool CS2U_WeaponWriteFile(char[] err, int errLen)
{
    char path[PLATFORM_MAX_PATH];
    CS2U_WeaponPath(path, sizeof(path));

    char tmp[PLATFORM_MAX_PATH];
    Format(tmp, sizeof(tmp), "%s.tmp", path);

    File f = OpenFile(tmp, "wt");
    if (f == null)
    {
        Format(err, errLen, "cannot open %s for writing", tmp);
        return false;
    }

    f.WriteLine("// ===========================================================================");
    f.WriteLine("// CS2Movement_L4D2 -- per-weapon ground speed table");
    f.WriteLine("// ---------------------------------------------------------------------------");
    f.WriteLine("// Written by CS2Unified (sm_cs2u_weapons / the in-game menu).  Edits made");
    f.WriteLine("// here by hand are read at map start, but the next edit from the menu");
    f.WriteLine("// rewrites the whole file.");
    f.WriteLine("//");
    f.WriteLine("// L4D2 weapon class -> CS2 ground speed (u/s).  Unknown classes fall back to");
    f.WriteLine("// cs2movement_base_speed.  ASCII only.");
    f.WriteLine("// ===========================================================================");
    f.WriteLine("");
    f.WriteLine("\"CS2MovementWeapons\"");
    f.WriteLine("{");

    char num[32];
    for (int i = 0; i < CS2U_WEAPON_COUNT; i++)
    {
        CS2U_WeaponFormatSpeed(g_fWpnCurrent[i], num, sizeof(num));
        f.WriteLine("    \"%s\"", g_sWpnClass[i]);
        f.WriteLine("    {");
        f.WriteLine("        \"speed\" \"%s\"", num);
        f.WriteLine("    }");
        if (i != CS2U_WEAPON_COUNT - 1)
            f.WriteLine("");
    }

    f.WriteLine("}");
    f.Close();

    char bak[PLATFORM_MAX_PATH];
    Format(bak, sizeof(bak), "%s.bak", path);
    if (FileExists(bak))
        DeleteFile(bak);

    if (FileExists(path) && !RenameFile(bak, path))
    {
        DeleteFile(tmp);
        Format(err, errLen, "cannot move %s aside", path);
        return false;
    }

    if (!RenameFile(path, tmp))
    {
        /* Put the previous table back: a failed write must not lose the file. */
        if (FileExists(bak))
            RenameFile(path, bak);
        DeleteFile(tmp);
        Format(err, errLen, "cannot move %s into place", path);
        return false;
    }

    return true;
}

/* ---- chat input ---------------------------------------------------------- */

void CS2U_WeaponClearInput(int client)
{
    if (client < 0 || client > MaxClients)
        return;
    g_bWpnInput[client] = false;
    g_iWpnInput[client] = 0;
    g_fWpnInputAt[client] = 0.0;
}

void CS2U_WeaponBeginInput(int client, int idx)
{
    if (idx < 0 || idx >= CS2U_WEAPON_COUNT)
        return;

    CS2U_WeaponRefresh();
    g_bWpnInput[client] = true;
    g_iWpnInput[client] = idx;
    g_fWpnInputAt[client] = GetGameTime();

    CS2U_Reply(client, "修改「%s」（%s）：当前 %.0f u/s",
               g_sWpnLabel[idx], g_sWpnClass[idx], g_fWpnCurrent[idx]);
    CS2U_Reply(client, "在聊天栏直接输入新速度（%.0f–%.0f），%.0f 秒内有效；输入「取消」放弃。",
               CS2U_WEAPON_MIN_SPEED, CS2U_WEAPON_MAX_SPEED, CS2U_WEAPON_INPUT_TIMEOUT);
}

/**
 * Consume a chat line when this client is in input mode.  Returns true when the
 * message was ours and must NOT reach the other players.
 */
bool CS2U_WeaponHandleInput(int client, const char[] text)
{
    if (client < 1 || client > MaxClients)
        return false;
    if (!g_bWpnInput[client])
        return false;

    if (GetGameTime() - g_fWpnInputAt[client] > CS2U_WEAPON_INPUT_TIMEOUT)
    {
        CS2U_WeaponClearInput(client);
        return false;   /* expired: let the line behave like a normal say */
    }

    char work[64];
    strcopy(work, sizeof(work), text);
    TrimString(work);

    if (StrEqual(work, "取消", false) || StrEqual(work, "cancel", false) || StrEqual(work, "q", false))
    {
        CS2U_WeaponClearInput(client);
        CS2U_Reply(client, "已取消，数值未改动。");
        return true;
    }

    if (!CS2U_IsNumericString(work))
    {
        CS2U_Reply(client, "「%s」不是数字：请直接输入 %.0f–%.0f，或输入「取消」。",
                   work, CS2U_WEAPON_MIN_SPEED, CS2U_WEAPON_MAX_SPEED);
        return true;
    }

    float speed = StringToFloat(work);
    if (speed < CS2U_WEAPON_MIN_SPEED || speed > CS2U_WEAPON_MAX_SPEED)
    {
        CS2U_Reply(client, "%.0f 超出范围 %.0f–%.0f；数值未改动，可重新输入或输入「取消」。",
                   speed, CS2U_WEAPON_MIN_SPEED, CS2U_WEAPON_MAX_SPEED);
        return true;
    }

    int idx = g_iWpnInput[client];
    char msg[256];
    bool ok = CS2U_WeaponSet(idx, speed, msg, sizeof(msg));
    CS2U_WeaponClearInput(client);
    if (ok)
    {
        CS2U_Reply(client, "%s", msg);
        CS2U_ActionLog("weapon-speed class=%s value=%.3f by=%d",
                       g_sWpnClass[idx], speed, client);
    }
    else
    {
        CS2U_Reply(client, "%s", msg);
    }

    /* Reopen the page so the admin sees the new number without typing !cs2u. */
    CS2U_MenuWeapon(client, 0);
    return true;
}

/* ---- console surface ----------------------------------------------------- */

void CS2U_WeaponPrintTable(int client)
{
    CS2U_WeaponRefresh();
    CS2U_Reply(client, "武器速度表（u/s，默认值见括号）：");
    for (int i = 0; i < CS2U_WEAPON_COUNT; i++)
    {
        bool changed = FloatAbs(g_fWpnCurrent[i] - g_fWpnDefault[i]) > 0.0005;
        CS2U_Reply(client, "  %2d. %-24s %-22s %6.0f%s",
                   i, g_sWpnClass[i], g_sWpnLabel[i], g_fWpnCurrent[i],
                   changed ? " *" : "");
    }
    CS2U_Reply(client, "改：sm_cs2u_weapons <序号|类名> <速度>；恢复：sm_cs2u_weapons reset");
}

public Action Cmd_Weapons(int client, int args)
{
    if (!CS2U_IsEnabled())
    {
        CS2U_Reply(client, "Management layer is disabled (cs2u_enable 0).");
        return Plugin_Handled;
    }
    if (!CS2U_AuthCheck(client, "weapons"))
        return Plugin_Handled;

    if (args < 1)
    {
        CS2U_WeaponPrintTable(client);
        return Plugin_Handled;
    }

    char token[64];
    GetCmdArg(1, token, sizeof(token));

    if (StrEqual(token, "reset", false))
    {
        char msg[192];
        CS2U_WeaponResetAll(msg, sizeof(msg));
        CS2U_Reply(client, "%s", msg);
        CS2U_ActionLog("weapon-speed reset by=%d", client);
        return Plugin_Handled;
    }

    int idx = CS2U_WeaponFind(token);
    if (idx < 0)
    {
        CS2U_Reply(client, "未知武器 '%s'；sm_cs2u_weapons 列出全部。", token);
        return Plugin_Handled;
    }
    if (args < 2)
    {
        CS2U_Reply(client, "%d %s（%s）= %.0f u/s",
                   idx, g_sWpnClass[idx], g_sWpnLabel[idx], CS2U_WeaponSpeed(idx));
        return Plugin_Handled;
    }

    char arg[32];
    GetCmdArg(2, arg, sizeof(arg));
    if (!CS2U_IsNumericString(arg))
    {
        CS2U_Reply(client, "'%s' 不是数字。", arg);
        return Plugin_Handled;
    }

    char msg[256];
    bool ok = CS2U_WeaponSet(idx, StringToFloat(arg), msg, sizeof(msg));
    CS2U_Reply(client, "%s", msg);
    if (ok)
        CS2U_ActionLog("weapon-speed class=%s value=%s by=%d", g_sWpnClass[idx], arg, client);
    return Plugin_Handled;
}
