# ATLite v0.2.0 重写实施计划（superpowers writing-plans）

> 测试层：`tools/verify_static.py`（37 断言，每条对应 docs/ERRORS.md 一起真实事故）。
> RED 已确认：HEAD 旧代码红在 R9-E9（自检脚本未随包）。以下任务全部完成后套件必须全绿（GREEN）。
> 已完成：`tweak/Tweak.xm` 重写（保 verified 常量/签名，清理 msleep 占位桩、冗余信号量、搜图窗口计算）。

### 任务 1：ATLWebServer 重写（R15/E15）
- 文件：`app/Source/ATLWebServer.h`、`app/Source/ATLWebServer.m`
- 要做：保持既有 API 面（GET / 页面、/api/list、/api/get、PUT /api/put、DELETE /api/del）；
  清理：连接上下文用 struct 而非 ObjC 指针容器、每连接 autoreleasepool 保持、
  `stop` 改名 `shutdownServer`（避免与常见基类方法混淆）、SO_REUSEADDR 保留。
- 验证：verify_static R15-E15 导入检查；人读审查线程与 FD 生命周期。

### 任务 2：ATLRootViewController 重写（R15/R16/R9）
- 文件：`app/Source/ATLRootViewController.h`、`app/Source/ATLRootViewController.m`
- 要做：保持脚本列表/运行/删除 UI 与 IP 展示；新增——首次启动把
  bundle 内 `test.at` 复制到 Scripts 目录（R9）；`struct ifaddrs`（R16）；
  启动段 try/catch 防御（App 打不开的教训：任何启动期异常都直接杀死 App）。
- 验证：verify_static R9/R16 检查。

### 任务 3：main.m / ATLAppDelegate 重写（R15/E15）
- 文件：`app/Source/main.m`、`app/Source/ATLAppDelegate.h/.m`
- 要做：与现版等价（AppDelegate 模式，无 SceneManifest），导入齐全。
- 验证：verify_static R15-E15。

### 任务 4：Info.plist 硬编码重写（R6/E6）
- 文件：`app/Resources/Info.plist`
- 要做：全部字面量，无任何 `$(...)`；`CFBundleExecutable=ATLite`；版本升 0.2.0。
- 验证：verify_static R6 三条断言。

### 任务 5：test.at 随包（R9/E9）
- 文件：`app/Resources/test.at`（自 examples/test.at 复制）
- 验证：verify_static R9 两条断言。

### 任务 6：版本与打包元数据（R7/E7）
- 文件：`control`（Version: 0.2.0）、`layout/DEBIAN/postinst`（保持）
- 验证：verify_static R7 全部断言。

### 任务 7：全量 GREEN + 子代理两段式评审
- 命令：`python tools/verify_static.py .` 必须退出 0。
- 评审：子代理按 05-code-review 两段式（规格符合度→代码质量），Critical 必修。

### 任务 8：一次推送 → 构建产物级验收
- 合并 v2-rewrite → main，单次推送；构建后解包 deb 复核：
  Info.plist 的 CFBundleExecutable==ATLite、test.at 在 .app 内、
  postinst 755+uicache、Architecture iphoneos-arm64e、dylib fat(arm64/arm64e)。
