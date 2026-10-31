# iPhone 11 / iOS 16.6 真机反馈与调试记录

更新：2026-10-31。环境为 Dopamine roothide；用户手机中控名为 baise2。

## 两次版本更新

| 版本 | 实际修改 | 已执行验证 | 未证明的内容 |
|---|---|---|---|
| 0.3.13 | stop() 持久取消；屏幕尺寸与渲染独立超时；探针子进程单一回收者 | macOS CI 55 项测试、131 项静态检查、29 项 deb 检查 | 真机抓屏、输入、OCR、邮箱往返 |
| 0.3.14 | stop.flag 快照与停止代次；命令编号有界去重；通知处理串行；P2 日志关联运行编号、PID 和退出状态 | macOS CI 60 项测试、131 项静态检查、29 项 deb 检查 | 真机注入及完整功能链路 |

0.3.14 构建提交为 5467645c1361972fcf782beb3f748e5980d35155；安装包 SHA-256 为 ad37bf3e600e9d25a9b55c5b704464d809b45e01e28963a39c2b1a4c2421e750。测试包含模拟系统接口，不能据此声称软件在手机上正常。

## 两次手机截图

1. 日志页：App 推导根目录为 /var/containers/Bundle/Application/.jbroot-8B2BCDE2B21B1630；该根下 ATLite/logs 不存在，未找到 tweak.log。单凭目录不存在不能确定未注入：也可能是目录创建失败、路径不一致或初始化提前退出。安装脚本没有自动 respring。
2. App 探针：run_id=09CDBAA4-E079-4ABA-88EA-F2ED82EDC821，uid/euid=501，PROBE_BEGIN 和 PROBE_END 均出现。P4 明确为 DISPATCHED（不证明触摸送达）；P5 的多种尺寸均 surface=NULL，结果 NO-READABLE-BUFFER；Framebuffer 服务发现为未实现。保存 probe-app.log 失败，原因是目录不存在。P2 仅提交请求，无同次 SpringBoard 完成证据。

截图中的 NOT-ROOT 是默认非 setuid 探针的预期，不能据此断言 root 是全部问题的原因。App 探针的抓屏结果不能代替 SpringBoard 内抓屏测试。截图没有明确包版本，仍需设备核对已安装版本及插件加载状态。

## 源码确认的问题

- App 启动只创建 Scripts/Images；ATLRunProbe 保存前不创建 logs，错误依赖插件先行初始化，故插件不可用时诊断结果反而无法落盘。
- 日志页将“目录不存在”等同“未注入”、将“目录存在但无日志”等同“已注入”，均证据不足，必须更正。
- 仓库 README/BUILD_STATUS/CHANGELOG/使用说明仍描述 0.3.11 未构建，落后于实际 0.3.14 产物；更新为本记录中的真实状态。

## 真机调试原则

先确认连接、已安装版本、活动 jbroot、插件文件、依赖、注入开关与 SpringBoard 日志，再修改渲染或输入实现。通过 SSH 取证或已存在的 baise2 投屏验证；不能连接时明确记录阻塞，不把 CI 通过改写为真机通过。保留用户脚本和邮箱记录。完整验收至少包括启动日志、脚本运行与停止、截图取色、OCR、目标页点击滑动与 ASCII 输入、局域网邮箱往返。

## 连接进展

Windows 已有 OpenSSH 客户端和鹰眼中控 baise2 窗口。自动化工具两次读取投屏画面均超时，尚未成功操控手机；中控主窗口仅暴露顶层可访问性信息。中控与 192.168.2.125 有活动连接，该地址只是候选，尚不能认定为手机 SSH 地址。未获得 SSH 登录凭据，未尝试默认密码。

## SSH 取证与根因复现

已通过调试公钥以 mobile 登录 192.168.2.127:2223；dpkg 确认安装 0.3.14。DynamicLibraries 是指向 /usr/lib/TweakInject 的符号链接。以手机原有 ATLiteProbe 建立隔离 RootCheck.app 测试进程（bundle ID 为 com.apple.springboard），加载原插件，真实输出 `[ATLite] current jailbreak root unavailable; tweak disabled`。不涉及替换真正的 SpringBoard。dyld 记录插件实际路径为 `<jbroot>/usr/lib/TweakInject/ATLiteTweak.dylib`，现有解析只认 MobileSubstrate 旧路径；在 libroot 的 @rpath 查找失败且无 /var/jb 时提前禁用。

修复中的 0.3.15：识别两种实际插件路径，已取得物理根时用其显式加载 libroot；App 诊断保存前创建父目录，正确显示保存失败；日志页不再凭目录存在性断言注入。路径解析新增真实 C 编译执行测试。尚未构建/安装 0.3.15，真正 SpringBoard 与完整功能待验。

0.3.15 构建成功：64 项 macOS 测试无跳过、131 项静态检查、29 项产物检查通过。已传手机 /var/mobile/ATLite_0.3.15_iphoneos-arm64e.deb，尚待管理员安装；root SSH 尚未授权。

## 0.3.15 已安装后的真机测试

已确认真正 SpringBoard PID 6723 载入 v0.3.15，根目录来源 libroot；日志目录自动创建。SSH 发出运行通知后，Lua 取得 414×896 点尺寸和 828×1792 BGRA 帧，getColor(20,20) 返回数值 687818；脚本正常结束。pcall(stop) 测试触发 STOP，未到达后续哨兵，状态恢复空闲。

OCR 在真正 SpringBoard 连续两次失败，日志为 CoreML `Error computing NN outputs`。独立 SSH 测试工具以已知 PNG 测试准确/快速、默认/CPU 路径，但该进程出现 CVPixelBuffer 分配错误，因此不能将该工具的结果当作 SpringBoard CPU 路径结果。下一步 0.3.16 只修改识别请求为 CPU，作为需真机验证的单变量实验，不能提前宣称修复。

手机 Safari 已通过局域网载入电脑上的本地测试页，页面加载回报已收到。脚本 tap 命令执行完成，但尚未收到页面 pointer/input 回报，故点击与输入仍未证明送达。

## 当前结论更新

以 RESEARCH_DEVICE_FAILURES_2026-10-31.md 为最新事实汇总：当前设备实际系统16.4，0.3.16 CPU实验失败且手机已退回0.3.15。用户要求扩大研究、先写计划；生产代码冻结。新计划位于superpowers/plans/2026-10-31-atlite-device-stability.md。此前“待安装0.3.15”等描述是历史进度，已由后续真机证据取代。

## 用户提供技术分析后的补证

用户文档的原始TSDaemon样本SHA为00f0014d503e8df2002499d06fea8c61e5058bcad83f36b9f0a1b89053d7066e。只读解析其签名确认H11ANEInDirectPathClient声明；未执行商业程序。手机隔离工具仅增加该类授权，准确中英识别从CoreML错误变成功。再缩减为8个相关图形/ANE类，20次英文/中文/混合/revision2测试全部通过预期邮箱、atlas123用户名及相应中文文本内容。证据见verification/device-2026-10-31。

G1已取得内容对照证据。下一步0.3.17仅为SSH内测开发包，增加按需OCR worker及有界父进程；在G2至G5通过前不作为正式交付。
