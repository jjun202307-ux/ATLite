# ATLite 构建修复计划书（Lua 5.3 vendor 路径）

> 目标：一次性修复 CI 构建失败，产出可安装的 deb。**按本计划逐项检查通过后才触发构建，不再改一处试一次。**

---

## 一、背景

第 8、9 次 CI 构建在同一位置失败：

```
Tweak.xm:23:10: fatal error: 'lua.h' file not found
#include <lua.h>
```

且日志中**只有 Tweak.xm 被编译，没有任何 lua .c 文件的编译记录**。

## 二、已验证事实（每条附证据）

| # | 事实 | 证据 |
|---|------|------|
| F1 | lua/lua 仓库（含 v5.3.6 tag）所有源码 `lua.h`、`lapi.c` 等 40+ 文件**全部在仓库根目录，没有 `src/` 子目录**；`src/` 布局只存在于官方 tarball | WebFetch 查看 github.com/lua/lua/tree/v5.3.6 文件列表 |
| F2 | CI 的 Vendor 步骤 `git clone --branch v5.3.6 ... tweak/lib/lua53` 后，lua.h 实际位于 `tweak/lib/lua53/lua.h`；而 Makefile 写的是 `-Ilib/lua53/src`、wildcard 是 `lib/lua53/src/*.c` → **指向不存在的目录** | F1 + run#9 日志（lua.h not found、零个 lua 文件编译） |
| F3 | 旧 Vendor 步骤 `rm -f tweak/lib/lua53/src/lua.c ...` 删错路径（静默失败）→ **`lua.c`（内含 `main()`）仍留在源码中**。即使 include 路径修好，编进 dylib 也会因 `main` 符号链接失败 | F1 + F2 同理 |
| F4 | `ltests.c/ltests.h` 是 lua 开发仓库的调试文件：官方 makefile 默认 `MYCFLAGS` 带 `-DLUA_USER_H='"ltests.h"'` 才配套使用；**我们不用该宏，编译 ltests.c 会重定义内部符号**。官方正式构建列表 = CORE_O(20) + AUX_O(lauxlib) + LIB_O(12) = 33 个文件 | v5.3.6 makefile 原文（已抓取核对） |
| F5 | 删除 lua.c/luac.c/onelua.c/ltests.c（及 .h）后，仓库根目录剩余 `*.c` **恰好 33 个，与官方列表一一对应** | F1 文件列表 + F4 清单比对 |
| F6 | luaconf.h 在无任何 `-DLUA_USE_*` 时走纯 C99 默认路径：不需要 readline/dlopen；`system()`/`popen()` 在 iOS SDK 中是 deprecated 而非 unavailable。**iOS 编译无需额外宏定义** | luaconf.h 原文（已抓取核对） |
| F7 | Theos aggregate.mk 用 `$(MAKE) -C $$d` 进入子项目 → 子 Makefile 解析时 CWD = `tweak/`，相对路径以 tweak/ 为基准；Vendor 步骤在 make 之前执行，wildcard 展开时文件已存在 | theos/makefiles/master/aggregate.mk 源码 + run#9 日志中 `> Making all in tweak…` |
| F8 | `ATLiteTweak_CFLAGS` 确实传到了编译器（错误发生在 `#include <lua.h>` 这一行说明 include 被处理，-I 只是指向了不存在的目录），CFLAGS 传递机制无需改动 | run#9 日志错误位置 |
| F9 | Tweak.xm 的 lua 头文件 include 已用 `extern "C" { ... }` 包裹（第 22-24 行），不存在 C++ 名字修饰导致的链接问题 | Tweak.xm 第 22-24 行 |
| F10 | 工具链、SDK、ldid 安装步骤在第 9 次构建中已全部通过（日志走到了编译阶段） | run#9 日志：apt → theos → toolchain → install-sdk 全部成功后才进入 make |

## 三、根因（唯一）

**F1 + F2**：CI clone 的 lua/lua 仓库是"根目录布局"，而 Makefile 和 rm 命令都按 tarball 的 "src/ 布局" 写 → 头文件找不到 + 源文件没进编译列表 + 含 main() 的文件没被删。

## 四、修复方案（共两处）

### 4.1 `.github/workflows/build.yml` — Vendor Lua 步骤（已改）

```yaml
- name: Vendor Lua 5.3.6
  run: |
    git clone --depth=1 --branch v5.3.6 https://github.com/lua/lua.git tweak/lib/lua53
    cd tweak/lib/lua53
    rm -rf .git manual testes makefile all
    rm -f lua.c luac.c onelua.c ltests.c ltests.h
    ls *.h | head -5
    ls *.c | wc -l     # 预期输出 33
```

说明：
- 按**真实根目录布局**删文件（不再有 src/ 前缀）
- 删 `lua.c/luac.c/onelua.c`（含 main()，F3）
- 删 `ltests.c/ltests.h`（调试文件，F4）
- 步骤末尾自检：`ls *.c | wc -l` 必须输出 `33`（F5），否则该步直接失败

### 4.2 `tweak/Makefile` — 路径改为根目录布局（待改）

```makefile
ATLiteTweak_FILES = Tweak.xm $(wildcard lib/lua53/*.c)
ATLiteTweak_CFLAGS = -fobjc-arc -Ilib/lua53 -Wno-deprecated-declarations
```

仅改动 `src/` → 根目录两处，其余不动。

## 五、已排除的风险（逐条说明为什么不会再炸）

1. **main() 符号冲突** → lua.c/luac.c/onelua.c 已删（F3/F5）
2. **ltests 重定义** → ltests.c/h 已删，且从不定义 LUA_USER_H（F4/F6）
3. **C++ 名字修饰** → extern "C" 已存在（F9）
4. **iOS 平台兼容宏** → 默认配置即可，无需 -D（F6）
5. **wildcard 展开时机** → Vendor 先于 make；CWD=tweak/（F7）
6. **CFLAGS 未传递** → 已证明传递正常（F8）
7. **工具链/SDK/ldid** → 第 9 次构建已验证通过（F10）
8. **app 子项目** → 第 9 次构建未报错即通过（错误发生在 tweak 编译，package 未到 app 之后；app 的编译在 aggregate 中位于 tweak 之后……）

   ⚠️ 注意：第 9 次构建失败在 tweak，app 子项目**尚未被构建验证过**。这是本次构建中唯一可能暴露的新错误面。风险登记：app 源文件（main.m、ATLAppDelegate、ATLRootViewController、ATLWebServer）为常规 ObjC/UIKit 代码，无第三方依赖；若失败按同样流程（取日志→定根因→改计划）处理，不盲目重试。

## 六、构建前检查清单（逐项核对）

- [ ] C1：build.yml Vendor 步骤与 4.1 一致（含 rm 列表与自检）
- [ ] C2：tweak/Makefile 与 4.2 一致（`lib/lua53/*.c`、`-Ilib/lua53`，无 src/ 残留）
- [ ] C3：Tweak.xm include 的 lua 头（lua.h/lualib.h/lauxlib.h）都在 -I 覆盖范围内
- [ ] C4：仓库中不存在对 `lib/lua53/src` 的其它引用（全仓 grep 确认）
- [ ] C5：`git status` 干净后再 push（避免把无关文件带上去）
- [ ] C6：push 后只观察，不中途改代码

## 七、本次构建的预期日志（验收标准）

1. Vendor 步骤输出 `ls *.c | wc -l` = **33**
2. `> Making all for tweak ATLiteTweak…` 后出现 **33 个 lua .c 文件 + Tweak.xm 的编译记录**（arm64、arm64e 各一遍）
3. 链接 `ATLiteTweak.dylib` 成功，无 undefined symbol
4. app 子项目编译链接成功
5. `make package` 产出 `packages/*.deb`，Upload artifact 成功

若任何一条不满足：停止、取日志、回到本计划书补充事实、修订方案后重来。

---

## 修订 1（run#10 结果 → 修订）

### run#10 实际结果

- ✅ 验收标准第 1 条通过：Vendor 步骤正常
- ✅ 验收标准第 2 条部分通过：33 个 lua .c 全部进入编译，**除 loslib.c 外全部编译通过**（含此前从未验证过的 loadlib/liolib/llex 等）
- ❌ 新失败点：`loslib.c:143: error: 'system' is unavailable: not available on iOS`

### 新增事实

| # | 事实 | 证据 |
|---|------|------|
| F11 | iPhoneOS16.5 SDK 将 `system()` 标记为 **unavailable（硬错误）**，而非 deprecated | run#10 日志原文 + SDK `stdlib.h:184` |
| F12 | loslib.c 非 POSIX 分支中调用的 libc 函数里，只有 `system` 是 unavailable；`tmpnam`（os.tmpname）、`getenv`、`exit` 等均可用。其余 32 个 lua 文件在 run#10 已实际编译通过 | loslib.c v5.3.6 原文（已抓取核对）+ run#10 编译日志 |

### 修订方案（4.3，新增一步）

在 Vendor Lua 之后新增 **Patch loslib** 步骤：用 sed 把 `os.execute` 的 `system(cmd)` 调用替换为恒失败桩，并断言补丁生效：

```bash
cd tweak/lib/lua53
sed -i 's|int stat = system(cmd);|int stat = -1; if (cmd == NULL) { lua_pushboolean(L, 0); return 1; } /* system() unavailable on iOS */|' loslib.c
! grep -q "system(cmd)" loslib.c   # 断言：调用已移除，否则步骤失败
```

语义说明：`os.execute(cmd)` 一律返回 nil（无法执行），`os.execute()`（无参探测 shell）返回 false。ATLite 脚本引擎不使用 os.execute，此行为符合预期。

### 修订后检查清单（增量）

- [ ] C7：build.yml 中 Patch 步骤位于 Vendor 之后、make 之前
- [ ] C8：sed 模式串与 loslib.c 原文逐字一致（`int stat = system(cmd);`，已核对）
- [ ] C9：断言命令 `! grep -q "system(cmd)"` 在位

---

## 修订 2（run#11 结果 → 修订）

### run#11 实际结果

- ✅ loslib 补丁生效：`system` 错误消失，编译推进到 ltm.c/lundump.c
- ❌ 新失败点：`lundump.c:244: error: adding 'int' to a string [-Werror,-Wstring-plus-int]`

### 新增事实

| # | 事实 | 证据 |
|---|------|------|
| F13 | Theos 默认 CFLAGS 含 `-Werror`；`lundump.c:244` 的 `LUA_SIGNATURE + 1` 是 Lua 故意的指针惯用法（跳过签名首字符），clang 的 `-Wstring-plus-int` 警告在 -Werror 下升级为错误 | run#11 日志原文（含 "use array indexing to silence" 提示） |
| F14 | 已知 lua 5.3.6 在 clang 下唯一惯用式警告即此一处；deprecated 警告（tmpnam 等）已被现有 `-Wno-deprecated-declarations` 覆盖 | run#10/#11 编译日志中其余文件零警告 |

### 修订方案（4.4）

`tweak/Makefile` 的 CFLAGS 追加 `-Wno-error=string-plus-int`（仅豁免该警告，不全局关闭 -Werror，Tweak.xm 自身代码仍受完整 -Werror 约束）：

```makefile
ATLiteTweak_CFLAGS = -fobjc-arc -Ilib/lua53 -Wno-deprecated-declarations -Wno-error=string-plus-int
```

### 修订后检查清单（增量）

- [ ] C10：Makefile CFLAGS 行与 4.4 完全一致；仓库无其它 -Werror 相关配置需改动

---

## 修订 3（run#12 结果 → 修订）

### run#12 实际结果

- ✅ **33 个 lua .c 全部编译通过，Lua 层打通**
- ❌ 新失败点：Tweak.xm 自身 4 个错误（557/559/579/580），全部集中在 Vision OCR 段

### 新增事实

| # | 事实 | 证据 |
|---|------|------|
| F15 | theos iPhoneOS16.5.sdk 的 `Vision.framework/Headers` **没有 VNRecognizedText.h**（目录清单已核对），VNRecognizedText 仅有 `@class` 前置声明 → 编译器不知道 `topCandidates:`/`boundingBox`。这些 API 运行时 iOS 13+ 存在，部署目标 14.0 | theos/sdks 仓库 Vision.framework/Headers 目录清单（API 查询） |
| F16 | `pt[0].intValue`（id 接收者的属性点语法）在该工具链下报 "property not found on object of type 'id'"；改用类型化局部变量静态绑定即可 | run#12 日志 |

### 修订方案（4.5）

1. Tweak.xm 在 import 之后加 SDK 兼容类别（运行期安全，仅补编译期声明）：

```objc
@interface VNRecognizedText (ATLiteSDKCompat)
- (NSArray<VNRecognizedText *> *)topCandidates:(NSUInteger)maxCandidateCount;
@property (nonatomic, readonly) CGRect boundingBox;
@end
```

2. `findText` 结果循环改为类型化局部变量：

```objc
for (NSArray *pt in hits) {
    lua_newtable(L);
    NSNumber *x = pt.firstObject;
    NSNumber *y = pt.lastObject;
    lua_pushinteger(L, x.intValue); lua_rawseti(L, -2, 1);
    lua_pushinteger(L, y.intValue); lua_rawseti(L, -2, 2);
    lua_rawseti(L, -2, ++n);
}
```

### 风险登记（更新）

- Tweak.xm 修复后：链接 dylib → app 子项目（**从未被构建验证**，普通 UIKit 代码，无三方依赖）→ 打包 deb。若 app 失败，按同一流程处理。

### 修订后检查清单（增量）

- [ ] C11：类别声明位置在 import 之后、首次使用之前；CGRect 类型已可见（CoreGraphics 已导入）
- [ ] C12：findText 循环与 4.5 一致，全文件不再有对 id 的属性点访问（grep 确认）

---

## 修订 4（run#13 结果 → 修订）

### run#13 实际结果

- ✅ **tweak 全部完成：33 个 lua .c + Tweak.xm 在 arm64/arm64e 双架构编译并链接成功**（`==> Linking tweak ATLiteTweak` 通过，仅有一条 `-undefined dynamic_lookup` 弃用警告，非错误）
- ❌ 失败点移至 app 子项目：`main.m:5: use of undeclared identifier 'ATLAppDelegate'`

### 新增事实

| # | 事实 | 证据 |
|---|------|------|
| F17 | `main.m` 缺 `#import "ATLAppDelegate.h"`；同类问题：`ATLRootViewController.m` 也缺 `#import "ATLRootViewController.h"`（`@implementation` 需要可见的类声明，将是下一个错误） | 本地源码核查（run#13 中该文件尚未编译到） |
| F18 | app 其余文件导入完备：ATLAppDelegate.m 导入两个头 ✅；ATLWebServer.m 导入自身头 ✅；交叉引用（ATLRootViewController→ATLWebServer 等）均有可见声明 | 本地源码核查 |

### 修订方案（4.6）

1. `app/Source/main.m`：加 `#import "ATLAppDelegate.h"`
2. `app/Source/ATLRootViewController.m`：加 `#import "ATLRootViewController.h"`

### 修订后检查清单（增量）

- [ ] C13：两处 import 已加；app 全部 4 个 .m 的 `@implementation` 类在编译单元内均有可见 `@interface`（import 链核查）
- [ ] C14：全仓 grep 确认无其它 "用类但未导入头" 的情况

---

## 修订 5（run#14 结果 → 修订）

### run#14 实际结果

- ✅ main.m、ATLAppDelegate.m、ATLWebServer.m 编译通过（日志无其它错误）
- ❌ `ATLRootViewController.m`：11 个错误，两个根因

### 新增事实

| # | 事实 | 证据 |
|---|------|------|
| F19 | Darwin 的 `ifaddrs.h` 只定义 `struct ifaddrs`，**没有 typedef**；`ifaddrs *i` 在 ObjC++ 中是"未声明标识符"并连锁报错。必须写 `struct ifaddrs *` | run#14 日志（75 行起连锁 use of undeclared identifier 'i'） |
| F20 | `ip` 声明为 `NSMutableString*`，把 `[NSString stringWithUTF8String:]`（instancetype→NSString*）赋给它，在 -Werror 下是 `-Wincompatible-pointer-types` 硬错误；改用 `[NSMutableString stringWithUTF8String:]` | run#14 日志（82 行） |

### 修订方案（4.7）

`deviceIPAddress` 函数三处：`struct ifaddrs *ifs`、`for (struct ifaddrs *i = ...)`、`ip = [NSMutableString stringWithUTF8String:buf]`。

### 修订后检查清单（增量）

- [ ] C15：ATLWebServer.m（含 sockaddr 等 C 结构）在 run#14 已编译通过，无需改动；确认剩余流程为：链接 app → ldid 签名 → dpkg-deb 打包，无其它已知风险

---

## 修订 6（run#15 结果 → 修订）

### run#15 实际结果

- ✅ **app 完整构建成功**：编译（4 个 .m，双架构）→ Linking → Merging → Signing 全部通过
- ✅ tweak 双架构编译+链接成功
- ❌ tweak **stage 阶段**：`Error: You are missing a filter property list. Make sure it's named "ATLiteTweak.plist" or "Filter.plist"`

### 新增事实

| # | 事实 | 证据 |
|---|------|------|
| F21 | Theos tweak.mk 的 stage 规则要求 filter plist 文件名与 `TWEAK_NAME` 完全一致（或通用名 `Filter.plist`）；原文件名为 `ATLite.plist` 不匹配 `TWEAK_NAME = ATLiteTweak` | run#15 日志 |
| F22 | L1ghtmann 工具链 arm64e 有 `incompatible arm64e ABI compiler` 警告（仅 ld warning，非错误，产物正常生成；app 已链接/签名成功） | run#15 日志 |

### 修订方案（4.8）

`git mv tweak/ATLite.plist tweak/ATLiteTweak.plist`（内容不变）。

### 修订后检查清单（增量）

- [ ] C16：plist 已改名且内容（Filter Bundles: com.apple.UIKit + com.apple.springboard, Mode: Any）不变
- [ ] C17：预期剩余流程：stage（tweak+app 安装到 .theos/_/）→ dpkg-deb 打包 → artifact 上传；全部为 theos 标准步骤，无代码风险

---

## 修订 7（真机安装架构不匹配 → roothide 支持）

### 问题（用户真机 `dpkg -i` 报错，NewTerm 截图）

```
dpkg: error processing archive .../ATLite_0.1.0_iphoneos-arm64.deb (--install):
 package architecture (iphoneos-arm64) does not match system (iphoneos-arm64e)
```

用户设备为 **roothide 版 Dopamine**（需求初始即明确），其 dpkg 系统架构为 `iphoneos-arm64e`。

### 新增事实

| # | 事实 | 证据 |
|---|------|------|
| F23 | roothide 包规格：`Architecture: iphoneos-arm64e`，**无前缀 rootful 式布局**（~~前缀 `/rootfs/var/jb`~~ 已被 E22/R22 推翻：官方 com.roothide.patcher deb 实证无前缀，roothide dpkg 在 vroot 下自动装进随机 jbroot）；rootless 包为 `iphoneos-arm64` + `/var/jb`；rootful 为 `iphoneos-arm` | JBDev DeepWiki 架构映射表；官方 patcher deb 拆解 |
| F24 | Theos 官方 `vendor/mod/` 只有 `rootless` 一个 scheme 模块，**没有 roothide** | theos/theos 仓库 API（mod/ 仅 .keep；vendor/mod/ 仅 rootless/） |
| F25 | Theos `deb.mk` 打包时 sed 删除 control 的 `Architecture:` 行，再用 `echo "Architecture: $(THEOS_PACKAGE_ARCH)"` 重写 → **改 control 文件的 Architecture 无效**，必须让 `THEOS_PACKAGE_ARCH` 本身等于 `iphoneos-arm64e` | makefiles/package/deb.mk 源码 |
| F26 | rootless scheme 模块 `vendor/mod/rootless/package/deb.mk` 强制 `THEOS_PACKAGE_ARCH := iphoneos-arm64`，覆盖任何外部设置 | 同上模块源码 |
| F27 | `_THEOS_SCHEME_STAGE` 由 common.mk L272-273 从 `THEOS_PACKAGE_INSTALL_PREFIX` 自动推导；自制 scheme 模块只需两个文件：`package.mk`（设前缀）+ `package/deb.mk`（设 ARCH） | common.mk / rootless 模块结构 |
| F28 | **二进制无需重编**：run#16 已验证 dylib 为 arm64+arm64e fat；roothide 设备（A12+，arm64e）加载 arm64e slice，App 同理 | run#16 产物 fat header 验证 |
| F29 | roothide 下 `/var/jb` 是指向随机 jbroot 的 symlink（Dopamine-roothide DOBootstrapper.m L481 实证）；tweak 内 `ATJBRoot()` 探测 `/var/jb` 天然兼容；jbroot 真实位置 `/var/containers/Bundle/Application/.jbroot-*`（同文件 find_jbroot 实证） | Dopamine-roothide 2.x 源码 |
| F30 | App 包装后必须执行 uicache，否则桌面不显示图标；postinst 需容错（uicache 不存在时不得让 dpkg configure 失败） | JBDev 文档 "System Application Already Installed Error" |

### 修订方案（4.9）

1. CI「Setup Theos」后新增步骤：自制 roothide scheme 模块（写 `$THEOS/vendor/mod/roothide/{package.mk,package/deb.mk}`，仿 rootless；**package.mk 留空不设前缀**（E22/R22 修正），package/deb.mk 强制 ARCH `iphoneos-arm64e`）
2. workflow env 与 3 个 Makefile：`THEOS_PACKAGE_SCHEME` rootless → roothide
3. `control`：`Architecture: iphoneos-arm64e`（保持一致性；实际生效值由 F25 机制决定）
4. 新增 `app/layout/DEBIAN/postinst`（可执行）：`uicache -p .../ATLite.app || true`
5. 下载页 `index.html` deb 文件名同步为新产物名

### 修订后检查清单（增量）

- [ ] C18：workflow 中 scheme 模块创建步骤位于 Build package 之前；模块两文件内容与方案一致
- [ ] C19：env + Makefile + tweak/Makefile + app/Makefile 共 4 处 scheme 均为 roothide；全仓无残留 rootless（排除 docs 历史记录）
- [ ] C20：postinst 存在、git 模式下为 755、含 `|| true` 容错
- [ ] C21：control Architecture 与 index.html 文件名同步为 arm64e

---

## 修订 8（run#18 结果 → 修订）

### run#18 实际结果

- ✅ 33 个 Lua 文件 + Tweak.xm 双架构编译全部通过（roothide scheme 不影响编译）
- ❌ 链接阶段（arm64/arm64e 双双）：`ld: library not found for -lroot_oldabi`

### 新增事实

| # | 事实 | 证据 |
|---|------|------|
| F31 | Theos 对 `THEOS_TARGET_NAME=iphone` 的实例无条件加 `-lroot$(ABI_SUFFIX)`；`ABI_SUFFIX` 由 `IS_NEW_ABI` 决定：clang < 12（L1ghtmann clang-11）→ `_oldabi` | makefiles/instance/rules.mk L126-142 |
| F32 | scheme 非空时，Theos 库搜索路径为 `$THEOS/lib/iphone/<scheme>/`（**不含** lib 根目录）；rootless 目录含 `libroot.a`+`libroot_oldabi.a`+各 .tbd，故 rootless 构建可链接；roothide 目录不存在 → ld 失败 | common.mk L195-203；theos/lib 仓库 API |
| F33 | 本项目的 dylib/App 未调用任何 libroot 函数（未 import rootless.h），`-lroot_oldabi` 仅为 Theos 无条件添加，静态库中未引用符号不会进入产物 | 代码审查；静态库链接语义 |

### 修订方案（4.10）

CI 的 roothide scheme 模块步骤中，将 rootless 的 lib 目录复制为 roothide：
`cp -r $THEOS/lib/iphone/rootless/. $THEOS/lib/iphone/roothide/`（libroot_oldabi.a 等对新 scheme 同样有效——F33）。

### 修订后检查清单（增量）

- [ ] C22：lib 复制步骤在 Setup roothide scheme module 内、Build package 之前
- [ ] C23：复制后 `$THEOS/lib/iphone/roothide/libroot_oldabi.a` 存在（CI 内断言）

---

## 修订 9（run#20/#21 结果 → 修订与收官）

### run#20 实际结果（set -x 追踪）

`ls $THEOS/lib/iphone/rootless/` **无输出** → 主仓库 `lib/iphone/rootless` 是**空壳目录**；真实库在 `$THEOS/vendor/lib/iphone/rootless`（recursive clone 的 theos/lib 子模块——rootless 构建（run#16）时 ld 就是从这里找到 `libroot_oldabi.a` 的，common.mk 搜索路径 vendor 在前）。

### run#21 实际结果

- ✅ **构建成功**，产物 `me.atlite.ios_0.1.0_iphoneos-arm64e.deb`
- ✅ control：`Architecture: iphoneos-arm64e`（roothide 设备可装）
- ✅ data.tar：`rootfs/var/jb/Applications/ATLite.app` + `rootfs/var/jb/Library/MobileSubstrate/DynamicLibraries/ATLiteTweak.dylib` + `ATLiteTweak.plist`
- ✅ dylib fat：arm64(subtype 0x0) + arm64e(subtype 0x2)
- ❌ **control.tar 缺 postinst**：子项目 `app/layout/DEBIAN/postinst` 未进入聚合包

### 新增事实

| # | 事实 | 证据 |
|---|------|------|
| F34 | Theos 主仓库 `lib/iphone/rootless` 为空壳；真实库在 `vendor/lib/iphone/rootless`（theos/lib 子模块）；common.mk 的 scheme 搜索路径 vendor 在前 | run#20 set -x 日志；theos/lib 仓库 API |
| F35 | `_THEOS_HAS_STAGING_LAYOUT` 在顶层 make 解析时一次性计算并导出，聚合子项目的 `layout/` 检测失效——子项目 `app/layout/DEBIAN/` 不会进包；**根级 `layout/DEBIAN/` 才会被顶层 internal-stage rsync** | common.mk L133-135 guard；run#21 产物 control.tar 仅含 control |

### 修订方案（4.11）

`git mv app/layout/DEBIAN/postinst layout/DEBIAN/postinst`（根级 layout，F35）。

### 修订后检查清单（增量）

- [ ] C24：新产物 control.tar 含 postinst 且 data.tar 布局不变（arm64e + rootfs/var/jb）
- [ ] C25：工作区 deb 与下载页 index.html 同步更新为新产物

---

## 修订 10（拟人化输入 + 修复两个会让真机触摸整个失效的 bug）

### 问题

用户要求三项拟人化：**点击坐标抖动、随机时间戳、随机接触面积**。

### 新增事实（全部来自权威源码，非推测）

| # | 事实 | 证据 |
|---|------|------|
| F36 | IOKit 真实的 setter 符号是 `IOHIDEventSetIntegerValue(event, field, int32_t)` 与 `IOHIDEventSetFloatValue(event, field, IOHIDFloat)`；**`IOHIDEventSetInteger` 这个符号不存在** | nanotech/iphoneheaders IOHIDEvent.h L190-193；witchan/ios-mcp IOHIDPrivate.h L220-221（真机提取、专为 dlsym 编写）；KIF 直接链接调用 |
| F37 | **当前代码 dlsym("IOHIDEventSetInteger") → NULL → 符号完整性检查失败 → gHIDReady=NO → 真机上所有触摸/按键静默失效**。CI 构建永远发现不了（dlsym 是运行时行为）——这是用户真机测试前必须修掉的头号 bug | 本地 Tweak.xm L114-128 逻辑 + F36 |
| F38 | `kIOHIDEventFieldDigitizerIsDisplayIntegrated = 0x000B0019`（base+25），**不是** 0x000B000B（0x000B000B 是 BarrelPressure=base+11）。base = kIOHIDEventTypeDigitizer(11)<<16 = 0x000B0000 | WebKit 官方 IOKitSPIIOS.h L110-112：`MajorRadius = X+20`、`IsDisplayIntegrated = MajorRadius+5`；KIF 枚举顺序一致；rpc-project consts.py 一致；IDAObjcTypes Types.h L261/266 一致 |
| F39 | `kIOHIDEventFieldDigitizerMajorRadius = 0x000B0014`，`MinorRadius = 0x000B0015` | WebKit（显式算式）；KIF 枚举；ZXTouch 文档 0xb0014/0xb0015 |
| F40 | 坐标**直接传点值**（不归一化），配合 IsDisplayIntegrated=1——这是 Apple 自家测试框架 KIF 的用法（`locationInView` 直接传入） | KIF IOHIDEvent+KIF.m L161-180 |
| F41 | 半径单位是 **mm**（Apple 头文件文档：默认 majorRadius=5mm）；KIF 传 5.0/5.0。真人指尖接触椭圆约 3.5~6mm | nanotech IOHIDEvent.h @discussion |
| F42 | 参考实现的 hand（父）事件模式：index=0、identity=0、x/y/z=0、压力=0、mask=Touch、range=0、touch=true；位置与状态全部由 finger（子）事件携带。SimulateTouch（SpringBoard 上下文，最贴近本项目）与 KIF 完全一致 | SimulateTouch TouchSimulator.xm；KIF L139-154 |
| F43 | finger 事件：index 从 1 起（KIF：touches+1）、identity=2（IOHIDFamily 源码注释 "identity = 2; // Multitouch interprets this as 'finger'"）、mask 动态（down/up=Range\|Touch，move=Position\|Touch）、range/touch = isTouching、tipPressure=0 | 同上 + blueboxd/IOHIDFamily IOHIDEvent.cpp |
| F44 | 我们现有的 hand 事件参数（携带真实 x/y、pressure、动态 mask、identity=3）偏离所有参考实现，且**从未在真机验证过**（此前版本因 F37 触摸整个是死的） | 本地代码 L148-155 vs F42 |

### 修订方案（4.12）

**A. 修两个致命 bug（F37/F38）**：符号名改 `IOHIDEventSetIntegerValue`、新增 `IOHIDEventSetFloatValue`；IsDisplayIntegrated 改 0x000B0019。

**B. 对齐参考实现（F42/F43）**：hand 事件改参考模式；finger index=finger+1、identity=2。

**C. 三项拟人化**：
1. 坐标抖动：`ATJitter()` —— down/up ±2pt、move ±1pt（真人无法精准复点同一像素）
2. 随机时间戳：`ATTimestampNow()` = mach_absolute_time() ± 1ms（按 mach_timebase 换算 ticks）；tap() 按住时长从固定 16ms 改 60-120ms 随机（固定 16ms 是最典型的机器特征）
3. 随机接触面积：majorRadius 3.5~6.0mm、minorRadius 2.5~4.5mm（minor≤major），经 `IOHIDEventSetFloatValue` 设置

**D. Extensions.lua 升 v2**：加版本标记；Lua 5.3 默认种子固定，用 /dev/urandom 播种 math.random；`ATEnsureLuaLibraries` 改版本感知（旧文件备份为 .bak 后覆写——否则已安装设备上旧 Extensions.lua 不会更新）。

### 修订后检查清单（增量）

- [ ] C25：全仓无 `IOHIDEventSetInteger`（不带 Value）残留
- [ ] C26：全仓无 `0x000B000B` 残留；0x000B0014/15/19 三个常量在位
- [ ] C27：dlsym 列表与完整性检查含 SetIntegerValue + SetFloatValue
- [ ] C28：hand 事件参数与 F42 一致；finger index=finger+1、identity=2
- [ ] C29：Extensions.lua v2 标记 + randomseed + tap 60-120ms；ATEnsureLuaLibraries 版本逻辑读 "v2" 标记
- [ ] C30：git diff 全量审查后才允许推送

---

## 修订 11（run#24 编译错误 + 抓屏签名的真机级取证）

### run#24 实际结果

`Tweak.xm:196: error: too few arguments to function call, expected 14, have 13`

### 新增事实（反汇编 AutoTouch libATGraphic.iOS15.0.dylib 实证）

| # | 事实 | 证据 |
|---|------|------|
| F45 | finger 事件 typedef 多一个 uint32（14 vs 真实 13）。原代码靠多传一个 `0` 绕过编译，但会把 range/touch/options 错位到错误寄存器（x5/x6/x7 偏移）——**即原版触摸即使符号修好也是错的** | 真实签名（nanotech/iphoneheaders IOHIDEvent.h）：`IOHIDEventCreateDigitizerFingerEvent(allocator, timeStamp, index, identity, eventMask, x, y, z, tipPressure, twist, range, touch, options)` = 13 参；SimulateTouch 实参 13 个 |
| F46 | AutoTouch 抓屏**不用 CaptureDisplay**，而是 `IOSurfaceCreate` + `CARenderServerRenderDisplay(0, CFSTR("LCD"), surface, 0, 0)` + `IOSurfaceLock/Unlock` + `IOSurfaceGetBaseAddress` | libATGraphic 导入符号表：仅 `_CARenderServerRenderDisplay`（无 CreateServer/CaptureDisplay）；调用点 0xf713dc 反汇编：`mov w0,#0; adrp/add x1→CFString"LCD"; ldr x2,[x19+0x58](surface); mov w3,#0; mov w4,#0; bl` |
| F47 | CARenderServer 家族首参数为 `uint32_t serverPort`（0=默认），第二参数为**显示屏名 CFStringRef**（iOS 上 "LCD"，备选 "Main"）——`CaptureDisplay(port, displayName, options) → IOSurfaceRef` | F46 的 RenderDisplay(0, @"LCD", ...) + witchan/ios-mcp（真机工具）：`CARenderServerCaptureDisplayFunc = CGImageRef(*)(uint32_t serverPort, CFStringRef displayName, CFDictionaryRef options)`，实参 `(0, @"LCD"/@"Main", nil)`，返回值送 `UICreateCGImageFromIOSurface`（证明实为 IOSurfaceRef） |
| F48 | 键盘事件真实签名 usagePage/usage 为 uint16_t（值 0x0C/0x40 等均 < 0x10000，uint32 传参兼容但按真实类型收窄） | nanotech/iphoneheaders IOHIDEvent.h L150 |

### 修订方案（4.13）

1. finger typedef 14→13（对齐真实签名，修 run#24 编译错误；新调用本就 13 参）
2. 抓屏改 `CaptureDisplay(0, CFSTR("LCD"), NULL)`，失败回退 `(0, CFSTR("Main"), NULL)`；删 CreateServer；读前后加可选 `IOSurfaceLock/Unlock`（kIOSurfaceLockReadOnly=1）
3. 键盘 typedef usagePage/usage 收窄为 uint16_t

### 修订后检查清单（增量）

- [ ] C31：finger typedef 参数个数 = 13；调用实参 = 13
- [ ] C32：CaptureDisplay typedef = (uint32_t, CFStringRef, CFDictionaryRef)；调用 (0, CFSTR("LCD"), NULL) + "Main" 回退；无 CreateServer 残留
- [ ] C33：IOSurfaceLock/Unlock 为可选符号（缺失不阻塞 capture ready）

---

## 修订 12（真机 App 闪退根因：Info.plist 占位符未替换）

### 真机现象

deb 安装成功，但点击 ATLite 图标 App 立即闪退（无法打开）。

### 根因（已从 run#25 产物解包实锤）

实装到 `ATLite.app/Info.plist` 的 `CFBundleExecutable` 是字面量 `$(EXECUTABLE_NAME)` —— 这是 Xcode 的构建变量占位符，**Theos 不做替换**。SpringBoard/launcher 按 CFBundleExecutable 定位可执行文件，找不到名为 `$(EXECUTABLE_NAME)` 的二进制 → 启动即失败。

### 事实

| # | 事实 | 证据 |
|---|------|------|
| F49 | Theos 打包时不替换 Info.plist 中的 Xcode 风格 `$(VAR)` 占位符 | run#25 deb 解包：data.tar 内 Info.plist 仍含 `$(EXECUTABLE_NAME)` 原文 |
| F50 | 仓库 Info.plist 全文仅此一处 `$(...)` 占位符 | grep 确认 |

### 修订方案（4.14）

`app/Resources/Info.plist`：`$(EXECUTABLE_NAME)` → `ATLite`（与应用二进制名/CFBundleName 一致）。

### 检查清单（增量）

- [x] C34：全文件无 `$(...)` 残留
- [x] C35：plistlib 解析通过，CFBundleExecutable == ATLite == 实际二进制名（app/Makefile APPLICATION_NAME）
- [ ] C37：新产物 deb 解包后 Info.plist 的 CFBundleExecutable == ATLite（产物级验证）
