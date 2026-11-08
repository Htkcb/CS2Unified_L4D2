/**
 * cs2u_auth.sp -- menu identity resolution (SteamID list > admin group).
 *
 * Priority (fixed, not configurable):
 *   1. client == 0 (server console)            -> source=console, tier=root
 *   2. SteamID present in menu.cfg auth.steamids -> source=steamid, tier=<entry>
 *   3. member of a configured SourceMod group    -> source=group:<name>, tier=<entry>
 *   4. neither                                  -> deny
 *
 * When both 2 and 3 match, the SteamID entry wins and AUTH-CONFLICT is logged
 * once per client per map. When menu.cfg has no auth entries at all, the
 * historic SourceMod flag path is used (source=flag) so an existing server is
 * not locked out by upgrading the plugin.
 */

#if defined _cs2u_auth_included
 #endinput
#endif
#define _cs2u_auth_included

void CS2U_AuthClear()
{
    g_iAuthSteamCount = 0;
    g_iAuthGroupCount = 0;
    g_bAuthStrict = false;
    for (int i = 0; i <= MaxClients; i++)
    {
        g_iClientTier[i] = CS2U_TIER_NONE;
        g_sClientAuthSource[i][0] = '\0';
        g_bClientAuthConflict[i] = false;
        g_bClientCfgNotified[i] = false;
        g_bAdvInit[i] = false;
        g_fClientDenyAt[i] = 0.0;
        g_iConfirmIdx[i] = -1;
        g_fConfirmAt[i] = 0.0;
    }
}

bool CS2U_AuthAddSteam(const char[] id, int tier)
{
    if (id[0] == '\0' || tier <= CS2U_TIER_NONE || g_iAuthSteamCount >= CS2U_MAX_AUTH_STEAM)
        return false;
    strcopy(g_sAuthSteam[g_iAuthSteamCount], CS2U_AUTH_ID_LEN, id);
    g_iAuthSteamTier[g_iAuthSteamCount] = tier;
    g_iAuthSteamCount++;
    g_bAuthStrict = true;
    return true;
}

bool CS2U_AuthAddGroup(const char[] name, int tier)
{
    if (name[0] == '\0' || tier <= CS2U_TIER_NONE || g_iAuthGroupCount >= CS2U_MAX_AUTH_GROUPS)
        return false;
    strcopy(g_sAuthGroup[g_iAuthGroupCount], CS2U_GROUP_NAME_LEN, name);
    g_iAuthGroupTier[g_iAuthGroupCount] = tier;
    g_iAuthGroupCount++;
    g_bAuthStrict = true;
    return true;
}

/* Resolve one client. Always fills source (never empty). Returns CS2U_TIER_*. */
int CS2U_AuthResolve(int client, char[] source, int maxlen)
{
    if (client <= 0)
    {
        strcopy(source, maxlen, "console");
        return CS2U_TIER_ROOT;
    }

    char steam[CS2U_AUTH_ID_LEN];
    steam[0] = '\0';
    bool haveSteam = GetClientAuthId(client, AuthId_Steam2, steam, sizeof(steam), true);
    if (!haveSteam)
        haveSteam = GetClientAuthId(client, AuthId_Steam3, steam, sizeof(steam), true);

    int steamTier = CS2U_TIER_NONE;
    if (haveSteam)
    {
        for (int i = 0; i < g_iAuthSteamCount; i++)
        {
            if (StrEqual(steam, g_sAuthSteam[i], false))
            {
                steamTier = g_iAuthSteamTier[i];
                break;
            }
        }
    }

    int groupTier = CS2U_TIER_NONE;
    char groupName[CS2U_GROUP_NAME_LEN];
    groupName[0] = '\0';
    AdminId aid = GetUserAdmin(client);
    if (aid != INVALID_ADMIN_ID && g_iAuthGroupCount > 0)
    {
        int groups = GetAdminGroupCount(aid);
        for (int gi = 0; gi < g_iAuthGroupCount && groupTier == CS2U_TIER_NONE; gi++)
        {
            GroupId want = FindAdmGroup(g_sAuthGroup[gi]);
            if (want == INVALID_GROUP_ID)
                continue;
            for (int i = 0; i < groups; i++)
            {
                char gname[CS2U_GROUP_NAME_LEN];
                GroupId got = GetAdminGroup(aid, i, gname, sizeof(gname));
                if (got == want)
                {
                    groupTier = g_iAuthGroupTier[gi];
                    strcopy(groupName, sizeof(groupName), g_sAuthGroup[gi]);
                    break;
                }
            }
        }
    }

    if (!g_bAuthStrict)
    {
        strcopy(source, maxlen, "flag");
        if (CheckCommandAccess(client, "sm_cs2u_root", ADMFLAG_ROOT))
            return CS2U_TIER_ROOT;
        if (CheckCommandAccess(client, "sm_cs2u", ADMFLAG_GENERIC))
            return CS2U_TIER_ADMIN;
        return CS2U_TIER_NONE;
    }

    if (steamTier > CS2U_TIER_NONE)
    {
        if (groupTier > CS2U_TIER_NONE && !g_bClientAuthConflict[client])
        {
            g_bClientAuthConflict[client] = true;
            CS2U_Log("AUTH-CONFLICT client=%d steamid=%s steamid_tier=%d group=%s group_tier=%d chosen=steamid",
                     client, steam, steamTier, groupName, groupTier);
        }
        strcopy(source, maxlen, "steamid");
        return steamTier;
    }
    if (groupTier > CS2U_TIER_NONE)
    {
        Format(source, maxlen, "group:%s", groupName);
        return groupTier;
    }

    strcopy(source, maxlen, "none");
    return CS2U_TIER_NONE;
}

/* Resolve + cache + deny (chat + rate-limited warning log). */
bool CS2U_AuthCheck(int client, const char[] where)
{
    if (client <= 0)
    {
        g_iClientTier[0] = CS2U_TIER_ROOT;
        strcopy(g_sClientAuthSource[0], sizeof(g_sClientAuthSource[]), "console");
        return true;
    }

    char source[64];
    int tier = CS2U_AuthResolve(client, source, sizeof(source));
    g_iClientTier[client] = tier;
    strcopy(g_sClientAuthSource[client], sizeof(g_sClientAuthSource[]), source);

    if (tier == CS2U_TIER_NONE)
    {
        CS2U_AuthDeny(client, where);
        return false;
    }
    return true;
}

void CS2U_AuthDeny(int client, const char[] where)
{
    if (client <= 0)
        return;

    CS2U_Reply(client, "权限不足 / Access denied — 你不在管理员名单中。");

    float now = GetGameTime();
    if (now - g_fClientDenyAt[client] < 10.0)
        return;
    g_fClientDenyAt[client] = now;

    char steam[CS2U_AUTH_ID_LEN];
    steam[0] = '\0';
    GetClientAuthId(client, AuthId_Steam2, steam, sizeof(steam), false);
    CS2U_Log("AUTH-DENIED client=%d steamid=%s name=%N where=%s", client, steam, client, where);
}

/* Item-level guard: the caller already ran CS2U_AuthCheck. */
bool CS2U_AuthRequire(int client, int tier, const char[] what)
{
    if (client == 0)
        return true;
    if (g_iClientTier[client] >= tier)
        return true;

    if (tier >= CS2U_TIER_ROOT)
        CS2U_Reply(client, "权限不足 / Access denied — %s 需要 ROOT。", what);
    else
        CS2U_Reply(client, "权限不足 / Access denied — %s 需要 ADMIN。", what);

    char steam[CS2U_AUTH_ID_LEN];
    steam[0] = '\0';
    GetClientAuthId(client, AuthId_Steam2, steam, sizeof(steam), false);
    CS2U_Log("AUTH-DENIED client=%d steamid=%s source=%s tier=%d need=%d what=%s",
             client, steam, g_sClientAuthSource[client], g_iClientTier[client], tier, what);
    return false;
}

void CS2U_AuthLogOpen(int client)
{
    if (client <= 0)
        return;
    char steam[CS2U_AUTH_ID_LEN];
    steam[0] = '\0';
    GetClientAuthId(client, AuthId_Steam2, steam, sizeof(steam), false);
    CS2U_Log("AUTH-OK client=%d steamid=%s source=%s tier=%d",
             client, steam, g_sClientAuthSource[client], g_iClientTier[client]);
}
