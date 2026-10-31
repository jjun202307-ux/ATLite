# ATLite 真机故障专项研究

日期：2026-10-31。目的：先核实运行条件和进程边界，停止逐个修改参数后直接发包的做法。

## 1. 当前状态与证据边界

- 当前 SSH 设备：baise2，iPhone12,1（iPhone 11），192.168.2.127:2223。mobile/root 公钥登录均已验证。
- 当前设备的 rootfs SystemVersion.plist 为 iOS 16.4、20E247；Darwin 22.4.0 与独立工具崩溃报告一致。用户此前提供的是 16.6；保留两项来源，不擅自断言另一台设备或伪装软件造成差异。
- 当前安装并加载：0.3.15。0.3.16 的 CPU 实验失败后已降回 0.3.15 并重启桌面。
- 当前 Git 构建分支仍含 0.3.16 实验，不能从该 HEAD 宣称可交付；下一次改代码前应以已知基线提交 3510205ec7016b79a5018785a5fc319bb1b9c68c 对照审查。
- 0.3.16 的 66 项 CI 测试、131 项静态检查和 29 项包检查通过，但手机表现失败。测试数量不能代替设备行为。

## 2. 两次早期更新与这次实验

| 版本 | 改动 | 实际结论 |
|---|---|---|
| 0.3.13 | stop() 持久取消、尺寸/渲染独立超时、探针单一回收 | CI 55 项测试；当时未真机验收 |
| 0.3.14 | 停止快照/代次、命令去重与通知串行、P2 退出记录 | CI 60 项测试；用户反馈日志缺失、App 探针保存失败 |
| 0.3.15 | 识别 canonical TweakInject 路径、显式加载 libroot、独立创建诊断目录、修正注入判断提示 | 真正 SpringBoard 加载成功，脚本/取色/合作停止通过；OCR 和输入链路未通过 |
| 0.3.16 实验 | OCR 设置 usesCPUOnly=YES | SpringBoard 内识别长时间未返回；独立进程出现 ANE 清理 SIGTRAP；已撤回手机安装 |

## 3. 已证明、待证明、被否定

### 已证明

1. 原插件的 dladdr 路径被解析为 `<jbroot>/usr/lib/TweakInject/ATLiteTweak.dylib`。旧逻辑只认 MobileSubstrate 路径，隔离进程真实输出根目录不可用，插件禁用。0.3.15 真正 SpringBoard 日志已确认修复。
2. Lua 获取 414×896 点尺寸；抓屏得到 828×1792 BGRA 帧，取色返回数值。尚无导出的截图与可见屏幕对照，不能把“可读帧”写为“所有旋转和颜色已正确”。
3. pcall(stop) 后未到达测试哨兵，脚本记录 STOP；同次测试退出后状态为 idle。
4. 默认准确 OCR 在 SpringBoard 两次报 CoreML `Error computing NN outputs`。
5. 已知 PNG 的独立测试：获得 IOSurface/图形类授权后，快速模式能读出 `Username: ATLiteDebug` 和测试邮箱；中文行没有读出。准确模式 revision 2/default 仍失败。
6. CPU 独立测试崩溃报告为 libdispatch 的“Semaphore object deallocated while in use”，栈包含 AppleNeuralEngine 的模型析构。它只证明该实验的失败栈，不能证明 ATLite 自己释放了系统信号量，也不能证明设备硬件损坏。
7. 重启桌面后旧 status.json 仍写 running=true，实际执行该脚本的 SpringBoard 已结束；缺少进程会话归属是独立状态缺陷。

### 尚未证明

- 早期未证实的 ANE 类权限假设已由后续同机单变量对照支持，详见第9节；其他模型/资源因素不再作为已证实根因。
- 模型/资源路径是否受 roothide 的 rootfs/jbroot 视角影响；尚未证明模型文件损坏。
- Safari 已加载本地测试页，但脚本 tap 后没有收到 pointer/input 回报。坐标、路由、前台状态均需单独验证，不能直接说某一项是唯一根因。
- ASCII 邮箱是否进入输入框、滑动是否发生、中文识别与邮箱完整往返均未通过。

### 明确不采用的推论

- root/符号 ready/dispatch 无错误不等于对应操作成功。
- 快速英文 OCR 成功不等于中文 OCR 成功。
- 仅切 CPU 不等于摆脱所有 ANE 初始化和资源清理路径。
- 给 SpringBoard 加一个等待超时，不等于终止了里面阻塞的 Vision 调用。

## 4. 原始资料核对

以下均于 2026-10-31 读取。代码只用于机制比对；旧项目的自述版本不能当作当前设备兼容证明。

| 资料 | 核实的事实 | 对 ATLite 的含义 |
|---|---|---|
| [Apple VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest) | 识别级别、语言优先列表、请求 revision 和语言能力查询是独立配置 | 先查询当前配置支持的语言，保留错误与识别级别 |
| [Apple WWDC21](https://developer.apple.com/videos/play/wwdc2021/10041/) | 建议按请求配置查询语言，不凭固定清单推断 | 验收必须包含中文、英文、混合图片，而非只检查表非空 |
| [Apple WWDC22](https://developer.apple.com/videos/play/wwdc2022/10024/) | revision 3 扩展语言；自动语言检测用于准确模式 | 不能随意用较早 revision 或 fast 替代后仍声称能力相同 |
| [TrollStore README](https://github.com/opa334/TrollStore#unsandboxing) | platform-application 会收紧部分沙盒，需要对 IOKit 用户客户端逐项授权 | 当前“去沙盒 + root 就够了”的调试前提不成立；授权要最小化验证 |
| [roothide Developer](https://github.com/roothide/Developer) | 用 jbroot API 转换越狱文件路径，并列出应用所需基础签名能力 | 构建、签名和运行路径一起验；禁止复制系统 App 整份权限 |
| [libroot](https://github.com/opa334/libroot) | 区分 jbroot、rootfs 和用户空间启动标识 | 统一文件视角；状态和回包要关联运行会话 |
| [XXTouch roothide 说明](https://xxtouch.app/en/docs/FAQ/faq-0021/) | Shell 的根视角与原生进程/系统根不同，存在文件镜像 | Shell 能读到文件不能证明模型所在进程也在读同一文件 |
| [WebKit HIDEventGenerator](https://github.com/WebKit/WebKit/blob/main/Tools/WebKitTestRunner/ios/HIDEventGenerator.mm) | 使用目标窗口上下文、BackBoardServices 标记和主线程 enqueue；包含 iOS 16 修饰键处理 | 应用内事件路由不能直接当作跨 App 系统事件投递方案 |
| [SimulateTouch 原源码](https://github.com/iolate/SimulateTouch/blob/master/SimulateTouch.mm) | 历史系统注入实现设置 SenderID，且对坐标做归一化 | 当前只宣称“参数一致”漏查了上下游转换；但该旧代码也不能直接照搬至 iOS 16 |
| [原版 ZXTouch](https://github.com/xuan32546/IOS13-SimulateTouch) | 自述主要覆盖 iOS 11–14，提供系统输入和 OCR 机制 | 只能借鉴接口、验证方式；新 fork 的 iOS 16 README 不是我们手机的实测记录 |
| [XXTouchNG](https://github.com/XXTouchNG/XXTouchNG) | 已归档，采用服务/进程分工且有 AGPL 许可 | 可学习故障隔离；不整套引入框架或直接复制实现 |

对于网上相同 CoreML 错误的报告，只能作为检索线索；没有找到能直接证明本设备相同根因的 Apple 修复说明。不能把“系统 bug”“缺权限”“缺缓存”任一项提前定案。

## 5. 关键假设与验证方法

| 编号 | 假设 | 最小验证 | 判定 |
|---|---|---|---|
| H1 | 平台进程缺 ANE 直接访问类别授权 | 同一隔离工具/图片/用户，只改变 H11ANEInDirectPathClient 访问声明；先与设备实际类名核对 | 只有中英准确识别由失败变成功且可重复，才支持此假设；不能扩大系统进程权限试错 |
| H2 | 准确识别的环境/模型路径错误 | 按 en-US、zh-Hans、混合三组，记录请求 revision、真实输入路径、请求错误与退出状态 | 英文准确模式也失败则不能归因为中文文本；不清缓存、不改模型文件 |
| H3 | 故障与进程上下文有关 | 同一 PNG 在独立 mobile 工具与前台 App 的诊断路径对照；不再在 SpringBoard 反复测试会挂起的组合 | 独立进程通过才允许设计集成；失败则继续定位外部运行条件 |
| H4 | 触摸的路由/坐标/父子状态不一致 | 一个固定测试页、关闭随机扰动的诊断动作，逐项检查归一化、SenderID、聚合 up 状态 | 以页面实际收到的 down/up/坐标为证据，不以派发函数返回为证据 |
| H5 | 状态文件跨 SpringBoard 会话残留 | 运行中重启桌面后对照 pid/sessionId/status | 新会话应报告中断或空闲，不继续显示旧进程正在运行 |

## 6. 方案比较

| 方案 | 收益 | 问题 | 结论 |
|---|---|---|---|
| 继续在 SpringBoard 内只换识别参数 | 改动少 | 无法隔离 SIGTRAP/阻塞；本轮 CPU 实验已否定其充分性 | 不作为下一轮主线 |
| 先证明环境可用，再加按需退出的 OCR 小进程 | 复用系统 Vision，无模型下载；父进程可终止坏子进程；保留 Lua/API | 需一个小目标和有界 IPC；准确中文仍须先证明 | 推荐的有条件方案，先过诊断门禁 |
| 一次迁移整个 Lua/HID/截图到完整 daemon | 长期隔离完整 | 同时改变太多边界，难以判断新故障来源 | 延后；本轮不重做平台 |

这不是用进程拆分掩盖模型失败：隔离工具的准确中文没通过之前，不实施 OCR 小进程集成。若只允许英文快识别，则属于能力调整，必须单独说明并获得用户选择，不能自动降级成同等成功。

## 7. 下一步顺序

环境/权限与模型对照 → OCR 进程边界定案 → 单点输入闭环 → 滑动/键盘闭环 → 停止/状态/命令并发 → 邮箱往返 → 一次候选构建与回归。

每步保存当前源码提交、安装包 SHA、进程、配置、预期、实际、退出状态和证据文件；没有证据的项目标记未通过，不填“全部正常”。

## 8. 检索工具记录

使用 Agent Reach 1.5.0 的 Exa/Jina 后端，并用网页检索核对原始出处；gh CLI 未安装，未为本任务安装新客户端。体检提示 Agent Reach 1.6.0 可用，本轮未升级工具。工具升级说明不属于 ATLite 修复范围。

## 9. 用户提供完整技术分析后的新证据

参考文档：用户提供的《iOS自动化脚本平台-完全技术分析.md》。有帮助的部分是原始样本路径与哈希、独立TSDaemon/Vision模块、SenderID符号和证据边界。其“事件与真实手指不可区分”等推断没有被本轮继承；价格、云OCR、加密容器与当前轻量修复无关。

原文把entitlements列为未解析项。本轮使用现有Mach-O签名解析器，只读检查TSDaemon（SHA256：00f0014d503e8df2002499d06fea8c61e5058bcad83f36b9f0a1b89053d7066e）和model.so，确认H11ANEInDirectPathClient在授权列表内；未执行或集成商业程序。签名元数据能在本机解析，无需先安装macOS。

在相同隔离工具、图片、mobile用户和识别配置下，仅给原有图形授权添加H11ANEInDirectPathClient：准确识别从CoreML失败变为中英文成功。因此这项缺失是已验证的关键运行条件，不再泛归因为Vision系统bug。只保留IOSurfaceRoot与H11两个类仍失败，保留8个相关图形/ANE类则成功；称为“已验证的缩减集合”，不宣称已证明数学意义最小。

随后默认准确识别按英文/中文/混合各5次、revision2混合5次，共20/20次通过预期用户名atlas123、邮箱test@example.invalid和相应中文文本检查。PNG SHA256：34d030eec482a4f6ba7701ef42d313a4a91ebcdc7f9c2d0b045ac9c35591c27d。首次ATLiteDebug样例被识别成ATLite Debug，已如实保留而未在脚本里偷偷拼接文字；正式夹具用明确的atlas123检查。证据见verification/device-2026-10-31。

当前SpringBoard原签名缺少该ANE类。不会重新签名或修改Apple系统进程；按计划采用独立的小型OCR worker承载所需签名，并由父进程有界管理。0.3.17为内部验证版本，不代表G2至G5已通过。
