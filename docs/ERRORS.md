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

## B. 打包/元数据错误（CI 绿勾，真机才炸）

### E6. Info.plist 用了 Xcode 占位符 → App 点图标立即闪退
- **现象**：`CFBundleExecutable = $(EXECUTABLE_NAME)`，Theos 不做替换，实装的 plist 里就是这串字面量，launcher 找不到可执行文件。
- **根因**：从 Xcode 模板抄 Info.plist，没确认 Theos 的替换行为。
- **R6：Theos 项目的 Info.plist 全部字段硬编码字面量；推送前用 plistlib 解析验证 `CFBundleExecutable` == 实际二进制名，并解包产物复核（C37）。**

### E7. 包架构与越狱类型不匹配 → dpkg 拒装
- **现象**：rootless 包（iphoneos-arm64）装 roothide 设备（系统架构 iphoneos-arm64e）被拒。
- **根因**：Theos 无 roothide scheme 模块，默认按 rootless 打包。
- **R7：roothide 三要素：`Architecture: iphoneos-arm64e`（由自制 scheme 模块的 `THEOS_PACKAGE_ARCH` 决定，改 control 无效）、安装前缀 `/rootfs/var/jb`、postinst 放**根级** `layout/DEBIAN/`（子项目 layout 在 aggregate 下会被忽略）。**

### E8. filter plist 文件名不匹配 → stage 阶段失败
- **现象**：`ATLite.plist` 不被识别，改名 `ATLiteTweak.plist`（== TWEAK_NAME）才通过。
- **R8：tweak 的注入过滤器文件名必须严格等于 `$(TWEAK_NAME).plist`。**

### E9. 自测脚本没随包发布 → 装完无东西可测
- **现象**：test.at 只在 GitHub 仓库里，手机上没有任何脚本可运行。
- **R9：用户在设备上需要的每一份文件必须打进 deb（本次重写：test.at 随 App Resources 发布，首次启动自动复制进 Scripts 目录）。**

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
