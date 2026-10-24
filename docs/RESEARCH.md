# ATLite 重研究文档（v0.3.0 事实基线）

> 全部技术结论重新取证，不沿用旧文档假设。证据分三级：★★★=参考实现二进制反汇编/内嵌数据（真机运行证明），★★=Apple/WebKit 官方源码，★=社区权威文档。
> 保留的应用框架与功能清单见 SPEC.md；本文件只管"怎么做"。

## A. 越狱 App 的打包与启动（本次事故的直接来源）

| # | 事实 | 证据等级与来源 |
|---|------|----------------|
| A1 | App 图标必须显式声明：`CFBundleIcons`→`CFBundlePrimaryIcon`→`CFBundleIconFiles:[AppIcon60x60]`+`CFBundleIconName:AppIcon`；iPad 另用 `CFBundleIcons~ipad`+`AppIcon76x76`。PNG 文件放 .app 根目录：`AppIcon60x60@2x.png`(120×120)、`AppIcon60x60@3x.png`(180×180)。缺声明=白色占位符图标 | ★★★ AutoTouch.app 实装 Info.plist（从 deb 解包） |
| A2 | 越狱 App 需要 entitlements 才能在 Dopamine/roothide 上启动并访问 /var/jb 文件系统：`platform-application` + `com.apple.private.security.no-sandbox` + `com.apple.private.security.storage.AppBundles` + `com.apple.private.security.storage.AppDataContainers`（四个全 true） | ★★★ AutoTouch 二进制内嵌签名块逐字提取；★ JBDev 项目全部 App 标配 platform-application |
| A3 | Theos 默认 `TARGET_CODESIGN_FLAGS = -S`（裸假签）；实例级覆写 `XXX_CODESIGN_FLAGS` 生效于 `makefiles/instance/rules.mk` L215 | ★★ theos 源码 |
| A4 | Theos 把 `Resources/` 目录内容 rsync 进 .app 根目录；Info.plist 不替换任何 `$(VAR)` 占位符 | ★★ theos bundle.mk 源码 + v0.1.0 实机解包验证 |
| A5 | roothide 包布局 = **rootful 式无前缀**：data.tar 内路径为 `./Applications/X.app`、`./Library/MobileSubstrate/DynamicLibraries/`。roothide 的 dpkg 在 vroot 环境运行（jbroot 为根），自动把文件装进随机 jbroot。包架构 `iphoneos-arm64e`（与 CPU 无关，纯环境标识） | ★★★ **n=8 多样本统计**（官方源 8 个不同 Section 的 arm64e 包：data.tar 顶层 `Library 152 / Applications 7`，`rootfs` 零命中；8 个 tweak 的 .dylib 全在 `Library/MobileSubstrate/DynamicLibraries`）；★★ 官方 com.roothide.patcher deb 拆解；★★ theapplewiki RootHide 条目；★★ roothide/theos vendor/mod/roothide 模块源码（package.mk 为空）。取证工具 `tools/verify_roothide_layout.py`，报告 `docs/AUDIT_ROOTHIDE_E22.md` |
| A6 | roothide maintainer scripts 用 **vroot 路径**（jbroot 为根的视角）：App 路径写 `/Applications/X.app`，不写 jbroot 真实路径；postinst 里 `uicache` 直接在 PATH | ★★★ 官方 com.roothide.patcher 的 postinst 原文 |
| A7 | Dopamine-roothide 2.x 实证：jbroot = `/var/containers/Bundle/Application/.jbroot-<16位hex带校验>`；且创建 `/var/jb` → jbroot 的符号链接。**该 symlink 是 Dopamine-roothide 自有行为，非 roothide 通用保证**（L410 还会 `"Remove /var/jb as it might be wrong"` 主动删除旧链接），因此任何依赖 `/var/jb` 的写法都是脆弱的 | ★★ Dopamine-roothide 源码 DOBootstrapper.m（L481 createSymlinkAtPath:@"/var/jb" toPath:JBROOT_PATH(@"/")、L410-422 删除旧链接、L766 JB_ROOT_PREFIX、L817 find_jbroot 扫描 /var/containers/Bundle/Application） |
| A8 | 注册图标靠 postinst `uicache`（A6 的 vroot 路径）；Theos roothide 库的 install_name 用 `@loader_path/.jbroot/...`（我们 tweak 无越狱库外部依赖，Lua 静态编译，不涉及） | ★★ roothide theos instance/library.mk 源码 |

## B. IOHIDEvent 触摸/按键合成（以 AutoTouch 二进制为最高证据）

| # | 事实 | 证据 |
|---|------|------|
| B1 | setter 符号名：`IOHIDEventSetIntegerValue` / `IOHIDEventSetFloatValue`（裸 `IOHIDEventSetInteger` **不存在**） | ★★★ ATTweak.dylib 符号表逐字节核验（含 null 终止符精确匹配） |
| B2 | 字段常量（AutoTouch 代码内实际使用的立即数）：`MajorRadius=0x000B0014`、`IsDisplayIntegrated=0x000B0019`（movk w,#0xb lsl#16 扫描实证）；MinorRadius=0x000B0015（base+21） | ★★★ ATTweak.dylib 反汇编立即数扫描；★★ WebKit SPI/KIF 枚举推导 |
| B3 | finger 事件 13 参签名；hand 父事件全 0 参数模式；finger index 从 1 起、identity=2 | ★★ SimulateTouch/KIF 源码逐参数一致 |
| B4 | 键盘：consumer page 0x0C，usagePage/usage 为 uint16_t | ★★ nanotech/iphoneheaders |
| B5 | 拟人化字段：AutoTouch 实际会写 MajorRadius/Density/Pressure（base+0x14/+0x5/+0x6/+0x7 均有立即数证据） | ★★★ 反汇编 |

## C. 抓屏与搜图搜字

| # | 事实 | 证据 |
|---|------|------|
| C1 | `CARenderServerCaptureDisplay(uint32_t port=0, CFStringRef displayName, CFDictionaryRef opts)`；iOS 显示屏名 "LCD"（备选 "Main"）；返回 IOSurfaceRef | ★★★ AutoTouch libATGraphic 反汇编（`RenderDisplay(0, CFSTR("LCD"), surface, 0, 0)` + ios-mcp） |
| C2 | 抓屏返回**物理像素**位图；触摸/显示坐标是**点**。AutoTouch 分设 `getScreenSize`（点）/`getScreenResolution`（像素）/`getScreenScale` 三个 API 即此证据 | ★★★ ATTweak 符号表（三个 API 名同时存在） |
| C3 | **坐标归一化设计**：Lua 对外统一用点坐标。内部：捕获位图宽 / UIScreen 点宽 = scale（自适应 1x/2x/3x，不假设）；getColor 入参×scale 查像素；find* 出参÷scale 还点 | 由 C2 推导 + 防御式设计 |
| C4 | OCR=Vision VNRecognizeTextRequest（zh-Hans+en-US）；theos SDK 头缺 VNRecognizedText.h 用类别补声明 | ★★★ v0.1.0 构建实证 |
| C5 | 搜图=灰度+1/4 粗搜+原图精搜（零均值 NCC）；模板限 4MP、路径白名单 | v0.1.0 已实现并构建验证 |

## D. 进程模型与可靠性

| # | 事实 | 证据 |
|---|------|------|
| D1 | jbroot 探测**改用 dladdr 取自身路径**推导（tweak: 去 `/Library/MobileSubstrate/DynamicLibraries/xx.dylib`；app: 去 `/Applications/xx.app`），探测法仅作回退 | 设计决策（比扫目录更稳：与安装路径天然一致） |
| D2 | App 启动链路与脚本运行链路都必须 @try 防御（启动崩=点不开；运行崩=拖死 SpringBoard） | v0.2.0 评审结论 |
| D3 | Lua 5.3 内嵌：vendor 33 个 .c（官方构建清单），loslib 的 os.execute 打桩，-Wno-error=string-plus-int 精确豁免 | v0.1.0 CI 实证 |
