/**
 * cs2u_shared.sp -- declarations shared by the unified modules.
 *
 * SourcePawn resolves functions in two passes but NOT global variables, so
 * every unified global lives here and is included before any module that reads
 * it. Keeping them in one place also makes the static data footprint auditable.
 */

#if defined _cs2u_shared_included
 #endinput
#endif
#define _cs2u_shared_included

#define CS2U_MAX_PARAMS      40
#define CS2U_MAX_CANDIDATES   8
#define CS2U_MAX_PRESETS     12   /* 7 built-in + 2 DIY slots + headroom       */
#define CS2U_MAX_ENTRIES     40
#define CS2U_NAME_LEN        32
#define CS2U_CVAR_LEN        64
#define CS2U_VALUE_LEN       32

enum
{
    PARAM_TYPE_BOOL = 0,
    PARAM_TYPE_INT = 1,
    PARAM_TYPE_FLOAT = 2
};

enum
{
    PARAM_GROUP_FEEL = 0,
    PARAM_GROUP_MOVE = 1,
    PARAM_GROUP_VISUAL = 2,
    PARAM_GROUP_INJURY = 3,
    /* 1.0.10: water depth is its own group so the movement page gets a
     * "水面减速" header instead of filing it under "速度与模型".  It still
     * renders inside CS2U_CTX_MOVE; groups only decide ordering and headers. */
    PARAM_GROUP_WATER = 4
};

enum
{
    PARAM_ACCESS_ADMIN = 0,   /* ADMFLAG_GENERIC */
    PARAM_ACCESS_ROOT  = 1    /* ADMFLAG_ROOT */
};

/* ---- unified ConVars ----------------------------------------------------- */
ConVar g_cvUVersion = null;
ConVar g_cvUEnable = null;
ConVar g_cvUDebug = null;
ConVar g_cvUMenuChatAlias = null;
ConVar g_cvULogActions = null;
ConVar g_cvUPreset = null;
ConVar g_cvUSimpleMode = null;      /* 1 = easy menu for non-technical admins */
ConVar g_cvUBmode;

/* ---- server-side tracer (visual aid) ------------------------------------ */
ConVar g_cvUTracerEnable = null;
ConVar g_cvUTracerWidth = null;
ConVar g_cvUTracerLife = null;
ConVar g_cvUTracerAlpha = null;
int    g_iTracerSprite = 0;
float  g_fTracerLast[MAXPLAYERS + 1];

bool   g_bUConfigLoaded = false;
char   g_sUConfigError[192];

/* ---- managed parameter table (cs2u_params.sp) ---------------------------- */
char  g_sParamCvar[CS2U_MAX_PARAMS][CS2U_CVAR_LEN];
char  g_sParamLabel[CS2U_MAX_PARAMS][96];
int   g_iParamType[CS2U_MAX_PARAMS];
int   g_iParamAccess[CS2U_MAX_PARAMS];
int   g_iParamGroup[CS2U_MAX_PARAMS];   /* 0 = feel, 1 = movement */
float g_fParamMin[CS2U_MAX_PARAMS];
float g_fParamMax[CS2U_MAX_PARAMS];
char  g_sParamCand[CS2U_MAX_PARAMS][CS2U_MAX_CANDIDATES][24];
int   g_iParamCandCount[CS2U_MAX_PARAMS];
int   g_iParamCount = 0;

/* ---- presets (cs2u_modes.sp / cs2u_config.sp) --------------------------- */
char g_sPresetName[CS2U_MAX_PRESETS][CS2U_NAME_LEN];
char g_sPresetCvar[CS2U_MAX_PRESETS][CS2U_MAX_ENTRIES][CS2U_CVAR_LEN];
char g_sPresetValue[CS2U_MAX_PRESETS][CS2U_MAX_ENTRIES][CS2U_VALUE_LEN];
int  g_iPresetEntries[CS2U_MAX_PRESETS];
int  g_iPresetCount = 0;
char g_sActivePreset[CS2U_NAME_LEN];

/* ---- persisted settings + last-stable snapshot -------------------------- */
char g_sPersistValue[CS2U_MAX_PARAMS][CS2U_VALUE_LEN];
bool g_bPersistPresent[CS2U_MAX_PARAMS];

char g_sSnapValue[CS2U_MAX_PARAMS][CS2U_VALUE_LEN];
char g_sSnapPreset[CS2U_NAME_LEN];
bool g_bSnapValid = false;

/* Config text buffer for BOM-tolerant KeyValues import (see cs2u_config.sp).
 * 48 KiB covers 12 presets x 26 entries plus the settings section; a larger
 * file is truncated by ReadFileString and then rejected by the section check. */
char g_sConfigText[49152];

/* ---- menu layout / auth (cs2u_layout.sp, cs2u_auth.sp) ------------------- */

#define CS2U_CTX_COUNT          7
#define CS2U_MAX_ORDER         40
#define CS2U_ITEM_KEY_LEN      48
#define CS2U_MAX_AUTH_STEAM    64
#define CS2U_MAX_AUTH_GROUPS   16
#define CS2U_AUTH_ID_LEN       40
#define CS2U_GROUP_NAME_LEN    64

enum
{
    CS2U_CTX_ROOT = 0,
    CS2U_CTX_PRESETS,
    CS2U_CTX_FEEL,
    CS2U_CTX_MOVE,
    CS2U_CTX_VISUAL,
    CS2U_CTX_STATUS,
    CS2U_CTX_CONFIG
};

enum
{
    CS2U_TIER_NONE = 0,
    CS2U_TIER_ADMIN,
    CS2U_TIER_ROOT
};

/* One ordered key list per context. Keys are "cvar:<name>", "preset:<name>"
 * or "act:<id>"; the menu resolves them at render time so the config never
 * carries raw info ids. */
char g_sOrder[CS2U_CTX_COUNT][CS2U_MAX_ORDER][CS2U_ITEM_KEY_LEN];
int  g_iOrderCount[CS2U_CTX_COUNT];
bool g_bBasicVisible[CS2U_CTX_COUNT];
bool g_bMenuCfgLoaded = false;
bool g_bMenuAdvancedDefault = false;
bool g_bMenuTelemetry = true;
bool g_bMenuConfirmDestructive = false;
bool g_bPermConfig = true;
bool g_bPermDiy = true;
bool g_bPermDiag = true;
char g_sMenuCfgError[192];

/* auth: strict mode is on as soon as one valid entry exists. An absent or
 * empty auth section keeps the historic SourceMod flag path (source=flag). */
char g_sAuthSteam[CS2U_MAX_AUTH_STEAM][CS2U_AUTH_ID_LEN];
int  g_iAuthSteamTier[CS2U_MAX_AUTH_STEAM];
int  g_iAuthSteamCount = 0;
char g_sAuthGroup[CS2U_MAX_AUTH_GROUPS][CS2U_GROUP_NAME_LEN];
int  g_iAuthGroupTier[CS2U_MAX_AUTH_GROUPS];
int  g_iAuthGroupCount = 0;
bool g_bAuthStrict = false;

int   g_iClientTier[MAXPLAYERS + 1];
char  g_sClientAuthSource[MAXPLAYERS + 1][64];
bool  g_bClientAdv[MAXPLAYERS + 1];
bool  g_bAdvInit[MAXPLAYERS + 1];
bool  g_bClientAuthConflict[MAXPLAYERS + 1];
bool  g_bClientCfgNotified[MAXPLAYERS + 1];
float g_fClientDenyAt[MAXPLAYERS + 1];
int   g_iConfirmIdx[MAXPLAYERS + 1];
float g_fConfirmAt[MAXPLAYERS + 1];

/* ---- per-team scope (1.0.13) --------------------------------------------
 *
 * L4D2 team ids are fixed: 1 spectator, 2 survivor, 3 infected.  The movement
 * layers use CS2M_TEAM_SURVIVOR; the unified layer needs the infected id to say
 * "this is not a survivor, do not touch it" without inverting the predicate.
 * verify.ps1 asserts both constants and that the feel gate exists. */
#define CS2U_TEAM_INFECTED 3

ConVar g_cvUFeelSurvivorOnly = null;
int    g_iFeelSkipNotSurvivor = 0;

/* ---- environment adaptation (cs2u_env.sp) --------------------------------
 *
 * What is probed, and where it comes from:
 *   hz / interval     GetTickInterval()   -- the only trustworthy tick source
 *   dedicated         IsDedicatedServer()
 *   maxplayers        GetMaxClients()
 *   profile cvar      cs2feel_spread_tick_profile (not a managed parameter:
 *                     see the capacity note in docs/09; it gets its own path)
 *   profile resolved  re-derived from the live hz with the same rule as
 *                     CS2F_SpreadProfileResolve(), plus the module's own
 *                     carried value for comparison
 *
 * The plan is at most three managed items (capacity is 40, we are at 39, and
 * none of the plan items is new) plus one independent-channel profile change. */
#define CS2U_ENV_MAX_PLAN    8
#define CS2U_ENV_NOTE_LEN    128
#define CS2U_ENV_BAND_LEN    40
#define CS2U_ENV_AT_LEN      24
#define CS2U_ENV_PREVIEW_TTL 120.0

float g_fEnvInterval = 0.0;
float g_fEnvHz = 0.0;
bool  g_bEnvDedicated = false;
int   g_iEnvMaxPlayers = 0;
int   g_iEnvPlayers = 0;
int   g_iEnvBand = 0;              /* 0 = uncalibrated, else 30 / 60 / 64      */
int   g_iEnvProfileCvar = 0;       /* cs2feel_spread_tick_profile as set       */
int   g_iEnvProfileResolved = 0;   /* what the rule resolves it to right now   */
int   g_iEnvProfileCarried = 0;    /* what the feel module currently carries   */
char  g_sEnvBandName[CS2U_ENV_BAND_LEN];

char  g_sEnvPlanCvar[CS2U_ENV_MAX_PLAN][CS2U_CVAR_LEN];
char  g_sEnvPlanValue[CS2U_ENV_MAX_PLAN][CS2U_VALUE_LEN];
char  g_sEnvPlanOld[CS2U_ENV_MAX_PLAN][CS2U_VALUE_LEN];
char  g_sEnvPlanWhy[CS2U_ENV_MAX_PLAN][CS2U_ENV_NOTE_LEN];
int   g_iEnvPlanItems = 0;
bool  g_bEnvPlanProfile = false;
int   g_iEnvPlanProfileOld = 0;
int   g_iEnvPlanProfileNew = 0;

/* Preview gate: "apply" is refused unless the same invoker previewed first
 * (120 s).  Index 0 is the server console, which is what RCON uses. */
bool  g_bEnvPreviewOk[MAXPLAYERS + 1];
float g_fEnvPreviewAt[MAXPLAYERS + 1];
int   g_iEnvPreviewItems[MAXPLAYERS + 1];

/* Undo snapshot: exactly the values the last apply overwrote, plus the env
 * section as it was, so undo restores both memory and disk. */
char  g_sEnvUndoCvar[CS2U_ENV_MAX_PLAN][CS2U_CVAR_LEN];
char  g_sEnvUndoValue[CS2U_ENV_MAX_PLAN][CS2U_VALUE_LEN];
int   g_iEnvUndoItems = 0;
bool  g_bEnvUndoProfile = false;
int   g_iEnvUndoProfileValue = 0;
bool  g_bEnvUndoValid = false;
bool  g_bEnvUndoPersist = false;
int   g_iEnvUndoPersistProfile = 0;
float g_fEnvUndoPersistHz = 0.0;
char  g_sEnvUndoPersistAt[CS2U_ENV_AT_LEN];

/* Persisted "env" section of configs/cs2unified/cs2unified.cfg. */
bool  g_bEnvPersist = false;
int   g_iEnvPersistProfile = 0;
float g_fEnvPersistHz = 0.0;
char  g_sEnvPersistAt[CS2U_ENV_AT_LEN];
bool  g_bEnvDriftNotified = false;

/* 1.0.14: the env page's actions print to chat, and the page itself re-renders
 * identically -- so on a listen server every click looked dead.  The menu title
 * now carries a "上次：..." line from this buffer: feedback inside the panel,
 * not only in the chat box.  Index 0 = server console (RCON path). */
char  g_sEnvLastMsg[MAXPLAYERS + 1][96];
