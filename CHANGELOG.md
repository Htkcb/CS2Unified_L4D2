# Changelog

本文件记录 CS2Unified_L4D2 的所有重要变更。

格式基于 [Keep a Changelog 1.1.0](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本 2.0.0](https://semver.org/lang/zh-CN/)。
上游版本见 `src\cs2unified.sp` 的 `CS2U_VERSION` 与启动日志
`[CS2Unified] LOAD version=<cs2u> feel=<cs2feel> movement=<cs2movement>`。

## [1.0.16] - 2026-11-08

### Changed

- **蹲下滑行时间档位调整**：
  - `cs2_full` 与 `cs2_competitive` 预设的 `cs2movement_crouch_slide_time` **0.45 → 0.35**
    （滑行手感档下调；`crouch_slide_min_speed 100`、`crouch_slide_client 1` 不变）；
  - 简易/高级菜单的「滑行档位」循环从 4 档扩到 **5 档**：
    `0.20 / 0.35 / 0.40 / 0.45 / 0.50`（行文案同步更新）；
  - 高级参数循环候选值加入 **0.35**、移除 **0.70**（候选容量 8 不变，该参数仍占满 8 档）。
- `tools/verify.ps1` 两条预设契约同步为 0.35（检查总数不变，仍 145 项）。

## [1.0.15] - 2026-11-08

### Fixed

- **撤销消息漏数档位通道**（全菜单审计时用 `sm_cs2u_menusel` 回放 `apply → undo` 发现）：
  撤销纯档位适配（64 Hz 的常见情况，只改 `cs2feel_spread_tick_profile`）时，消息显示
  **「0 个值回到适配前」**——实际档位已正确还原，只是计数只数了受管参数通道，没数档位通道。
  现在 undo 与 apply 同口径：两个通道都计入（纯档位适配显示「1 个值」）。

### Audit（1.0.14 全菜单审计，本次无其它发现）

- 24 个 `act:` 行 id ↔ 24 个分发分支一一对应；`cyc:` / `preset:` / `wpn:` / `diy.*` /
  `env.*` 解析路径全部正确；`nav:` / `adv.*` 不加页后缀（不在 `InfoNeedsPage` 名单），
  Root 的 `info[4]` 截取安全；`env.info.*` 两行是 `ITEMDRAW_DISABLED`（点不了，符合设计）。
- 测试服实测 `sm_cs2u_menudump`：12 份页面 dump（9 高级 + 3 基本视图第二轮），
  **无一空布局**；env 页 7 行、move 页 33 行（5 页）、weapons 页 21 行（18 武器 + reset）全部正确渲染。
- 8 个子系统命令逐个探活（status / diag / presets / weapons / feel_status / feel_verify /
  movement_status / movement_selftest）全部应答；`env` 四动作经菜单分发器端到端回放
  （preview → apply → undo → 未知 id 拒绝）全通。
- 今日 SourceMod 错误日志只有第三方插件 `survivor_chat_select.smx` 的签名提示，与本插件无关。
- `tools\verify.ps1` 新增 1 项契约（undo 消息计两通道），**144 → 145**。

## [1.0.14] - 2026-11-08

### Fixed

- **环境适配页的四个动作按钮点了没反应**（1.0.13 的菜单 bug，真人首次点选时发现）：
  行 id 是 `env.preview`（**点号**分隔），而 `CS2U_MenuEmit` 会给每行追加 `:<页码>` 后缀；
  旧 handler 只按冒号切分，`parts[1]` 拿到的是 `"0"` 而不是 `"preview"`，
  于是 detail / preview / apply / undo **全部静默落空** —— 返回键能用，纯粹因为它的 id 是 `back`（无后缀）。
  证据：客户端 SourceMod 日志有 `MENU-SELECT ctx=env info=env.preview:0` 却没有任何后续输出。
  现在解析改为**先按冒号剥页码、再按点号取动作**（与 weapons 子页同一约定）。
- 点过动作后，页面标题会带上**上一次动作的结果**（`预览：3 项待确认` / `已适配，改 3 项` 等）——
  聊天输出一闪而过，四个能用的按钮看起来像坏的，这个反馈缺口本身就是 bug 报告的一半。

### Added

- 回归命令 `sm_cs2u_menusel <env.detail|env.preview|env.apply|env.undo>[:page]`（ROOT）：
  把一行原始菜单 id 喂给**菜单真正用的那个分发器**，不需要客户端就能回放菜单点选。
  1.0.13 正是因为没有这条路，测试套件才全部绿灯、真人一点就穿帮。
- `tests\env_runtime.ps1` 新增 **6b 菜单行回放**节：对 `env.detail/preview/apply/undo`
  各回放一次并断言输出形态；`tools\verify.ps1` 新增 3 项契约（按点解析、无冒号解析残留、
  回放命令存在），**141 → 144**。

## [1.0.13] - 2026-11-08

### Changed

- **特感不再被手感层碰到（只影响幸存者）**：`OnPlayerRunCmd` 里对 feel 三层
  （recoil / ballistics / spread）加了一道队门 —— **只跳过 3 队（特感）**，
  幸存者、旁观者、未分配客户端**逐字节不变**。这三层是 1.0.13 之前唯一没有按队门控的
  逐玩家路径：它们由引擎对每个客户端调用，而特感不开枪，所以在特感身上只可能做坏事
  （recoil 键在共享的 `IN_ATTACK` 上——爪击/扑击/舌头都用它；spread 会写开火者的武器对象）。
- 新 ConVar `cs2u_feel_survivor_only`（默认 **1**）。设 0 回到 1.0.13 之前的全队行为，
  不需要重编。它不是受管参数（39 个表不动），也不进预设。
- `sm_cs2u_status` 新增两行：
  - `team gate: feel_survivor_only=1 feel_skipped_infected=N movement_skipped_non_survivor=M`
    —— 两个计数器是"门控真的在拦人"的运行时证据；
  - `global physics: apply_global=… accel=/friction=/stopspeed=/airaccel=/gravity=/maxvel= …`
    —— 明说这几条是**引擎级**、特感也会跟着走，且 `sv_maxspeed` 从不写。

### Why not more (and what was already there)

- movement 的逐玩家路径**本来就**是幸存者专属（0.4.7 起的 `CS2M_IsSurvivor` + 跳过计数器）：
  `m_flMaxspeed`、蹲下三属性、`CGameMovement::Friction` 修正、滑行的复制属性、injury、water
  全都在门后；这回只是把"唯一漏掉的一层"补上，并把证据摆到状态页。
- **引擎物理 cvar 拆不开**：`cs2movement_apply_global` 写的是 `sv_accelerate/friction/stopspeed/
  airaccelerate`（`gravity`/`maxvelocity` 与原版同值，`sv_maxspeed` 自 0.4.8 起刻意不写，
  因为它会压住 Charger 冲锋）。L4D2 的 `CGameMovement` 从全局 cvar 读数，没有按队入口。
  要让特感完全原版，只能 `cs2movement_apply_global 0`，代价是幸存者失去 accel/friction 曲线 ——
  这是取舍，不是 bug，写进了 `docs/06` L26。

### Verification

- `tools/verify.ps1` **141/141 PASS**（新增 6 项 `team:`：feel 门存在、只跳过特感、
  开关默认 1、movement 12 处门控 + 5 处计数器、**从不写 `sv_maxspeed`**、状态页两行）。
- 编译 `build.ps1 -StrictWarnings` → **174,508 B，0 error 0 warning**。
- 运行时 `tests\results\env-runtime-20261108-115533.md`：**31/31 PASS**（1.0.13，幸存者侧未受影响）。
  其中状态块留下了门控的运行时证据：
  `team gate: feel_survivor_only=1 feel_skipped_infected=1 movement_skipped_non_survivor=3` ——
  测试服上确实有一个 3 队客户端被这道门拦下过。
- 顺带修掉 harness 的"半应答"漏洞：一条 RCON 请求带多条命令时，socket 在第一条之后断掉
  仍会留下 `### ` 标记、被当成成功；现在要求**标记数 == 命令数**，测试里也把
  `preview`/`apply` 拆成两次独立请求。
- **UNVERIFIED**：对抗服上真人变特感后"确实没有被写过"——测试服是 coop，没有特感客户端；
  静态契约与计数器已就位，判定口径写在 `docs/06` L26.3。

## [1.0.12] - 2026-11-07

### Added

- **环境适配（一次性把 tick 相关值对齐这台服务器）**：移动与受伤页末尾新增「环境适配」入口 →
  一页只读的探测 + 三个动作（预览 / 确认应用 / 撤销）。它回答的是这个项目一直没显式说过的那句话：
  **“这些值是在哪个 tick 下量的”**。
  - 探测（`sm_cs2u_env`，每行都注明来源）：`GetTickInterval()` 实测 Hz、`IsDedicatedServer()` 形态、
    `MaxClients` 槽位、在线人数、标定档（30 / 60 / 64 / 未标定）、
    `cs2feel_spread_tick_profile` 的「档位 / 规则解析 / 模块携带」三个值、
    受管项现值、以及 `sv_maxupdaterate` 建议（**只显示，从不写**）。
  - 适配顺序是**先预览、再应用**：预览只打印 `旧 → 新` 与理由，未确认前任何值都不动；
    应用只写预览里列出的项，全部成功或全部回滚；撤销能把内存与 `env` 段一起还原。
  - 幂等：已经对齐时预览/应用都说「无需改动」，不写盘、不记 ACTION。
- 新模块 `src\cs2u_env.sp`（探测 / 推荐 / 预览 / 应用 / 撤销 / 持久化）。
- 新命令 `sm_cs2u_env [status|preview|apply|undo|clear]`（ROOT）：
  `status` 是探测块，`preview`/`apply` 给 RCON 与脚本用，`clear` 只清「已存适配」标记、不动当前值。
- 启动日志新增 `ENV-PROBE hz=64.00 interval=0.015625 dedicated=1 band=64 ...`。

### Changed

- **推荐值是按实测档位算的，不是写死的 64**：
  - 64 Hz → `spread 档位 4（强制 64）`；`air_jump_speed` / `lowspeed_sustain` 保持不动（这里量过）。
  - 60 Hz → `档位 3（强制 60）`；两个 opt-in 若开着会被建议关掉（没量过）。
  - 30 Hz → `档位 0（关）`。**关就是 30 Hz 的标定**（TV-45/TV-56 标的就是默认 ConVar），
    强行写 2 反而会覆盖操作者自己的 duck/air 值。
  - 其它（如 100 Hz）→ 0 并注明「未标定，不猜」。
- **从不自动开启功能**：`air_jump_speed` / `lowspeed_sustain` 只会被建议**关**（当本机不是 64 tick 时），
  不会被建议开 —— 开不开是玩法决定，不是环境决定。
- `lowspeed_sustain` 与 `duck_speed_min > 0` 的互斥（D9）只**警告**，不替你选。
- 适配结果存进 `cs2unified.cfg` 的 **`env` 段**（`spread_tick_profile` / `adapted_hz` / `adapted_at`），
  换图、重启、热重载都会重新回填（`ENV-PROFILE-RECLAIM`）。
- **`cs2feel_spread_tick_profile` 不进受管参数表**（39/40 已到上限），走独立通道；
  因此 `sm_cs2u_set` 改不了它、预设里也没有它 —— 这是设计，不是遗漏。
- **tick 变了只提示、不偷改**：`OnMapStart` 重新量一次，与 `adapted_hz` 差 >2 Hz 时写
  `ENV-CHANGED` 并只在聊天里告诉在线 ROOT 管理员。
- `configs\cs2unified\menu.cfg` 的 `order.move` 加入 `act:env_adapt`；
  `CS2U_OrderAppendMissing()` 同样给旧 menu.cfg 补这一行（1.0.11 已经因旧配置踩过一次）。
- 状态页新增一行 `env: hz=.. dedicated=.. band=.. profile_cvar=.. stored=.. plan=..`。

### Tooling / CI

- `tests\lib\ds_harness.ps1`：`Start-DsServer` 增加 `-Tickrate`（默认 64）与 `-NoTickMod`
  （临时把 `l4dtoolz.vdf` / `tickrate_enabler.vdf` 改名，跑**真 30 tick**）；
  `Stop-DsServer` 无论怎么退出都会把 `.vdf` 还原，套件崩了也不会把测试服留在 30 Hz。
- 新增 `Get-SmLogLines`：`LogMessage`（ACTION 遥测）写的是
  `addons\sourcemod\logs\L<日期>.log`，**不在** `console.log` 里 —— 1.0.11 的负向断言因此一直
  是“真空通过”，这次顺手纠正。
- 新套件 `tests\env_runtime.ps1`（64 Hz 腿，CI 默认项）与 `tests\env30_runtime.ps1`
  （30 Hz 腿，同一个实现的 `-Phase B` 入口，按需跑：`ci.ps1 -Only env30`），
  覆盖 E-1…E-7；`tools\ci.ps1` 的 `$wanted` 加入 `env`。
  30 Hz 腿**故意不进默认门**：本机 30 tick 起服会偶发卡在 `Host_NewGame` 好几分钟
  （监听端口关闭、进程还活着；把本插件禁用后同样复现），那是这台机器的属性，不该让它把
  “保护功能”的门变红。
- 顺手修掉两处**让测试说谎**的基础设施问题：
  1. `LogMessage`（ACTION 遥测）写在 `addons\sourcemod\logs\L<日期>.log`，**不在** `console.log` 里
     —— 1.0.11 的“被拒的值没有记 ACTION”其实是一条真空断言。新增 `Get-SmLogLines`。
  2. RCON 的监听端口在 `Host_NewGame` 期间会短暂关闭（本机实测 5–15 s 窗口，插件多时更久），
     旧 `Invoke-Rcon` 把连接异常当成“答案”返回 —— “服务器正在载图”被误报成“功能坏了”。
     现在按 `### <cmd>` 标记判定成功、重试前先探测端口、`Wait-DsReady` 也先等端口再花一次认证。

### Verification

- `tools/verify.ps1` **135/135 PASS**（新增 20 项：模块存在、只有 `GetTickInterval` 可信、
  档位区间与 feel 模块一致、档位不进受管表、独立通道、预览门禁、全有或全无、撤销持久化、
  **0 处 `sv_*` 写入**、受管通道复用、ROOT 命令、`env` 段读写、换图回填、漂移只报告、
  菜单页/handler/行 id、GENERIC 看不到该行、旧 menu.cfg 兜底、menudump 覆盖、状态行）。
- 编译 `build.ps1 -StrictWarnings` → **174,010 B，0 error 0 warning**。
- 运行时 `tests\results\env-both-runtime-20261107-232617.md`：**54 / 54 PASS**（两轮合并版）与
  `tests\results\env-runtime-20261108-003830.md`：**31 / 31 PASS**（拆分后的 64 Hz 腿）。
  - 64 Hz：`plan=1`（只差档位）→ 未预览时 apply 被拒 → 预览不动值 → 应用后 `profile=4`、
    配置出现 `env` 段 → 再点一次「无需改动」、**ACTION 计数不增** → 撤销后 `profile=0`、`env` 段消失。
  - 30 Hz（`plan=3`）：`ENV-CHANGED` 如实记录 → 预览给出 `档位 4→0` + `air_jump 1→0` + `sustain 1→0`
    → 应用 → 撤销逐字回到 1/1/4。
  - 拆分后的入口：`tests\env_runtime.ps1`（31 项）与 `tests\env30_runtime.ps1`（22 项）。
- `tools\package.ps1` 的版本号不再写死：以前 `-Version` 的默认值是 `'1.0.0'`，升级后忘了传参就会
  产出 `CS2Unified_L4D2-v1.0.0-<日期>.zip`（本轮真的发生了）。现在默认读 `src\cs2unified.sp`
  的 `CS2U_VERSION`。
- 发布包 `dist\CS2Unified_L4D2-v1.0.12-20261108.zip`：**54 files / 673,917 B**，
  sha256 `E38A55A3EE506C645E253B0E6E3F496A0350D4A4CFEA440CA473CD1FD4195091`。

### Known limits

- 探不到 tick 增强插件本身：`L4DToolZ` / `tickrate_enabler` 是 **Metamod** 插件，SourceMod 没有 API，
  所以文案一律写“实测 64 Hz ⇒ 推断已生效”。
- 菜单页的真人点选仍是 `UNVERIFIED`（没有客户端环境）；静态契约与 RCON 路径都已覆盖。

## [1.0.11] - 2026-11-07

### Added

- **详细移动数值页**：移动页末尾新增「详细移动数值」入口，进入后是 **18 件武器**的
  当前移动速度（u/s）。点任意一行 → 聊天栏直接输入新数值（50–1000）→ 立即生效并写盘；
  列表末尾是「恢复默认数值（18 件）」。改过的行带 `*` 标记。
- 聊天输入模式：60 秒超时、输入「取消 / cancel / q」放弃、非数字与越界都会在聊天栏回显原因
  且不写入；生效后自动重开该页，数值不回退。
- 新命令 `sm_cs2u_weapons`（ROOT）：无参列出 18 件武器（`*` = 已改）；`<序号|类名> <速度>`
  设置；`reset` 恢复出厂。给 RCON/脚本用，也是运行时证据的入口。
- 新模块 `src\cs2u_weapon.sp`：有序武器表（类名 / 中文名 / 出厂值）、StringMap 读写、
  cfg 备份式重写、聊天输入状态机。

### Changed

- 武器速度**不进受管参数表**（39 个已到 `CS2U_MAX_PARAMS` 40 的上限），也不进预设：
  它是 `configs\cs2movement_weapons.cfg` 这份文件表的运行时视图，由本模块直接改写。
- `configs\cs2unified\menu.cfg` 的 `order.move` 加入 `act:weapon_speeds`；
  `CS2U_OrderAppendMissing()` 也会给旧 menu.cfg 补这一行（否则升级服的入口会消失）。
- 该页是菜单里**唯一的三层页**（根 → 移动与受伤 → 武器明细）；它不是 `CS2U_CTX_*` 上下文，
  没有自己的 `menu.cfg` 顺序，只有 ROOT 能进。

### Tooling / CI

- **`tools\ci.ps1`**：一条命令三段门（static → deploy → runtime），退出码即结论，
  产物 `tests\results\ci-<stamp>\{summary.md,summary.json,*.log}`。
- **运行时证据脚本升级成带断言的套件**，共用 `tests\lib\ds_harness.ps1`（起停 srcds、等插件真的
  应答 RCON、RCON 重试、检查记录器同时写 `.md` 与 `.json`）：
  `tests\water_runtime.ps1` 20 项、`tests\weapons_runtime.ps1` 26 项，失败即非 0。
- **`tools\install-hooks.ps1`**：写 `.git/hooks/pre-commit`（LF、无 BOM），只跑静态门（~5 s），
  `CS2U_SKIP_CI=1` 可跳过；运行时套件故意不挂钩子。
- 已有 srcds 在跑时默认拒绝，`-Force` 才替换；静态阶段失败会跳过 deploy/runtime。
- **新增静态检查** `tooling: non-ASCII .ps1 files have a UTF-8 BOM`：PowerShell 5.1 对无 BOM 的
  脚本按 ANSI 解析，中文断言会变乱码甚至破坏语法（新套件第一次就是因此解析失败）。verify 114 → **115**。

### Verification

- `tools/verify.ps1` **115/115 PASS**（新增 11 项：18 类表、默认/当前数组、写盘回退、
  reset、输入超时/取消/区间、console 注册、页面+handler+行 id、ROOT 门控、
  入口进 order 与随包 menu.cfg、旧 menu.cfg 补入口、say 先于别名吞行）。
- 编译 `build.ps1 -StrictWarnings` → **163,599 B，0 error 0 warning**。
- 发布包 `dist\CS2Unified_L4D2-v1.0.11-20261107.zip`：**53 files / 631,441 B**，
  sha256 `23AF2A79CF4B04BC41591CFDF2A7F72185D46243D844C6CA4520DFFF0B2CD7AF`。
- DS `c5m1_waterfront` 实测（`tests\results\weapons-runtime-20261107-162747.md`）：
  `LOAD version=1.0.11`；`sm_cs2u_weapons 3 200` → `已写盘` → 读回 200 →
  文件里 `"speed" "200"` → `sm_cs2movement_reload`（重读文件）后仍是 **200**（不回退）→
  `reset` → 读回 225、文件回到 `"speed" "225"`；越界 2000 与未知类名都被拒且不写盘；
  `sm_cs2u_menudump` 显示 `ctx=weapons pages=3 rows=21`（18 行 + 2 分组标题 + 恢复行），
  移动页末行为 `act:weapon_speeds`。
- **UNVERIFIED**：真人点行→聊天输入的完整交互（无客户端环境无法点菜单）；
  底层 `set → 写盘 → 重载不回退` 已由 console 路径证明。

## [1.0.10] - 2026-11-07

### Added

- **水面高度减速（movement 0.5.3）**：幸存者按 `m_nWaterLevel`（1 踝 / 2 腰 / 3 眼）减速，
  `factor = 1 - cs2movement_water_slowdown * level/3`，默认 0.35 ⇒ 踝 0.883 / 腰 0.767 / 眼 0.650。
  叠加在受伤减速**之后**（两者都只降不升），感染者/特感/Tank 完全不受影响。
- 新模块 `patches\movement_water\cs2movement_water.sp` + `apply.ps1`。`tools\sync_sources.ps1`
  在“复制 + 重命名”之后应用 patch，`-Check` 走同一套变换，`src\movement\` 因此变成 **6 个文件**。
- 新命令 `sm_cs2movement_water [level]`：打印曲线表、实际 factor，以及（控制台调用时）每个已连接
  客户端的 `level / prop=send:data / in_water`。
- 统一层 2 个受管参数：`cs2movement_water_enable`、`cs2movement_water_slowdown`（37 → **39**），
  菜单新增「水面减速」分组（`cs2u_layout.sp` 默认布局里排在受伤减速之后）。

### Changed

- `cs2_full` 与 `cs2_competitive` 各写满 **39** 条；`vanilla` 显式 `water_enable 0`。
  新增 `CS2U_ModesEnsureWater()`：旧配置/自定义预设缺这两个键时补齐，避免切预设后残留上一个值。
- `cs2u_core.sp` 状态页新增 `water: enable / slowdown / ankle / waist / eyes / caps` 一行。
- `configs\cs2unified\menu.cfg` 的 `order.move` 加入水面两项。
- `tests\rcon.ps1` 的认证判定改为按 id（这台 L4D2 DS 把 AUTH_RESPONSE 当 `type 0` 回，
  旧代码只认 `type 2`，一直报 `RCON AUTH FAILED`）。

### Fixed

- **旧 `menu.cfg` 会隐藏新参数**：`deploy.ps1` 用 onlyIfMissing 安装 `menu.cfg`，升级服保留旧文件，
  新参数就永远不出现在菜单里。新增 `CS2U_OrderAppendMissing()`：加载时把“属于该页但 order 里没有”
  的受管参数**追加**到末尾（不重排、不重复）。DS 上未更新的 `menu.cfg` 实测生效（水面两项出现在移动页末页）。

### Verification

- `tools/verify.ps1` **103/103 PASS**（新增 13 项：patch 生效、两个调用点、survivor gate、曲线、
  config clamp、water 参数/分组/表头/预设 39 条、旧 menu.cfg 兜底、状态行）。
- 编译 `build.ps1 -StrictWarnings` → **157,825 B，0 error 0 warning**。
- 发布包 `dist\CS2Unified_L4D2-v1.0.10-20261107.zip`：**53 files / 614,470 B**，
  sha256 `232AAB69CCA2131BCAA0A41757BCCE8A5DFDA488AC2FB903FEEEA4B379608F21`。
- DS `c5m1_waterfront` 实测（`tests\results\water-runtime-20261107-160518.md`）：
  `LOAD version=1.0.10 feel=0.5.7-m11 movement=0.5.3`、`managed_params=39`、
  曲线 `0.8833/0.7666/0.6499`、实时改 0.50 后 `0.833/0.666/0.500`、
  `Applied preset 'cs2_full' (39 parameters)`、`PERSIST-APPLY params=39`、
  `m_nWaterLevel` 在 netprops（2 bits，offset 575）与 datamaps（1 byte）均存在。
- **UNVERIFIED**：真人客户端在水里的减速观感与“离水立即恢复”（需要一名玩家实测）；
  level 3（游泳）是否吃 `m_flMaxspeed` 同样待实测。

## [1.0.9] - 2026-11-04

### Changed

- **预设全部中文化**（显示名；内部 key 不变，`sm_cs2u_preset` 与配置文件仍用 ASCII）：
  `vanilla` = 原版、`cs2_matched` = CS2 匹配、`cs2_split` = CS2 原生分离、
  `movement_only` = 仅移动、`cs2_competitive` = CS2 竞技移动、`cs2_tracer` = CS2 匹配 + 曳光、
  `cs2_full` = CS2 完全仿真、`diy_*` = DIY 高级 / DIY 简单。
  预设行格式：`中文名（内部 key）[active]`；应用回显同样带中文名。
- **`cs2_competitive` 的滑行 0.20 → 0.45**，与 `cs2_full` 统一（菜单四档循环不变）。

### Fixed

- `tools/verify.ps1` 丢了 UTF-8 BOM：PowerShell 5.1 会按 ANSI 解析脚本，导致 `'权限不足'`
  这类中文断言变成乱码、出现**假失败**。已补回 BOM，并给 `tools\*.ps1` 全部加了非 ASCII 检查。

### Verification

- `tools/verify.ps1` **90/90 PASS**（新增中文标签、预设行格式、竞技滑行 0.45 三项）。
- DS 实测：`sm_cs2u_preset cs2_full` → 37 参数；配置里 `cs2_competitive` 与 `cs2_full` 的
  `cs2movement_crouch_slide_time` 同为 `0.45`。

## [1.0.8] - 2026-11-03

### Fixed

- **`cs2_full` 的滑行值 1.45 → 0.45**：1.45 是录入时的笔误（用户 2026-11-03 更正）。
  `cs2movement_crouch_slide_time` 回到菜单里既有的四档循环（0.20 / 0.40 / 0.45 / 0.50），
  预设取 **0.45**（长滑行手感档；CS2 数值档仍是 0.207）。菜单「滑行档位」行的 1.45 档同时撤掉。

### Verification

- DS 实测 `sm_cs2u_preset cs2_full` → 37 参数应用，"`cs2movement_crouch_slide_time` = 0.450000"，
  回读 `cs2u_bmode=1`、`cs2feel_ballistics_scale=1.200000`。
- `tools/verify.ps1` **87/87 PASS**（检查项改为断言 0.45）。

## [1.0.7] - 2026-11-03

### Changed

- **`cs2_full` 预设重设**，与手感层对齐：
  - 弹道模式 → **单人·TR-40**（`cs2u_bmode 1`）：预设现在显式写 `recoil_scale 1.0` /
    `recoil_view_scale 1.0` / `ballistics_mode 1` / `ballistics_scale 1.20` / `ballistics_yaw 1`，
    即相机 1.00×表值、弹道 2.20×表值、弹孔比准星高约 **4.98°**。
  - 蹲下滑行 → **`cs2movement_crouch_slide_time 0.45`**（旧值 0.20 是 CS2 数值档 0.207 的近似；
    0.45 是菜单里既有的长滑行手感档，用户 2026-11-03 指定；`1.45` 是当时打错的值，已改回）。
  - 其余 37 个受管值保持「尽可能贴近 CS2」：扩散走数据层（`spread_mode 0`）、曳光关、
    武器速度表 CS2、`base_speed 250`、低速度维持/空中速度/蹲速全开。
- **应用预设时聊天栏给出客户端设置提示**（`CS2U_PresetClientHint`）：TR-40 档提示
  `cs2feel_aimsync.ini` 的 `ratio = 1.200000` / `enable=1` / `yaw=1`、Left4Neko 保持
  `l4n_view_punch_scale 1.0`（不要 1.10）、以及“没装插件也能玩，子弹/命中不受影响”；
  其它预设提示 ratio 用 0.0 即可。服务器端永远无法代设这些客户端值，只能当场说清楚。

### Verification

- DS 实测 `sm_cs2u_preset cs2_full` → `Applied preset 'cs2_full' (37 parameters); persisted`，
  回读 `cs2u_bmode=1`、`cs2feel_ballistics_scale=1.200000`、`cs2movement_crouch_slide_time=0.450000`，
  `settings` 段同步。
- `tools/verify.ps1` **87/87 PASS**（新增 cs2_full TR-40 / 滑行 0.45 / 客户端提示 三项）。

## [1.0.6] - 2026-11-03

### Changed

- **「单人·TR-40」替换原来的「单人（CS2 原生分离）」**（`cs2u_bmode 1` 语义变更）：新档
  `recoil_scale 1.00 / view 1.00 / ballistics_mode 1 / ballistics_scale +1.20 / yaw 1` →
  相机 4.1–4.25°、弹道 ≈9.0°、**弹孔比准星高 4.98° ± 0.11°**，与旧 TR-40 台架的 5.225° 差 −4.7%
  （真机实测 97 发，证据 `docs/evidence/tr40-gap-20261103/`）。旧「单人」把弹着压在准星下方 0.48°，
  既不是想要的观感又仍要客户端插件，故退役；CS2 原样结构仍由「后坐结构」行 / `cs2_split` 预设负责。
- 循环行由四档变三档：**自动 → 单人·TR-40 → 多人 → 自动**；旧持久化值 `3`（1.0.5 的弱爬升 +0.30）
  在 `CS2U_BmodeBase` 里自动迁移到 `1`，不会把配置判为无效。
- 客户端要求随之收紧：单人·TR-40 档**必须**让 `cs2feel_aimsync.ini` 的 `ratio = 1.200000`
  （菜单行与切换回显都会提示），否则弹孔贴相机、看不到爬升（子弹/命中不受影响）。

### Verification

- `tools/verify.ps1` **84/84 PASS**（把“四档循环”检查改为“三档 + TR-40 常量 + `(base + 1) % 3`”）。
- 构建 153,193 B / 0 warning；真机 gap 实测见上。

## [1.0.5] - 2026-11-03

### Added

- **两级菜单改版（常用 / 高级，7 个页面）**：根菜单常用 6 行 / 高级 7 行，
  子页固定为 `presets` / `feel` / `move` / `visual` / `status` / `config`；
  最大层级从 3 降到 2（取消 37 个值页，参数改为行内循环）。
- **`menu.cfg` 布局配置**：`configs/cs2unified/menu.cfg` 控制预设/分组顺序、
  常用视图可见性、配置/DIY/诊断页权限、`confirm_destructive`、`telemetry`。
  可调键 20 项上限；`sm_cs2u_reload` 同时热重载参数与菜单；解析失败整段回退
  内置默认布局并写 `MENU-CONFIG-FALLBACK`，管理员下次开菜单时收到提示。
- **SteamID 列表 > 管理员组鉴权**：`menu.cfg` 的 `auth` 段支持
  `"STEAM_x tier"` 与 `"Group Name tier"`；冲突以 SteamID 为准并写
  `AUTH-CONFLICT`。无 `auth` 段时保持原 SourceMod flag 路径（`source=flag`）。
  非管理员不打开菜单，提示“权限不足”，写 1 条 `AUTH-DENIED`。
- **`sm_cs2u_menudump`（ROOT）**：不需要客户端即可把 7 个页面的分页/行内容
  打到服务端控制台，用于静态验收（`MENU-DUMP`）。
- **`MENU-SELECT` 遥测**：记录每次选择的 ctx / info / SteamID / tier，
  为后续 CTR 排序留数据。

### Changed

- 简易模式不再是独立根：常用视图就是默认根；`cs2u_simple_mode` 保留为
  兼容 ConVar，但新菜单不再根据它切换视图。
- “移动 + 受伤减速”合并为「移动与受伤」；“视觉辅助 + 相机页”合并为
  「视觉与准星」；根菜单的 `savecfg` / `reloadcfg` 收进「配置与保存」。
- 相机推荐项移除“1.10”（与当前服务器分离策略冲突），保留 0 / 1.0 / 说明。
- **7 套内置预设各补 `cs2u_bmode "0"`**：`cs2_full` / `cs2_competitive`
  从 36 条变 37 条，应用预设后轨迹模式不再残留；`CS2U_ModesEnsureBmode`
  会给旧配置里缺该键的预设补 0（已有值不覆盖）。
- 菜单文案统一为「中文 / English」（顶层/分组）与「中文：值（点此切换）」
  （参数/动作），参数行不再混排长英文。

### Fixed

- 菜单根页 `#8` 在首页从“上一页”改为“返回 / Back”。
- 分组标题只使用 `ITEMDRAW_DISABLED`（分页菜单允许的唯一样式），并保证
  标题不会单独落在页面末尾。
- 菜单回退错误不再只写日志：管理员下次打开菜单会收到一行提示。
- **弹道模式读数**：1.0.4 的“当前生效：多人 matched”只判断 single/multi，
  climb 落进 else 被误标；“单人·爬升（相机 0.30）”也是错文案（实际是
  相机 1.00 / 弹道 1.30）。1.0.5 的 `act:bmode` 行直接显示实时
  `相机 x.xx / 弹道 x.xx`，切换后聊天回读服务器结构与客户端
  `cs2feel_aimsync` ratio，避免把“已切换”看成“没切换”。
- **后坐结构误判 climb**：`CS2U_RecoilIsSplit` 原来只判断 `ballistics_mode != 0`，
  把 +0.30 的爬升也当成“分离”，导致结构行显示“CS2 原生（1.10/1.00）”，
  点一下还会在 `cs2u_bmode` 仍为 3 的情况下把结构改成 matched。现在按
  `ballistics_scale` 的正负区分 匹配/分离/爬升；结构行切换后 `cs2u_bmode`
  回自动，策略与结构不再互相打架。
- **弹道模式行只显示策略**：原行显示 `effective`，auto→multi 时看不出基值。
  现在显示“策略 + 实际结构 + 相机/弹道比例”，例如
  `弹道模式：自动（实际 匹配；1.00/1.00）`。
- **DIY 行翻页**：`preset:<idx>:<page>` 有两个字段，DIY 行
  `diy.apply.0:<page>` 只有一个；原来统一取 `parts[2]`，点 DIY 后总回到第 1 页。
  现在按行类型取页号。
- **控制台切换 bmode 不生效**：`sm_cs2u_set cs2u_bmode 3` 只写 ConVar，不写
  7 个结构值，菜单行正常而控制台“没反应”。现在该命令也会调用
  `CS2U_BmodeApply`，与菜单行等价。
- **重载后 ROOT 行消失一次**：`act:reload` 清空鉴权缓存，重建页面时未重新解析，
  管理员会看到少一截的页面。现在重建前按需重新 `CS2U_AuthCheck`。
- **配置校验缺口**：`perm.*` 原来接受任意非 "hidden" 字符串；`visible.basic`
  的 `config` 被接受但根常用视图并不渲染。现在 `perm.*` 只接受
  `root|hidden`，`visible.basic` 拒绝 `config`（高级视图专属），两者都会
  `MENU-CONFIG-FALLBACK`。
- **单人模式文案**：聊天原写“相机 1.21 / 弹道 1.00”，实际是 1.21/1.11；
  已改为“相机 1.21 / 弹道 1.11（比例 0.917）”。`aim-sync` 回读不再写死
  0.3/-0.090909，而是按当前结构计算期望 ratio（单人是 -0.082600）。
- **“推荐 0：相机冻结”只打印不生效**：`camera_zero` / `camera_off` 原来只回聊天
  命令，点完没有任何变化。现在通过 `ClientCommand` 直接下发
  `l4n_view_punch_scale 0/1.0`，并用 `QueryClientConVar` 回读；这是让 climb
  “准星静止、弹孔明显上爬”的关键一步（相机 1.0 时分离只有 punch 的 30%）。

### Verification

- `tools/verify.ps1`：84 项 PASS（0 失败），新增 7 ctx / 无值页 / 行内循环 /
  鉴权日志 / menu.cfg 回退 / 37 参数 / bmode 预设覆盖等静态检查。
- 测试服（`<DS_DIR>`）：1.0.5 加载成功；`sm_cs2u_menudump` 实测
  常用根 6 行、高级根 7 行、预设 7+DIY、移动 4 页、最大每页 7 行；
  `menu.cfg` 改顺序/可见性后 `sm_cs2u_reload` 立即生效；坏配置与 22 键
  配置均触发 `MENU-CONFIG-FALLBACK`；`cs2_full` 应用 37 参数、`cs2u_bmode=0`。
- **未验证**：真人客户端点选/翻页观感（沿用项目 `UNVERIFIED` 标注）。


## [1.0.4] - 2026-11-02

### Added

- **「后坐结构」开关（服务器侧一半 + 客户端 ini 一半，上游 D-058）**：简易模式第 2 页新增 `s.recoil`
  → 二级页「后坐结构 / Recoil structure」（`CS2U_MenuRecoil` / `MenuHandler_Recoil`，ctx `recoil`）：
  - `r.matched` / `r.split` 两个一次性切换，**只动 7 个受管参数**（先 `cs2feel_enable 1` + `cs2feel_recoil_mode 1` 打开 CS2 后坐链，再写结构那五个；`cs2_competitive` 预设出厂是关闭的，少了这两个开关就是静默空操作）
    （`cs2feel_recoil_view_scale` / `cs2feel_recoil_scale` / `cs2feel_ballistics_mode` /
    `cs2feel_ballistics_scale` / `cs2feel_ballistics_yaw`），走 `CS2U_ParamSet`
    （与 `sm_cs2u_set` 同一套校验与权限），末尾 `CS2U_PersistLive` 只写一次配置文件；
  - 页面标题与 `r.client` 行里的 `ratio` 是**从实时 cvar 推导**的
    （`ballistics_scale / recoil_scale`，`ballistics_mode 0` 时为 `0.0`），不写死；
  - `r.split` 应用后**复检客户端 Left4Neko**（`QueryClientConVar`；相机 k≠1 会与服务器分离叠加），
    并把客户端那一半的装法贴给管理员。
- **`client\cs2feel_aimsync.ini` 随包分发**：客户端一半（Left4Neko 插件 `cs2feel_aimsync.dll` 的配置），
  两个可用值 `ratio 0.0`（匹配）/ `-0.090909`（CS2 原生）。**只放 ini 不放 dll 没有效果；只放 dll 没有副作用**。
  dll 本体在上游 `CS2FeelVScript_L4D2` 的 `client_src\cs2feel_aimsync\`（决策 D-058，全文 `docs/TR40/README.md`）。
- 文案修正：`cs2_split` 预设行尾注记由「弹孔不跟随」改为「弹孔要看客户端装没装 aim-sync」；
  `OnL4NQuery` 里两条 `cs2_split` 提示改为指向客户端 aim-sync
  （旧提示教人改用 `cs2_matched` + 客户端 `l4n_view_punch_scale 1.10`——那是没有客户端组件时的唯一办法；
  有了 aim-sync 之后 `cs2_split` + 客户端 ini 才是「弹孔说真话」的正路）。

### Changed

- `client\cs2u_client_l4n.cfg` 的默认值 **`1.10` → `0`**（2026-11-02）：本包服务器现在跑 CS2 原生分离，
  玩家的相机若再按 1.10 缩放会**双重分离**（相机 1.10 × 服务器 1.10）。`0` = 准星冻结、可见弹孔按 1.00 倍表值往上爬
  （= 旧 TR-40 那种「准星在弹道下面、弹道像 CS2 一样爬升」的观感）；想要相机后坐反馈的玩家用 0.1–0.3，或 1.0 关掉相机分离。
- **弹道模式页（单人 / 多人，`cs2u_bmode` 0 auto / 1 single / 2 multi）**：`!cs2u` → 简易模式 → 第 2 页 →「弹道模式」。
  单人 = 服务器双通道（相机 5.95° / 弹道 5.47°），弹孔跟随需客户端 aim-sync；多人 = 服务器 matched，
  所有客户端弹道一致、不存在"所见≠所中"，分离交给客户端相机。auto 按未装 aim-sync 比例 u 分支
  （u<20% 单人 / 20–50% 单人+提示 / >50% 多人；未知按未装计）。规范与 13 项验收见 `docs\07_弹道模式.md`。
- **`l4n_view_punch_scale` 回到 1.0**（本栈的 CS2 相机比例由 `recoil_scale 1.21` 承担；1.10 会叠成 1.33×标称值、兑现后 6.54°，超 CS2 +8%）。
- `CS2U_VERSION` **1.0.3 → 1.0.4**；受管参数 **36 → 37**（新增 `cs2u_bmode`）——这套开关没有新增 cvar，只是把已有的 5 个按结构成套写。
- 静态验收 **65 → 69 项**（`tools\verify.ps1` 新增 4 项：recoil 页接线 / 5 写 + 1 次持久化 / ratio 由 cvar 推导 / client ini 随包）。

### Note

- 「弹孔跟随命中」的**像素级**证据仍未取。本版保证的是：客户端装上 aim-sync 后弹孔按 `ratio × punch` 移动
  （AK 满自动 punch≈5.9° ⇒ **0.53° ≈ 7 px @1280×720/90°**）；但客户端预测吃的是**上一条命令**的 punch，
  满自动时可见后坐仍比真实子弹滞后一发份（实测 **1.76°**）。详见上游 `docs/TR40/README.md` §6.2 / §9。
- `1.0.2` / `1.0.3` 的条目当时没有写进本文件（改动见 `HANDOVER.md` §15：相机检测页、滑行档位 0.45）。

## [1.0.1] - 2026-11-01

### Changed

- **`cs2movement_crouch_slide_time` 出厂值 0.10 → 0.20（CS2 等价）**。
  CS2 蹲下按 `sv_friction 5.2` 衰减：`ln(215/73.1)/5.2 = 0.207 s`、滑距
  `(215−73.1)/5.2 = 27.3 u`；0.10 只有约一半（64 tick 实测 13.0 u vs 25.9 u）。
  改的是 movement 的**出厂默认**（ConVar 默认 + `configs/cs2movement.cfg`），
  **滑行曲线/物理未改**。
- **`cs2movement_crouch_slide_client`（插件默认 0）升级为受管参数**：把复制的 `survivor_crouch_speed` 沿同一条衰减曲线写下，client.dll 也按滑行预测（两端都滑、零回拉）。**`cs2_competitive` / `cs2_full` 显式写 1**（其余预设写 0）：这是"接近 CS2"的唯一手段。该 cvar 是全局的，所以实现里带「干净房间」门控——只在恰好一个幸存者滑行、且其他幸存者都没蹲时才驱动它，否则退回服务端单边（避免队友蹲走被客户端预测成加速再被拉回）。`sv_cheats 0` 下客户端接受复制值**已实测（2026-11-01：客户端 console.log 打印 `SetConVar: survivor_crouch_speed = "200"/"75"`，`FCVAR_CHEAT` 不阻止服务端→客户端复制）**。
- `cs2movement_crouch_slide_time` / `cs2movement_crouch_slide_min_speed` 升级为统一层
  受管参数（`PARAM_GROUP_MOVE`，float，候选值 time **0.10/0.20/0.30/0.40/0.50/0.60/0.70**、
  min_speed 0/50/100/150）：菜单 / `sm_cs2u_set` / 保存 / 重载 / 回滚 / DIY / 快照全覆盖。
- **简易模式新增「蹲下滑行档位」二级页**（`MenuHandler_SlideTier`）：三个档位
  **0.20（CS2 数值等价，26 u）/ 0.40（长滑，53 u）/ 0.50（手感档，66 u）**，选中即同时
  打开 `crouch_slide` 并保存；当前档用 `> ` 标记。数值来源见上游 `docs/12` §12.7.2
  「数值档 vs 手感档」（0.50 是真人挑出来的观感档，为 CS2 数值的 241%）。
- `cs2_competitive` / `cs2_full` 显式写 `crouch_slide_time 0.20` + `crouch_slide_min_speed 100` + `crouch_slide_client 1`
  （两套预设 33 → **36 条**）。
- 受管参数 33 → **36**；参数索引按插入顺序后移（movement 11–25、injury **26–32**、
  visual **33–35**）。菜单 `p.<idx>`/`v.<idx>.<cand>` 动态生成，分页契约（7 行/#8/#9/
  `MENU_NO_PAGINATION`）不变。
- 合并上游 movement **0.5.2**（只含上述默认值与诊断改动；injury 等既有层不变）。

### Added

- **滑行生效诊断**：`sm_cs2movement_status` 的滑行行新增 `ready=` / `duck_layer=` / `hook=` / `client_slide=` / `cvar_now=` / `base=`；
  `sm_cs2u_status` 新增 `slide:` 行（cvar/ready/duck_layer/hook/time/min_speed/starts/writes/
  last_client/v0/ceil），`sm_cs2u_diag` 新增 `slide gates:` 分解行。
  `ready=0` = `crouch_slide 1` 但蹲速层门控未就绪，此时滑行不会启动。
- `cs2movement_crouch_slide_client` 的全局副作用写进 docs（repo A 的 docs/12 §12.8、docs/14）；
  `sv_cheats 0` 下客户端接受复制值已于 2026-11-01 实测（客户端日志 `SetConVar: survivor_crouch_speed = …`）。
- `crouch_slide 1` 但蹲速层未就绪时，在 `OnConfigsExecuted`、cvar 变更、统一层持久化应用
  三处各打印一次 `WARNING crouch_slide=1 but duck layer not armed`
  （`LogMessage` + `PrintToServer`，按状态转换闩锁，不刷屏）。
- 文档同步：`docs\02`/`03`/`05`/`06`、`README.md`、`HANDOVER.md` 更新 36 参数 / 36 条预设 /
  索引迁移；`docs\05` 的运行时证据保留当时值并标注“当时 33 / 1.0.0 / movement 0.5.1”。
- 运维坑（repo A `docs\14`）：L4D2 客户端 `console.log` **只有引擎控制台（`~`）打开时才写盘**；
  关着控制台时 `-condebug -dev -console` 也不落内容。客户端 `getpos` 采样的复现步骤必须先开控制台。

### Note

- 版本号 bump 只为让“出厂默认值变了”可追溯；**未打 tag、未打包、未部署**。
- 运行时数据仍来自 **1.0.0 / movement 0.5.1** 那一轮（`docs\05` §4 已标注），
  1.0.1 / movement 0.5.2 未重跑运行时；曲线形状等证据回来再定。

## [1.0.0] - 2026-10-31

首个合并版本：cs2feel **0.5.7-m11** + cs2movement **0.5.1**（含 injury）+ 统一管理面
（33 个受管参数 / 7 套预设 / 2 个 DIY 槽位 / 手写分页菜单 / 简易模式 / KeyValues 持久化 /
热重载 / 回滚 / 服务端曳光）。设计与验收见 `docs\00`、`HANDOVER.md`。
