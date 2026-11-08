# CS2Unified_L4D2 1.0.11 安装说明（Windows / SourceMod 1.12）

> 本包是 **L4D2 服务器部署包 + 可选客户端件**：
> `cs2unified.smx` + 两份 gamedata + 配置（含 `menu.cfg`）+ 数据层 VPK + 部署/卸载脚本。
> 合并内容：cs2feel 0.5.7-m11 + cs2movement 0.5.2（本地 patch 0.5.3：水面减速）+ 两级管理菜单（39 个受管参数、预设、持久化、服务端曳光）。
> 版本：**1.0.11**（2026-11-07）；静态验收 `tools\verify.ps1` **115/115 PASS**。

## 0. 先确认你是哪种用法

### A. 朋友自己开服（listen 或专用服）

按 §1–§5 安装；需要 SourceMod 1.12、MetaMod、DHooks。

### B. 朋友只进别人的服（不建服）

**不要**安装 `cs2unified.smx`，也不需要 SourceMod。只需要：

1. 把 `addon\cs2feel_r2_plugin.vpk` 复制到 `left4dead2\addons\`；
2. 可选：装了 Left4Neko 的，把 `client\cs2u_client_l4n.cfg` 放进 `left4dead2\cfg\`，并在 `autoexec.cfg` 加：
   ```text
   exec cs2u_client_l4n
   ```
3. 可选：需要“弹孔跟随服务器弹道”的，装 `cs2feel_aimsync.dll`（**本包不含 DLL**，见 §6b），
   并把 `client\cs2feel_aimsync.ini` 放进 `bin\neko\plugins\`。

服务器端的菜单、预设、参数由服主安装；你只装客户端内容即可。

## 1. 服务器安装（推荐：用脚本）

前置：

- L4D2 **Windows** 服务器（listen 或专用服）；SourceMod 1.12；DHooks 扩展（movement 引擎层需要）。
- **停服后再复制文件**（`.smx` / VPK 被占用会失败）。
- 先备份 `left4dead2\addons` 与 `left4dead2\cfg`。
- 旧的 `cs2feel_core.smx` / `cs2movement.smx` 必须停用，否则会重复 ConVar/命令；
  `deploy.ps1` 会自动移到 `plugins\disabled\`。

```powershell
# 在解压后的包根目录执行；<服务器目录> 例如 <DS_DIR>
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -GameDir <服务器目录> -DisableProbes

# 只打印计划、不改文件：
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -GameDir <服务器目录> -DryRun
```

脚本逐文件备份到 `_backup\<时间戳>\` 并写 `install-manifest.csv`。

## 2. 手动安装

把 `left4dead2\` 下的内容按原路径覆盖到服务器：

```text
left4dead2\addons\sourcemod\plugins\cs2unified.smx
left4dead2\addons\sourcemod\gamedata\l4d2_cs2feel.txt
left4dead2\addons\sourcemod\gamedata\cs2movement.txt
left4dead2\addons\sourcemod\configs\cs2feel\*
left4dead2\addons\sourcemod\configs\cs2movement_weapons.cfg
left4dead2\addons\sourcemod\configs\cs2unified\cs2unified.cfg
left4dead2\addons\sourcemod\configs\cs2unified\menu.cfg
left4dead2\cfg\sourcemod\cs2movement.cfg
left4dead2\addons\cs2feel_r2_plugin.vpk
```

启动后确认日志：

```text
[CS2Unified] LOAD version=1.0.11 feel=0.5.7-m11 movement=0.5.3
[CS2Feel] ACTIVE version=0.5.7-m11 ... offset=6124
[CS2Movement] ACTIVE enable=1 ...
[cs2unified.smx] MENU-CONFIG-OK initial=1 keys=13 ...
```

`sm plugins list` 中 `CS2Unified (L4D2) 1.0.11` 不应出现 `[FAILED]`。

## 3. 游戏内验收

- 聊天栏输入 **`!cs2u`**（需要 `ADMFLAG_GENERIC`；ROOT 自动包含）。
- 1.0.11 没有“简易模式”页面：菜单是 **常用 6 行 / 高级 7 行** 的两级结构；
  高级模式只增加配置、DIY、诊断和 ROOT 参数，不放大权限。
- 常用：预设与模式 / 手感 / 移动与受伤 / 视觉与准星 / 状态 / 高级模式。
- 高级额外有「配置与保存」，预设页多 2 个 DIY，状态页多诊断；只有 ROOT 能看到「高级模式」行。
- 39 个受管参数在页面内**行内循环**，点选即写盘并回显 `(persisted)`；移动页末两组是「水面减速」与「详细移动数值」。
- **详细移动数值**（ROOT）：18 件武器的当前移动速度。点一行后在聊天栏输入新值（50–1000），
  立即写盘；末行「恢复默认数值」一键回出厂。换图/重载不会回退；但**重新部署安装包会覆盖**
  `configs\cs2movement_weapons.cfg`，改动会丢。控制台等价物：`sm_cs2u_weapons`。
- 预设：`sm_cs2u_presets` 查看；`cs2_full` 是 **39 个值 / 单人·TR-40**（弹孔比准星高约 5°），
  `cs2_tracer` 是匹配 + 曳光，`cs2_split` 是服务器侧相机/弹道分离。
- 菜单布局/鉴权排错：`sm_cs2u_status`、`sm_cs2u_menudump`（ROOT，打印 7 个页面）。

## 4. 常用命令

```text
sm_cs2u_status
sm_cs2u_presets
sm_cs2u_preset cs2_full          # 37 个值，单人·TR-40
sm_cs2u_preset cs2_tracer        # 匹配 + 曳光
sm_cs2u_preset cs2_matched       # 匹配，无曳光
sm_cs2u_save                     # 当前 37 个值写入配置
sm_cs2u_reload                   # 重读参数 + menu.cfg 并应用
sm_cs2u_rollback                 # 回到应用预设前的快照
sm_cs2u_set <cvar> <value>       # 单项校验写入（cs2u_bmode 也会写结构值）
sm_cs2u_menudump                 # ROOT：打印全部菜单页面
```

`cs2u_bmode`：`0` 自动 / `1` 单人·TR-40 / `2` 多人；菜单「手感 → 弹道模式」行循环切换。

## 5. 卸载 / 回滚

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\uninstall.ps1 -GameDir <服务器目录> -Apply
```

按 `project-manifest.csv` 恢复旧插件与文件，并删除项目自己的配置目录。

## 6. 可选客户端增强（Left4Neko 相机）

`client\cs2u_client_l4n.cfg` 内含 `l4n_view_punch_scale` 示例。服务器**不能**设置客户端 cvar，
所以这是玩家自选项：

- 单人·TR-40（`cs2_full`）：Left4Neko 保持 **1.0**（不要 1.10，会和服务器偏移叠加）；
- 想要“准星几乎不动、弹孔明显上爬”：客户端设 **0**（最强分离）；
- 只影响渲染相机，服务器子弹/命中/客户端预测弹孔不变。

## 6b. 可选客户端增强：瞄准同步（`cs2feel_aimsync`）

`client\cs2feel_aimsync.ini` 配合 `bin\neko\plugins\cs2feel_aimsync.dll`（**本包不含 DLL**；
来自上游 `CS2FeelVScript_L4D2\client_src\`，拿到后自行放入），让**可见弹孔**表达服务器弹道偏移。

`ratio` 必须与服务器结构一致：

| 服务器结构 | 客户端 ini `ratio` |
|---|---:|
| `cs2_full`（单人·TR-40，`bmode 1`） | **1.200000** |
| `cs2_matched` / 匹配 | 0.0 |
| `cs2_split`（服务器侧分离） | -0.090909 |

同时 `enable = 1`、`yaw = 1`。不装它不影响子弹与命中，只影响弹孔。只在 `-insecure` / LAN 使用，
不要用于 VAC 服务器。

## 7. 已知边界

- cs2feel gamedata 与 cs2movement 签名均为 **Windows-only**；Linux 不支持。
- 数据层 VPK 的扩散键是加载期资产，不能热切换；数据层变更要重新部署 VPK + 重启。
- 本包合并 cs2movement **0.5.2** + 本地 patch **0.5.3**（水面减速）；线上若有更新二进制，其改动不在本包内。
- 1.0.11 的 `cs2_full` 是 **代码重建的 TR-40 预设**；旧配置文件里可能仍写着 matched 值，
  加载后以 `sm_cs2u_presets` / `sm_cs2u_status` 为准。
- “简易模式”已在 1.0.5 移除；`cs2u_simple_mode` 仅为旧配置兼容，不影响 1.0.9 菜单。
- 真人客户端菜单观感与“曳光是否看得见”需客户端验收；服务端路径已实测。
- 本包仅供朋友私用/测试；公开再分发前请阅读 `LICENSE`、`NOTICE` 与上游 cs2feel/Left4Neko 的授权说明。

## 8. 最短流程

```powershell
# 1) 停服，解压
# 2) 服务器目录执行：
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -GameDir <DS_DIR> -DisableProbes
# 3) 起服，游戏内 !cs2u
# 4) 需要 TR-40：sm_cs2u_preset cs2_full（37 个值），客户端 ini ratio = 1.200000
```
