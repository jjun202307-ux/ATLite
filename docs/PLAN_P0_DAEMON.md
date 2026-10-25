# P0 重构计划：把脚本引擎移出 SpringBoard

> **状态**：保活方案已定为 **A / B 双模式可选（默认 B，自动降级 A）**；**尚未改动任何代码**。下一步：出探针包（P1–P5）拿真机结论。
> **触发**：用户提供的《触动精灵 iOS 技术分析文档》v4.1.1 §9.3 —— rootless/roothide 版的 `TSTweak.dylib` **不做 Substrate Hook**（无 `MSHook*`、不链 CydiaSubstrate/IOKit），只做悬浮窗 UI；Lua 引擎 + 触摸注入 + 抓屏全在独立 `TSDaemon`（setuid root），由 `Hades` 守护崩溃重启。
> **本文性质**：设计 + 取证 + 验证清单。所有标【实证】的结论都来自可查证的二进制/源码证据；标【待验】的必须真机确认后才能进入下一阶段。

---

## 1. 动机：我们在给错误的架构打补丁

| 事故 | 症状 | 当时修法 | 本质 |
|---|---|---|---|
| E25 | 脚本跑飞 → 整个系统打不开新程序，只能重启 | 抓屏看门狗 1.5s + Lua 60s 时限 + HID 节流 | 脚本在 SpringBoard 进程内 |
| E26 | 划掉 App 也停不掉脚本，无强停手段 | 双通道停止标志（通知 + flag 文件）+ UI 停止按钮 | 杀不掉 SpringBoard |
| E29 | 抓屏 API 零实证，是系统 hang 最大嫌疑 | 对齐 AutoTouch 实证改用 RenderDisplay | 渲染 IPC 阻塞发生在 SpringBoard 内 |
| E30 | 尺寸获取 `dispatch_sync` 主线程无超时，绕过看门狗 | semaphore 限时等待 | 任何跨线程等待都在 SpringBoard 内 |

四条补丁有同一个根因：**用户的 Lua 代码与 SpringBoard 共享一个进程和一条主线程**。

### 关键洞察（决定分期策略）

卡死系统的从来不是"触摸注入"或"抓屏"这两个短促调用，而是**用户脚本本身**（死循环、等一个永远不来的图像）。所以：

> **只要把 Lua 引擎移出 SpringBoard，E25/E26 就根治了 90%**，哪怕触摸与抓屏暂时仍由 SpringBoard 代劳。

这句话把 P0 从"一次高风险大爆炸"降级为"三个可独立验收的阶段"。

---

## 2. 目标架构（终态）

```
  电脑（写脚本 / HTTP 推脚本）
        │ 局域网
        ▼
  ┌────────────────────────────┐
  │ ATLite.app（UI，mobile）    │  脚本列表、日志查看、停止按钮、Web 传文件
  └────────────┬───────────────┘
               │ 127.0.0.1 HTTP（JSON）
  ┌────────────▼───────────────┐
  │ ATLiteDaemon（setuid root） │  Lua VM + 抓屏 + HID + 时限/强停
  │  ← 独立进程，崩了可 kill -9  │
  └────────────┬───────────────┘
               │ 心跳 / 保活（阶段 3）
  ┌────────────▼───────────────┐
  │ ATLiteWatchdog 或 SpringBoard│
  └────────────────────────────┘

  SpringBoard：终态**不注入**；过渡期只保留一个"转发/保活"极简 dylib
```

---

## 3. 分期（每阶段独立验收、独立可回退）

### 阶段 1：引擎外移（根治 E25/E26，保留 SpringBoard 转发）

- 新增 `daemon/` 子工程（theos tool）：Lua VM 移进来，跑脚本。
- 触摸/抓屏**暂时不变**，由 SpringBoard tweak 提供；daemon 通过本地 HTTP 把 `touchDown/findImage/snapshot` 请求转发给 tweak，tweak 回传结果。
- 收益验证：脚本里写 `while true do end` → 系统应当完全无感，App 点"停止"直接 `kill -9` daemon 立即生效。
- 风险最低：不涉及任何新私有 API。

### 阶段 2：能力外移（抓屏 + HID 进 daemon）

- daemon 以 root 身份自建 IOSurface 抓屏（`IOMobileFramebufferGetLayerDefaultSurface` 优先，`CARenderServerRenderDisplay` 回退）+ `IOHIDEventSystemClient` 注入。
- SpringBoard tweak 退化为**只做保活转发**，脚本逻辑一行不留。

### 阶段 3：去注入（可选终态）

- tweak 只保留 watchdog 职责，或直接由 App/守护进程保活，把 `TSTweak.dylib` 从 deb 里拿掉。
- 触发条件：阶段 2 真机验证 HID/抓屏在 root daemon 下稳定。

---

## 4. 关键技术决策（决策 / 证据 / 待验）

### D1 构建方式【实证】
`TOOL_NAME = ATLiteDaemon` + `include $(THEOS_MAKE_PATH)/tool.mk`，配 `ATLiteDaemon_FILES / _FRAMEWORKS / _CFLAGS / _CODESIGN_FLAGS = -Sentitlements.plist`。
证据：fouldecrypt、TrollRecorder、KernBypass、SimulateTouch(`zxtouch-binary`) 四个项目均用此模板，且都支持 arm64e + 自定义 entitlements。

### D2 安装位置与 stage 写法【实证，已结案】
**决策**：放进 App bundle 内 `/Applications/ATLite.app/ATLiteDaemon`，用 `ATLiteDaemon_INSTALL_PATH` 一步 stage。
- 触动精灵实证：`Hades`/`TSDaemon`/`TSInstaller` 都在 app 内（rootless 版 `/var/jb/Applications/TouchSpritePe.app/Hades`），roothide 版 postinst 走 `/Applications/...` vroot 路径。
- 复用现有 `ATLJBRoot()`（从 `mainBundle.bundlePath` 推导 jbroot），路径逻辑一行不用改。
- **theos 源码实证**（已读 `makefiles/instance/tool.mk`，E18/R18 铁律要求的"动构建前读完整链路"）：
  ```make
  LOCAL_INSTALL_PATH = $(strip $($(THEOS_CURRENT_INSTANCE)_INSTALL_PATH))
  ifeq ($(LOCAL_INSTALL_PATH),)
      LOCAL_INSTALL_PATH = $($(THEOS_CURRENT_INSTANCE)_PACKAGE_TARGET_DIR)
      ifeq ($(LOCAL_INSTALL_PATH),)   # 兜底
          LOCAL_INSTALL_PATH = /usr/bin
  internal-tool-stage_::
      mkdir -p "$(THEOS_STAGING_DIR)$(LOCAL_INSTALL_PATH)"
      cp $(THEOS_OBJ_DIR)/$(THEOS_CURRENT_INSTANCE)$(TARGET_EXE_EXT) "$(THEOS_STAGING_DIR)$(LOCAL_INSTALL_PATH)"
  ```
  → **`ATLiteDaemon_INSTALL_PATH = /Applications/ATLite.app` 即可，不需要 `before-package::` 手工 cp。**
- `package.mk` 实证：`package:: internal-package-check stage before-package internal-package after-package` → `before-package` 在 **stage 之后**执行，可用作兜底与断言（`ls -l` 确认产物就位）。

### D2b 执行权限：exec 能否成功【实证 + 待验】
- **路径实证**：rootlessJB writeup —— iOS 上只能在 `/var/containers/Bundle/` 内 exec，出界即 `Operation not permitted`；界内 exec 未签名/无 entitlement 的二进制会 `Killed: 9`。
  **roothide 的 jbroot 正是 `/var/containers/Bundle/Application/.jbroot-<hex>`（find_jbroot L817 实证），天然落在可 exec 区域内。**
- **entitlement 实证**：`Killed: 9` 的解法是 `platform-application` + 去沙盒。我们的 `app/entitlements.plist` **已同时具备** `platform-application` 与 `com.apple.private.security.no-sandbox`（对齐 AutoTouch 四键，RESEARCH A2）。
- 【待验】：即便如此，App 侧 `posix_spawn` 后 **euid 是否真为 0**（setuid vs `com.apple.private.persona-mgmt` 两条路径，触动精灵走 setuid，TrollStore 走 persona-mgmt）。→ 探针 P1。

### D3 setuid【实证】
`postinst` 里 `chmod u+s /Applications/ATLite.app/ATLiteDaemon`。
证据：触动精灵三形态 postinst 都 `chmod u+s TSDaemon/TSLn/TSUpdate/unzip/TSInstaller`，**roothide(355) 版同样执行** —— 说明 roothide 下 setuid 有效。
补充：App（mobile）`NSTask` exec 一个 setuid-root 二进制后 euid=root，这是触发精灵的既有路径，不需要 launchd。

### D4 启动与保活【决策：A / B 双模式可选，默认 B，B 失败自动降级 A】
C（LaunchDaemon）本轮不做：roothide 下 jbroot 随机路径 → plist 必须 postinst 动态生成 + 卸载要 unload，且 daemon 启动失败会被 launchd 反复重启形成风暴，调试周期拉长数倍。**保留为阶段 3 的候选**，届时若仍需要"开机即活且不注入"，再上。

双模式的核心不是"二选一"，而是**同一套拉起逻辑、两个触发源**：

| | A 模式 | B 模式 |
|---|---|---|
| 触发源 | App（发命令前 / 前台时） | SpringBoard tweak（ctor + 收命令时） |
| 开机即活 | 否（重启后需开一次 App） | 是 |
| 崩后自愈 | 下次发命令时补拉 | 收命令时补拉 |
| 注入面 | 不注入 | 仍注入（但只剩 spawn，几十行） |
| 失败兜底 | — | **自动降级为 A** |

详见 §4.1 的双模式设计。

### 4.1 A/B 双模式详细设计

#### 单一拉起器（shared/ATLSpawn.*，App 与 tweak 共用同一份）
```objc
typedef NS_ENUM(NSInteger, ATLLaunchMode) {
    ATLLaunchModeApp          = 0,  // A：仅 App 拉起
    ATLLaunchModeSpringBoard  = 1,  // B：SpringBoard 保活（App 仍可兜底拉起）
    ATLLaunchModeOff          = 2,  // 禁用 daemon（排障用，退回 v0.3.x 行为）
};
BOOL ATLEnsureDaemon(NSTimeInterval timeout);   // 活着返回 YES；否则 spawn + 轮询探活
ATLLaunchMode ATLCurrentLaunchMode(void);       // 读配置文件，缺省 = SpringBoard
```
判定顺序（**先探活，后 spawn** —— 这是幂等的唯一保证）：
1. 读端口文件拿到端口 → `connect()` 成功即认定活着，直接返回 YES
2. 否则 `posix_spawn` app bundle 内的 `ATLiteDaemon`（参数：`--port-file <path>`）
3. 轮询探活 ≤ timeout（默认 3s），期间每 100ms 试一次
4. 失败 → 记日志（含 errno）并返回 NO

#### 模式开关
- 配置文件：`$(ATLBaseDir)/launch_mode`，内容 `app` / `springboard` / `off`
- **App 侧**：`mode != off` 时都调 `ATLEnsureDaemon`（所以开 B 时 App 也能兜底，A 的价值不丢失）
- **tweak 侧**：仅 `mode == springboard` 时才 spawn + 补拉；每次检查现场读文件，切模式**无需重启 SpringBoard**
- 默认 `springboard`（开机即活）；用户可在 App 设置切换

#### 幂等与去重
- 以"端口可连"为唯一存活判据 → A 与 B 同时触发也不会起第二个
- 额外保险：daemon 启动时 `bind` 失败（端口占用）→ 打印日志并立即退出，绝不双实例

#### 自动降级（B 失败不至于全瘫）
tweak 侧 spawn 失败连续 N 次（默认 3）→ 写日志 `springboard spawn failed (errno=%d), falling back to app mode`，并把配置文件改写成 `app`。App 下次发命令会自己拉起。**用户无需手动干预，只是失去"开机即活"。**

#### UI（App 设置区）
- 三段选择：SpringBoard 保活（推荐）/ 仅 App 拉起 / 停用
- 状态行：daemon 存活 + pid + euid（root / mobile）+ 当前生效模式 + 最近一次拉起失败原因

### D5 IPC【决策】
**127.0.0.1 TCP + JSON**（复用 `ATLWebServer` 的写法），不用 CFMessagePort。
理由：① CFMessagePort 跨 uid（App=mobile / daemon=root）在 iOS 上通常要借 rocketbootstrap，凭空多一个依赖；② TCP 无权限问题；③ **顺带给电脑留了一条直连通道**——`curl 127.0.0.1` 模式的调试/投脚本体验正好命中"电脑写脚本"的主需求。
安全：只 bind `127.0.0.1`，不对外暴露；命令需带一次性 token（token 写文件，权限 0600）。

### D6 强停【根治 E26】
停止 = `kill -9 <daemon pid>`。这是**100% 有效**的强停（对比现在：SpringBoard 内的脚本无法强停，只能靠 Lua 钩子在指令边界自杀）。
App 侧：停止按钮 → HTTP stop → 500ms 无响应 → 直接 `kill -9`。UI 文案可以简化为"停止（卡死也有效）"。

### D7 抓屏【实证，两项互为回退】
- 主：`IOMobileFramebufferGetLayerDefaultSurface` 拿主屏 layer 的 IOSurface → 读像素。**不走 Mach IPC 到 render server，E29/E30 那类同步阻塞风险直接归零。**
- 回退：`CARenderServerRenderDisplay`（v0.3.8 已实现，AutoTouch 实证）。
- 证据：触动精灵 `TSDaemon` 同时导入 `IOMobileFramebuffer*` + `IOSurface*` + `CARenderServerRenderDisplay`（文档 §4.1 / E7）；
- 【待验】：iOS 15/16 root 进程能否成功 `IOMobileFramebufferOpen`（可能需要 root + 特定 entitlement）。

### D8 HID 注入【实证 + 待验】
- 决策：daemon 内 `IOHIDEventSystemClientCreate` + `IOHIDEventCreateDigitizerFingerEvent` + `DispatchEvent`，与现在 tweak 里的代码同源。
- 证据：触动精灵 TSDaemon 就是 setuid-root 独立进程承担**全部**触摸注入（文档 §9.3）；另有开源 LaunchDaemon + HIDEvents 项目佐证非 SpringBoard 进程可行。
- 【待验】：iOS 15/16 上非 SpringBoard 进程 dispatch 是否需要额外 entitlement。**这是整个 P0 最大的未知项**，必须先做最小验证（见 §7）。

### D9 日志与文件权限
daemon 是 root，写日志/脚本目录要用 `0666` 或 `chown mobile`（触动精灵 postinst 明确 `chown -R mobile:mobile` 数据区）。现有 `ATLLogsDir()` 路径不变，App 只读，需保证 root 写出的文件 mobile 可读。

---

## 5. 代码组织变动（阶段 1）

| 变动 | 说明 |
|---|---|
| 新增 `probe/`（阶段 0，先做） | `Makefile`（tool.mk + `INSTALL_PATH=/Applications/ATLite.app`）、`main.m`（P1–P5）、`entitlements.plist` |
| 新增 `daemon/` | `Makefile`（tool.mk）、`main.m`（runloop + HTTP server）、`ATLDaemonEngine.m`（Lua VM，从 Tweak.xm 搬迁）、`entitlements.plist` |
| 新增顶层 `shared/` | `ATLPaths.*`（jbroot 推导，tweak/daemon 共用）、**`ATLSpawn.*`（A/B 双模式共用拉起器：探活→spawn→轮询）**、`ATLBitmap.*`（抓屏位图与像素格式）、`ATLMatch.*`（粗到细 NCC）——**避免两份拷贝** |
| `lib/lua53` 上提到顶层 | tweak 与 daemon 都引用同一份 Lua 源码（注意 E27：C 文件顺序、Makefile wildcard 清单） |
| `Tweak.xm` 瘦身 | 阶段 1：只保留能力实现 + HTTP 转发端；阶段 2/3：进一步退化 |
| 根 `Makefile` | `SUBPROJECTS += tweak app daemon` |

---

## 6. 验收断言（写进现有工具，不新增工具）

`tools/verify_static.py` 新增 R31 组（阶段 1）：
- `daemon/Makefile` 存在且 `include $(THEOS_MAKE_PATH)/tool.mk`、`TOOL_NAME = ATLiteDaemon`
- 根 Makefile `SUBPROJECTS` 含 `daemon`
- daemon 的 `ATLiteDaemon_FILES` 覆盖 `daemon/*.m` 全部文件（复用 R24 的 FILES 覆盖守卫思路）
- 引擎侧（Lua VM / `ATPlayLuaFile`）**只出现在 daemon 源码中，Tweak.xm 不再出现**（负向断言）
- daemon 监听仅 `127.0.0.1`
- postinst 含 `chmod u+s` 且指向 daemon（阶段 1 起）
- 版本三处同步（v0.4.0）

双模式（R31b）新增：
- `shared/ATLSpawn.m` 存在，且 `ATLEnsureDaemon` 内**先探活后 spawn**（顺序断言：探活语句行号 < spawn 语句行号）
- 默认模式为 `springboard`（配置文件缺省值断言）
- App 与 tweak **都引用同一份** `ATLSpawn`（负向断言：tweak 内不得出现第二份 spawn 实现）
- daemon 侧 `bind` 失败立即退出（双实例防护，字符串断言）
- tweak 连续 spawn 失败写日志并改写配置为 `app`（自动降级链路断言）
- 探针 `atlprobe` 存在且覆盖 P1–P5 五项（每项一个可 grep 的日志标记）

`tools/verify_artifact.py` 新增：
- deb 内 `./Applications/ATLite.app/ATLiteDaemon` 存在且为可执行
- postinst 含 setuid 动作
- 仍满足无前缀 roothide 布局

---

## 7. 必须先做的真机验证（D8 是最大未知）

**在写任何重构代码之前**，先出一个验证包（新增独立 tool，**不改现有架构**）：

```
ATLiteProbe（tool, postinst chmod u+s, 放在 ATLite.app 内）
  P1 [A 模式可行性]  App 侧 posix_spawn → 打印 spawn 返回值/errno
  P2 [B 模式可行性]  SpringBoard 侧 posix_spawn → 同上（这是 B 最大的未知）
  P3 [两种模式共有]  子进程打印 geteuid()/getegid() + 实际 entitlements
  P4 [阶段 2 前提]   root 下 IOHIDEventSystemClient + DispatchEvent 一次 touchDown
                     → 看屏幕有无可见反应（画图 App 或主屏图标抖动）
  P5 [阶段 2 前提]   root 下 IOMobileFramebufferOpen + GetLayerDefaultSurface
                     → 打印宽高与首像素 RGBA，失败则回退 RenderDisplay 再试一次
```
**P1/P2/P3 决定 A/B 双模式能否成立**（若 P2 失败 → 默认模式改为 A；若 P1 也失败 → 需要补 `persona-mgmt` 或改由 tweak 代拉起）。
**P4/P5 决定阶段 2 能否做**。两者都不阻塞阶段 1（引擎外移、能力仍走 SpringBoard），所以探针与阶段 1 可并行推进；但因为 P1/P2 直接影响双模式的默认值，**建议先出探针包，一次构建拿到结果**。

触发方式：App 日志页加一个「运行诊断探针」按钮（`NSTask` 捕获 stdout 打印到日志页）；SpringBoard 侧由现有 `command.json` 通道加一个 `probe` action 触发。

---

## 8. 风险与回退矩阵

| 风险 | 影响 | 回退 |
|---|---|---|
| root daemon 无法注入 HID（D8 未过） | 阶段 2 做不了 | 停在第 1 阶段：脚本引擎仍在独立进程，能力仍由 SpringBoard 转发 —— **E25/E26 已根治**，只是没去掉注入 |
| root 无法用 IOMobileFramebuffer | 抓屏退回 RenderDisplay | v0.3.8 实现原样搬进 daemon 即可 |
| setuid 在 roothide 不生效 | daemon 只有 mobile 权限 | 退化为"mobile daemon"（仍能解决脚本卡死问题，因为引擎已外移）；或改由 tweak(SpringBoard,root) 代拉起 |
| HTTP 端口冲突/被占用 | 命令不通 | 端口从文件读取 + 随机高位端口 + App 侧探活；回退到现有 Darwin 通知 + json 文件机制 |
| **SpringBoard 内 spawn 被 sandbox 拒（B 模式失败）** | 失去"开机即活" | **自动降级为 A**：连续失败 3 次写日志并改写配置为 `app`，App 侧照常拉起 —— 功能不丢，只是重启后要开一次 App |
| **App 侧 spawn 被拒 / euid 非 0（A 模式也失败）** | daemon 只有 mobile 权限 | ① 补 `com.apple.private.persona-mgmt` + `posix_spawnattr_set_persona_uid_np`（TrollStore 实证路径）；② 或改为由 tweak(SpringBoard) 代拉起并以 root 身份保持；③ 最坏情况退化为 mobile daemon —— **脚本卡死问题依然根治**（引擎已外移） |
| **exec 出 jbroot 被 `Operation not permitted`** | 完全拉不起 | 已规避：daemon 放 app bundle 内，jbroot 位于 `/var/containers/Bundle/` 内（rootlessJB 实证可 exec 区域）；禁止把 daemon 装到 `/usr/bin`（tool.mk 默认路径）|
| 构建系统 stage 行为不符预期 | 打包失败 | 先读 theos 源码确认变量语义；备选 `before-package::` 手工 cp（需在 CI 里 `ls` 断言产物就位） |

---

## 9. 零构建验证清单（推送前逐项打勾，R18 铁律）

- [x] 读 `makefiles/instance/tool.mk`：`LOCAL_INSTALL_PATH` ← `_INSTALL_PATH` ← `_PACKAGE_TARGET_DIR` ← `/usr/bin`；stage = `mkdir -p` + `cp` → **`ATLiteDaemon_INSTALL_PATH = /Applications/ATLite.app` 成立**
- [x] 读 `makefiles/package.mk`：`package:: ... stage before-package internal-package ...` → `before-package` 在 stage 之后，可作兜底与 `ls` 断言
- [x] 确认 `app/entitlements.plist` 已含 `platform-application` + `no-sandbox`（exec 免 `Killed: 9`）
- [x] 确认 jbroot 位于 `/var/containers/Bundle/Application/` 内（可 exec 区域，rootlessJB 实证 + find_jbroot L817）
- [ ] 新 tool 的 entitlements 是否需 `persona-mgmt`（取决于探针 P3 的 euid 结果）
- [ ] 确认 roothide scheme 下 app bundle 在 staging 中的目录名（`.app` 路径大小写）
- [ ] CI 增加一步：`ls -l $(THEOS_STAGING_DIR)/Applications/ATLite.app/` 断言 daemon + probe 就位且权限正确
- [ ] 本地用 `git show`/读源码确认：新增 `daemon/*.m` 全部登记进 `_FILES`；`shared/` 头文件引用路径在 tweak 与 daemon 两侧都成立
- [ ] C 函数定义顺序守卫（R27）对 `daemon/*.m` 生效（把新文件加进 R27 扫描列表）
- [ ] `postinst` 的 vroot 路径写法与 v0.3.x 一致（`/Applications/ATLite.app/...`，无 `/var/jb`、无 `/rootfs` 前缀）
- [ ] 静态套件全绿 + 新断言对旧代码 RED（缺一不可）
- [ ] CI workflow 步骤保留 `set -x`；新增一步 `ls -l` 断言 daemon 产物在 staging 中就位

---

## 10. 未决问题（需要你的输入或真机回答）

1. ~~保活方案选 A / B / C~~ → **已定：A / B 双模式可选，默认 B，B 失败自动降级 A**；C（LaunchDaemon）暂缓至阶段 3。
2. **是否接受 App 与 daemon 走 127.0.0.1 HTTP**（D5）—— 顺带可让电脑直连推脚本，但要处理 token。（待你确认）
3. **真机探针 P1–P5 结果**（§7）—— P1/P2/P3 定 A/B 默认值与是否需要 persona-mgmt；P4/P5 定阶段 2 起点。
4. 阶段 1 完成后版本号定为 **v0.4.0**（结构性变更，不沿用 0.3.x）。

---

## 11. 本轮新增取证（2026-10-25）

| 结论 | 来源 | 影响 |
|---|---|---|
| `posix_spawn` 出界即 EPERM，只有 `/var/containers/Bundle/` 内可 exec；界内无 entitlement → `Killed: 9` | rootlessJB writeup | jbroot 天然在可 exec 区；我们 App 已有 `platform-application`+`no-sandbox` 免 Killed |
| App spawn root 的两条路：setuid bit（触动精灵实证）vs `persona-mgmt` + `posix_spawnattr_set_persona_uid_np`（TrollStore/NathanLR 实证） | TrollStore README、NathanLR `util.m` | 若 setuid 不生效，有成熟备选 |
| `platform-application` 会收紧部分 sandbox，需逐个 IOKit 例外 entitlement | TrollStore README | 阶段 2 若 IOKit 被拒，先怀疑这个 |
| theos `tool.mk` 的 `LOCAL_INSTALL_PATH` 语义与 stage 行为 | theos 源码 | D2 结案，不需要手工 cp |
