# 03 · 配置 schema 与持久化语义

> 权威来源：`src\cs2u_config.sp`（读写/校验/回滚）、`src\cs2u_shared.sp`（容量常量）、`src\cs2u_params.sp`（39 个参数与值域）、`src\cs2u_layout.sp`（menu.cfg）、`configs\cs2unified\cs2unified.cfg`（随附默认文件）。
> 所有“字段是否被读取/校验”的结论都按代码实际行为书写；不要按“看起来应该”推断。

---

## 1. 位置与生命周期

| 项 | 值 |
|---|---|
| 运行期路径 | `addons\sourcemod\configs\cs2unified\cs2unified.cfg`（`BuildPath(Path_SM, ...)`） |
| 仓库内副本 | `configs\cs2unified\cs2unified.cfg`（deploy 时**仅在目标不存在时**复制，`-onlyIfMissing`） |
| 不存在时 | 首次 `OnPluginStart` 创建目录并写一份**不含 settings 值**的骨架（日志 `CONFIG-CREATED`），随后正常加载 |
| 读取时机 | `OnPluginStart`（初次）→ `OnConfigsExecuted` + 0.5 s 定时器应用 settings；`sm_cs2u_reload`（热重载）；保存/回滚后由插件自己重写 |
| 写入时机 | 应用预设、`sm_cs2u_save`、`sm_cs2u_rollback`、首次创建骨架 |
| 句柄策略 | **不保留** KeyValues 句柄（`CS2U_ConfigShutdown` 只清标志）；文件是唯一真相，避免外部编辑被旧句柄掩盖 |

---

## 2. 完整 schema

```text
"CS2Unified"
{
    "schema"        "1"                 // 恒为 "1"；加载时不读、不校验（见 §3）
    "version"       "1.0.1"             // 写盘时 = CS2U_VERSION；加载时不读
    "active_preset" "cs2_matched"       // 仅记录“上次成功应用的预设”，不触发应用
    "presets"
    {
        "<预设名>"
        {
            "<受管 cvar>"  "<值>"        // 每个预设 ≤ 40 条
            ...
        }
        ...                              // 全文件 ≤ 8 个预设
    }
    "settings"
    {
        "<受管 cvar>"     "<值>"         // 39 个受管参数的当前值（原样字符串）
        ...
        "menu_chat_alias" "0"            // 0/非 0；加载时覆盖 cs2u_menu_chat_alias（0 = 只保留 !cs2u）
    }
    "env"                                // 1.0.12，可选：只在“已适配”时存在
    {
        "spread_tick_profile" "4"        // 0..4；写 cs2feel_spread_tick_profile（不受管）
        "adapted_hz"          "64.00"    // 适配当时的实测 Hz，用于漂移提示
        "adapted_at"          "2026-11-07 23:24"
    }
}
```

KeyValues 的键名**不区分大小写**；随附默认文件写的是 `"Version"`，与插件写出的 `"version"` 等价。

### 2.1 字段语义

| 字段 | 类型 | 谁写 | 加载时行为 |
|---|---|---|---|
| `schema` | 字符串 | 插件（固定 `"1"`） | **不读取、不校验**；不是版本门禁 |
| `version` | 字符串 | 插件（`CS2U_VERSION`） | **不读取**；仅供人看 |
| `active_preset` | 字符串 ≤32 | 插件 / 人 | 读到即写入 `g_sActivePreset` 与 ConVar `cs2u_preset`；**不校验是否存在**、**不应用该预设的参数** |
| `presets.<name>` | 子节 | 插件 / 人 | 逐条只读取**受管 cvar**；未受管键被忽略 |
| `presets.<name>.<cvar>` | 字符串 | 插件 / 人 | 按该参数的类型/范围校验 |
| `settings.<cvar>` | 字符串 | 插件 / 人 | 按该参数的类型/范围校验；命中任一非法 → **整份 settings 拒绝 → 整份文件拒绝** |
| `settings.menu_chat_alias` | 字符串 | 插件 / 人 | `StringToInt(v) != 0` → 把 ConVar 置 1，否则置 0 |
| `settings.simple_mode` | 字符串 | 插件 / 人 | `StringToInt(v) != 0` → `cs2u_simple_mode` 置 1，否则置 0（默认 0） |
| `env.spread_tick_profile` | 字符串（0..4） | 插件（环境适配）/ 人 | 合法 → 记为“已适配”，换图 / 热重载时回填到 ConVar；非法 → **只记 `ENV-BAD-PROFILE` 并忽略整个 env 段，不拒绝整份文件** |
| `env.adapted_hz` | 字符串（浮点） | 插件 | 仅用于 `ENV-CHANGED` 漂移提示；与应用时的实测 Hz 差 >2 才提示 |
| `env.adapted_at` | 字符串 | 插件 | 仅显示 |

### 2.2 随附默认文件的差异（重要）

`configs\cs2unified\cs2unified.cfg` 是**手工维护的精简版**：

- 有 **7** 套预设（含 `cs2_tracer` 与 `cs2_full`）；
- `settings` 里**只有** `menu_chat_alias` 与 `simple_mode`；
- **没有** `active_preset` 键。

因此首启（部署了该文件）的预期日志是 `CONFIG-OK initial load: presets=7 (invalid=0) settings=accepted active=(none)`（早期 5 预设版本的实测日志为 presets=5）。执行过一次 `sm_cs2u_save` / 应用预设后，文件会被插件重写为含 `active_preset` + 26 个 settings 的完整形态。

---

## 3. 校验规则（逐条）

### 3.1 文件级

| 步骤 | 规则 | 失败结果 |
|---|---|---|
| 打开 | `OpenFile(path, "rb")` 成功 | 拒绝（`config not found` / `parse failed`） |
| 读入 | `ReadFileString` 到 32,768 B 缓冲 | 读不到 → 拒绝 |
| BOM | 前 3 字节 `EF BB BF` → 跳过 | 不跳过则解析失败（Source 的 KV 不剥 BOM） |
| 解析 | `kv.ImportFromString(text)` | 失败 → `parse failed` |
| 结构 | `presets` 与 `settings` **至少存在一个** | 都不存在 → `config rejected: no presets/settings sections (corrupt file?)` |
| 预设汇总 | 统计 `valid/invalid/total` | `total > 0 && valid == 0` → 整份拒绝 |
| settings | 逐条校验 | 任一非法 → `settingsOk=false` → 整份拒绝（消息带 `presets valid=x/y settings=invalid`） |

“整份拒绝”的含义：**内存里的预设表、settings 表、`g_sActivePreset`、所有实时 ConVar 都不变**；`sm_cs2u_reload` 额外返回 `(previous tables kept)`。

### 3.2 值级（`CS2U_ParamValidate`）

1. **数字语法**：可选前导 `-`；最多一个小数点；至少一个数字；长度 ≤31。`abc`、`1.2.3`、`` 全部拒绝。
2. **范围**：`min ≤ value ≤ max`（每个参数的区间见 §6）。
3. **bool**：只接受 `0` 或 `1`（`0.5` 也拒绝）。
4. **int**：四舍五入后与原值差 ≤ `0.0001`（`1.4` 拒绝、`1.0` 接受）。
5. 通过后才允许写 ConVar（`CS2U_ParamSet` 内部会再校验一次，双保险）。

### 3.3 未知键

- `presets.<name>` 下**不属于 36 个受管参数**的键：直接忽略，**不报错**（向前兼容）。
- `settings` 下的未知键：同样忽略；但 `menu_chat_alias` 是特例（被显式读取）。
- 根级未知键（例如未来新增的 `meta`）：忽略。

### 3.4 预设表的“替换”语义（容易踩坑）

- 配置文件**没有** `presets` 节，或所有预设都非法 → 内存里的预设表保持不动（即 `cs2u_modes.sp` 的 7 套内置预设）。
- 配置文件的 `presets` 节**至少有一条有效** → `g_iPresetCount = 0` 后从文件重建，**内置 5 套会被文件内容整体替换**。
- 也就是说：手写一份只含 1 个预设的配置并 `sm_cs2u_reload`，内置 7 套会消失（直到你删掉 `presets` 节并重载）。保存时插件会把自己当前的 `g_iPresetCount` 条全部写回，因此“先 reload 掉内置预设、再 save”会把这个状态固化（多存几次自定义预设可覆盖，上限 8）。

---

## 4. 示例

### 4.1 最小可加载配置

```text
"CS2Unified"
{
    "schema"  "1"
    "version" "1.0.1"
    "settings"
    {
        "menu_chat_alias" "0"
    }
}
```

（无 `presets` → 内置 5 套保留；无参数 settings → 换图时不应用任何持久值。）

### 4.2 带一条预设与两个持久参数

```text
"CS2Unified"
{
    "schema"        "1"
    "version"       "1.0.1"
    "active_preset" "my_hs"
    "presets"
    {
        "my_hs"
        {
            "cs2feel_enable"          "1"
            "cs2feel_recoil_mode"     "1"
            "cs2feel_recoil_scale"    "1.10"
            "cs2movement_enable"      "1"
            "cs2movement_maxspeed"    "1000"
        }
    }
    "settings"
    {
        "cs2feel_recoil_scale" "1.10"
        "cs2movement_maxspeed" "1000"
        "menu_chat_alias"      "0"
    }
}
```

注意：`active_preset` 只影响显示与状态输出，**不会**在加载时把 `my_hs` 应用到 ConVar；真正生效的是 `settings`。

### 4.3 七套内置预设的完整内容（权威副本：`src\cs2u_modes.sp`）

`—` = 该预设**不含**此键（保持当前值，不会被重置）。`cs2_tracer` = `cs2_matched` 的克隆 + `cs2u_tracer_enable 1`；`cs2_full` 由 `CS2U_ModesBuildFull` **显式写满 36 个受管值**（不走克隆）。movement 侧的 `maxspeed` 统一写 **1000**（per-player 上限，0.4.8 起语义）。

| 受管参数 | vanilla | cs2_matched | cs2_split | movement_only | cs2_competitive | cs2_tracer | cs2_full |
|---|---|---|---|---|---|---|---|
| `cs2feel_enable` | 0 | 1 | 1 | 0 | **0** | 1 | 1 |
| `cs2feel_recoil_mode` | 0 | 1 | 1 | — | **0** | 1 | 1 |
| `cs2feel_recoil_scale` | 1.0 | 1.0 | 1.10 | — | **0.0** | 1.0 | 1.0 |
| `cs2feel_recoil_view_scale` | 1.0 | 1.0 | 1.0 | — | 1.0 | 1.0 | 1.0 |
| `cs2feel_ballistics_mode` | 0 | 0 | 1 | — | 0 | 0 | 0 |
| `cs2feel_ballistics_scale` | 0.0 | 0.0 | -0.10 | — | 0.0 | 0.0 | 0.0 |
| `cs2feel_ballistics_yaw` | 0 | 0 | 1 | — | 0 | 0 | 0 |
| `cs2feel_spread_mode` | 0 | 0 | 0 | — | 0 | 0 | 0 |
| `cs2feel_spread_scale` | — | — | — | — | 1.0 | — | 1.0 |
| `cs2feel_spread_move` | — | — | — | — | 0 | — | 0 |
| `cs2feel_spread_posture` | — | — | — | — | 0 | — | 0 |
| `cs2movement_enable` | 0 | 1 | 1 | 1 | 1 | 1 | 1 |
| `cs2movement_apply_global` | 0 | 1 | 1 | 1 | 1 | 1 | 1 |
| `cs2movement_engine_speed` | 0 | 1 | 1 | 1 | 1 | 1 | 1 |
| `cs2movement_duck_speed` | 0 | 1 | 1 | 1 | 1 | 1 | 1 |
| `cs2movement_air_jump_speed` | 0 | 0 | 0 | 0 | 1 | 0 | 1 |
| `cs2movement_lowspeed_sustain` | 0 | 0 | 0 | 0 | 1 | 0 | 1 |
| `cs2movement_crouch_slide` | 0 | 0 | 0 | 0 | 1 | 0 | 1 |
| `cs2movement_crouch_slide_client` | — | — | — | — | **1** | — | **1** |
| `cs2movement_crouch_slide_time` | — | — | — | — | **0.20** | — | **0.20** |
| `cs2movement_crouch_slide_min_speed` | — | — | — | — | **100** | — | **100** |
| `cs2movement_crouch_enable` | — | 1 | 1 | 1 | 1 | 1 | 1 |
| `cs2movement_maxspeed` | — | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 |
| `cs2movement_weapon_speed_mode` | — | 1 | 1 | 1 | 1 | 1 | 1 |
| `cs2movement_duck_speed_min` | — | — | — | — | 0 | — | 0 |
| `cs2movement_base_speed` | — | — | — | — | 250 | — | 250 |
| `cs2movement_injury_enable` | — | — | — | 1 | 1 | — | 1 |
| `cs2movement_injury_mode` | — | — | — | 1 | 1 | — | 1 |
| `cs2movement_injury_health` | — | — | — | 0.0 | 0.0 | — | 0.0 |
| `cs2movement_injury_speed` | — | — | — | 132.0 | 132.0 | — | 132.0 |
| `cs2movement_injury_base` | — | — | — | 220.0 | 220.0 | — | 220.0 |
| `cs2movement_injury_temp_health` | — | — | — | 1 | 1 | — | 1 |
| `cs2movement_injury_adrenaline` | — | — | — | 1 | 1 | — | 1 |
| `cs2u_tracer_enable` | 0 | 0 | 0 | 0 | 0 | **1** | 0 |
| `cs2u_tracer_width` | — | — | — | — | — | — | 1.0 |
| `cs2u_tracer_life` | — | — | — | — | — | — | 0.2 |
| **条目数** | **16** | **19** | **19** | **25** | **36** | **19** | **36** |

`vanilla` 显式写入 feel 的 scale 中性值（`recoil_scale 1.0`、`recoil_view_scale 1.0`、`ballistics_scale 0.0`、`ballistics_yaw 0`，同时 `cs2feel_enable 0`），因此从 `cs2_split` 之类的预设切回 `vanilla` 时，上一套的缩放会一并被重置。

`movement_only` / `cs2_competitive` / `cs2_full` 都显式写 7 个 injury 值；三个非 tracer 预设都会把 `cs2u_tracer_enable` 写成 0，所以从 `cs2_tracer` 切回不会残留 beam。

**`cs2_full` / `cs2_competitive` / `cs2_matched` / `cs2_tracer` 的区别**：

| 预设 | 手感 | 移动 opt-in | injury | 曳光 | 条目 |
|---|---|---|---|---|---|
| `cs2_matched` | matched（所见即所中） | 关 | 不含（保持当前值） | 关 | 19 |
| `cs2_tracer` | matched | 关 | 不含 | **开** | 19 |
| `cs2_competitive` | **关闭（recoil 0 / ballistics 0）** | **全开** | **7 项全写** | 关 | **36** |
| `cs2_full` | **TR-40（bmode 1）** | **全开** | **7 项全写** | 关 | **36** |

`cs2_full` 的意义是“**确定性**”：它把全部受管值逐项写死（包括 `spread_scale 1.0`、`spread_move/posture 0`、`base_speed 250`、`duck_speed_min 0`、`crouch_slide_time 0.35`（1.0.16 起的手感档）、`crouch_slide_min_speed 100`、`crouch_slide_client 1`、injury 7 项、tracer 3 项），所以即使服务器 cfg 之前改过某些项，应用后也会回到同一组值。它**不**覆盖未纳入统一层的 engine cvar（见 `docs\06` L20）。该预设基于 movement **0.5.2**。

---

## 5. 保存 / 重载 / 回滚 / 坏文件 / BOM

### 5.1 保存（`CS2U_ConfigSave` → `CS2U_ConfigWriteInternal`）

```text
1. 若带 presetName：找到或新建预设（上限 12）；带 overrideMode 让写盘时用“当前 live 值”序列化该预设
2. 组装 KeyValues：schema / version / active_preset / presets(全部) / settings(36 值 + menu_chat_alias + simple_mode)
3. 备份：删除旧 .bak → RenameFile("<path>.bak", path)   // 把现有文件改名成 .bak
4. ExportToFile(path)
5. 写成功后**才**提交内存：新预设条目、CS2U_CapturePersisted()（内存持久表 = 当前值）、active_preset、ACTION 日志
   写失败：DeleteFile(path) → RenameFile(path, bak) 恢复旧文件 → 返回失败；若是新建预设则 count 回退，并 ConfigLoad 回读
```

要点：

- **先写盘、后改内存**（修复 M-04）：`CS2U_ConfigWriteInternal` 的 `overrideMode` 用当前 live 值序列化目标预设，因此写失败不会出现“内存里已有新预设、磁盘没有”的不一致。
- **注释与手工排版会丢失**：`ExportToFile` 重写整份文件，不会保留 `//` 注释。
- `.bak` 每次保存都被覆盖（只保留最近一份）。
- 不是原子写：`rename → export` 之间若崩溃，会留下 `.bak` 而没有主文件；**下次启动会先从 `.bak` 恢复**（`CONFIG-RESTORED-FROM-BAK`）；主文件存在但被拒且 `.bak` 可用时，会把坏文件改名 `.corrupt` 再恢复一次（`CONFIG-RECOVERED-FROM-BAK`）。
- 保存的是 `GetConVarString` 的**原样值**（`CS2U_ParamRaw`），不是菜单显示的 `%.3f` 舍入值。

### 5.2 重载（`sm_cs2u_reload`）

```text
解析 + 校验（§3）→ 提交（预设表、settings、active_preset、menu_chat_alias）
→ 立即 CS2U_ApplyPersistedSettings()（applied=N）→ CS2U_ReconcileMovement()
→ "Reloaded config: presets=5 active=cs2_matched applied=23"
```

- 失败：**保留上一版内存表**，并把错误写进 `g_sUConfigError`（`sm_cs2u_status` 会打印 `config error: ...`），回复带 `(previous tables kept)`。
- 与“保存”不同，重载**不会**重写文件。
- 若 settings 里有非法值：整份文件被拒绝，**不会**只跳过坏字段。
- `cs2u_enable 0` 时 `sm_cs2u_reload` 会被直接拒绝（M-01），不会再“关着开关还应用 settings”。

### 5.3 回滚（`sm_cs2u_rollback`）

- 快照来源：`CS2U_ModeApply` 在应用预设**之前**调用 `CS2U_Snapshot()`（23 个参数 + 当时的 preset 名）。
- **没有快照**（还没应用过预设）→ `no snapshot yet: apply a preset or change a parameter first`。
- 回滚动作：把 23 个参数写回快照值 → 恢复 preset 名 → `CS2U_ReconcileMovement()` → **把快照写成新的 settings 并落盘**（所以换图不会把回滚冲掉）。
- 落盘失败（修复 M-02）：值已在内存恢复，但命令**返回失败**并提示“下次换图会重新应用旧 settings”；日志记 `ROLLBACK-PERSIST-FAILED`。
- 语法上，回滚**不依赖** `cs2u_save`；它写的是 `active_preset = 快照里的 preset 名`（可能为空）。

### 5.4 坏文件

| 坏法 | 结果 |
|---|---|
| 语法坏（缺 `{`、截断） | `parse failed` → 拒绝整份 |
| 既无 `presets` 也无 `settings` | `no presets/settings sections` → 拒绝 |
| 预设值越界/非数字（全部预设都坏） | `config rejected (presets valid=0/1 settings=...)` → 拒绝 |
| settings 有一个非法值 | 整份拒绝（即使预设都合法） |
| 未知键/未知参数 | 忽略，不报错 |
| `active_preset` 指向不存在的预设 | **不报错**，状态显示该名字 |

实测（`tests\results\runtime-smoke.md` §2 第 12 行）：带 BOM 且 `cs2feel_recoil_scale 999` 的配置 → `config rejected (presets valid=0/1 settings=ok); previous tables kept`，实时值与上一版表都保留。

### 5.5 BOM

Source 的 KeyValues 不剥 UTF-8 BOM，会报 `missing {` 却可能返回部分解析结果。本项目自己按字节读文件、跳过 BOM，再 `ImportFromString`（`CS2U_KvImport`，`cs2u_config.sp:36-54`）：

- 带 BOM 的**坏**配置 → 仍被内容校验拒绝（实测）；
- 带 BOM 的**正常**配置 → 正常加载（实测）；
- 插件自己写出的文件同样走这条读取路径（先剥 BOM 再解析），因此不依赖编辑器是否加 BOM；写盘侧是否带 BOM 未专门核验，也不影响加载。

### 5.6 直接改值会立即持久化（H-01 已修复并复验）

`sm_cs2u_set` 与菜单点选成功后不再只改 ConVar：它们调用 `CS2U_PersistLive()`：

```text
CS2U_ParamSet() 成功
  → CS2U_PersistLive()
      → CS2U_ConfigWriteInternal(active_preset, includeSettings=true)   // 先写盘
          成功 → CS2U_CapturePersisted()（内存持久表 = 当前值）→ 回显 "OK: <cvar> = <value> (persisted)"
          失败 → 保留旧持久表 → 回显 "OK: <cvar> = <value>, but persistence failed: <原因>"
```

- 写失败时**内存 ConVar 已改、磁盘仍是旧值**，所以下一次换图会回退到旧值——这与成功提示是明确区分的，不是静默行为。
- 持久表 `g_sPersistValue[]` 的刷新点因此有四处：应用预设、`sm_cs2u_save`、回滚（落盘成功后）、单参数 `PersistLive`（写盘成功后）。
- 复验（`tests\results\runtime-smoke.md` §8/§9）：`sm_cs2u_set cs2feel_recoil_scale 2.4` → `changelevel` → 状态仍 `2.400`；另一次 1.8 的复验在换图后显示 `1.799`（浮点显示）。
- 这与“回滚”仍是两件事：回滚的语义是“回到上一次应用预设之前的快照”，不是“撤销上一步操作”。

---

## 6. 39 个受管参数（类型 / 范围 / 候选 / 权限）

菜单只能选“候选值”（§6 最后一列，2–5 个）；控制台 `sm_cs2u_set` 可以给区间内任意合法值。

| # | cvar | 类型 | 范围 | 候选（菜单） | 权限 |
|---:|---|---|---|---|---|
| 0 | `cs2feel_enable` | bool | 0–1 | 0, 1 | GENERIC |
| 1 | `cs2feel_recoil_mode` | int | 0–1 | 0, 1 | GENERIC |
| 2 | `cs2feel_recoil_scale` | float | 0–3 | 0.5, 1.0, 1.5, 2.4 | GENERIC |
| 3 | `cs2feel_recoil_view_scale` | float | 0–2 | 0.055, 0.1, 0.5, 1.0 | GENERIC |
| 4 | `cs2feel_ballistics_mode` | int | 0–1 | 0, 1 | GENERIC |
| 5 | `cs2feel_ballistics_scale` | float | -2–3 | -0.10, 0.0, 1.0, 2.4 | GENERIC |
| 6 | `cs2feel_ballistics_yaw` | bool | 0–1 | 0, 1 | GENERIC |
| 7 | `cs2feel_spread_mode` | int | 0–1 | 0, 1 | GENERIC |
| 8 | `cs2feel_spread_scale` | float | 0.1–3 | 0.5, 1.0, 1.5 | GENERIC |
| 9 | `cs2feel_spread_move` | bool | 0–1 | 0, 1 | GENERIC |
| 10 | `cs2feel_spread_posture` | bool | 0–1 | 0, 1 | GENERIC |
| 11 | `cs2u_bmode` | int | 0–3 | 0, 1, 2, 3 | GENERIC |
| 12 | `cs2movement_enable` | bool | 0–1 | 0, 1 | GENERIC |
| 13 | `cs2movement_apply_global` | bool | 0–1 | 0, 1 | GENERIC |
| 14 | `cs2movement_engine_speed` | bool | 0–1 | 0, 1 | GENERIC |
| 15 | `cs2movement_duck_speed` | bool | 0–1 | 0, 1 | GENERIC |
| 16 | `cs2movement_air_jump_speed` | bool | 0–1 | 0, 1 | GENERIC |
| 17 | `cs2movement_lowspeed_sustain` | bool | 0–1 | 0, 1 | GENERIC |
| 18 | `cs2movement_crouch_slide` | bool | 0–1 | 0, 1 | GENERIC |
| 19 | `cs2movement_crouch_slide_client` | bool | 0–1 | 0, 1 | GENERIC |
| 20 | `cs2movement_crouch_slide_time` | float | 0.02–2 | 0.10, 0.20, 0.30, 0.35, 0.40, 0.45, 0.50, 0.60 | GENERIC |
| 21 | `cs2movement_crouch_slide_min_speed` | float | 0–1000 | 0, 50, 100, 150 | GENERIC |
| 22 | `cs2movement_crouch_enable` | bool | 0–1 | 0, 1 | GENERIC |
| 23 | `cs2movement_maxspeed` | float | 50–1000 | 150, 215, 230, 240, 320, 1000 | **ROOT** |
| 24 | `cs2movement_weapon_speed_mode` | int | 0–1 | 0, 1 | **ROOT** |
| 25 | `cs2movement_duck_speed_min` | float | 0–200 | 0, 76 | GENERIC |
| 26 | `cs2movement_base_speed` | float | 50–400 | 210, 220, 230, 240, 250 | **ROOT** |
| 27 | `cs2movement_injury_enable` | bool | 0–1 | 0, 1 | GENERIC |
| 28 | `cs2movement_injury_mode` | int | 0–1 | 0, 1 | GENERIC |
| 29 | `cs2movement_injury_health` | float | 0–100 | 0, 20, 40, 60 | GENERIC |
| 30 | `cs2movement_injury_speed` | float | 0–500 | 0, 85, 100, 132 | GENERIC |
| 31 | `cs2movement_injury_base` | float | 0–500 | 0, 210, 220, 230 | GENERIC |
| 32 | `cs2movement_injury_temp_health` | bool | 0–1 | 0, 1 | GENERIC |
| 33 | `cs2movement_injury_adrenaline` | bool | 0–1 | 0, 1 | GENERIC |
| 34 | `cs2movement_water_enable` | bool | 0–1 | 0, 1 | GENERIC |
| 35 | `cs2movement_water_slowdown` | float | 0–0.8 | 0, 0.15, 0.25, 0.35, 0.50, 0.65 | GENERIC |
| 36 | `cs2u_tracer_enable` | bool | 0–1 | 0, 1 | GENERIC |
| 37 | `cs2u_tracer_width` | float | 0.5–5 | 0.5, 1.0, 2.0 | GENERIC |
| 38 | `cs2u_tracer_life` | float | 0.05–1 | 0.1, 0.2, 0.4 | GENERIC |

未列入本表的 ConVar（例如 `cs2feel_spread_tick_profile`、`cs2movement_accelerate`、`cs2movement_bhop_*`）**不受统一层管理**：不能通过菜单/`sm_cs2u_set`/预设/配置持久化修改，需要按上游方式设置（`server.cfg` 或 `cfg\sourcemod\cs2movement.cfg`）。

> `cs2u_tracer_enable` / `cs2u_tracer_width` / `cs2u_tracer_life` 属于 `PARAM_GROUP_VISUAL`（菜单「视觉辅助」，参数索引 36–38），是**纯视觉**参数：不会改变后坐力、扩散、速度或命中判定，也不会被数据层 VPK 读取。`cs2u_tracer_enable 1` 时服务端在 `bullet_impact` 上画 `TE_SetupBeamPoints` 并 `TE_SendToAll`（所有客户端可见），每客户端 50 ms 节流；精灵缺失时自动 no-op；`cs2u_tracer_alpha`（默认 110，0–255）控制光束透明度，**不是**受管参数，所以受管参数仍是 39，也不会写入预设。

> **蹲下滑行三项（索引 18–20）**由 movement 0.4.5 执行，客户端半是 0.5.2 新增；**水面两项（索引 34–35）**由 patch 层的 movement 0.5.3 执行：

```text
cs2movement_water_enable      0/1        默认 1
cs2movement_water_slowdown   0.0–0.8    默认 0.35（factor = 1 - slowdown * m_nWaterLevel/3）
```

落盘示例（`cs2_full` 的 Settings 段）：`"cs2movement_water_enable" "1"` / `"cs2movement_water_slowdown" "0.350000"`；`vanilla` 预设写 `0`。旧配置缺这两个键时由 `CS2U_ModesEnsureWater()` 在内存里补齐（vanilla 补 0，其余补 1/0.35），下一次保存即落盘。

>
> - `crouch_slide_client`（插件默认 **0**；**`cs2_competitive` / `cs2_full` 预设显式写 1**，0/1）：把复制的 `survivor_crouch_speed` 沿同一曲线写下，让客户端也预测滑行（两端都滑、零回拉）。**受"干净房间"门控**：只在「恰好一个幸存者在滑行、且其他幸存者都没蹲」时才驱动这条全局 cvar，否则这次滑行退回服务端单边修正——避免队友蹲走时被客户端预测成加速再被拉回。`sv_cheats 0` 下客户端接受复制值**已实测（2026-11-01：客户端日志 `SetConVar: survivor_crouch_speed = …`）**，`FCVAR_CHEAT` 不阻止复制。依赖 `crouch_slide 1` + 蹲速层就绪；`survivor_crouch_speed` 缺失时 fail-closed（status: `client_slide=missing`）。
> - `crouch_slide_time`（默认 **0.20**，范围 0.02–2.0）：从起滑速度衰减到蹲速的时间；
>   **0.20 = CS2 摩擦曲线**（`ln(215/73.1)/5.2 = 0.207 s`，27.3 u），0.10 只有一半（64 tick 实测 13.0 u）。
> - `crouch_slide_min_speed`（默认 100，范围 0–1000）：起滑所需的最低 pre-duck 速度（u/s）。
>
> 注意：`crouch_slide 1` 只是门槛之一，真正生效还要求蹲速层就绪
> （`enable ∧ duck_speed ∧ weapon_speed_mode ∧ write_props ∧ speed_enforce` ∧ `CS2M_CheckParams` 就绪）。
> `sm_cs2u_status` / `sm_cs2u_diag` 的 `slide:` 行打印 `cvar/ready/duck_layer/hook/starts/writes/last v0/ceil/client_slide/cvar_now/base`，
> `ready=0` 时不会滑且会打一次警告。

> **injury 七项（索引 27–33）**由 movement 0.5.1 执行，统一层只负责校验/写 ConVar/持久化：
>
> - `injury_enable`（默认 1）：总开关；0 = 完全交回引擎（低血量不再被武器速度覆盖）。
> - `injury_mode`：1 = ratio（默认），0 = absolute。
> - `injury_health`：跛行阈值；**0 = 沿用引擎阈值**（L4D2 为 40 HP）。
> - `injury_speed`：ratio 模式的“受伤目标速度”/ absolute 模式的绝对上限（默认 132）。
> - `injury_base`：ratio 模式的分母（默认 220）；`ratio = injury_speed / injury_base`。
> - `injury_temp_health`：1 = 临时生命计入血量判定。
> - `injury_adrenaline`：1 = 肾上腺素期间不减速。
>
> 默认 ratio 132/220 = **60%**：AK 215→129、SMG 240→144；absolute 模式则统一 132。`injury_health 0` 不等于“关闭”，关闭请用 `injury_enable 0`。

---

## 7. `cs2u_*` 十二个 ConVar 与配置的关系

| ConVar | 默认 | 是否被配置覆盖 | 说明 |
|---|---|---|---|
| `cs2u_version` | `1.0.1` | 否 | `FCVAR_NOTIFY|FCVAR_DONTRECORD` |
| `cs2u_enable` | `1` | 否 | 门控**菜单入口、可选聊天别名、预设应用、换图定时器**，以及 `sm_cs2u_set/save/reload/rollback`；`sm_cs2u_status/presets/diag` 仍只读可用 |
| `cs2u_debug` | `0` | 否 | 打开后 `CS2U_Log` 同时 `PrintToServer` |
| `cs2u_menu_chat_alias` | `0` | **是**（`settings.menu_chat_alias`） | 0 = 只保留 `!cs2u`（默认，避免冲突）；1 = 额外拦截 `!menu`/`!c2u` |
| `cs2u_log_actions` | `1` | 否 | 打开后把菜单/配置/预设动作写 `ACTION ...` 到日志 |
| `cs2u_preset` | `""` | **是**（`active_preset`） | 信息用途；状态输出会显示 |
| `cs2u_simple_mode` | `0` | **是**（`settings.simple_mode`） | 1 = `!cs2u` 直接打开白话菜单；只改视图，不改权限 |
| `cs2u_tracer_enable` | `0` | 是（作为受管参数写入 settings） | 服务端曳光总开关（纯视觉） |
| `cs2u_tracer_width` | `1.0` | 是 | 曳光宽度（0.5–5） |
| `cs2u_tracer_life` | `0.20` | 是 | 曳光存在时间（0.05–1 s） |
| `cs2u_tracer_alpha` | `110` | 否（不是受管参数） | 曳光颜色 alpha（0–255，越小越透明）；`sm_cvar cs2u_tracer_alpha 80` |
| `cs2u_feel_survivor_only` | `1` | 否（1.0.13，不是受管参数） | 1 = 手感三层（压枪/弹道/散布）只跳过**特感**，幸存者与旁观者不变；0 = 回到 1.0.13 之前的全队行为。见 `docs/06` L26 |

`cs2u_enable 0` 的精确效果（修复 M-01 后）：

| 路径 | 是否被 `cs2u_enable 0` 阻止 |
|---|---|
| `!cs2u` / `!menu` 打开菜单 | 是（提示 `Management layer is disabled (cs2u_enable 0).`） |
| 换图时应用 settings | 是（定时器直接 `Plugin_Stop`） |
| `sm_cs2u_preset` | 是（`CS2U_ModeApply` 返回 `management layer disabled`） |
| `sm_cs2u_set` | 是（`Cmd_Set` 入口检查） |
| `sm_cs2u_save` | 是（`Cmd_Save` 入口检查） |
| `sm_cs2u_reload` | 是（`Cmd_Reload` 入口检查）——不会再“关着开关还应用 settings” |
| `sm_cs2u_rollback` | 是（`Cmd_Rollback` 入口检查） |
| `sm_cs2u_status` / `sm_cs2u_presets` / `sm_cs2u_diag` | **否**（只读，仍可用） |

运行复验（`runtime-smoke.md` §9）：`cs2u_enable 0` 后 `sm_cs2u_set` 与 `sm_cs2u_reload` 都被明确拒绝；`sm_cs2u_status` 仍输出（`enable=0`）。

---

## 8. 容量与边界

| 边界 | 值 | 越界行为 |
|---|---:|---|
| 配置文本缓冲 | 32,768 B | 超出被 `ReadFileString` 截断；**预期**随后解析/section 检查失败并整份拒绝，但“截断点恰好落在合法结构内”的路径**未实测**（独立审计 L-05 建议在读取返回值达到上限时直接报错） |
| 预设数 | **12** | 7 内置 + 2 DIY 槽位 + 余量；超限返回 `preset limit reached (12)` |
| 单预设条目 | **40** | `CS2U_MAX_ENTRIES` 24→32→40；`cs2_full`/`cs2_competitive` 的 39 条可完整装入（余量 1） |
| 参数数 | **40**（当前 39） | `CS2U_ParamAdd` 超过 40 返回 -1；再加参数必须同时抬 `CS2U_MAX_PARAMS` 与 `CS2U_MAX_ENTRIES` |
| 菜单候选值 | 8 / 参数（当前最大 8：`cs2movement_crouch_slide_time`） | 超出忽略 |
| 预设名 | 32 B | 超长截断 |
| 值字符串 | 32 B | 超长在读取时截断；数字语法校验会拒绝残缺值 |
| cvar 名 | 64 B | 受管表内的名字都远小于此 |

`verify.ps1` 会检查“参数表非空且 ≤40”“每个受管 cvar 都被模块创建”“无重复受管 cvar”“预设只引用受管 cvar”，以及新增的 ConVar 注册校验、主开关闭环、单参数持久化顺序与 `.bak` 启动恢复；但它不检查配置文件内容（配置文件不存在也能编译/验收）。

---

## 9. 与旧版/未来版本的兼容

- **向前（旧 → 新）**：未知键忽略、缺失键用默认值，因此新增字段不会让旧文件失效。
- **向后（新 → 旧）**：旧插件不认识新键，同样忽略；但旧插件保存时会**重写整份文件**并丢掉它不认识的键——降级前请备份。
- `schema` 目前只是常量 `"1"`，**没有**版本迁移代码；若未来引入不兼容变更，必须新增显式迁移或提升 schema 并加校验。

---

## 10. `menu.cfg`（v1.0.5，菜单布局与鉴权）

`addons/sourcemod/configs/cs2unified/menu.cfg` 是**独立文件**，不写进 `cs2unified.cfg`：后者的保存会整体重建 KeyValues，未建模的段会被覆盖丢失。

```text
"CS2UnifiedMenu"
{
    "schema" "1"
    "menu"
    {
        "advanced_default" "0"          // 0/1
        "confirm_destructive" "0"       // 1 = ROOT 参数需二次点击
        "telemetry" "1"                 // 1 = 写 MENU-SELECT
        "perm.config" "root"            // root | hidden
        "perm.diy" "root"
        "perm.diag" "root"
        "visible.basic" "presets,feel,move,visual,status"
        "order.presets" "preset:cs2_full,preset:cs2_tracer,..."
        "order.feel"    "act:recoil,act:bmode,act:clientinfo,act:facts,cvar:cs2feel_enable,..."
        "order.move"    "act:slide_tier,cvar:cs2movement_crouch_slide,..."
        "order.visual"  "cvar:cs2u_tracer_enable,...,act:camera_detect,..."
        "order.status"  "act:status_full,act:status_plain,act:auth_log,act:diag_verify,..."
        "order.config"  "act:save,act:save_custom,act:reload,act:rollback,act:path,act:menu_reset"
    }
    "auth"
    {
        "priority" "steamid"            // 只接受 steamid
        "steamids" { "0" "STEAM_1:0:xxx root" }   // tier = root | admin
        "groups"   { "0" "Full Admins root" }
    }
}
```

### 10.1 校验规则

| 规则 | 失败结果 |
|---|---|
| `menu` 直接键 + `auth` 直接键 ≤ 20 | 超过 → 整段拒绝，回退默认布局（`too_many_keys N>20`） |
| `order.*` 每项必须是该 ctx 的已知 key（`cvar:*` 受管 / `preset:*` 已加载 / `act:*` 属于该页） | 未知/重复/空/≥40 项 → 整段拒绝 |
| `auth.priority` 必须是 `steamid` | 否则整段拒绝，auth 清空 → flag 模式 |
| `perm.config` / `perm.diy` / `perm.diag` 只接受 `root` \| `hidden` | 其它值 → 整段拒绝（1.0.5 起；原实现会把 `admin` 静默当 `root`） |
| `visible.basic` 只接受 `presets,feel,move,visual,status` | `config` 是高级视图专属，写进去 → 整段拒绝（原实现接受但根常用视图不渲染） |
| 单条 auth `"<identity> <tier>"` | 格式错跳过该条并记 `MENU-CONFIG-AUTH-SKIP` |
| 文件缺失 | 内置默认布局（不报错） |

回退（`MENU-CONFIG-FALLBACK`）会同时清空 auth，回到 SourceMod flag 判定，避免坏文件锁死管理员。回退原因写在 `g_sMenuCfgError`，`sm_cs2u_status` 的 `menu config error:` 行可见；管理员下次开菜单会收到聊天提示。

### 10.2 热重载

`sm_cs2u_reload` 重载 `cs2unified.cfg` 与 `menu.cfg`；新布局在下一次打开菜单时生效。`act:reload` / `act:menu_reset` 走同一路径（后者先把 `menu.cfg` 改名为 `.bak`）。

### 10.3 鉴权

`auth.steamids` 条目优先级高于 `auth.groups`；同时命中时以 SteamID 为准并写 `AUTH-CONFLICT`。`auth` 段缺失/为空时保持 flag 模式（`source=flag`）。控制台命令仍由 SourceMod flag 控制；两套源可用 `tools\gen_menu_auth.ps1` 从 `admins_simple.ini` 一次性生成对齐。

---

## 11. 武器速度表（1.0.11，**不是**受管参数）

`configs/cs2movement_weapons.cfg` 是 cs2movement 的武器速度表，由
`CS2M_MoveLoadWeaponTable()` 在插件启动时读进 `g_mWeaponSpeeds`（StringMap，class → speed）。

- **不进受管参数表**：39 个已到 `CS2U_MAX_PARAMS` 40 的上限；它也不是 ConVar，塞进参数表要同时改
  容量、预设条目数和菜单分组，收益不成比例。
- **不进预设**：换预设不改武器速度；想回到出厂值用菜单「详细移动数值」末行或
  `sm_cs2u_weapons reset`。
- 菜单里可改（移动页 →「详细移动数值」→ 点一行 → 聊天栏输入），**每次修改立即重写该文件**
  （tmp → `.bak` → rename），所以换图与 `sm_cs2movement_reload` 都不会回退。
- 控制台：`sm_cs2u_weapons`（列出，`*` = 已改）/ `sm_cs2u_weapons <序号|类名> <速度>` / `sm_cs2u_weapons reset`，ROOT。
- 取值区间 **50–1000 u/s**；越界与未知类名都被拒，不写盘。
- 出厂 18 条（与文件、`CS2M_MoveWeaponSpeed()` 的内联兜底一致）：
  rifle 215 / ak47 215 / desert 225 / sg552 225 / smg 240 / smg_silenced 240 / mp5 240 /
  pistol 240 / magnum 230 / hunting 230 / scout 230 / military 230 / awp 200 /
  chrome 230 / spas 230 / pumpshotgun 230 / melee 250 / chainsaw 250。

> ⚠️ `tools\deploy.ps1` 每次都覆盖 `configs\cs2movement_weapons.cfg`（它是“部署资产”，不是
> onlyIfMissing）。在菜单里改过速度后**再次部署会回到包内默认值**；重新部署后请再改一次，
> 或把改动同步进仓库的 `configs\cs2movement_weapons.cfg`。

---

## 12. `env` 段（1.0.12）：tick 适配的独立通道

`cs2feel_spread_tick_profile` 是**唯一一个**与 tick 直接相关、却不在 39 个受管参数里的
ConVar（`CS2U_MAX_PARAMS` 40 已经只剩一个槽，而它一旦进表，`cs2_full` 就会顶满
`CS2U_MAX_ENTRIES` 40，零余量）。所以它走自己的通道：

| 环节 | 实现 |
|---|---|
| 读 | `FindConVar("cs2feel_spread_tick_profile")` |
| 写 | `SetConVarInt`（不经 `CS2U_ParamSet`，所以 `sm_cs2u_set` 改不了它，这是设计） |
| 持久化 | 本文件的 `env` 段（`spread_tick_profile` / `adapted_hz` / `adapted_at`） |
| 回填 | `CS2U_EnvApplyStored()`：`OnMapStart`、`OnConfigsExecuted` 的 0.5 s 定时器、`sm_cs2u_reload` |
| 清除 | `sm_cs2u_env clear`（只删标记，不动当前值）或 `undo` |

**为什么 env 段不跟随 settings 的 fail-closed**：

- `settings` 里出现一个非法值 → 整份配置拒绝（一台“半配置”服务器比一台“旧配置”服务器更危险）。
- `env` 是**辅助**信息：一个手改坏的 `spread_tick_profile` 只该让这一条失效，不该把 39 个
  受管值一起打回上一个快照。因此非法值只写 `ENV-BAD-PROFILE` 并忽略整个 env 段。

**注意**：适配**不会**写 `sv_*`。`sv_maxupdaterate` 的建议值只出现在探测输出里（`本插件从不写`），
这是 `cs2_full` 边界说明的延续：全服 rate 不在“一键适配”的权限范围内。

**换图 / 重启后的行为**：`ENV-APPLY profile=N adapted_hz=X`（回填）、必要时
`ENV-PROFILE-RECLAIM old -> new`（值被人改过，抢回来）；若实测 Hz 与 `adapted_hz` 差 >2
则写 `ENV-CHANGED` 并在聊天里通知在线 ROOT —— **只提示，不偷改**。
