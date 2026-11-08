# CS2Unified_L4D2

> **公开版说明**：本仓库是 CS2Unified_L4D2 的**公开发布镜像**，由私有开发版定期同步发布；不包含开发历史、运行时证据目录（`tests\results\`）与内部任务书。
> 文档中的 `<DS_DIR>` / `<DS_HOST>` / `<REPO_ROOT>` / `<CLIENT_DIR>` 是路径占位符，请替换为你自己的专用服根目录（含 `srcds.exe`）/ 服务器地址 / 本仓库根目录 / 客户端 `left4dead2` 目录。
> 运行环境要求（自备）：L4D2 专用服 + SourceMod 1.12 / MetaMod 1.12；RCON 密码用 `-Password` 参数或 `CS2U_RCON_PASSWORD` 环境变量提供，**不要写进仓库**。

把 **CS2 枪械手感**（cs2feel）与 **CS2 移动物理**（cs2movement）合并成**单一 `cs2unified.smx`**，并在这两个上游模块之上加一层统一管理面：**两级管理员菜单**（常用 6 行 / 高级 7 行，7 个页面，`menu.cfg` 可热重载）、**39 个受管参数**（含受伤减速 7 项、蹲下滑行 3 项、水面减速 2 项）的校验写入、7 套内置预设（含**完全仿真 CS2** 与**CS2 压枪 + 弹道曳光**）、KeyValues 配置持久化与回滚、**SteamID 列表 > 管理员组**鉴权；1.0.2 起另加一个**纯客户端**的「相机 / 准星分离」检测（Left4Neko 的 `l4n_view_punch_scale`，服务器只检测/引导，绝不动弹道）。1.0.10 起 movement 多一层**按水面高度（踝/腰/眼）的幸存者减速**，感染者完全不受影响。1.0.12 起移动页尾部多一页**环境适配**：按 `GetTickInterval()` 实测的 tick 与运行形态，把“只在某个 tick 下成立”的值一次对齐 —— **先预览、再应用、可撤销**，而且**从不写 `sv_*`**。1.0.13 起**手感三层（压枪 / 弹道 / 散布）按队门控**：只跳过特感，幸存者与旁观者行为逐字节不变（`cs2u_feel_survivor_only`，默认开）。1.0.14 修复**环境适配页四个动作按钮点了没反应**的解析 bug，并加了无需客户端的行回放命令 `sm_cs2u_menusel`；1.0.15 全菜单审计后修正**撤销消息漏数档位通道**的计数（纯档位适配时曾显示「0 个值」）。

- 插件版本：**1.0.15**（单一产物 `cs2unified.smx`）
- 上游基线：**cs2feel 0.5.7-m11**（5 个 `.sp`）+ **cs2movement 0.5.2**（`CS2Movement_L4D2.public`，5 个 `.sp`，含 `cs2movement_injury.sp`；2026-11-01 本地 bump，未打 tag）
- 本地 patch 层：`patches\movement_water\` 在生成阶段给 movement 打上 **0.5.3 水面减速**（新增 `cs2movement_water.sp` + 3 处确定性插入）；`sync_sources.ps1` 写模式与 `-Check` 模式走同一套变换，`verify.ps1` 因此能证明补丁仍在
- 许可：**GPL-3.0**（继承上游 CS2Movement_L4D2；见 [NOTICE](NOTICE) 与 [LICENSE](LICENSE)）
- 静态验收：`tools\verify.ps1` → **VERIFY PASS (145 checks)**，编译 **0 error 0 warning**
- 运行时：在单人 Windows 专用服完成多轮冒烟（**23 项 PASS / 3 项 UNVERIFIED**，含 H-01/H-02 修复、简易模式/曳光/`cs2_full`/受伤减速复验），1.0.5 另做**菜单布局 dump**（`sm_cs2u_menudump`）与 `menu.cfg` 回退/热重载验证；1.0.10 追加**水面层运行时证据**（`tests\results\water-runtime-*.md`）；**没有**真人客户端菜单点选验证

> 文档与实现冲突时**以 `src\` 与 `tools\` 的代码为准**。所有“已实测”结论都给了文件路径或命令；未验证/无法验证的项按 `UNVERIFIED` 标注，不做推测性表述。

---

## 1. 项目定位

| 问题 | 本项目的回答 |
|---|---|
| 两个上游插件能同时装吗 | 能装，但 CS2 手感与移动共享 `OnPlayerRunCmd`、`sv_*` 与回调命名空间；装成两个 `.smx` 时回调顺序由 SourceMod 决定，无法保证“手感先读原始按键、移动后改速度” |
| 本项目怎么做 | 把 10 个上游文件（feel 5 + movement 5）**机械重命名**后编进**同一个 `.smx`**，由 `src\cs2unified.sp` 成为**唯一** `myinfo` 与**唯一**回调出口，再显式排序分发 |
| 多出来的价值 | 两级聊天菜单（常用/高级，7 个页面，`menu.cfg` 热重载）/ 39 参数校验 + 18 件武器速度明细（菜单改、聊天输入、立即写盘） / 7 套预设（含 `cs2_full` 完全仿真、`cs2_tracer` 曳光）+ 2 个 DIY 槽位 / 配置持久化 / 回滚 / 诊断 / 受伤减速 / **客户端相机分离检测** / **SteamID 列表 > 组鉴权**；上游 `cs2feel_*`、`cs2movement_*` 的 ConVar 名、命令名与 feel natives **完全不变**（向后兼容） |
| 不做的事 | 不改写上游行为逻辑；不把加载期数据层（VPK 里的 `scripts\weapon_*.txt`）做成可热切换；不支持 Linux；不做反作弊/绕过 VAC |

---

## 2. 当前状态

| 项 | 值 | 证据 |
|---|---|---|
| 插件名 / 版本 | `CS2Unified (L4D2)` / `1.0.15` | `src\cs2unified.sp`（`CS2U_VERSION`）；DS 日志 `[CS2Unified] LOAD version=1.0.15 feel=0.5.7-m11 movement=0.5.3` |
| 产物 | 单一 `build\cs2unified.smx`，**约 160–180 KB**（最新构建 **174,010 B**） | `tools\build.ps1`；`spcomp` 输出**不可逐字节复现**，同一源码两次构建大小会漂移、SHA256 每次不同 → **不要写死哈希，以当次 build 输出为准** |
| 编译体积 | Code / Data / Stack 以当次 `build.ps1` 输出为准；error / warning 必须为 0 / 0 | `tools\build.ps1` 输出 |
| 源码规模 | **23 个 `.sp`** / **15,103 行** / **573,761 B** | `src\` 同一统计口径（含 patch 生成的 `cs2movement_water.sp` 与 `cs2u_weapon.sp` / `cs2u_env.sp`） |
| 生成文件 | `src\feel\` 5 个、`src\movement\` **6 个**（上游 5 + patch 1，含 `cs2movement_injury.sp` / `cs2movement_water.sp`）由 `tools\sync_sources.ps1` 生成 | `powershell -File tools\sync_sources.ps1 -Check` → `SYNC-OK 11 files match upstream + rename table + patches` |
| 静态验收 | **145 / 145 PASS** | `powershell -File tools\verify.ps1` → `VERIFY PASS (145 checks)` |
| 编译告警 | 0 error / 0 warning（`-StrictWarnings`） | `verify.ps1` 第 2 项检查 |
| 运行时冒烟 | 加载、状态、预设、保存/热重载、换图持久化、回滚、坏配置拒绝、BOM、控制台入口、还原、`set→changelevel`、`enable 0` 拒绝写、默认卸载、**简易模式持久化（旧版）**、**`cs2_tracer` 应用**、**曳光精灵预缓存**、**`cs2_competitive` 参数（1.0.4 时 36；1.0.9 起 37；1.0.10 起 39）**、**`managed_params`（1.0.10 起 39）**、**受伤减速状态（enable=1 / speed=132）**、**水面层（1.0.10：曲线/实时改值/预设 39/netprop/菜单行）**：**23 PASS / 3 UNVERIFIED**；UNVERIFIED = 真人客户端菜单/分页、曳光“看得见”、低血量受伤减速观感 | tests\results\runtime-smoke.md（开发版运行时记录） §0/§8–§17、tests\results\water-runtime-*.md（开发版运行时记录） |
| 受管参数 | **39** 个（`cs2feel_*` 12 + `cs2movement_*` 15 + **`cs2movement_injury_*` 7** + **`cs2movement_water_*` 2** + `cs2u_tracer_*` 3；`cs2u_bmode` 属 feel 组） | `src\cs2u_params.sp`；`sm_cs2u_status` → `managed_params=39` |
| 内置预设 | **7** 套 + 2 个 DIY 槽位（保存后才出现）；`cs2_full` / `cs2_competitive` 各 **39** 条全量写入，其余为语义子集并**自动补齐** `cs2u_bmode` 与水面键（`vanilla` 19 / `cs2_matched` 22 / `cs2_split` 22 / `cs2_tracer` 22 / `movement_only` 28） | `src\cs2u_modes.sp`；DS 落盘 `cs2unified.cfg` |
| 对外接口 | **107** 个 ConVar（统一层 12 + feel 35 + **movement 60**）、22 个命令、7 个 feel natives | 旧审计 `_audit_extract.txt` 为 105 / 21 / 7（现 107 ConVar，missing=0；1.0.13 加 `cs2u_feel_survivor_only`，1.0.14 加回归命令 `sm_cs2u_menusel`） |
| 实测环境 | L4D2 `PatchVersion 2.2.4.3`，SourceMod **1.12.0.7230**，MetaMod 1.12，64 tick（L4DToolZ），`-insecure` 专用服 `<DS_DIR>` | 运行时证据记录不随本公开仓库发布（见下方说明） |

### 2.1 基线版本（已统一）

| 组件 | 仓库源码 | 线上 DS 二进制 | 处理 |
|---|---|---|---|
| cs2feel | `0.5.7-m11`（`..\CS2FeelVScript_L4D2\plugin_src`） | `cs2feel_core.smx` **49,201 B**，与源码自述版本一致 | 已整合（`CS2F_VERSION "0.5.7-m11"`） |
| cs2movement | `0.5.2`（`..\CS2Movement_L4D2.public\scripting`；上一发布 tag `v0.5.1`）+ 本地 patch **0.5.3** | `cs2movement.smx` **0.5.1**（线上未更新） | **已整合**（`CS2M_VERSION "0.5.3"`）；0.5.1 起含 `cs2movement_injury.sp`，0.5.3 由 patch 层加 `cs2movement_water.sp` |

- 合并产物内的 movement 日志是 `LOAD version=0.5.3`（0.5.1 时实测行为基线：`LOAD version=0.5.1`；0.5.2 只改 `crouch_slide_time` 出厂默认与诊断；0.5.3 只加水面层，未改其它物理路径）。
- **0.5.3 新增水面减速（water）**：2 个 `cs2movement_water_*` ConVar，`factor = 1 - slowdown * m_nWaterLevel/3`，只作用于幸存者，叠加在受伤减速之后（见 §4.1 与 [docs\08](docs/08_水面减速_任务交接.md)）。
- **0.5.1 新增受伤减速（injury）**：7 个 `cs2movement_injury_*` ConVar；默认 ratio 模式 `132/220 = 60%`，让 20 HP 幸存者恢复跛行减速（否则 movement 每 tick 重写 `m_flMaxspeed`，低血量仍按 CS2 武器全速）。
- 保留 0.4.8 的 `cs2movement_maxspeed` 语义：**per-player 上限钳制，默认 1000**，不再把全局 `sv_maxspeed` 压到 320（避免压慢 Charger 冲撞）；内置预设统一写 `1000`。
- 上游目录以 `CS2Movement_L4D2.public` 为准；旧的 `CS2Movement_L4D2`（0.4.5）与 `CS2Feel_L4D2\scripting`（m10）**不再使用**。数据层 VPK 仍需客户端/服务端成对部署。

---

## 3. 能力边界

**能做**

- 一个 `.smx` 同时提供 cs2feel（后坐力/弹道/扩散运行层）与 cs2movement（全局 `sv_*`、per-player 跑速/蹲速/空中速度等）的既有能力，ConVar 名与命令名不变。
- `!cs2u` 打开**两级菜单**（常用 6 行 / 高级 7 行；每页 7 内容行，#8 返回/上一页、#9 下一页；`!menu`/`!c2u` 默认不拦截，需 `cs2u_menu_chat_alias 1` 才启用）。常用视图：预设与模式、手感、移动与受伤、视觉与准星、状态、高级模式；高级视图追加配置与保存、DIY、诊断与 3 个 ROOT 参数。39 个受管参数**行内循环**修改（不再有第三层值页），先校验再写 ConVar，单参数改动**立即持久化**（回显 `(persisted)`）。
- 内置预设一键切换（含 `cs2_tracer` = `cs2_matched` + 服务端曳光）；应用前自动快照，`sm_cs2u_rollback` 可回到应用前状态并**落盘**。`cs2_matched` / `cs2_tracer` 就是“**所见即所中**”（recoil 1.0 / ballistics 0 / spread 0）。预设区另有 **2 个 DIY 槽位**（`diy_advanced` / `diy_simple`，保存后才出现）。`cs2_split` 是**服务器侧**分离：所有客户端都生效，但“弹孔跟不跟随命中”取决于该客户端装没装 aim-sync（行尾标「服务器侧分离·弹孔要看客户端装没装 aim-sync」）。
- **弹道模式（单人·TR-40 / 多人，2026-11-03）**：`!cs2u` → 手感 →「弹道模式」行（点此循环：自动 / 单人·TR-40 / 多人）。
  单人·TR-40 = 旧 TR-40 的观感：相机 1.00×表值、弹道 2.20×表值，**实测弹孔比准星高 4.98°**（TR-40 台架 5.225°），
  客户端需 `cs2feel_aimsync` 的 `ratio = 1.200000`；多人 = 服务器 matched，所有客户端弹道一致、无“所见≠所中”。
  规范与 13 项验收见 [`docs/07_弹道模式.md`](docs/07_弹道模式.md)。

**不能做**

- **不能热切换数据层**：VPK 内 `scripts\weapon_*.txt` 的 7 个扩散键是**加载期资产**，SourceMod 无法在运行时替换；预设只管理运行时 ConVar。数据层变更必须重新部署 VPK + 重启。
- 不能绕过 `cs2feel_spread_mode 0` 的前提：数据层 VPK 的 `addoninfo.txt` 明确要求“不要让 spread 模块同时启用”，否则同一扩散有两个来源。
- 不支持 **Linux** 服务器：两份 gamedata 都只有 `windows` 键（源码与 gamedata 注释明确说明）。
- 不保证跨 tick 的位移级一致：cs2movement 的部分层是**服务器单边修正**，客户端预测仍有代价（见 [docs\06_已知限制.md](docs/06_已知限制.md) L6）。
- 未做多人/远程/真人客户端的菜单与手感验证；性能只做过静态评估，没有帧耗时压测。
- **曳光是纯视觉**：服务端 `bullet_impact → TE_SetupBeamPoints → TE_SendToAll`，不改命中判定；默认关闭，透明度由 `cs2u_tracer_alpha`（默认 110，0–255）控制。真人客户端是否“看得见”仍 UNVERIFIED。
- 不修改游戏本体、不携带 Valve 代码或反编译产物、不面向 VAC 规避。

---

## 4. 快速开始

### 4.1 构建

前置：SourceMod 1.12 的 `spcomp.exe` 与其 `include\`。`tools\build.ps1` 的查找顺序：

1. `-CompilerPath` 参数；
2. `<DS_DIR>\left4dead2\addons\sourcemod\scripting\spcomp.exe`；
3. 与本项目同级目录的 `..\Left 4 Dead 2\left4dead2\addons\sourcemod\scripting\spcomp.exe`；
4. `PATH` 上的 `spcomp.exe`。

```powershell
cd <REPO_ROOT>

# 先同步上游（可选：build.ps1 -Sync 也会做）
powershell -ExecutionPolicy Bypass -File .\tools\sync_sources.ps1

# 编译（-StrictWarnings：有告警即失败）
powershell -ExecutionPolicy Bypass -File .\tools\build.ps1 -StrictWarnings

# 静态验收（145 项：sync 漂移 + 编译 + 符号/接口/菜单契约 + 队伍边界 + 脚本 BOM）
powershell -ExecutionPolicy Bypass -File .\tools\verify.ps1
```

产物：`build\cs2unified.smx`（约 150 KB）。**不要跨次比对大小/哈希**，`spcomp` 产物含非确定内容。

### 4.1.1 CI（一条命令，一个退出码）

```powershell
# 静态门（~5 s，不需要服务器）：sync 漂移 + 编译 + 145 项契约
powershell -ExecutionPolicy Bypass -File .\tools\ci.ps1

# 全量（静态 + 部署到测试服 + 运行时套件水/武器/环境，~4 min，会自己起停 srcds）
powershell -ExecutionPolicy Bypass -File .\tools\ci.ps1 -Stage Runtime -Force

# 只跑其中一套
powershell -ExecutionPolicy Bypass -File .\tools\ci.ps1 -Stage Runtime -Only water -Force
```

- 产物在 `tests\results\ci-<时间戳>\`：`summary.md` / `summary.json`（机器可读）+ `static.log` /
  `deploy.log` + 每套件的 `<suite>.md` / `<suite>.json` / `<suite>.console.log`。
- 运行时套件是**带断言的**，不只是“打印证据”：`tests\water_runtime.ps1`（20 项）、
  `tests\weapons_runtime.ps1`（26 项）、`tests\env_runtime.ps1`（31 项，64 Hz）；
  30 Hz 那一腿是同一个实现的另一个入口 `tests\env30_runtime.ps1`（22 项，会临时停用
  `l4dtoolz` / `tickrate_enabler` 跑真 30 tick），**默认不进 CI**（见下）。
  每套各自起服 → 断言 → 关服，失败即非 0 退出。
- **跑运行时套件前请退出本机正在运行的《L4D2》客户端**：客户端占着 Steam 的 app 会话，
  专用服起服会偶发卡在地图载入（进程活着、端口没开、`console.log` 不增长）。
  这是实测到的干扰，不是插件问题。
- 正在跑的 srcds 不会被悄悄杀掉：`-Force` 才替换。
- **宿主 CI 只能做静态那一半**（没有游戏文件、没有 Steam 认证的 DS），所以运行时门放在本机，
  由 `tools\ci.ps1` 统一入口；`-CompilerPath/-IncludePath` 可指向任意 SourceMod 安装。

Git 钩子（可选，装一次）：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\install-hooks.ps1        # pre-commit
powershell -ExecutionPolicy Bypass -File .\tools\install-hooks.ps1 -Hook pre-commit,pre-push
powershell -ExecutionPolicy Bypass -File .\tools\install-hooks.ps1 -Uninstall
```

`pre-commit` 只跑静态门（~5 s），跳过一次用 `CS2U_SKIP_CI=1 git commit ...`。运行时套件
**故意不挂钩子**——它要占一台服务器好几分钟。

### 4.2 部署

先**停服**（`.smx` 与 VPK 被占用会复制失败），再执行：

```powershell
# 只打印计划，不动服务器
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -DryRun

# 正式部署（默认目标 <DS_DIR>；会自动备份到 _backup\<时间戳>\）
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1

# 同时停用测试探针 cs2f_mv3.smx / cs2f_aimdebug.smx
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -DisableProbes
```

说明（详见 [docs\04_部署与回滚.md](docs/04_部署与回滚.md)）：

- 默认把 `plugins\cs2feel_core.smx`、`plugins\cs2movement.smx` 移到 `plugins\disabled\`——合并产物注册同样的 ConVar/命令，同时加载会重复注册。
- 每个被覆盖文件先复制到 `_backup\<时间戳>\<相对路径>`；`_backup\<时间戳>\install-manifest.csv` **每完成一个动作就追加一次**（中途失败也有撤销记录）。
- 每次部署还会合并写 `_backup\project-manifest.csv`：**每个路径保留第一次备份的绝对路径**，重复部署不会覆盖真正的“项目前状态”。卸载默认优先用它。
- `-NoAddon` 不装数据层 VPK；`-KeepLegacy` 不停用旧插件（**不推荐**）。

### 4.3 运行时命令

```
sm plugins list                 # 期望看到 CS2Unified (L4D2) 1.0.15，无 [FAILED]
sm_cs2u_status                  # 版本 / 配置 / 预设 / 39 参数 / 菜单布局 / 鉴权 / feel / movement 摘要
sm_cs2u_presets                 # 列出 7 套预设，标注 [active]
sm_cs2u_preset cs2_full         # 完全仿真 CS2（39/39 个受管值）并落盘  [ROOT]
sm_cs2u_preset cs2_tracer       # CS2 压枪 + 弹道曳光（20 参数）并落盘   [ROOT]
sm_cs2u_preset cs2_matched      # 所见即所中（recoil 1.0 / ballistics 0）[ROOT]
sm_cs2u_set cs2feel_recoil_scale 1.5   # 校验→写 ConVar→立即持久化（回显 (persisted)）
sm_cs2u_set cs2u_tracer_enable 1       # 打开服务端曳光（纯视觉）
sm_cs2u_save                    # 保存当前 39 参数到 cs2unified.cfg  [ROOT]
sm_cs2u_save custom             # 另存为新预设 custom（≤12 套）     [ROOT]
sm_cs2u_reload                  # 重读参数配置 + menu.cfg 并立即应用 [ROOT]
sm_cs2u_rollback                # 回到上一次“应用预设前”的快照并落盘 [ROOT]
sm_cs2u_diag                    # 状态 + gamedata/配置路径/签名错误  [ROOT]
sm_cs2u_menudump                # 打印 7 个菜单页（常用/高级各一遍） [ROOT]
```

高级模式（给 ROOT）：

```
!cs2u                             # 常用 6 行；最后一行「高级模式」
# 点「高级模式」→ 7 行：追加配置与保存、DIY、诊断、3 个 ROOT 参数
# 再点「退出高级模式」回到常用；状态不写盘（会话内）
```

聊天入口：**`!cs2u`**（SourceMod 原生映射到 `sm_cs2u`）。`!menu` / `!c2u` 是常见命名空间，**默认不拦截**（`cs2u_menu_chat_alias 0`），避免与其它插件冲突；确实没有冲突时才 `cs2u_menu_chat_alias 1` 显式开启。`!admin` 未接管，仍是 SourceMod 自带 Admin Menu。

> **1.0.15 菜单**：常用/高级两个视图，7 个页面（预设、手感、移动与受伤、视觉与准星、状态、配置与保存 + 根），参数行内循环；`menu.cfg` 可热重载，校验失败回退默认并提示管理员。移动页末尾有两页是**代码拥有的三层页**：**详细移动数值**（根 → 移动与受伤 → 18 件武器速度，点一行后在聊天栏输入数值，立即写盘、末行可一键恢复默认）与 **环境适配**（根 → 移动与受伤 → 探测 / 预览 / 确认 / 撤销）。真人客户端点选/翻页仍是 `UNVERIFIED`。

> `sm_cs2u_set` 与菜单点选现在**立即持久化**：成功后回显 `OK: <cvar> = <value> (persisted)`，写盘失败则明确提示 `but persistence failed: <原因>`（此时内存值已改、磁盘仍是旧值，换图会回退）。该行为已修复并复验（`set 2.4` → `changelevel` → 仍 `2.400`）。`cs2u_enable 0` 时这些写命令会被拒绝，`status`/`diag` 仍只读可用。
>
> **所见即所中**：`cs2_matched`（也是内置默认）、`cs2_tracer` 与 `cs2_full` 都是 recoil 1.0 / ballistics 0 / spread 0；`cs2_split` 是“相机−弹道分离”，不是所见即所中。服务器 cfg 可能把 `cs2feel_recoil_scale` 改成别的值，要强制一致就重新应用 `cs2_matched` 或 `cs2_full`。**客户端侧**的相机分离（Left4Neko `l4n_view_punch_scale`）不在预设里：服务器检测不到/设置不了它，装了且设了 k≠1 的客户端相机会按 k 偏，而子弹/命中/弹孔仍是同一个——这是客户端自选，见 `client\cs2u_client_l4n.cfg`。
>
> **`cs2_full` 与滑行**：它把 39 个受管值全部显式写死，包含 `cs2movement_crouch_slide 1`、`crouch_slide_time 0.20`、`crouch_slide_min_speed 100` 与 `crouch_slide_client 1`（客户端半开启：两端同滑；它驱动的是全局 cvar，所以插件内置了「只有一个幸存者在滑行且没有别人蹲着」的门控，不满足时退回服务端单边）。这个滑行是项目对 **CS2 蹲下过渡**的近似（跑动按蹲保留动量、指数衰减到蹲速），**不是** CS2 里独立存在的“滑铲技能”；要严格无滑行就把 `cs2movement_crouch_slide` 设 0。详见 [docs\06_已知限制.md](docs/06_已知限制.md) L20。

### 4.4 还原

```powershell
# 默认 DRY-RUN：只打印会删除/恢复哪些文件
powershell -ExecutionPolicy Bypass -File .\tools\uninstall.ps1

# 真正回滚：默认优先使用 _backup\project-manifest.csv（每路径首次备份）
powershell -ExecutionPolicy Bypass -File .\tools\uninstall.ps1 -Apply

# 只想撤销某一次部署：显式指定该次的时间戳目录
powershell -ExecutionPolicy Bypass -File .\tools\uninstall.ps1 -Apply -BackupDir .\_backup\20261031-180836
```

- **默认（project-manifest）** = 回到“项目引入前”：移除 `cs2unified.smx`、把 4 个 legacy（含探针）移回 `plugins\`、删除仅剩 `cs2unified.cfg(.bak)` 的运行期配置目录。
- **单次（`-BackupDir`）** = 只撤销那一次部署的动作，适合“部署回退一步”，不适合“彻底卸载”。
- 还原后重启 srcds；脚本会打印 `UNINSTALL manifest=...` 与逐行动作（实测 15 行）。

---

## 5. 命令一览

| 命令 | 注册权限 | 说明 |
|---|---|---|
| `sm_cs2u` / `sm_cs2u_menu` | `RegConsoleCmd`（内部再判 `ADMFLAG_GENERIC`） | 打开菜单；服务端控制台调用会提示 client-only |
| `sm_cs2u_status` | `ADMFLAG_GENERIC` | 打印统一层/配置/feel/movement 状态 |
| `sm_cs2u_presets` | `ADMFLAG_GENERIC` | 预设列表 |
| `sm_cs2u_set <cvar> <value>` | `ADMFLAG_GENERIC`（3 个 ROOT 参数在命令内逐项拒绝） | 单参数写入：校验 → 写 ConVar → 立即持久化 |
| `sm_cs2u_preset <name>` | `ADMFLAG_ROOT` | 应用预设 + 快照 + 落盘 |
| `sm_cs2u_save [preset]` | `ADMFLAG_ROOT` | 保存 settings / 覆盖或新建预设 |
| `sm_cs2u_reload` | `ADMFLAG_ROOT` | 重读配置（失败保留上一版） |
| `sm_cs2u_rollback` | `ADMFLAG_ROOT` | 回滚到预置快照并落盘 |
| `sm_cs2u_diag` | `ADMFLAG_ROOT` | 诊断输出 |

上游命令原样保留：`sm_cs2feel_status|reload|verify|spreadtest|recoiltest|ballisticstest`、`sm_cs2movement_status|apply|unapply|reload|selftest`。

> 权限入口与菜单一致：`sm_cs2u_set` 注册为 `ADMFLAG_GENERIC`，3 个 ROOT 参数（`cs2movement_maxspeed` / `weapon_speed_mode` / `base_speed`）在 `Cmd_Set` 内逐项拒绝。菜单与命令走同一套 `CS2U_IsAdmin` / `CS2U_IsRoot` 判定。详见 [docs\02_菜单结构.md](docs/02_菜单结构.md) §4。

---

## 6. 目录结构

```text
CS2Unified_L4D2\
├─ README.md                     # 本文件
├─ NOTICE                        # 三方组件、来源与修改说明
├─ LICENSE                       # GPL-3.0（复制自 ..\CS2Movement_L4D2\LICENSE，未改写）
├─ docs\                         # 00~06 设计与运维文档
├─ src\
│  ├─ cs2unified.sp              # 唯一 myinfo + 唯一回调出口 + 分发顺序
│  ├─ cs2u_shared.sp             # 统一层全局/常量（32 参数槽、8 预设、32 条目、32 KiB 缓冲）
│  ├─ cs2u_params.sp             # 39 个受管参数表（feel/movement/injury/water/tracer）
│  ├─ cs2u_weapon.sp             # 18 件武器速度表：菜单页 + 聊天输入 + 写盘
│  ├─ cs2u_core.sp               # 生命周期、权限、日志、命令注册、状态输出、聊天别名
│  ├─ cs2u_config.sp             # KeyValues 读写、校验、.bak、快照/回滚
│  ├─ cs2u_modes.sp              # 7 套内置预设（含 cs2_tracer/cs2_full）与原子应用
│  ├─ cs2u_menu.sp               # 两级菜单（7 页 + #8/#9）与 7 个 handler
│  ├─ cs2u_layout.sp             # menu.cfg 解析/校验/默认布局/热重载
│  ├─ cs2u_auth.sp               # SteamID > 组鉴权与 AUTH-* 日志
│  ├─ feel\                      # 【生成】cs2feel 0.5.7-m11，5 个文件
│  └─ movement\                  # 【生成】上游 0.5.2 5 个 + patch 0.5.3：cs2movement_water.sp
├─ tools\
│  ├─ sync_sources.ps1           # 上游 → src\ 的机械重命名（-Check 供验收）
│  ├─ build.ps1                  # spcomp 编译；-Sync / -StrictWarnings
│  ├─ verify.ps1                 # 65 项静态验收
│  ├─ deploy.ps1                 # 备份 + 安装 + 停用旧插件 + 清单
│  └─ uninstall.ps1              # 按清单还原（默认 dry-run，-Apply 执行）
├─ tests\
│  ├─ rcon.ps1                   # 正确的 Source RCON 客户端（EXEC=2）
│  └─ results\                   # 启动/运行日志与 runtime-smoke.md
├─ configs\
│  ├─ cs2feel\                   # weapons.cfg / native_baseline.cfg / punch_sequences.cfg / presets\
│  ├─ cs2movement.cfg            # movement 的 AutoExecConfig 模板
│  ├─ cs2movement_weapons.cfg    # 武器速度表（18 条）
│  └─ cs2unified\cs2unified.cfg  # 统一层配置（schema/version/active_preset/presets/settings）
├─ gamedata\                     # l4d2_cs2feel.txt / cs2movement.txt（均 Windows-only）
├─ addon\
│  ├─ addoninfo.txt              # 数据层 VPK 的元数据源（908 B）
│  └─ cs2feel_r2_plugin.vpk      # 数据层 VPK，85,318 B（与上游 .vpk 同 SHA256）
├─ build\cs2unified.smx          # 构建产物（不入库策略由维护者决定）
└─ _backup\<时间戳>\             # deploy 的备份与 install-manifest.csv
```

---

## 7. 兼容性

| 项 | 要求 | 依据 |
|---|---|---|
| 游戏 | Left 4 Dead 2，**Windows**（listen 或专用服） | gamedata 仅 `windows` 键 |
| 游戏版本 | `PatchVersion 2.2.4.3`，`server.dll` 9,130,288 B，SHA256 `A93EC916A8F26FBEA85688C321D2BA8DD346D435FAB09A0B926DD950C2E1EA12` | `gamedata\l4d2_cs2feel.txt` 头部；`cs2movement.txt` 三个签名同样绑定该构建 |
| SourceMod | **1.12**（实测 `1.12.0.7230`，编译器 `spcomp 1.12.0.7210`） | DS 实测；`build.ps1` 默认取该 DS 的编译器 |
| MetaMod:Source | 1.12 | DS 实测 |
| DHooks | 需要（movement 引擎层三条 detour） | 缺失时自动降级为仅全局 `sv_*`，不会崩服 |
| tickrate | 默认 30 tick；64 tick 需 **L4DToolZ + tickrate enabler** | 实测 DS 启动日志 `[L4DToolZ] tickrate: 64`；上游 D8 |
| Linux | **不支持** | 两份 gamedata 无 `linux` 键，feel 会 fail-closed 拒绝激活 |
| 数据层 | 客户端与服务器需**同版本** `cs2feel_r2_plugin.vpk` | 加载期资产，双端不一致会导致表现分裂 |

---

## 8. 已知限制摘要

1. **改值现在立即持久化（H-01 已修复并复验）**：菜单/`sm_cs2u_set` 成功写 ConVar 后会同步写盘并回显 `(persisted)`；写盘失败会明确提示，此时换图会回退。写失败场景本身未制造磁盘故障实测（代码路径）。
2. **数据层不可热切换**：VPK 的 `scripts\weapon_*.txt` 只在加载期生效；预设只覆盖运行时 ConVar。
3. **基线已统一**：合并的是 `CS2Movement_L4D2.public` 当前源码（movement 0.5.2，2026-11-01 本地 bump，未打 tag；上一发布 tag 为 `v0.5.1`），线上二进制仍是 0.5.1；数据层 VPK 仍需客户端/服务端成对部署。
4. **无真人客户端验证**：菜单点选、可选 `!menu` 别名与 basechat 的交互（默认关闭）、多人/远程手感与预测回拉都未验证。
5. **Windows-only + 单一游戏构建绑定**：游戏更新后必须重扫签名，否则引擎层自动关闭。
6. **movement 部分层是服务器单边修正**（`air_jump_speed`、`lowspeed_sustain`、`crouch_slide` 等），客户端预测仍有代价；不要把它当作“零成本还原 CS2”。
7. **配置损坏处理是 fail-closed**：整份拒绝、保留上一版；启动时主文件缺失/被拒会从 `.bak` 恢复一次（`CONFIG-RESTORED/RECOVERED-FROM-BAK`）。崩溃窗口与磁盘写失败未逐一实测；>32 KiB 截断行为也未实测。
8. **曳光是纯视觉且默认关闭**：服务端画 beam 给所有客户端看，不改命中；精灵缺失时自动 no-op（会记 `TRACER-SPRITE-MISSING`）。真人“看得见弹道”未验证。
9. **高级模式只是可见性**：它只决定是否渲染 ROOT/低频行，不放大任何权限；ROOT 动作仍在 handler 内二次判权。`cs2u_simple_mode` 是旧版兼容 ConVar，1.0.5 菜单不再据此切换视图。
10. **`cs2_full` 覆盖 39 个受管值**：未纳入统一层的 engine cvar（`sv_accelerate` 等）仍由 `cs2movement.cfg` / 上游默认负责；它的“完全仿真”是这些受管值的 CS2 最近设定，不是逐项引擎等价。
11. **`cs2_full` 的滑行是近似**：`cs2movement_crouch_slide 1` 近似 CS2 蹲下过渡（动量指数衰减），**不是** CS2 原生的独立滑铲技能；严格无滑行设为 0。
12. **受伤减速依赖服务器每 tick 重写速度**：客户端预测/回拉仍存在；真人低血量观感未验证（`injury_enable=1`、ratio 132/220）。
13. **卸载默认已按 `project-manifest.csv` 还原**（H-02 已修复并复验：4 条 `ALREADY-DISABLED`、15 行清单、legacy 回位、运行期配置清理）；`-BackupDir` 只用于“只撤销某一次部署”。进程在动作之间被强杀的窗口未逐一模拟。
14. **许可待确认**：`..\CS2FeelVScript_L4D2` 仓库内**未见 LICENSE 文件**；本项目按 GPL-3.0 发布并保留来源说明，再分发前请与 cs2feel 作者确认授权（详见 [NOTICE](NOTICE) §5）。

完整版见 [docs\06_已知限制.md](docs/06_已知限制.md)。

---

## 9. 文档索引

| 文档 | 内容 |
|---|---|
| [docs\00_整合设计.md](docs/00_整合设计.md) | 模块职责（含 `cs2u_visual.sp`）、回调分发顺序与理由、fail-closed 设计、为什么单 `.smx` |
| [docs\01_符号映射表.md](docs/01_符号映射表.md) | 14 + 19 条重命名表、冲突清单、保留的公开接口、上游升级流程 |
| [docs\02_菜单结构.md](docs/02_菜单结构.md) | 两级菜单树、info id、鉴权、menu.cfg、热重载、反馈与验收 |
| [docs\03_配置schema.md](docs/03_配置schema.md) | KeyValues schema、校验规则、保存/重载/回滚/BOM、容量上限 |
| [docs\04_部署与回滚.md](docs/04_部署与回滚.md) | 构建前置、产物清单、旧插件停用原因、备份/清单、卸载回滚、VPK 双端 |
| [docs\05_测试清单.md](docs/05_测试清单.md) | **65 项**静态检查逐项、编译尺寸、运行时命令与实测结果、未验证项 |
| [docs\06_已知限制.md](docs/06_已知限制.md) | 全部限制与风险的工程化描述 |

---

## 10. 许可与归属

- 本项目以 **GNU GPL-3.0** 发布（继承自上游 CS2Movement_L4D2）。许可证全文见 [LICENSE](LICENSE)，**逐字节复制自 `..\CS2Movement_L4D2\LICENSE`**（35,147 B，SHA256 `8CEB4B9E…`），未做任何改写。
- 来源与修改说明见 [NOTICE](NOTICE)：cs2feel / cs2movement 的出处、本项目所做的机械重命名与新增统一层、SourceMod 与 DHooks 的归属。
- SourceMod / MetaMod / DHooks 由 AlliedModders 及其贡献者以 GPL-3.0 发布，本项目**不随附**其二进制（DHooks 需另行安装）。
- Left 4 Dead 2、Counter-Strike 2、Source 为 Valve Corporation 的商标；本项目与 Valve、AlliedModders 无隶属或背书关系。
