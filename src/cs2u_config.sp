/**
 * cs2u_config.sp -- unified KeyValues config, persistence and rollback.
 *
 * File: addons/sourcemod/configs/cs2unified/cs2unified.cfg
 *
 *   "CS2Unified"
 *   {
 *       "schema" "1"
 *       "version" "1.0.1"
 *       "active_preset" "cs2_matched"
 *       "presets"  { "<name>" { "<cvar>" "<value>" ... } ... }
 *       "settings" { "<cvar>" "<value>" ...  "menu_chat_alias" "0" "simple_mode" "0" }
 *   }
 *
 * Guarantees:
 *   - Load never touches a live ConVar. It parses/validates first and only
 *     then commits preset tables, so a broken file keeps the previous tables.
 *   - A single invalid entry in "settings" rejects the whole persisted set
 *     (fail-closed) instead of applying a half-configured server.
 *   - Save writes a .bak of the previous file first; if ExportToFile fails the
 *     .bak is restored, so a full disk cannot destroy the last good config.
 */

#if defined _cs2u_config_included
 #endinput
#endif
#define _cs2u_config_included

#define CS2U_ABSENT "\x01"

void CS2U_ConfigPath(char[] path, int maxlen)
{
    BuildPath(Path_SM, path, maxlen, "configs/cs2unified/cs2unified.cfg");
}

/* Source's KeyValues parser does not strip a UTF-8 BOM and then reports
 * "missing {" while still returning success on a partially parsed tree. Read
 * the bytes ourselves, strip the BOM, and import from the string so a config
 * saved by an editor that adds a BOM still works. */
bool CS2U_KvImport(KeyValues kv, const char[] path)
{
    File f = OpenFile(path, "rb");
    if (f == null)
        return false;
    int n = ReadFileString(f, g_sConfigText, sizeof(g_sConfigText), -1);
    delete f;
    if (n <= 0)
        return false;

    int off = 0;
    if (n >= 3 && g_sConfigText[0] == 0xEF && g_sConfigText[1] == 0xBB && g_sConfigText[2] == 0xBF)
        off = 3;
    return kv.ImportFromString(g_sConfigText[off]);
}

void CS2U_ConfigInit()
{
    char path[PLATFORM_MAX_PATH];
    CS2U_ConfigPath(path, sizeof(path));
    char bak[PLATFORM_MAX_PATH];
    Format(bak, sizeof(bak), "%s.bak", path);

    /* Crash window: ConfigWriteInternal renames the old file to .bak and then
     * exports. If the process dies in between, the main file is missing but the
     * .bak is the last good state -> restore it before doing anything else. */
    if (!FileExists(path) && FileExists(bak))
    {
        if (RenameFile(path, bak))
            CS2U_Log("CONFIG-RESTORED-FROM-BAK %s", path);
        else
            CS2U_Log("CONFIG-BAK-RESTORE-FAILED %s", bak);
    }

    if (!FileExists(path))
    {
        char dir[PLATFORM_MAX_PATH];
        BuildPath(Path_SM, dir, sizeof(dir), "configs/cs2unified");
        CreateDirectory(dir);
        char msg[256];
        if (CS2U_ConfigWriteInternal("", false, msg, sizeof(msg)))
            CS2U_Log("CONFIG-CREATED %s", path);
        else
            CS2U_Log("CONFIG-CREATE-FAILED %s", msg);
    }

    char msg[256];
    g_bUConfigLoaded = CS2U_ConfigLoad(true, msg, sizeof(msg));

    /* A rejected main file is usually a truncated export or a hand-edit error;
     * fall back to the last good .bak once, keeping the bad file for forensics. */
    if (!g_bUConfigLoaded && FileExists(bak))
    {
        char corrupt[PLATFORM_MAX_PATH];
        Format(corrupt, sizeof(corrupt), "%s.corrupt", path);
        DeleteFile(corrupt);
        if (RenameFile(corrupt, path) && RenameFile(path, bak))
        {
            CS2U_Log("CONFIG-RECOVERED-FROM-BAK %s (corrupt kept at %s)", path, corrupt);
            g_bUConfigLoaded = CS2U_ConfigLoad(true, msg, sizeof(msg));
        }
    }

    CS2U_ModesEnsureTracer();
    CS2U_ModesEnsureFull();
    CS2U_ModesEnsureMovementOnly();
    CS2U_ModesEnsureCompetitive();
    CS2U_ModesEnsureMaxspeed();
    CS2U_ModesEnsureBmode();
    CS2U_ModesEnsureWater();

    if (g_bUConfigLoaded)
        g_sUConfigError[0] = '\0';
    else
        strcopy(g_sUConfigError, sizeof(g_sUConfigError), msg);
    CS2U_Log("CONFIG-%s %s", g_bUConfigLoaded ? "OK" : "ERROR", msg);
}

void CS2U_ConfigShutdown()
{
    /* No KeyValues handle is retained between calls on purpose: the file is the
     * single source of truth and a stale handle would hide external edits. */
    g_bUConfigLoaded = false;
}

bool CS2U_ConfigReload(char[] msg, int msgLen)
{
    char detail[256];
    bool ok = CS2U_ConfigLoad(false, detail, sizeof(detail));
    if (ok)
    {
        g_bUConfigLoaded = true;
        g_sUConfigError[0] = '\0';
        CS2U_ModesEnsureTracer();
        CS2U_ModesEnsureFull();
        CS2U_ModesEnsureMovementOnly();
        CS2U_ModesEnsureCompetitive();
        CS2U_ModesEnsureMaxspeed();
        CS2U_ModesEnsureBmode();
        CS2U_ModesEnsureWater();
        /* Hot reload means "make the file take effect now", not just
         * "re-read the preset list": apply the persisted settings immediately. */
        int applied = CS2U_ApplyPersistedSettings();
        if (applied > 0)
            CS2U_ReconcileMovement();
        /* The env section travels with the same file, so a hot reload must
         * re-assert the stored tick profile too, not just the 39 settings. */
        CS2U_EnvApplyStored();
        Format(msg, msgLen, "Reloaded config: presets=%d active=%s applied=%d",
               g_iPresetCount, g_sActivePreset[0] ? g_sActivePreset : "(none)", applied);
    }
    else
    {
        /* Keep the last good tables and the "loaded" flag: a rejected file does
         * not unload the configuration that is still in effect. */
        strcopy(g_sUConfigError, sizeof(g_sUConfigError), detail);
        Format(msg, msgLen, "%s (previous tables kept)", detail);
    }
    return ok;
}

/* ---- load ---------------------------------------------------------------- */

bool CS2U_ConfigLoad(bool initial, char[] msg, int msgLen)
{
    char path[PLATFORM_MAX_PATH];
    CS2U_ConfigPath(path, sizeof(path));

    if (!FileExists(path))
    {
        Format(msg, msgLen, "config not found: %s", path);
        return false;
    }

    KeyValues probe = new KeyValues("CS2Unified");
    if (!CS2U_KvImport(probe, path))
    {
        delete probe;
        Format(msg, msgLen, "parse failed: %s", path);
        return false;
    }

    /* ImportFromString can succeed on a partially parsed/corrupt tree; require
     * at least one of the two top-level sections before trusting the file. */
    bool hasPresets = probe.JumpToKey("presets");
    if (hasPresets) probe.Rewind();
    bool hasSettings = probe.JumpToKey("settings");
    if (hasSettings) probe.Rewind();
    if (!hasPresets && !hasSettings)
    {
        delete probe;
        Format(msg, msgLen, "config rejected: no presets/settings sections (corrupt file?)");
        return false;
    }

    int validPresets = 0;
    int invalidPresets = 0;
    int totalPresets = 0;
    CS2U_ValidatePresets(probe, validPresets, invalidPresets, totalPresets);
    probe.Rewind();

    bool settingsOk = CS2U_ValidateSettings(probe);
    probe.Rewind();

    /* Fail-closed: a file whose presets are all invalid, or whose settings
     * contain one bad value, is rejected whole. Live values and the previous
     * in-memory tables are kept. */
    if (!settingsOk || (totalPresets > 0 && validPresets == 0))
    {
        delete probe;
        Format(msg, msgLen, "config rejected (presets valid=%d/%d settings=%s)",
               validPresets, totalPresets, settingsOk ? "ok" : "invalid");
        return false;
    }

    char active[CS2U_NAME_LEN];
    probe.GetString("active_preset", active, sizeof(active), "");

    char alias[8];
    char simple[8];
    alias[0] = '\0';
    simple[0] = '\0';
    if (probe.JumpToKey("settings"))
    {
        probe.GetString("menu_chat_alias", alias, sizeof(alias), "");
        probe.GetString("simple_mode", simple, sizeof(simple), "");
        probe.Rewind();
    }
    delete probe;

    /* Commit phase: re-import so the navigation state is clean and only the
     * presets that passed validation above are committed. */
    KeyValues kv = new KeyValues("CS2Unified");
    if (!CS2U_KvImport(kv, path))
    {
        delete kv;
        Format(msg, msgLen, "second parse failed: %s", path);
        return false;
    }

    if (validPresets > 0)
    {
        g_iPresetCount = 0;
        CS2U_CommitPresets(kv);
    }
    CS2U_CommitSettings(kv, settingsOk);
    /* 1.0.12: the tick adaptation ("env" section).  Soft-fail on purpose --
     * one malformed aux key must not reject the 39 settings above. */
    CS2U_EnvLoadFromConfig(kv);
    delete kv;

    strcopy(g_sActivePreset, sizeof(g_sActivePreset), active);
    if (g_cvUPreset != null)
        SetConVarString(g_cvUPreset, g_sActivePreset);

    if (alias[0] != '\0' && g_cvUMenuChatAlias != null)
        SetConVarInt(g_cvUMenuChatAlias, StringToInt(alias) != 0 ? 1 : 0);
    if (simple[0] != '\0' && g_cvUSimpleMode != null)
        SetConVarInt(g_cvUSimpleMode, StringToInt(simple) != 0 ? 1 : 0);

    Format(msg, msgLen, "%s: presets=%d/%d (invalid=%d) settings=%s active=%s",
           initial ? "initial load" : "reload",
           g_iPresetCount, totalPresets, invalidPresets,
           settingsOk ? "accepted" : "rejected", g_sActivePreset[0] ? g_sActivePreset : "(none)");
    return true;
}

void CS2U_ValidatePresets(KeyValues kv, int &validPresets, int &invalidPresets, int &totalPresets)
{
    validPresets = 0;
    invalidPresets = 0;
    totalPresets = 0;

    if (!kv.JumpToKey("presets"))
        return;
    if (!kv.GotoFirstSubKey())
    {
        kv.Rewind();
        return;
    }

    do
    {
        char name[CS2U_NAME_LEN];
        kv.GetSectionName(name, sizeof(name));

        bool ok = true;
        for (int i = 0; i < g_iParamCount && ok; i++)
        {
            char value[CS2U_VALUE_LEN];
            kv.GetString(g_sParamCvar[i], value, sizeof(value), CS2U_ABSENT);
            if (StrEqual(value, CS2U_ABSENT))
                continue;

            float parsed;
            char err[160];
            if (!CS2U_ParamValidate(i, value, parsed, err, sizeof(err)))
            {
                CS2U_Log("CONFIG-BAD-PRESET preset=%s %s", name, err);
                ok = false;
            }
        }
        if (ok) validPresets++;
        else    invalidPresets++;
        totalPresets++;
    }
    while (kv.GotoNextKey());
    kv.Rewind();
}

bool CS2U_ValidateSettings(KeyValues kv)
{
    if (!kv.JumpToKey("settings"))
        return true;   /* no persisted settings is valid (fresh install) */

    bool ok = true;
    for (int i = 0; i < g_iParamCount && ok; i++)
    {
        char value[CS2U_VALUE_LEN];
        kv.GetString(g_sParamCvar[i], value, sizeof(value), CS2U_ABSENT);
        if (StrEqual(value, CS2U_ABSENT))
            continue;

        float parsed;
        char err[160];
        if (!CS2U_ParamValidate(i, value, parsed, err, sizeof(err)))
        {
            CS2U_Log("CONFIG-BAD-SETTING %s", err);
            ok = false;
        }
    }
    kv.Rewind();
    return ok;
}

void CS2U_CommitPresets(KeyValues kv)
{
    if (!kv.JumpToKey("presets"))
        return;
    if (!kv.GotoFirstSubKey())
    {
        kv.Rewind();
        return;
    }

    do
    {
        char name[CS2U_NAME_LEN];
        kv.GetSectionName(name, sizeof(name));

        /* Re-validate so the commit matches what the probe pass accepted. */
        bool ok = true;
        int entries = 0;
        for (int i = 0; i < g_iParamCount && ok; i++)
        {
            char value[CS2U_VALUE_LEN];
            kv.GetString(g_sParamCvar[i], value, sizeof(value), CS2U_ABSENT);
            if (StrEqual(value, CS2U_ABSENT))
                continue;
            float parsed;
            char err[160];
            if (!CS2U_ParamValidate(i, value, parsed, err, sizeof(err)))
            {
                ok = false;
                break;
            }
            entries++;
        }
        if (!ok || g_iPresetCount >= CS2U_MAX_PRESETS)
            continue;
        if (entries > CS2U_MAX_ENTRIES)
            entries = CS2U_MAX_ENTRIES;

        int p = g_iPresetCount++;
        strcopy(g_sPresetName[p], CS2U_NAME_LEN, name);
        g_iPresetEntries[p] = 0;

        int stored = 0;
        for (int i = 0; i < g_iParamCount && stored < entries; i++)
        {
            char value[CS2U_VALUE_LEN];
            kv.GetString(g_sParamCvar[i], value, sizeof(value), CS2U_ABSENT);
            if (StrEqual(value, CS2U_ABSENT))
                continue;
            strcopy(g_sPresetCvar[p][stored], CS2U_CVAR_LEN, g_sParamCvar[i]);
            strcopy(g_sPresetValue[p][stored], CS2U_VALUE_LEN, value);
            stored++;
        }
        g_iPresetEntries[p] = stored;
    }
    while (kv.GotoNextKey());
    kv.Rewind();
}

void CS2U_CommitSettings(KeyValues kv, bool settingsOk)
{
    for (int i = 0; i < g_iParamCount; i++)
    {
        g_bPersistPresent[i] = false;
        g_sPersistValue[i][0] = '\0';
    }

    if (!settingsOk)
        return;
    if (!kv.JumpToKey("settings"))
        return;

    for (int i = 0; i < g_iParamCount; i++)
    {
        char value[CS2U_VALUE_LEN];
        kv.GetString(g_sParamCvar[i], value, sizeof(value), CS2U_ABSENT);
        if (StrEqual(value, CS2U_ABSENT))
            continue;
        strcopy(g_sPersistValue[i], CS2U_VALUE_LEN, value);
        g_bPersistPresent[i] = true;
    }
    kv.Rewind();
}

/* Persisted values must track every successful write; the map-change timer
 * re-applies this in-memory table, so a stale table would silently undo an
 * admin's preset on the next changelevel. */
void CS2U_CapturePersisted()
{
    for (int i = 0; i < g_iParamCount; i++)
    {
        CS2U_ParamRaw(i, g_sPersistValue[i], CS2U_VALUE_LEN);
        g_bPersistPresent[i] = true;
    }
}

/* Single-parameter edits (menu / sm_cs2u_set) must be durable immediately:
 * otherwise the next changelevel re-applies the older persisted table and the
 * edit disappears without an error. Persist the live table and report failure. */
bool CS2U_PersistLive(char[] msg, int msgLen)
{
    /* Write first, then update the in-memory table. If the write fails the old
     * table remains, so the next map reverts the change instead of silently
     * keeping a value that is not on disk. */
    bool ok = CS2U_ConfigWriteInternal(g_sActivePreset, true, msg, msgLen);
    if (ok)
        CS2U_CapturePersisted();
    return ok;
}

int CS2U_ApplyPersistedSettings()
{
    int present = 0;
    int invalid = 0;
    char err[160];
    float parsed;

    for (int i = 0; i < g_iParamCount; i++)
    {
        if (!g_bPersistPresent[i])
            continue;
        present++;
        if (!CS2U_ParamValidate(i, g_sPersistValue[i], parsed, err, sizeof(err)))
        {
            CS2U_Log("PERSIST-INVALID %s", err);
            invalid++;
        }
    }
    if (invalid > 0)
    {
        CS2U_Log("PERSIST-REJECT present=%d invalid=%d (nothing applied)", present, invalid);
        return 0;
    }

    int applied = 0;
    for (int i = 0; i < g_iParamCount; i++)
    {
        if (!g_bPersistPresent[i])
            continue;
        if (CS2U_ParamSet(i, g_sPersistValue[i], err, sizeof(err)))
            applied++;
        else
            CS2U_Log("PERSIST-SET-FAILED %s", err);
    }

    if (applied > 0 && g_sActivePreset[0] != '\0' && g_cvUPreset != null)
        SetConVarString(g_cvUPreset, g_sActivePreset);
    return applied;
}

/* ---- save ---------------------------------------------------------------- */

bool CS2U_ConfigSave(int client, const char[] presetName, char[] msg, int msgLen)
{
    char active[CS2U_NAME_LEN];
    strcopy(active, sizeof(active), g_sActivePreset);

    int mode = -1;
    bool isNew = false;
    if (presetName[0] != '\0')
    {
        mode = CS2U_ModeFind(presetName);
        if (mode < 0)
        {
            if (g_iPresetCount >= CS2U_MAX_PRESETS)
            {
                Format(msg, msgLen, "preset limit reached (%d)", CS2U_MAX_PRESETS);
                return false;
            }
            mode = g_iPresetCount++;
            strcopy(g_sPresetName[mode], CS2U_NAME_LEN, presetName);
            g_iPresetEntries[mode] = 0;
            isNew = true;
        }
        strcopy(active, sizeof(active), presetName);
    }

    /* Write first, mutate the preset table only after success (MED-04). */
    if (!CS2U_ConfigWriteInternal(active, true, msg, msgLen, mode))
    {
        if (isNew)
            g_iPresetCount--;
        char detail[256];
        CS2U_ConfigLoad(false, detail, sizeof(detail));
        return false;
    }

    if (mode >= 0)
    {
        int stored = 0;
        for (int i = 0; i < g_iParamCount && stored < CS2U_MAX_ENTRIES; i++)
        {
            strcopy(g_sPresetCvar[mode][stored], CS2U_CVAR_LEN, g_sParamCvar[i]);
            CS2U_ParamRaw(i, g_sPresetValue[mode][stored], CS2U_VALUE_LEN);
            stored++;
        }
        g_iPresetEntries[mode] = stored;
    }

    CS2U_CapturePersisted();
    strcopy(g_sActivePreset, sizeof(g_sActivePreset), active);
    if (g_cvUPreset != null)
        SetConVarString(g_cvUPreset, g_sActivePreset);
    CS2U_ActionLog("save preset=%s settings=%d by=%d",
                   active[0] ? active : "(none)", g_iParamCount, client);

    char path[PLATFORM_MAX_PATH];
    CS2U_ConfigPath(path, sizeof(path));
    if (active[0])
        Format(msg, msgLen, "Saved %d parameters to %s (preset %s)", g_iParamCount, path, active);
    else
        Format(msg, msgLen, "Saved %d parameters to %s", g_iParamCount, path);
    return true;
}

bool CS2U_ConfigWriteInternal(const char[] activePreset, bool includeSettings, char[] msg, int msgLen, int overrideMode = -1)
{
    char path[PLATFORM_MAX_PATH];
    CS2U_ConfigPath(path, sizeof(path));

    KeyValues kv = new KeyValues("CS2Unified");
    kv.SetString("schema", "1");
    kv.SetString("version", CS2U_VERSION);
    kv.SetString("active_preset", activePreset);

    if (!kv.JumpToKey("presets", true))
    {
        delete kv;
        Format(msg, msgLen, "cannot create presets section");
        return false;
    }
    for (int p = 0; p < g_iPresetCount; p++)
    {
        if (!kv.JumpToKey(g_sPresetName[p], true))
            continue;
        if (p == overrideMode)
        {
            /* Serialize the live values for this one preset without mutating the
             * in-memory table first, so a failed write cannot leave memory ahead
             * of disk (MED-04). */
            for (int i = 0; i < g_iParamCount; i++)
            {
                char raw[CS2U_VALUE_LEN];
                CS2U_ParamRaw(i, raw, sizeof(raw));
                kv.SetString(g_sParamCvar[i], raw);
            }
        }
        else
        {
            for (int e = 0; e < g_iPresetEntries[p]; e++)
                kv.SetString(g_sPresetCvar[p][e], g_sPresetValue[p][e]);
        }
        kv.GoBack();
    }
    kv.GoBack();

    if (!kv.JumpToKey("settings", true))
    {
        delete kv;
        Format(msg, msgLen, "cannot create settings section");
        return false;
    }
    if (includeSettings)
    {
        for (int i = 0; i < g_iParamCount; i++)
        {
            char raw[CS2U_VALUE_LEN];
            CS2U_ParamRaw(i, raw, sizeof(raw));
            kv.SetString(g_sParamCvar[i], raw);
        }
    }
    kv.SetString("menu_chat_alias", g_cvUMenuChatAlias != null && GetConVarBool(g_cvUMenuChatAlias) ? "1" : "0");
    kv.SetString("simple_mode", g_cvUSimpleMode != null && GetConVarBool(g_cvUSimpleMode) ? "1" : "0");
    kv.GoBack();

    /* 1.0.12 "env" section: the tick adaptation.  Written only when one is in
     * effect, so an untouched server's config keeps exactly its 1.0.11 shape. */
    if (g_bEnvPersist && kv.JumpToKey("env", true))
    {
        char num[CS2U_VALUE_LEN];
        Format(num, sizeof(num), "%d", g_iEnvPersistProfile);
        kv.SetString("spread_tick_profile", num);
        Format(num, sizeof(num), "%.2f", g_fEnvPersistHz);
        kv.SetString("adapted_hz", num);
        kv.SetString("adapted_at", g_sEnvPersistAt);
        kv.GoBack();
    }

    /* Backup-then-write. RenameFile(newpath, oldpath). */
    char bak[PLATFORM_MAX_PATH];
    Format(bak, sizeof(bak), "%s.bak", path);
    bool hadFile = FileExists(path);
    if (hadFile)
    {
        DeleteFile(bak);
        if (!RenameFile(bak, path))
            CS2U_Log("CONFIG-BACKUP-FAILED %s", path);
    }

    bool ok = kv.ExportToFile(path);
    delete kv;

    if (!ok)
    {
        if (hadFile && FileExists(bak))
        {
            DeleteFile(path);
            RenameFile(path, bak);
            CS2U_Log("CONFIG-ROLLBACK restored=%s", path);
        }
        Format(msg, msgLen, "write failed: %s", path);
        return false;
    }
    return true;
}

/* ---- snapshot / rollback ------------------------------------------------- */

void CS2U_Snapshot()
{
    for (int i = 0; i < g_iParamCount; i++)
        CS2U_ParamRaw(i, g_sSnapValue[i], CS2U_VALUE_LEN);
    strcopy(g_sSnapPreset, sizeof(g_sSnapPreset), g_sActivePreset);
    g_bSnapValid = true;
}

bool CS2U_Rollback(char[] msg, int msgLen)
{
    if (!g_bSnapValid)
    {
        Format(msg, msgLen, "no snapshot yet: apply a preset or change a parameter first");
        return false;
    }

    int restored = 0;
    char err[160];
    for (int i = 0; i < g_iParamCount; i++)
    {
        if (CS2U_ParamSet(i, g_sSnapValue[i], err, sizeof(err)))
            restored++;
        else
            CS2U_Log("ROLLBACK-SET-FAILED %s", err);
    }

    strcopy(g_sActivePreset, sizeof(g_sActivePreset), g_sSnapPreset);
    if (g_cvUPreset != null)
        SetConVarString(g_cvUPreset, g_sActivePreset);
    CS2U_ReconcileMovement();
    CS2U_ActionLog("rollback restored=%d preset=%s", restored, g_sActivePreset);

    /* A rollback that is silently undone by the next changelevel would not be a
     * rollback: persist the restored state as the new settings. */
    char persistMsg[256];
    bool persisted = CS2U_ConfigWriteInternal(g_sSnapPreset, true, persistMsg, sizeof(persistMsg));
    if (persisted)
        CS2U_CapturePersisted();
    else
        CS2U_Log("ROLLBACK-PERSIST-FAILED %s", persistMsg);

    if (!persisted)
    {
        Format(msg, msgLen, "Rolled back %d parameters in memory, but persistence failed (%s); the next map will re-apply the older settings", restored, persistMsg);
        return false;
    }

    if (g_sActivePreset[0])
        Format(msg, msgLen, "Rolled back %d parameters to the pre-preset snapshot (preset %s)",
               restored, g_sActivePreset);
    else
        Format(msg, msgLen, "Rolled back %d parameters to the pre-preset snapshot", restored);
    return true;
}
