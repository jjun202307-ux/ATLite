# ATLite 错误全档案（重写的规避规则集）

> 本文记录 ATLite 第一版开发过程中犯下的**每一个错误**。重写版（v0.2.0）必须逐条规避。
> 每条错误附带：现象 → 根因 → 为什么当初没发现 → 规避规则（R#）。

---

## A. 运行时错误（CI 永远测不出，真机上才炸——最严重的一类）

### E1. dlsym 了不存在的符号 → 真机触摸/按键 100% 失效
- **现象**：代码写 `dlsym("IOHIDEventSetInteger")`，真机上返回 NULL，符号完整性检查失败，`gHIDReady=NO`，所有触摸/按键模拟被静默禁用。
- **根因**：IOKit 真实符号名是 `IOHIDEventSetIntegerValue` / `IOHIDEventSetFloatValue`（`...Value` 结尾）。凭记忆写符号名。
- **为什么没发现**：dlsym 是运行时行为，编译/链接全过；CI 结构性测不出。
- **R1（铁律）：一切 dlsym 的符号名与函数签名，必须来自真机提取的头文件、WebKit SPI、KIF/SimulateTouch 等已验证实现或参考二进制的反汇编，禁止凭记忆书写。**

### E2. IOHIDEvent 字段值写错 → 事件语义完全错误
- **现象**：`IsDisplayIntegrated` 写成 `0x000B000B`（实为 BarrelPressure=base+11），正确值 `0x000B0019`（base+25）。
- **根因**：从网上零散代码抄了未交叉验证的常量。
- **R2：私有框架枚举值必须 ≥2 个权威来源一致（WebKit SPI + KIF + IOHIDFamily 源码 + 真机 dump），并写出推导算式（base=11<<16）。**

### E3. 抓屏 API 签名整体写错 → findImage/findColor/getColor/findText 全部不可用
- **现象**：`CARenderServerCaptureDisplay(server指针, 0, NULL)` —— 三个参数里错两个。
- **根因**：真实签名是 `(uint32_t serverPort=0, CFStringRef displayName, CFDictionaryRef options)`；iOS 显示屏名为 "LCD"（备选 "Main"）。
- **为什么没发现**：与 E1 同理，运行时行为。
- **R3：无公开头文件的 API，最可靠取证是反汇编一个真实可用的实现（本项目反汇编了 AutoTouch libATGraphic.dylib，拿到铁证 `RenderDisplay(0, CFSTR("LCD"), surface, 0, 0)`）。**

### E4. IOHIDEvent 事件结构偏离全部参考实现
- **现象**：hand 父事件携带坐标/压力、identity 随意取值；finger 子事件 index 从 0 起。
- **根因**：未对齐 SimulateTouch/KIF 的验证过的参数模式（hand 全 0、finger index 从 1 起、identity=2）。
- **R4：合成事件的参数装配必须逐参数对照一个已在真机工作的开源实现，禁止自由发挥。**

### E5. finger 事件 typedef 多一个参数（14 vs 真实 13）
- **现象**：run#24 编译报 too few arguments 之前，旧代码靠多传一个 `0` 绕过编译——但会把 range/touch/options 错位到错误寄存器，即使 E1 修好触摸也是错的。
- **R5：typedef 参数个数必须与权威头文件逐个参数核对；"多传一个 0 能编译"不是正确性证据，是寄存器错位的证据。**

### E21. dispatch_once block 内调用间接依赖自身的函数 → 重入死锁
- **现象**：v0.3.0 的 ATJBRoot 在 once block 里加了一行 ATLog 做诊断。ATLog → ATLogsDir() → ATBaseDir() → ATJBRoot() —— 回到同一个尚未完成的 dispatch_once token，永久自旋。SpringBoard 注入即死锁，真机必现。
- **根因**：dispatch_once 不可重入。block 内调用的任何函数，其（间接）依赖图不允许回到该 once 保护的函数本身。
- **为什么没发现**：改动只有一行日志，看起来人畜无害；评审（子代理两段式）顺依赖链才抓到。
- **R21：dispatch_once block 内禁止调用任何（间接）依赖本 once 函数的接口；诊断需求改用"block 内设标志、block 外输出"模式（见 gJBRootSource）。静态守卫：verify_static.py C1 断言。**

## B. 打包/元数据错误（CI 绿勾，真机才炸）

### E6. Info.plist 用了 Xcode 占位符 → App 点图标立即闪退
- **现象**：`CFBundleExecutable = $(EXECUTABLE_NAME)`，Theos 不做替换，实装的 plist 里就是这串字面量，launcher 找不到可执行文件。
- **根因**：从 Xcode 模板抄 Info.plist，没确认 Theos 的替换行为。
- **R6：Theos 项目的 Info.plist 全部字段硬编码字面量；推送前用 plistlib 解析验证 `CFBundleExecutable` == 实际二进制名，并解包产物复核（C37）。**

### E7. 包架构与越狱类型不匹配 → dpkg 拒装
- **现象**：rootless 包（iphoneos-arm64）装 roothide 设备（系统架构 iphoneos-arm64e）被拒。
- **根因**：Theos 无 roothide scheme 模块，默认按 rootless 打包。
- **R7：roothide 三要素：`Architecture: iphoneos-arm64e`（由自制 scheme 模块的 `THEOS_PACKAGE_ARCH` 决定，改 control 无效）、**无前缀 rootful 式布局**（roothide dpkg 在 vroot 下自动装进随机 jbroot，见 E22/R22——早期"/rootfs/var/jb 前缀"是错的）、postinst 放**根级** `layout/DEBIAN/`（子项目 layout 在 aggregate 下会被忽略）。**

### E8. filter plist 文件名不匹配 → stage 阶段失败
- **现象**：`ATLite.plist` 不被识别，改名 `ATLiteTweak.plist`（== TWEAK_NAME）才通过。
- **R8：tweak 的注入过滤器文件名必须严格等于 `$(TWEAK_NAME).plist`。**

### E9. 自测脚本没随包发布 → 装完无东西可测
- **现象**：test.at 只在 GitHub 仓库里，手机上没有任何脚本可运行。
- **R9：用户在设备上需要的每一份文件必须打进 deb（本次重写：test.at 随 App Resources 发布，首次启动自动复制进 Scripts 目录）。**

### E22. roothide 包前缀凭推测发明（/rootfs/var/jb）→ 非规范布局，靠巧合才能装上
- **现象**：v0.1.0-v0.3.0 的 CI 自制 roothide 模块设了 `THEOS_PACKAGE_INSTALL_PREFIX = /rootfs/var/jb`，包内路径 `rootfs/var/jb/Applications/ATLite.app`。在 roothide 设备上能装上纯属两层巧合：vroot 语义下 `/rootfs` 映射真实 rootfs + Dopamine-roothide 恰好创建了 `/var/jb` → jbroot 的 symlink（DOBootstrapper.m L481）。在没有该 symlink 的 roothide 实现（如 RootHide Bootstrap）上必装错位置。
- **根因**：官方 roothide 包布局是**无前缀 rootful 式**（官方 com.roothide.patcher deb 拆解实证：`./Applications/Patcher.app`），roothide dpkg 在 vroot 环境（jbroot 为根）自动安装进随机 jbroot；roothide/theos 官方 roothide 模块的 package.mk 就是空的。当时没去拆官方包验证，凭 vroot 语义推测发明了前缀。
- **为什么没发现**：包装上了、图标出来了，"能用"掩盖了"不规范"。
- **R22：deb 布局/maintainer 脚本路径必须以官方实证为准（拆一个官方 roothide 包看真实结构），禁止凭语义推测发明路径前缀；maintainer 脚本里一律用 vroot 路径（/Applications/...），不写 jbroot 真实路径。**
- 同类附带修正：jbroot 探测的 `/var/mobile/.jbroot-*` 无证据支持，实证位置是 `/var/containers/Bundle/Application/.jbroot-*`（DOBootstrapper.m find_jbroot）。
- **二次核验（2026-10-24，debug-error-recovery + pc-debugging-expert）**：样本量从 n=1 提升到 n=8（官方源 8 个不同 Section 的 arm64e 包），顶层目录全部为 `Library 152 / Applications 7`，`rootfs` 仅出现在 v0.3.0；`DOBootstrapper.m` L410 还会**主动删除** `/var/jb`（"Remove /var/jb as it might be wrong"），坐实该 symlink 是 Dopamine-roothide 自有行为而非 roothide 通用保证。RED 实测：用 v0.3.1 断言跑 v0.3.0 快照 → 55 PASS / 6 FAIL，R22 五条全部变红，证明断言有效。完整报告见 `docs/AUDIT_ROOTHIDE_E22.md`，取证工具见 `tools/verify_roothide_layout.py`。

### E23. App 界面无标题栏、IP 状态行不可见（真机截图实证）
- **现象**：v0.3.1 真机打开后，界面无导航栏（标题"ATLite"与刷新按钮不渲染），IP 状态行（`电脑访问: http://<ip>:8080`）看不见。
- **根因（两 bug 叠加）**：
  1. `ATLAppDelegate` 把 `ATLRootViewController` 直接设为 `window.rootViewController`，没包 `UINavigationController` → `self.title` / `navigationItem` 无处渲染。
  2. `ATLRootViewController` 本身是 `UITableViewController`（`self.view` 天生已是 tableView），`viewDidLoad` 又新建了一个 `UITableView` addSubview 盖上去——后添加者在上层，把先加的 `statusLabel`（IP 行）**完全遮挡**（z-order 问题）；`contentInset.top=48` 只是表格内部留白，底下被盖的 label 依然不可见。
- **修复**：AppDelegate 包 `UINavigationController`；删自建 table（直接用 `self.tableView`），`statusLabel` 改为 `tableHeaderView`（永不被遮挡、随表格滚动）。
- **R23：UI 状态行必须用 tableHeaderView / 导航栏这类有主的位置承载；禁止在 UITableViewController 的 self.view 上再叠自建 table；涉及可见性的改动必须脑内渲染一遍 z-order 与视图层级。**

### E24. App 内无法查看 tweak 日志 → 脚本"没反应"时没有调试手段
- **现象**：用户运行脚本后无任何反馈，唯一线索 tweak.log 要自己用 Filza 摸到 `<jbroot>/var/mobile/Library/ATLite/logs/` 才能看，而 jbroot 是随机路径——等于没有调试通道。
- **根因**：App 只做了"发命令"，没做"看结果"。诊断信息全在 tweak 侧日志里，App 侧零可见性。
- **修复**：新增 `ATLLogViewController`（导航栏"日志"入口 + 操作表"运行并查看日志"）：
  1. 显示 tweak.log，1.5 秒自动刷新（运行脚本时可看实时输出）
  2. **多路径探测**（`ATLExistingLogPath`）：App 侧 jbroot 推导（bundlePath）与 tweak 侧（dladdr）可能不同，逐个候选试，避免"文件其实在、只是路径字符串不同"
  3. 找不到日志时输出**诊断文本**（jbroot 推导值 + 各候选路径 + logs 目录是否存在），直接区分三种情况：全部不存在＝tweak 未注入；目录存在无文件＝注入了没写日志；只有载入行无 command 行＝命令没送达
  4. 路径逻辑抽出为 `ATLPaths.h/.m` 共享模块（App 与日志页共用）
- **R24：任何"发起方—执行方"分离的架构，发起方必须内置查看执行方输出的通道；且该通道要能自我诊断（说清是没启动、没送达还是没产出），不能只显示空白。** 另：app/Source 新增 .m 必须同步登记 `ATLite_FILES`（已加通用守卫断言防漏）。

### E25. 脚本跑在 SpringBoard 进程内 → 一个卡死就把整个系统拖垮（用户实报：打不开新程序，只能重启）
- **现象**：用户运行脚本后，整个系统无法打开任何新程序，只能重启设备。
- **根因**：Lua 引擎住在 **SpringBoard 进程**（触摸/抓屏必须在该进程才有效）。任何一次"永不返回"的阻塞或"停不下来"的循环，代价都是整个系统，而不是一个 App 崩溃。三个具体风险点：
  1. **抓屏同步 IPC 无超时**（最可疑）：`CARenderServerCaptureDisplay` 是到 render server 的同步调用；若 render server 与 SpringBoard 互相等待，该调用永不返回。补充证据：AutoTouch 的 libATGraphic **只导入 `_CARenderServerRenderDisplay`**（调用者自带 IOSurface），**根本没有** `CARenderServerCaptureDisplay` —— 我们用的 API 与稳定商业产品的实证选择不一致。
  2. **脚本无执行时限**：死循环脚本（`while true do tap() end`）永不停歇。
  3. **HID 事件无节流**：密集合成事件会淹没 SpringBoard 事件队列，表现同样是系统无响应。
- **修复（v0.3.4，止血）**：
  - A. `ATCaptureSurfaceWithTimeout()`：抓屏挪到专用串行队列 + `dispatch_semaphore` 只等 1.5s；超时即置 `gCaptureBroken` **本进程内永久停用抓屏**并记日志——宁可功能失效也不拖垮系统
  - B. `ATLuaTimeoutHook`：Lua count hook 每 10 万条指令查一次挂钟，超过 60s 中止脚本（不中止 SpringBoard）
  - C. `ATThrottleEvents()`：HID 事件最小间隔 8ms（≈125/s），防事件风暴
- **R25：注入型代码运行在系统进程里时，每一个"可能不返回/可能不停止"的调用都必须有看门狗或上限；同步 IPC 一律加超时，用户脚本一律加时限，事件/资源类循环一律加节流。功能失效可接受，系统挂死不可接受。**
- **遗留（v0.3.5 候选）**：抓屏 API 对齐 AutoTouch 实证的 `CARenderServerRenderDisplay`（调用者自带 IOSurface），需自建 IOSurface 并确认像素格式常量，风险较高故本版未动。

## C. 构建期错误（CI 能抓到，但每条都浪费一轮构建）

### E10. 假设 lua/lua 仓库是 tarball 的 src/ 布局
- **现象**：`-Ilib/lua53/src` 与 `wildcard(.../src/*.c)` 全部落空（run#8-10）。
- **R10：引用任何外部仓库前，用 API 列出其真实目录结构；镜像仓库的布局 ≠ 官方 tarball。**

### E11. Lua 调试文件没删干净
- **现象**：`ltests.c/h`（开发调试用，不在官方构建清单）与含 `main()` 的 `lua.c/luac.c/onelua.c` 若不删，链接 dylib 时符号冲突。
- **R11：vendor 第三方源码时，文件清单必须与官方 makefile 的构建列表一一对应（33 = CORE_O 20 + lauxlib 1 + LIB_O 12）。**

### E12. iOS SDK 把 system() 标记 unavailable
- **现象**：loslib.c 的 os.execute 编译硬错误（run#11）。
- **R12：iOS 上编译 Lua 类 C 库，先排查 loslib/loslualib 的 system/popen；处理方式=桩函数替换，不是删功能。**

### E13. Theos 默认 -Werror 与 Lua 惯用法冲突
- **现象**：`LUA_SIGNATURE + 1`（故意的指针算术）触发 `-Wstring-plus-int` → 错误（run#12）。
- **R13：第三方 C 源码进 Theos，预备精确的 `-Wno-error=<具体警告>`，不做全局豁免。**

### E14. theos SDK 的 Vision 头文件不完整
- **现象**：无 VNRecognizedText.h，`topCandidates:`/`boundingBox` 无声明（run#13）。
- **R14：用 theos SDK 编译前，先确认所用框架头文件齐不齐（API 目录列出检查）；缺口用 ObjC 类别补声明（运行时存在、部署目标低于引入版本时合法）。**

### E15. 用了类但没导入其头文件（2 处）
- **现象**：main.m 漏 `ATLAppDelegate.h`、ATLRootViewController.m 漏自己的 .h（run#14/#15）。
- **R15：每个 .m 编写完立即自查：本文件出现的每个自定义类名都有对应 #import；重写时逐文件核对。**

### E16. Darwin 的 ifaddrs 无 typedef + NSMutableString/NSString 赋值 -Werror
- **现象**：`ifaddrs *ifs` 编译错误，必须 `struct ifaddrs *`（run#15）。
- **R16：Darwin C 结构体一律带 struct 关键字（或用 typedef 名）；ARC 下可变/不可变字符串赋值类型必须精确。**

### E17. Lua 扩展文件版本不感知 → 老设备永远用旧版
- **现象**：`if (!fileExists) write` 导致升级后 Extensions.lua 不更新，拟人化改动不生效。
- **R17：设备上自动落地的文件必须带版本标记 + 版本感知覆写（旧文件备份 .bak）。**

## D. 流程错误（浪费用户时间的元错误）

### E18. 把远程构建当验证手段（"改一处构建一次"）
- **现象**：26 次构建里 17 次失败；run#17-22 的 6 连败全是推送前读一遍源码就能避免的。
- **R18（最高优先级）：推送前完成零构建验证——涉及的路径、变量语义、机制调用链全部书面核实；构建是最后手段。**

### E19. CI 步骤无诊断能力
- **现象**：run#19 零输出退出码 1，无法定位，白费一轮才补 set -x。
- **R19：所有 CI run 步骤带 `set -x`；关键文件操作后带存在性断言（test -f / ls）。**

### E20. theos 库目录的空壳陷阱
- **现象**：`$THEOS/lib/iphone/rootless` 是主仓库的空壳目录，真实库在 `$THEOS/vendor/lib/iphone/rootless`（递归 clone 的子模块）——run#20 的 set -x 才暴露。
- **R20：引用 theos 内部路径前，区分主仓库占位与 vendor 子模块实体的差别。**

---

## 重写版（v0.2.0）逐条规避核对表

| 规则 | 落实位置 | 核对 |
|------|----------|------|
| R1/R2/R3/R4/R5 | Tweak.xm 符号/常量/签名段（保留四方验证的常量，逐条注释来源） | ☐ |
| R6 | Info.plist 全硬编码 + plistlib 验证 + 产物解包复核 | ☐ |
| R7 | workflow roothide 模块 + control arm64e + 根级 layout/DEBIAN/postinst | ☐ |
| R8 | tweak/ATLiteTweak.plist 命名 | ☐ |
| R9 | app/Resources/test.at + 首次启动复制进 Scripts | ☐ |
| R10/R11 | workflow vendor 步骤（保持已验证逻辑，不改动） | ☐ |
| R12/R13/R14 | Makefile CFLAGS / loslib 桩 / Vision 类别 | ☐ |
| R15/R16 | 每个 .m 导入清单逐文件核对；struct 关键字 | ☐ |
| R17 | Extensions.lua v2 版本感知 | ☐ |
| R18/R19/R20 | 推送前静态清单全过 + workflow 保留 set -x/断言 | ☐ |
