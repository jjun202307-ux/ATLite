# ATLite 真机稳定性修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 使用当前会话逐项执行，不新增分派任务。

**Goal:** 在保持软件轻量的前提下，验证并修复 roothide 上的图色、OCR、点击滑动、ASCII 邮箱输入、停止和局域网结果回传；真机闭环通过后才交付。

**Architecture:** 保留现有 App 管理界面和局域网协议，不整体迁移引擎。先用隔离诊断证明准确中英文 OCR 的运行条件；若通过，再把有崩溃/阻塞风险的 OCR 放进按需退出的小进程，SpringBoard 保留已经验证的抓屏与暂存输入桥。A/B 以后复用相同核心，本轮不把模式开关冒充已实现的 daemon。

**Tech Stack:** Objective-C/C、Lua 5.3、系统 Vision/CoreGraphics/ImageIO、现有 Theos/macOS CI、SSH、Python 主机验收工具。无第三方 OCR 模型、无新数据库、无云端服务。

---

## 0. 执行约束

- [x] 阅读当前上下文、版本记录、真机日志和失败实验；研究见 ../../RESEARCH_DEVICE_FAILURES_2026-10-31.md。
- [x] 手机退出 CPU 实验并恢复 0.3.15；原始 0.3.10 与用户脚本不改。
- [ ] 整理原始证据到 verification/device-2026-10-31/，对公网分享的材料去掉登录密钥、设备标识和真实邮箱。
- [ ] 以 3510205ec7016b79a5018785a5fc319bb1b9c68c 为基线审查后续差异。保留 2c2c045ceaf7726f4b74433146e7463193ab1cdd 为失败实验记录，不直接发布。
- [ ] 各任务先补实际失败复现，再改相应模块；一个变量一次对照。未完成前一门禁不推进后续集成。

下文参数是验收目标，不表示已经测得。耗时、内存、包大小只填实际测量，不能预先承诺。

## Task 1：先证明 OCR 运行条件

**文件与职责：**
- 诊断：现有 work/atl_ocr_check.c、work/ATLOCRCheck、work/ocr-known.png。
- 证据：verification/device-2026-10-31/ocr-matrix.json 与 crash-summary.md。
- 正式代码：本任务不修改 tweak/Tweak.xm、App 或安装包签名。

- [ ] 固定设备实际版本、已安装 0.3.15、PNG SHA 和已知中英文字；把此前 16.6 信息与当前 16.4 实测并列，避免混淆设备。
- [ ] 记录工具签名、实际 uid、进程路径与 IOKit 类声明；只核对需要的图形/ANE 类，不复制 SpringBoard 整份签名。
- [ ] 对照 H11ANEInDirectPathClient 的访问条件：基础图形授权一组、增加经设备核对的 ANE 类一组。每次只运行隔离工具；不修改系统二进制、系统授权或其他插件开关。
- [ ] 以 en-US、zh-Hans、二者组合分别测试准确模式；先查询该 revision 支持的语言。准确模式 default/revision 2 分别记录，不用快速模式替代中文能力。
- [ ] 每个诊断子进程最多等待 8 秒；超时只杀本次创建的 PID并回收，保存超时/信号/退出码。禁止杀所有同名系统进程。
- [ ] 对实际图像内容核对：英文用户名、测试邮箱、中文用户名三项均有确定预期。每一配置连续 5 次，不能只凭一次返回非空通过。
- [ ] 若准确识别仍失败，检查模型资源的 rootfs/jbroot 视角与子进程初始化差异；保存系统错误原文。此时停止生产集成，不清理系统缓存、不替换模型、不继续发布参数试验包。

已有工具的命令格式（通过受控父进程运行，不直接无界等待）：

```sh
ATLOCRCheck 0 /实际物理路径/ocr-known.png
ATLOCRCheck 4 /实际物理路径/ocr-known.png
ATLOCRCheck 2 /实际物理路径/ocr-known.png
```

其中 0=默认准确、4=revision 2 准确、2=快速对照。上述工具当前固定中英语言；测试语言矩阵时修改诊断工具的参数入口，不改正式请求配置。CPU 组合已留下失败证据，禁止再次放进 SpringBoard。

**门禁 G1：** 隔离进程必须可重复识别中英和邮箱，且超时/崩溃能被父进程识别与回收。未通过时只交付调查结果，不称 OCR 已修复。

## Task 2：OCR 采用可终止的小进程

仅在 G1 通过并完成方案核对后实施。它是故障边界调整，不是新增常驻服务。

**文件：**
- 新增 ocr/Makefile、ocr/main.m、ocr/entitlements.plist：只读入图像、调用已通过的 Vision 配置、返回结果并退出。
- 新增 shared/ATLOCRProtocol.h：长度与错误码等共享常量。
- 修改 tweak/Tweak.xm 的 ATRecognizeScreen：截图/点位换算不变，调用子进程。
- 修改根 Makefile、.github/workflows/build.yml、tools/verify_artifact.py：构建签名与产物检查。
- 新增 tests/test_ocr_worker_native.py、tests/test_ocr_parent.py；替换失败实验 test_ocr_policy.py 的 CPU 假设。

**协议约定：**

```json
{"version":1,"requestId":"本次唯一编号","ok":true,"mode":"accurate","languages":["zh-Hans","en-US"],"lines":[{"text":"Username: ATLiteDebug","x":0.1,"y":0.2,"width":0.4,"height":0.1,"confidence":0.9}]}
```

失败返回同版本和同编号、ok=false、errorCode/errorMessage；errorCode 固定为 INPUT_INVALID、LANGUAGE_UNSUPPORTED、VISION_FAILED、TIMEOUT、STOPPED、WORKER_SIGNALED、WORKER_EXITED、OUTPUT_INVALID 或 REAP_FAILED，不返回伪造的空成功。

- [ ] 输入是父进程打开的受控 PNG 文件描述符，不接受网络传来的任意路径；上限 16MiB、图像 16MP。
- [ ] 输出使用独占 pipe；最多 128KiB、64 行、每行最多 511 UTF-8 字节；拒绝 NaN、非法 UTF-8、越界框和错误 requestId。
- [ ] 父进程用 posix_spawn，不经 shell；子进程签名与执行路径只使用 G1 验证结果。默认 mobile，无 setuid 与常驻监听端口。
- [ ] 单次 8 秒合作等待预算，到期或停止时终止本次子进程，最多额外 0.5 秒回收；无法回收则明确失败并停止后续 OCR，绝不输出成功。
- [ ] 子进程 SIGTRAP、非零退出、输出截断、编号不符、提前 EOF 均有独立测试；父进程仍可执行停止、下一段 Lua 和新脚本。
- [ ] 图像/描述符/临时文件在每个退出路径清理；父进程重启后的遗留进程另做生命周期测试，不能用 PID 文件误杀复用 PID。
- [ ] 不默认降级英文快速识别。只有用户明确选择英文能力后才设计这种模式，并向脚本公开其语言限制。

**门禁 G2：** 在目标手机运行真实成功、失败、卡住、崩溃和停止用例；SpringBoard 不随子进程崩溃且等待有界。中文准确识别未过不进入交付。

## Task 3：统一触摸坐标和投递路由

**文件：** tweak/Tweak.xm 的 ATLoadHIDSymbols、ATSimulateTouch、ATASCIIKeyEvent；tweak/ATCore.h 的可测试坐标函数；tests/native_core.c、tests/test_input_native.py；主机 verification/device-test-page.html。

- [ ] 建立专用本地测试页，显示输入框、提交按钮和中英用户名。事件收集器返回 204，并按 testId 保存 pointerdown/up/move、目标控件与实际输入；不能只靠 404 访问日志判断成功。
- [ ] 页面就绪、手机解锁、目标确在前台、布局/缩放已测得后才发输入。测试页面只使用 example.invalid 等虚构数据。
- [ ] 明确选择系统 IOHIDEventSystemClient 路由，先验证它要求的坐标表示和 SenderID。若切换应用上下文 enqueue 路由，必须重新定义目标 contextID 与坐标，不能混用 WebKit 的应用内实现。
- [ ] 新增 pointToDigitizer 的纯 C 测试：414×896 的点(207,448)在归一化路由应为(0.5,0.5)；若实验选定其他路由，应按对应接口单位设期望，不能为通过测试硬改。
- [ ] 校验父事件的 range/touch 与全部活动子触点一致，up 后不保留 touch=true；多指 identity 唯一。检查实际 SenderID 来源，不照抄旧机型固定值。
- [ ] 先以固定坐标、无扰动的诊断动作验证一次 down/up，再加回既有抖动与单调时间戳；不同时更换事件模型与随机参数。
- [ ] 输入 API 对初始化/事件创建失败明确报错；事件已送出仍只表示投递，目标接受由测试页验证。
- [ ] 连续 20 次 tap 坐标命中；swipe 有连续 move 和最终 up；ASCII 测试精确匹配含 @、点、加号、大小写和数字的邮箱，无残留按键/触点。

**门禁 G3：** 测试页收到预期事件、动作结果与精确输入。日志中 API 被调用或事件被 dispatch 不算通过。

## Task 4：停止、状态与命令文件生命周期

**文件：** tweak/Tweak.xm 的构造器/ATWriteStatus/命令入口；app/Source/ATLCommand.m、ATLStatusText.h；shared/ATLStopFile.h；tests/test_stop_race.py、tests/app_status_native.m。

- [ ] 为“重启桌面后残留 running=true”先建立失败复现：旧状态写 running=true，新的进程会话没有旧脚本。
- [ ] 状态增加 ownerPid/sessionId、script/requestId 和 idle/running/interrupted/error；App 不把上次会话文件当成正在运行的证明。
- [ ] 初始化确认本次进程无脚本后写状态；对遗留 OCR 子进程按 G2 生命周期结果处理，不能只为了显示空闲掩盖仍存活的进程。
- [ ] 保留已验证的停止快照/代次和单脚本准入，不在运行时清除新 stop.flag。
- [ ] 实测两个快速不同命令和 run/stop 交错是否覆盖；若复现丢失，用单槽占用/已消费确认拒绝新 run，而非新增无界队列。stop.flag 仍独立可写。
- [ ] 复核重复通知、旧编号、启动期间停止、OCR 中停止、错误后下一次运行、重启桌面中断；每项都检查目标动作与最终状态。

**门禁 G4：** 状态与真实进程一致，停止后输入释放，下一次运行不复活旧脚本；不同命令要么被确认接收，要么明确拒绝。

## Task 5：邮箱往返与全模块回归

**文件：** shared/ATLEmailJob.m、examples/email_roundtrip.at、app/Resources/email_roundtrip.at、app/Source/ATLWebServer.m；tests/test_device_roundtrip.py；verification/device-acceptance.md。

- [ ] 先保存已有用户任务；有未完成真实任务时不覆盖，用独立测试记录目录或等待任务结束。
- [ ] PC PUT 创建虚构邮箱 → 手机认领 → 目标测试页真实输入 → 实际 OCR 取得用户名 → sendEmailResult → PC 按同一 jobId 取回。
- [ ] 同时比对测试页接收的邮箱、OCR 原文与回传用户名；禁止用固定字符串或邮箱前缀代替 OCR。
- [ ] 负例：无用户名、OCR 进程崩溃/超时、无输入焦点、页面未就绪、任务被取消、旧 jobId 回写、网络中断。均应明确失败且不串单。
- [ ] 再覆盖模板搜图、搜色、旋转后的点位、时间戳递增、随机抖动范围、中文日志、P1/P2 本次完成状态和结果保存。
- [ ] 连续 20 次本地邮箱往返全部通过；再测 3 次桌面重启、App 前后台切换和停止恢复。后台 HTTP 仍如实标注受 iOS 调度影响。

**门禁 G5：** G1–G4 全部通过且上述闭环有证据。没有目标 App 专用适配需求时，只声明受控测试页通过，不扩大为所有 App 兼容。

## Task 6：只交付通过验证的候选包

**文件：** control、app/Resources/Info.plist、tweak 版本日志、README.md、BUILD_STATUS.md、CHANGELOG.md、使用说明.md、docs/LUA_API.md、构建与真机记录。

- [ ] 候选版版本仅在门禁通过后统一提升；失败实验不混入正式下载目录。
- [ ] 审查最终差异无外部大型框架、无常驻 OCR 服务、无调试密钥/测试邮箱记录/诊断工具意外入包。
- [ ] 完整 macOS 测试无失败；跳过项目必须说明。产物核对架构、版本化 arm64e ABI、签名、依赖与实际安装路径。
- [ ] 下载后与手机已安装候选包的 SHA 对齐，重启桌面确认实际加载版本；对最终确切包复跑 G5 冒烟，不拿先前构建代替。
- [ ] 生成一份状态表：已通过/失败/未验证，附源码提交、包 SHA、实际 iOS/设备、截图/日志与失败回退点。
- [ ] 将原始 0.3.10、0.3.15 基线和实验记录分开保留；只把最终通过包推到局域网下载位置。

## 停止条件与取舍

1. 准确中英文 OCR 隔离验证不过：停止集成，提交错误/权限/模型矩阵；不自作主张只剩英文。
2. 输入没有目标事件回报：停止邮箱闭环，先修输入路由；不通过延长 sleep 掩盖。
3. 需要更换整体架构或引入 OCR 模型库：重写方案与体积/资源预算，先和用户核对，不在本计划中偷偷扩大。
4. 每项通过才进入下一项；最终报告不出现“应该好了”“测试多所以没问题”。

## 执行补记：G1与开发构建

已对用户提供的静态分析追溯原始样本，补出此前未解析的ANE权限。保持系统与输入图片不变的授权对照成功；8类缩减集合完成20次准确语言/revision内容检查。G1结果已保存verification/device-2026-10-31。

为在真正设备执行G2，内部开发构建也使用独立版本号0.3.17用于识别日志；它只经SSH安装测试，不作为候选交付或推送局域网下载。Task6的版本提升要求以“只发布通过G1至G5的确切构建”为准；不因内部版本号提升而声称验收完成。
