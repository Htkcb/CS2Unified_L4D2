/**
 * cs2feel_config.sp -- MOD-1: configuration loader, per-weapon parameter table,
 * hot reload.  Included by cs2feel_core.sp (single .smx).
 *
 * WHAT THIS FILE IS
 *   The M3 skeleton's data layer.  It owns:
 *     - configs/cs2feel/weapons.cfg         CS2 per-weapon parameters (measured)
 *     - configs/cs2feel/native_baseline.cfg L4D2 native KeyValues baseline (measured)
 *   and exposes read-only getters to the other modules.  It performs NO runtime
 *   intervention on any entity in M3.
 *
 * DATA CLASSIFICATION
 *   Every numeric value in the generated config files is a measured value (see the
 *   provenance headers inside them).  The only non-measured fact is the CS2->L4D2
 *   weapon mapping, which is intentionally almost empty: L7 (mapping/conflict
 *   comparison) has not been done, so an empty l4d2_class means "unmapped" and the
 *   caller must fall back to the native baseline.  Do not guess mappings here.
 *
 * FAILURE SEMANTICS (conservative / fail closed)
 *   - A reload parses and validates into scratch storage first.  Only a fully valid
 *     file is swapped in.  Any error keeps the previous table untouched.
 *   - If no valid table was ever loaded, g_bConfigReady stays false and every getter
 *     returns "not found" -> callers fall back to native values.  The plugin does not
 *     invent parameters.
 *   - Validation rejects: wrong schema, missing keys, non-numeric values, values
 *     outside conservative bounds, duplicate section names, duplicate l4d2_class,
 *     and a meta weapon_count that disagrees with the parsed count.
 *
 * ASCII only on purpose (the SourcePawn compiler in this install is invoked from a
 * PowerShell session whose code page mangles non-ASCII source arguments).
 */

#if defined _cs2feel_config_included
 #endinput
#endif
#define _cs2feel_config_included

#define CS2F_MAX_WEAPONS      64
#define CS2F_MAX_NATIVE       64
#define CS2F_MAX_SHOTS        128   /* v8/TR-49: 64 transient + one 64-row steady cycle */
#define CS2F_CLASS_LEN        64
#define CS2F_MAPSTATE_LEN     24
#define CS2F_ERROR_LEN       192

#define CS2F_CFG_WEAPONS     "configs/cs2feel/weapons.cfg"
#define CS2F_CFG_NATIVE      "configs/cs2feel/native_baseline.cfg"
#define CS2F_CFG_PUNCH       "configs/cs2feel/punch_sequences.cfg"
#define CS2F_SCHEMA_WEAPONS  "cs2feel.weapons.v1"
#define CS2F_SCHEMA_NATIVE   "cs2feel.native.v1"
#define CS2F_SCHEMA_PUNCH    "cs2feel.punch.v1"

/* Sentinel for "key was not present"; outside every valid range below. */
#define CS2F_MISSING_NUM     -987654.0
#define CS2F_MISSING_STR     "@@CS2F_MISSING@@@"

enum CS2F_Param
{
    CS2F_Param_RecoilMagnitude = 0,
    CS2F_Param_RecoilMagnitudeVariance,
    CS2F_Param_RecoilAngle,
    CS2F_Param_RecoilAngleVariance,
    CS2F_Param_Spread,
    CS2F_Param_InaccuracyStand,
    CS2F_Param_InaccuracyFire,
    CS2F_Param_InaccuracyMove,
    CS2F_Param_Count
};

enum CS2F_NativeParam
{
    CS2F_Native_VerticalPunch = 0,
    CS2F_Native_SpreadPerShot,
    CS2F_Native_MaxSpread,
    CS2F_Native_SpreadDecay,
    CS2F_Native_MinDuck,
    CS2F_Native_MinStand,
    CS2F_Native_MinAir,
    CS2F_Native_MaxMove,
    CS2F_Native_Tier,
    CS2F_Native_Count
};

/* ---- live table ---------------------------------------------------------- */
float g_fWeaponParams[CS2F_MAX_WEAPONS][2][CS2F_Param_Count];  /* [id-1][mode][param] */
int   g_iWeaponSeeds[CS2F_MAX_WEAPONS][2];                     /* [id-1][0=recoil 1=spread] */
char  g_sWeaponSource[CS2F_MAX_WEAPONS][CS2F_CLASS_LEN];       /* CS2 weapon name */
char  g_sWeaponClass[CS2F_MAX_WEAPONS][CS2F_CLASS_LEN];        /* L4D2 class or "" */
char  g_sWeaponMapState[CS2F_MAX_WEAPONS][CS2F_MAPSTATE_LEN];  /* provisional / unmapped */
int   g_iWeaponCount = 0;
int   g_iMappedCount = 0;

float g_fNative[CS2F_MAX_NATIVE][CS2F_Native_Count];
char  g_sNativeClass[CS2F_MAX_NATIVE][CS2F_CLASS_LEN];
int   g_iNativeCount = 0;

/* MOD-3 per-shot punch sequence, keyed by weapon id (CS2 source name). */
float g_fPunchPitch[CS2F_MAX_WEAPONS][CS2F_MAX_SHOTS];
float g_fPunchYaw[CS2F_MAX_WEAPONS][CS2F_MAX_SHOTS];
float g_fPunchVelPitch[CS2F_MAX_WEAPONS][CS2F_MAX_SHOTS];
float g_fPunchVelYaw[CS2F_MAX_WEAPONS][CS2F_MAX_SHOTS];
int   g_iPunchCount[CS2F_MAX_WEAPONS];
int   g_iPunchCycle[CS2F_MAX_WEAPONS];   /* TR-49: 0 = no wrap; else period of the steady cycle */

StringMap g_hClassIndex = null;   /* l4d2 class -> 1-based weapon id */
StringMap g_hSourceIndex = null;  /* cs2 source name -> 1-based weapon id */

bool  g_bConfigReady = false;
char  g_sConfigError[CS2F_ERROR_LEN];

/* ---- scratch table used by the atomic reload ----------------------------- */
float t_fWeaponParams[CS2F_MAX_WEAPONS][2][CS2F_Param_Count];
int   t_iWeaponSeeds[CS2F_MAX_WEAPONS][2];
char  t_sWeaponSource[CS2F_MAX_WEAPONS][CS2F_CLASS_LEN];
char  t_sWeaponClass[CS2F_MAX_WEAPONS][CS2F_CLASS_LEN];
char  t_sWeaponMapState[CS2F_MAX_WEAPONS][CS2F_MAPSTATE_LEN];
int   t_iWeaponCount = 0;
int   t_iMappedCount = 0;

float t_fNative[CS2F_MAX_NATIVE][CS2F_Native_Count];
char  t_sNativeClass[CS2F_MAX_NATIVE][CS2F_CLASS_LEN];
int   t_iNativeCount = 0;

float t_fPunchPitch[CS2F_MAX_WEAPONS][CS2F_MAX_SHOTS];
float t_fPunchYaw[CS2F_MAX_WEAPONS][CS2F_MAX_SHOTS];
float t_fPunchVelPitch[CS2F_MAX_WEAPONS][CS2F_MAX_SHOTS];
float t_fPunchVelYaw[CS2F_MAX_WEAPONS][CS2F_MAX_SHOTS];
int   t_iPunchCount[CS2F_MAX_WEAPONS];
int   t_iPunchCycle[CS2F_MAX_WEAPONS];

/* ---- small helpers ------------------------------------------------------- */

void CS2F_ConfigSetError(const char[] fmt, any ...)
{
    VFormat(g_sConfigError, sizeof(g_sConfigError), fmt, 2);
}

/**
 * Strict numeric parser: optional leading '-', digits, at most one '.', nothing else.
 * Rejects empty strings, hex, exponents, whitespace inside, NaN/Inf spellings.
 */
bool CS2F_ConfigParseNumber(const char[] text, float &value)
{
    char t[CS2F_CLASS_LEN];
    strcopy(t, sizeof(t), text);
    TrimString(t);

    int len = strlen(t);
    if (len == 0)
        return false;

    int dots = 0;
    int digits = 0;
    for (int i = 0; i < len; i++)
    {
        char c = t[i];
        if (c == '-' && i == 0)
            continue;
        if (c == '.')
        {
            if (++dots > 1)
                return false;
            continue;
        }
        if (c < '0' || c > '9')
            return false;
        digits++;
    }
    if (digits == 0)
        return false;

    value = StringToFloat(t);
    return true;
}

bool CS2F_ConfigParseSeed(const char[] text, int &value)
{
    char t[CS2F_CLASS_LEN];
    strcopy(t, sizeof(t), text);
    TrimString(t);

    int len = strlen(t);
    if (len == 0)
        return false;
    for (int i = 0; i < len; i++)
    {
        if (t[i] < '0' || t[i] > '9')
            return false;
    }
    value = StringToInt(t);
    return value >= 0;
}

bool CS2F_ConfigParamInRange(CS2F_Param param, float v)
{
    switch (param)
    {
        case CS2F_Param_RecoilMagnitude:          return v >= 0.0 && v <= 200.0;
        case CS2F_Param_RecoilMagnitudeVariance:  return v >= 0.0 && v <= 200.0;
        case CS2F_Param_RecoilAngle:              return v >= 0.0 && v <= 360.0;
        case CS2F_Param_RecoilAngleVariance:      return v >= 0.0 && v <= 360.0;
        case CS2F_Param_Spread:                   return v >= 0.0 && v <= 10.0;
        case CS2F_Param_InaccuracyStand:          return v >= 0.0 && v <= 10.0;
        case CS2F_Param_InaccuracyFire:           return v >= 0.0 && v <= 10.0;
        case CS2F_Param_InaccuracyMove:           return v >= 0.0 && v <= 10.0;
    }
    return false;
}

bool CS2F_ConfigNativeInRange(CS2F_NativeParam param, float v)
{
    switch (param)
    {
        case CS2F_Native_VerticalPunch:  return v >= 0.0 && v <= 100.0;
        case CS2F_Native_SpreadPerShot:  return v >= 0.0 && v <= 100.0;
        case CS2F_Native_MaxSpread:      return v >= 0.0 && v <= 100.0;
        case CS2F_Native_SpreadDecay:    return v >= 0.0 && v <= 100.0;
        case CS2F_Native_MinDuck:        return v >= 0.0 && v <= 100.0;
        case CS2F_Native_MinStand:       return v >= 0.0 && v <= 100.0;
        case CS2F_Native_MinAir:         return v >= 0.0 && v <= 100.0;
        case CS2F_Native_MaxMove:        return v >= 0.0 && v <= 100.0;
        case CS2F_Native_Tier:           return v >= 0.0 && v <= 10.0;
    }
    return false;
}

void CS2F_ParamKey(CS2F_Param param, char[] out, int maxlen)
{
    switch (param)
    {
        case CS2F_Param_RecoilMagnitude:
        { strcopy(out, maxlen, "recoil_magnitude"); return; }
        case CS2F_Param_RecoilMagnitudeVariance:
        { strcopy(out, maxlen, "recoil_magnitude_variance"); return; }
        case CS2F_Param_RecoilAngle:
        { strcopy(out, maxlen, "recoil_angle"); return; }
        case CS2F_Param_RecoilAngleVariance:
        { strcopy(out, maxlen, "recoil_angle_variance"); return; }
        case CS2F_Param_Spread:
        { strcopy(out, maxlen, "spread"); return; }
        case CS2F_Param_InaccuracyStand:
        { strcopy(out, maxlen, "inaccuracy_stand"); return; }
        case CS2F_Param_InaccuracyFire:
        { strcopy(out, maxlen, "inaccuracy_fire"); return; }
        case CS2F_Param_InaccuracyMove:
        { strcopy(out, maxlen, "inaccuracy_move"); return; }
    }
    out[0] = '\0';
}

void CS2F_NativeKey(CS2F_NativeParam param, char[] out, int maxlen)
{
    switch (param)
    {
        case CS2F_Native_VerticalPunch:
        { strcopy(out, maxlen, "vertical_punch"); return; }
        case CS2F_Native_SpreadPerShot:
        { strcopy(out, maxlen, "spread_per_shot"); return; }
        case CS2F_Native_MaxSpread:
        { strcopy(out, maxlen, "max_spread"); return; }
        case CS2F_Native_SpreadDecay:
        { strcopy(out, maxlen, "spread_decay"); return; }
        case CS2F_Native_MinDuck:
        { strcopy(out, maxlen, "min_duck"); return; }
        case CS2F_Native_MinStand:
        { strcopy(out, maxlen, "min_stand"); return; }
        case CS2F_Native_MinAir:
        { strcopy(out, maxlen, "min_air"); return; }
        case CS2F_Native_MaxMove:
        { strcopy(out, maxlen, "max_move"); return; }
        case CS2F_Native_Tier:
        { strcopy(out, maxlen, "tier"); return; }
    }
    out[0] = '\0';
}

/* ---- loaders ------------------------------------------------------------- */

/**
 * ImportFromFile leaves the current position either at the empty root we created
 * (file root is then a child) or at the file root itself, depending on the reader
 * implementation.  Accept both shapes.
 */
bool CS2F_ConfigEnterRoot(KeyValues kv, const char[] rootName)
{
    kv.Rewind();

    char name[CS2F_CLASS_LEN];
    if (kv.GetSectionName(name, sizeof(name)) && StrEqual(name, rootName))
        return true;                       /* already inside the file root */

    if (kv.JumpToKey(rootName))
        return true;                       /* file root is a child of our node */

    return false;
}

/**
 * Reads meta.schema, meta.weapon_count and iterates "Weapons" into scratch storage.
 * Root section is expected to be "CS2Feel".  Returns true only if every entry is
 * complete and valid.
 */
bool CS2F_ConfigLoadWeapons(const char[] path)
{
    KeyValues kv = new KeyValues("");
    if (!kv.ImportFromFile(path))
    {
        CS2F_ConfigSetError("cannot read %s", path);
        delete kv;
        return false;
    }

    if (!CS2F_ConfigEnterRoot(kv, "CS2Feel") || !kv.JumpToKey("meta"))
    {
        CS2F_ConfigSetError("%s: missing CS2Feel.meta", path);
        delete kv;
        return false;
    }

    char schema[CS2F_CLASS_LEN];
    kv.GetString("schema", schema, sizeof(schema), "");
    if (!StrEqual(schema, CS2F_SCHEMA_WEAPONS))
    {
        CS2F_ConfigSetError("%s: schema '%s' != '%s'", path, schema, CS2F_SCHEMA_WEAPONS);
        delete kv;
        return false;
    }

    char countText[CS2F_CLASS_LEN];
    int declared = -1;
    kv.GetString("weapon_count", countText, sizeof(countText), "");
    if (!CS2F_ConfigParseSeed(countText, declared))
    {
        CS2F_ConfigSetError("%s: meta.weapon_count missing or invalid", path);
        delete kv;
        return false;
    }

    if (!CS2F_ConfigEnterRoot(kv, "CS2Feel") || !kv.JumpToKey("Weapons") || !kv.GotoFirstSubKey())
    {
        CS2F_ConfigSetError("%s: missing CS2Feel.Weapons entries", path);
        delete kv;
        return false;
    }

    StringMap seenNames = new StringMap();
    StringMap seenClasses = new StringMap();
    int count = 0;
    int mapped = 0;
    bool ok = true;

    do
    {
        if (!ok)
            break;

        if (count >= CS2F_MAX_WEAPONS)
        {
            CS2F_ConfigSetError("%s: more than %d weapons", path, CS2F_MAX_WEAPONS);
            ok = false;
            break;
        }

        char name[CS2F_CLASS_LEN];
        if (!kv.GetSectionName(name, sizeof(name)) || name[0] == '\0')
        {
            CS2F_ConfigSetError("%s: empty weapon section name", path);
            ok = false;
            break;
        }

        int dummy = 0;
        if (seenNames.GetValue(name, dummy))
        {
            CS2F_ConfigSetError("%s: duplicate weapon section '%s'", path, name);
            ok = false;
            break;
        }
        seenNames.SetValue(name, 1, true);

        char cls[CS2F_CLASS_LEN];
        kv.GetString("l4d2_class", cls, sizeof(cls), CS2F_MISSING_STR);
        if (StrEqual(cls, CS2F_MISSING_STR))
        {
            CS2F_ConfigSetError("%s: %s missing l4d2_class", path, name);
            ok = false;
            break;
        }
        TrimString(cls);

        char mapState[CS2F_MAPSTATE_LEN];
        kv.GetString("mapping_state", mapState, sizeof(mapState), "");
        TrimString(mapState);
        if (mapState[0] == '\0')
        {
            if (cls[0] == '\0')
                strcopy(mapState, sizeof(mapState), "unmapped");
            else
                strcopy(mapState, sizeof(mapState), "provisional");
        }

        if (cls[0] != '\0')
        {
            if (seenClasses.GetValue(cls, dummy))
            {
                CS2F_ConfigSetError("%s: duplicate l4d2_class '%s'", path, cls);
                ok = false;
                break;
            }
            seenClasses.SetValue(cls, 1, true);
            mapped++;
        }

        for (int mode = 0; mode < 2; mode++)
        {
            for (int p = 0; p < view_as<int>(CS2F_Param_Count); p++)
            {
                char key[CS2F_CLASS_LEN];
                CS2F_ParamKey(view_as<CS2F_Param>(p), key, sizeof(key));
                if (mode == 1)
                    StrCat(key, sizeof(key), "_alt");

                char text[CS2F_CLASS_LEN];
                kv.GetString(key, text, sizeof(text), CS2F_MISSING_STR);

                float v;
                if (StrEqual(text, CS2F_MISSING_STR))
                {
                    if (mode == 0)
                    {
                        CS2F_ConfigSetError("%s: %s missing %s", path, name, key);
                        ok = false;
                        break;
                    }
                    /* mode 1 defaults to mode 0 */
                    v = t_fWeaponParams[count][0][p];
                }
                else if (!CS2F_ConfigParseNumber(text, v))
                {
                    CS2F_ConfigSetError("%s: %s.%s is not a number ('%s')", path, name, key, text);
                    ok = false;
                    break;
                }

                if (!CS2F_ConfigParamInRange(view_as<CS2F_Param>(p), v))
                {
                    CS2F_ConfigSetError("%s: %s.%s out of range (%.6f)", path, name, key, v);
                    ok = false;
                    break;
                }
                t_fWeaponParams[count][mode][p] = v;
            }
            if (!ok)
                break;
        }
        if (!ok)
            break;

        char seedText[CS2F_CLASS_LEN];
        int seed;
        kv.GetString("recoil_seed", seedText, sizeof(seedText), "");
        if (!CS2F_ConfigParseSeed(seedText, seed))
        {
            CS2F_ConfigSetError("%s: %s.recoil_seed missing or invalid", path, name);
            ok = false;
            break;
        }
        t_iWeaponSeeds[count][0] = seed;

        kv.GetString("spread_seed", seedText, sizeof(seedText), "");
        if (!CS2F_ConfigParseSeed(seedText, seed))
        {
            CS2F_ConfigSetError("%s: %s.spread_seed missing or invalid", path, name);
            ok = false;
            break;
        }
        t_iWeaponSeeds[count][1] = seed;

        strcopy(t_sWeaponSource[count], CS2F_CLASS_LEN, name);
        strcopy(t_sWeaponClass[count], CS2F_CLASS_LEN, cls);
        strcopy(t_sWeaponMapState[count], CS2F_MAPSTATE_LEN, mapState);
        count++;
    }
    while (kv.GotoNextKey());

    delete seenNames;
    delete seenClasses;
    delete kv;

    if (!ok)
        return false;

    if (count != declared)
    {
        CS2F_ConfigSetError("%s: parsed %d weapons but meta declares %d", path, count, declared);
        return false;
    }
    if (count == 0)
    {
        CS2F_ConfigSetError("%s: zero weapons", path);
        return false;
    }

    t_iWeaponCount = count;
    t_iMappedCount = mapped;
    return true;
}

bool CS2F_ConfigLoadNative(const char[] path)
{
    KeyValues kv = new KeyValues("");
    if (!kv.ImportFromFile(path))
    {
        CS2F_ConfigSetError("cannot read %s", path);
        delete kv;
        return false;
    }

    if (!CS2F_ConfigEnterRoot(kv, "CS2FeelNative") || !kv.JumpToKey("meta"))
    {
        CS2F_ConfigSetError("%s: missing CS2FeelNative.meta", path);
        delete kv;
        return false;
    }

    char schema[CS2F_CLASS_LEN];
    kv.GetString("schema", schema, sizeof(schema), "");
    if (!StrEqual(schema, CS2F_SCHEMA_NATIVE))
    {
        CS2F_ConfigSetError("%s: schema '%s' != '%s'", path, schema, CS2F_SCHEMA_NATIVE);
        delete kv;
        return false;
    }

    char countText[CS2F_CLASS_LEN];
    int declared = -1;
    kv.GetString("weapon_count", countText, sizeof(countText), "");
    if (!CS2F_ConfigParseSeed(countText, declared))
    {
        CS2F_ConfigSetError("%s: meta.weapon_count missing or invalid", path);
        delete kv;
        return false;
    }

    if (!CS2F_ConfigEnterRoot(kv, "CS2FeelNative") || !kv.JumpToKey("Weapons") || !kv.GotoFirstSubKey())
    {
        CS2F_ConfigSetError("%s: missing CS2FeelNative.Weapons entries", path);
        delete kv;
        return false;
    }

    StringMap seen = new StringMap();
    int count = 0;
    bool ok = true;

    do
    {
        if (!ok)
            break;

        if (count >= CS2F_MAX_NATIVE)
        {
            CS2F_ConfigSetError("%s: more than %d native rows", path, CS2F_MAX_NATIVE);
            ok = false;
            break;
        }

        char name[CS2F_CLASS_LEN];
        if (!kv.GetSectionName(name, sizeof(name)) || name[0] == '\0')
        {
            CS2F_ConfigSetError("%s: empty native section name", path);
            ok = false;
            break;
        }

        int dummy = 0;
        if (seen.GetValue(name, dummy))
        {
            CS2F_ConfigSetError("%s: duplicate native class '%s'", path, name);
            ok = false;
            break;
        }
        seen.SetValue(name, 1, true);

        for (int p = 0; p < view_as<int>(CS2F_Native_Count); p++)
        {
            char key[CS2F_CLASS_LEN];
            CS2F_NativeKey(view_as<CS2F_NativeParam>(p), key, sizeof(key));

            char text[CS2F_CLASS_LEN];
            kv.GetString(key, text, sizeof(text), CS2F_MISSING_STR);

            float v;
            if (StrEqual(text, CS2F_MISSING_STR))
            {
                CS2F_ConfigSetError("%s: %s missing %s", path, name, key);
                ok = false;
                break;
            }
            if (!CS2F_ConfigParseNumber(text, v))
            {
                CS2F_ConfigSetError("%s: %s.%s is not a number ('%s')", path, name, key, text);
                ok = false;
                break;
            }
            if (!CS2F_ConfigNativeInRange(view_as<CS2F_NativeParam>(p), v))
            {
                CS2F_ConfigSetError("%s: %s.%s out of range (%.6f)", path, name, key, v);
                ok = false;
                break;
            }
            t_fNative[count][p] = v;
        }
        if (!ok)
            break;

        strcopy(t_sNativeClass[count], CS2F_CLASS_LEN, name);
        count++;
    }
    while (kv.GotoNextKey());

    delete seen;
    delete kv;

    if (!ok)
        return false;

    if (count != declared)
    {
        CS2F_ConfigSetError("%s: parsed %d native rows but meta declares %d", path, count, declared);
        return false;
    }
    if (count == 0)
    {
        CS2F_ConfigSetError("%s: zero native rows", path);
        return false;
    }

    t_iNativeCount = count;
    return true;
}

/* ---- MOD-3 punch sequence loader ---------------------------------------- */

int CS2F_ConfigTempWeaponId(const char[] name)
{
    for (int i = 0; i < t_iWeaponCount; i++)
    {
        if (StrEqual(t_sWeaponSource[i], name))
            return i + 1;
    }
    return 0;
}

bool CS2F_ConfigParseList(const char[] text, int expected, float out[CS2F_MAX_SHOTS],
                          float lo, float hi, int offset = 0)
{
    char parts[CS2F_MAX_SHOTS][24];
    int got = ExplodeString(text, ",", parts, CS2F_MAX_SHOTS, 24);
    if (got != expected || offset < 0 || offset + expected > CS2F_MAX_SHOTS)
        return false;

    for (int i = 0; i < got; i++)
    {
        float v;
        if (!CS2F_ConfigParseNumber(parts[i], v))
            return false;
        if (v < lo || v > hi)
            return false;
        out[offset + i] = v;
    }
    return true;
}

/**
 * Optional third config: per-shot punch sequences (MOD-3).  A missing file is not
 * an error (MOD-3 then has no sequence and leaves the native kick alone); a present
 * but invalid file rejects the whole config load, like the other two files.
 */
bool CS2F_ConfigLoadPunch(const char[] path)
{
    for (int i = 0; i < CS2F_MAX_WEAPONS; i++)
    {
        t_iPunchCount[i] = 0;
        t_iPunchCycle[i] = 0;
    }

    if (!FileExists(path))
        return true;

    KeyValues kv = new KeyValues("");
    if (!kv.ImportFromFile(path))
    {
        CS2F_ConfigSetError("cannot read %s", path);
        delete kv;
        return false;
    }

    if (!CS2F_ConfigEnterRoot(kv, "CS2FeelPunch") || !kv.JumpToKey("meta"))
    {
        CS2F_ConfigSetError("%s: missing CS2FeelPunch.meta", path);
        delete kv;
        return false;
    }

    char schema[CS2F_CLASS_LEN];
    kv.GetString("schema", schema, sizeof(schema), "");
    if (!StrEqual(schema, CS2F_SCHEMA_PUNCH))
    {
        CS2F_ConfigSetError("%s: schema '%s' != '%s'", path, schema, CS2F_SCHEMA_PUNCH);
        delete kv;
        return false;
    }

    char countText[CS2F_CLASS_LEN];
    int declared = -1;
    kv.GetString("weapon_count", countText, sizeof(countText), "");
    if (!CS2F_ConfigParseSeed(countText, declared))
    {
        CS2F_ConfigSetError("%s: meta.weapon_count missing or invalid", path);
        delete kv;
        return false;
    }

    if (!CS2F_ConfigEnterRoot(kv, "CS2FeelPunch") || !kv.JumpToKey("Weapons") || !kv.GotoFirstSubKey())
    {
        CS2F_ConfigSetError("%s: missing CS2FeelPunch.Weapons entries", path);
        delete kv;
        return false;
    }

    StringMap seen = new StringMap();
    int count = 0;
    bool ok = true;

    do
    {
        if (!ok)
            break;

        char name[CS2F_CLASS_LEN];
        if (!kv.GetSectionName(name, sizeof(name)) || name[0] == '\0')
        {
            CS2F_ConfigSetError("%s: empty punch section name", path);
            ok = false;
            break;
        }

        int dummy = 0;
        if (seen.GetValue(name, dummy))
        {
            CS2F_ConfigSetError("%s: duplicate punch section '%s'", path, name);
            ok = false;
            break;
        }
        seen.SetValue(name, 1, true);

        int id = CS2F_ConfigTempWeaponId(name);
        if (id <= 0)
        {
            CS2F_ConfigSetError("%s: punch sequence for unknown weapon '%s'", path, name);
            ok = false;
            break;
        }

        char nText[CS2F_CLASS_LEN];
        int n = 0;
        kv.GetString("count", nText, sizeof(nText), "");
        if (!CS2F_ConfigParseSeed(nText, n) || n < 1 || n > CS2F_MAX_SHOTS)
        {
            CS2F_ConfigSetError("%s: %s.count missing or outside 1..%d", path, name, CS2F_MAX_SHOTS);
            ok = false;
            break;
        }

        /* TR-49: optional two-segment table.  cycle = 0 (absent) keeps the plain
           row=(shot-1) table; otherwise cycle must equal count and the four
           cycle_* keys carry a second block of the same length.  The runtime row
           mapping then has count = 2*cycle rows: [0, cycle) transient and
           [cycle, 2*cycle) the measured steady cycle. */
        char cyText[CS2F_CLASS_LEN];
        int cyc = 0;
        kv.GetString("cycle", cyText, sizeof(cyText), "");
        if (cyText[0] != '\0')
        {
            if (!CS2F_ConfigParseSeed(cyText, cyc) || cyc <= 0 || cyc != n
                || 2 * cyc > CS2F_MAX_SHOTS)
            {
                CS2F_ConfigSetError("%s: %s.cycle must equal count (<= %d)",
                                    path, name, CS2F_MAX_SHOTS / 2);
                ok = false;
                break;
            }
        }
        t_iPunchCycle[id - 1] = cyc;

        char list[4096];   /* v8/TR-49: 128 rows x ~10 chars per list */
        kv.GetString("pitch", list, sizeof(list), CS2F_MISSING_STR);
        if (StrEqual(list, CS2F_MISSING_STR) ||
            !CS2F_ConfigParseList(list, n, t_fPunchPitch[id - 1], -90.0, 90.0))
        {
            CS2F_ConfigSetError("%s: %s.pitch list invalid (expected %d values)", path, name, n);
            ok = false;
            break;
        }

        kv.GetString("yaw", list, sizeof(list), CS2F_MISSING_STR);
        if (StrEqual(list, CS2F_MISSING_STR) ||
            !CS2F_ConfigParseList(list, n, t_fPunchYaw[id - 1], -90.0, 90.0))
        {
            CS2F_ConfigSetError("%s: %s.yaw list invalid (expected %d values)", path, name, n);
            ok = false;
            break;
        }

        kv.GetString("vel_pitch", list, sizeof(list), CS2F_MISSING_STR);
        if (StrEqual(list, CS2F_MISSING_STR) ||
            !CS2F_ConfigParseList(list, n, t_fPunchVelPitch[id - 1], -1000.0, 1000.0))
        {
            CS2F_ConfigSetError("%s: %s.vel_pitch list invalid (expected %d values)", path, name, n);
            ok = false;
            break;
        }

        kv.GetString("vel_yaw", list, sizeof(list), CS2F_MISSING_STR);
        if (StrEqual(list, CS2F_MISSING_STR) ||
            !CS2F_ConfigParseList(list, n, t_fPunchVelYaw[id - 1], -1000.0, 1000.0))
        {
            CS2F_ConfigSetError("%s: %s.vel_yaw list invalid (expected %d values)", path, name, n);
            ok = false;
            break;
        }

        t_iPunchCount[id - 1] = n;

        /* TR-49: the steady cycle lives in a second block of the same length.  It is
           a separate key set because a KeyValues text value has a length limit: a
           128-value list in one string is truncated by the parser (observed as
           "expected 128 values" at load time, 2026-10-25). */
        if (cyc > 0)
        {
            kv.GetString("cycle_pitch", list, sizeof(list), CS2F_MISSING_STR);
            if (StrEqual(list, CS2F_MISSING_STR) ||
                !CS2F_ConfigParseList(list, cyc, t_fPunchPitch[id - 1], -90.0, 90.0, n))
            {
                CS2F_ConfigSetError("%s: %s.cycle_pitch list invalid (expected %d values)",
                                    path, name, cyc);
                ok = false;
                break;
            }
            kv.GetString("cycle_yaw", list, sizeof(list), CS2F_MISSING_STR);
            if (StrEqual(list, CS2F_MISSING_STR) ||
                !CS2F_ConfigParseList(list, cyc, t_fPunchYaw[id - 1], -90.0, 90.0, n))
            {
                CS2F_ConfigSetError("%s: %s.cycle_yaw list invalid (expected %d values)",
                                    path, name, cyc);
                ok = false;
                break;
            }
            kv.GetString("cycle_vel_pitch", list, sizeof(list), CS2F_MISSING_STR);
            if (StrEqual(list, CS2F_MISSING_STR) ||
                !CS2F_ConfigParseList(list, cyc, t_fPunchVelPitch[id - 1], -1000.0, 1000.0, n))
            {
                CS2F_ConfigSetError("%s: %s.cycle_vel_pitch list invalid (expected %d values)",
                                    path, name, cyc);
                ok = false;
                break;
            }
            kv.GetString("cycle_vel_yaw", list, sizeof(list), CS2F_MISSING_STR);
            if (StrEqual(list, CS2F_MISSING_STR) ||
                !CS2F_ConfigParseList(list, cyc, t_fPunchVelYaw[id - 1], -1000.0, 1000.0, n))
            {
                CS2F_ConfigSetError("%s: %s.cycle_vel_yaw list invalid (expected %d values)",
                                    path, name, cyc);
                ok = false;
                break;
            }
            t_iPunchCount[id - 1] = n + cyc;
        }
        count++;
    }
    while (kv.GotoNextKey());

    delete seen;
    delete kv;

    if (!ok)
        return false;

    if (count != declared)
    {
        CS2F_ConfigSetError("%s: parsed %d punch sequences but meta declares %d",
                            path, count, declared);
        return false;
    }

    return true;
}

/* ---- public-ish module API ---------------------------------------------- */

void CS2F_ConfigInit()
{
    if (g_hClassIndex == null)
        g_hClassIndex = new StringMap();
    if (g_hSourceIndex == null)
        g_hSourceIndex = new StringMap();
}

void CS2F_ConfigShutdown()
{
    if (g_hClassIndex != null)
    {
        delete g_hClassIndex;
        g_hClassIndex = null;
    }
    if (g_hSourceIndex != null)
    {
        delete g_hSourceIndex;
        g_hSourceIndex = null;
    }
}

/**
 * Parse both files into scratch storage; swap only when both are valid.
 * Returns true and sets g_bConfigReady on success; otherwise the live table is
 * untouched and g_sConfigError explains the first failure.
 */
bool CS2F_ConfigLoadAll()
{
    CS2F_ConfigInit();
    g_sConfigError[0] = '\0';

    char weaponsPath[PLATFORM_MAX_PATH];
    char nativePath[PLATFORM_MAX_PATH];
    char punchPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, weaponsPath, sizeof(weaponsPath), CS2F_CFG_WEAPONS);
    BuildPath(Path_SM, nativePath, sizeof(nativePath), CS2F_CFG_NATIVE);
    BuildPath(Path_SM, punchPath, sizeof(punchPath), CS2F_CFG_PUNCH);

    t_iWeaponCount = 0;
    t_iMappedCount = 0;
    t_iNativeCount = 0;

    if (!CS2F_ConfigLoadWeapons(weaponsPath))
        return false;
    if (!CS2F_ConfigLoadNative(nativePath))
        return false;
    if (!CS2F_ConfigLoadPunch(punchPath))
        return false;

    /* ---- atomic swap ---- */
    g_hClassIndex.Clear();
    g_hSourceIndex.Clear();

    for (int i = 0; i < t_iWeaponCount; i++)
    {
        for (int mode = 0; mode < 2; mode++)
        {
            g_iWeaponSeeds[i][mode] = t_iWeaponSeeds[i][mode];
            for (int p = 0; p < view_as<int>(CS2F_Param_Count); p++)
                g_fWeaponParams[i][mode][p] = t_fWeaponParams[i][mode][p];
        }
        strcopy(g_sWeaponSource[i], CS2F_CLASS_LEN, t_sWeaponSource[i]);
        strcopy(g_sWeaponClass[i], CS2F_CLASS_LEN, t_sWeaponClass[i]);
        strcopy(g_sWeaponMapState[i], CS2F_MAPSTATE_LEN, t_sWeaponMapState[i]);

        g_hSourceIndex.SetValue(g_sWeaponSource[i], i + 1, true);
        if (g_sWeaponClass[i][0] != '\0')
            g_hClassIndex.SetValue(g_sWeaponClass[i], i + 1, true);
    }
    g_iWeaponCount = t_iWeaponCount;
    g_iMappedCount = t_iMappedCount;

    for (int i = 0; i < t_iNativeCount; i++)
    {
        for (int p = 0; p < view_as<int>(CS2F_Native_Count); p++)
            g_fNative[i][p] = t_fNative[i][p];
        strcopy(g_sNativeClass[i], CS2F_CLASS_LEN, t_sNativeClass[i]);
    }
    g_iNativeCount = t_iNativeCount;

    for (int i = 0; i < CS2F_MAX_WEAPONS; i++)
    {
        g_iPunchCount[i] = t_iPunchCount[i];
        g_iPunchCycle[i] = t_iPunchCycle[i];
        for (int row = 0; row < t_iPunchCount[i]; row++)
        {
            g_fPunchPitch[i][row] = t_fPunchPitch[i][row];
            g_fPunchYaw[i][row] = t_fPunchYaw[i][row];
            g_fPunchVelPitch[i][row] = t_fPunchVelPitch[i][row];
            g_fPunchVelYaw[i][row] = t_fPunchVelYaw[i][row];
        }
    }

    g_bConfigReady = true;
    return true;
}

bool CS2F_ConfigIsReady()
{
    return g_bConfigReady;
}

void CS2F_ConfigLastError(char[] out, int maxlen)
{
    strcopy(out, maxlen, g_sConfigError);
}

int CS2F_ConfigWeaponCount()
{
    return g_iWeaponCount;
}

int CS2F_ConfigMappedCount()
{
    return g_iMappedCount;
}

int CS2F_ConfigNativeCount()
{
    return g_iNativeCount;
}

int CS2F_ConfigWeaponIdByClass(const char[] cls)
{
    if (g_hClassIndex == null || cls[0] == '\0')
        return 0;
    int id = 0;
    if (!g_hClassIndex.GetValue(cls, id))
        return 0;
    return id;
}

stock int CS2F_ConfigWeaponIdBySource(const char[] name)
{
    if (g_hSourceIndex == null || name[0] == '\0')
        return 0;
    int id = 0;
    if (!g_hSourceIndex.GetValue(name, id))
        return 0;
    return id;
}

bool CS2F_ConfigGetParams(int id, float mode0[CS2F_Param_Count], float mode1[CS2F_Param_Count],
                          int &recoilSeed, int &spreadSeed)
{
    if (!g_bConfigReady || id < 1 || id > g_iWeaponCount)
        return false;

    for (int p = 0; p < view_as<int>(CS2F_Param_Count); p++)
    {
        mode0[p] = g_fWeaponParams[id - 1][0][p];
        mode1[p] = g_fWeaponParams[id - 1][1][p];
    }
    recoilSeed = g_iWeaponSeeds[id - 1][0];
    spreadSeed = g_iWeaponSeeds[id - 1][1];
    return true;
}

bool CS2F_ConfigGetNative(const char[] cls, float out[CS2F_Native_Count])
{
    if (!g_bConfigReady || cls[0] == '\0')
        return false;

    for (int i = 0; i < g_iNativeCount; i++)
    {
        if (StrEqual(g_sNativeClass[i], cls))
        {
            for (int p = 0; p < view_as<int>(CS2F_Native_Count); p++)
                out[p] = g_fNative[i][p];
            return true;
        }
    }
    return false;
}

stock void CS2F_ConfigGetSourceName(int id, char[] out, int maxlen)
{
    out[0] = '\0';
    if (id >= 1 && id <= g_iWeaponCount)
        strcopy(out, maxlen, g_sWeaponSource[id - 1]);
}

stock void CS2F_ConfigGetL4D2Class(int id, char[] out, int maxlen)
{
    out[0] = '\0';
    if (id >= 1 && id <= g_iWeaponCount)
        strcopy(out, maxlen, g_sWeaponClass[id - 1]);
}

stock void CS2F_ConfigGetMappingState(int id, char[] out, int maxlen)
{
    out[0] = '\0';
    if (id >= 1 && id <= g_iWeaponCount)
        strcopy(out, maxlen, g_sWeaponMapState[id - 1]);
}

/* ---- MOD-3 punch getters ------------------------------------------------- */

int CS2F_ConfigPunchCount(int id)
{
    if (!g_bConfigReady || id < 1 || id > g_iWeaponCount)
        return 0;
    return g_iPunchCount[id - 1];
}

/* TR-49: 0 = single-segment table (no wrap); otherwise the steady-cycle period. */
int CS2F_ConfigPunchCycle(int id)
{
    if (!g_bConfigReady || id < 1 || id > g_iWeaponCount)
        return 0;
    return g_iPunchCycle[id - 1];
}

/**
 * TR-49 row mapping for the two-segment table.  Rows [0, cycle) are the measured
 * transient; rows [cycle, count) are one measured steady cycle.  With wrap off the
 * row is returned unchanged (and CS2F_*ShouldApply rejects rows past the table).
 * CS2's absolute punch state converges onto a 64-shot limit cycle (TV-95), so with
 * wrap on every row >= cycle is folded back into the measured cycle.
 */
stock int CS2F_PunchRowWrap(int row, int count, int cycle, bool wrap)
{
    if (!wrap || cycle <= 0 || count <= cycle)
        return row;
    if (row < cycle)
        return row;
    return cycle + ((row - cycle) % (count - cycle));
}

bool CS2F_ConfigGetPunch(int id, int row, float &pitch, float &yaw,
                         float &velPitch, float &velYaw)
{
    if (!g_bConfigReady || id < 1 || id > g_iWeaponCount)
        return false;
    if (row < 0 || row >= g_iPunchCount[id - 1])
        return false;

    pitch = g_fPunchPitch[id - 1][row];
    yaw = g_fPunchYaw[id - 1][row];
    velPitch = g_fPunchVelPitch[id - 1][row];
    velYaw = g_fPunchVelYaw[id - 1][row];
    return true;
}

int CS2F_ConfigPunchWeaponCount()
{
    int n = 0;
    for (int i = 0; i < g_iWeaponCount; i++)
    {
        if (g_iPunchCount[i] > 0)
            n++;
    }
    return n;
}
