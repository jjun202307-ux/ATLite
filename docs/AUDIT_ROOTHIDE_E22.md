> 历史资料：保留原始研究与决策记录，不代表 v0.3.11 当前实现。以 TECHNICAL.md 与 LIGHTWEIGHT_PLAN.md 为准。

# roothide 兼容性二次核验报告（E22/R22）

> 方法：`debug-error-recovery` 六阶段 + `pc-debugging-expert` 四步法
> 目的：验证 v0.3.1 的修复不是"症状消失"，而是根因被定位、修复彻底、且有能捕获复发的断言
> 核验时间：2026-10-24

---

## 阶段 1 · 稳定复现

**一条命令，最小输入**（无需构建、无需真机）：

```bash
python tools/verify_roothide_layout.py --samples 8 \
    --deb <v0.3.1.deb> --deb <v0.3.0.deb>
```

输出即判定：`rootfs` 前缀条目数 > 0 说明该包不符合 roothide 布局规范。

**实测结果**：

| 包 | arch | data.tar 路径数 | `rootfs/var/jb` 前缀条目 |
|---|---|---|---|
| me.atlite.ios **0.3.1**（修复后） | iphoneos-arm64e | 13 | **0** ✅ |
| me.atlite.ios **0.3.0**（修复前） | iphoneos-arm64e | 16 | **15** ❌ |
| 官方 8 个样本（Tweaks/System/Utilities 等） | iphoneos-arm64e | 155 | **0** ✅ |

**判定**：10 个样本中，唯一带前缀的包就是修复前的我们自己的包。根因假设得到统计确认。

---

## 阶段 2 · 定位（在哪一层）

失败层 = **构建工具层**（Theos scheme 模块的 `THEOS_PACKAGE_INSTALL_PREFIX`）+ **打包元数据层**（postinst 路径写法），不是代码逻辑层。

判断依据：包内路径由 staging 目录决定，staging 前缀由 scheme 模块 `package.mk` 决定；postinst 是打包层常量字符串。

---

## 阶段 3 · 缩减

最小复现体 = 只看两样：

1. `data.tar` 的顶层目录名（`rootfs` vs `Applications`/`Library`）
2. `postinst` 里的路径常量（`/rootfs/var/jb/...` vs `/Applications/...`）

---

## 阶段 4 · 根治（含假设验证）

### 假设 A：官方 roothide 包是"无前缀 rootful 式"布局

**预测**：官方源任意 arm64e 包的 data.tar 顶层目录应为 `Applications` / `Library` / `usr`，不应出现 `rootfs` / `var`。
**验证**：抓 8 个不同 Section 的官方包，顶层分布为 `Library 152`、`Applications 7`，`rootfs` 仅出现在我们 v0.3.0。
**结论**：假设成立（样本量从 n=1 提升到 n=8）。

### 假设 B：tweak dylib 装在 `Library/MobileSubstrate/DynamicLibraries`

**预测**：官方 tweak 包的 .dylib 都在该目录（相对 jbroot 根，无前缀）。
**验证**：8 个样本中 8 个 .dylib 条目全部落在该目录。
**结论**：成立 —— 我们的 tweak 目录正确，且 `dladdr` 自推导逻辑（去掉该目录后缀得 jbroot）与安装路径天然一致。

### 假设 C：`/var/jb` 是指向 jbroot 的 symlink（v0.3.0 碰巧能装的原因）

**预测**：Dopamine-roothide 源码中存在创建该 symlink 的调用。
**验证**：`DOBootstrapper.m` **L481**
```objc
error = [self createSymlinkAtPath:@"/var/jb" toPath:JBROOT_PATH(@"/") createIntermediateDirectories:YES];
```
且 **L410–422** 会先执行 `// Remove /var/jb as it might be wrong` 删除旧链接。
**结论**：成立 —— 该 symlink 是 Dopamine-roothide 的**自有行为，不是 roothide 的通用保证**。这正是"v0.3.0 能装上"的侥幸来源，也是必须改的硬理由。

### 假设 D：jbroot 真实位置是 `/var/containers/Bundle/Application/.jbroot-<16hex>`

**验证**：`DOBootstrapper.m` **L817** `find_jbroot()` 遍历的正是该目录，L766 `#define JB_ROOT_PREFIX ".jbroot-"`、L767 `#define JB_RAND_LENGTH (sizeof(uint64_t)*sizeof(char)*2)` = 16。
**结论**：成立 —— tweak 与 App 两侧的回退探测已改为该实证位置（旧值 `/var/mobile/.jbroot-*` 无任何证据支持，已废）。

---

## 阶段 5 · 防复发（RED 实测，唯一能证明断言有效的动作）

**做法**：取 v0.3.0 快照（`git archive e13bb46`），用 v0.3.1 的**新断言**去跑旧代码。

```bash
git archive e13bb46 | tar -x -C /tmp/red/v030
cp tools/verify_static.py /tmp/red/v030/tools/
cd /tmp/red/v030 && python tools/verify_static.py .
```

**结果：55 PASS / 6 FAIL**，R22 五条全部变红 ——

```
[FAIL] R22-E22 CI 无 /rootfs/var/jb 前缀
[FAIL] R22-E22 roothide package.mk 置空
[FAIL] R22-E22 postinst 用 vroot 路径
[FAIL] R22-E22 tweak 探测实证 jbroot 位置
[FAIL] R22-E22 app 探测实证 jbroot 位置
[FAIL] V 版本0.3.1三处同步          ← 版本号差异，属预期噪音
```

**GREEN 对照**：当前 v0.3.1 → **61 PASS / 0 FAIL**。

**结论**：5 条 R22 断言满足"无修复则失败"，是有效回归测试，不是摆设。

---

## 阶段 6 · 端到端验证

| 项 | 结果 |
|---|---|
| 静态套件（当前仓库） | 61 PASS / 0 FAIL |
| 静态套件（旧版对照） | 55 PASS / 6 FAIL（预期，证明断言有效） |
| CI 构建 | run#40076117948 一次通过 |
| 产物验收 | 15 项全过：`./Applications/ATLite.app`、`./Library/MobileSubstrate/DynamicLibraries/`、arch=arm64e、图标 120/180、entitlements 四键嵌入、`CFBundleExecutable=ATLite`、test.at 随包 |
| 官方布局对齐（本轮新增） | data.tar 顶层无 `rootfs`，与 8 个官方样本一致 |

---

## 兄弟 bug 扫描（同类推测路径是否还有遗漏）

全仓库 grep `/var/jb|/var/mobile|\.jbroot|/rootfs|/Applications|/Library/MobileSubstrate`（排除 docs）：

- `tweak/Tweak.xm` L70 — 探测目录 `/var/containers/Bundle/Application` ✅ 已改
- `app/Source/ATLRootViewController.m` L25 — 探测目录 `/var/containers/Bundle/Application` ✅ 已改
- `ATBaseDir()` = `<jbroot>/var/mobile/Library/ATLite` — 自建数据目录，roothide jbroot 即完整根，路径合法 ✅
- `layout/DEBIAN/postinst` — `/Applications/ATLite.app`（vroot 路径，对齐官方 Patcher）✅
- `.github/workflows/build.yml` — `package.mk` 置空（无前缀）✅

**未发现遗漏。**

---

## 结论

| 核验目标 | 判定 |
|---|---|
| 根因定位是否准确 | ✅ 准确（多样本统计 + 源码实证，非推测） |
| 修复是否彻底 | ✅ 彻底（布局/postinst/探测路径三处全部对齐官方证据） |
| 防复发断言是否有效 | ✅ 有效（RED 实测 5 条变红） |
| 是否引入新问题 | ✅ 无 |
| 是否需要再次构建 | ❌ 不需要（v0.3.1 产物已验收，本轮仅新增核验工具与文档） |

**新增强化**：`tools/verify_roothide_layout.py` —— 可重复运行的官方源布局取证器，把"我记得是这样"变成"一条命令可复核"。
