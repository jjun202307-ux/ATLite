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
