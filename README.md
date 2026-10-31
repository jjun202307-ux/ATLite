# ATLite 轻量自动化（最近构建 0.3.14）

面向 Dopamine roothide 的轻量工具：图色/OCR、点击滑动、抖动与时间戳、局域网邮箱任务。

第一次使用先看 [使用说明](使用说明.md)：包括脚本编辑格式、上传运行、点位设置和邮箱完整流程。

**已构建 0.3.14 deb，真机验收未通过。** 当前正在定位用户反馈的日志缺失与插件加载问题；见 [构建状态](BUILD_STATUS.md) 和 [真机调试记录](docs/DEVICE_DEBUG_2026-10-31.md)。原始 v0.3.10 未改动。

## 核心流程

1. 用本源码构建并安装后，手机前台打开 ATLite，电脑在同一可信 Wi-Fi。
2. 电脑发送邮箱，手机运行随包 `email_roundtrip.at`。
3. 示例留 5 秒切到目标 App 并点中邮箱框；知道坐标时填写 focus/submit。
4. 脚本输入邮箱，OCR 识别“用户名：...”或“Username:...”，回传邮箱和用户名。页面规则不同，只改示例的几行匹配。
5. 手机回到 ATLite 前台，电脑按 jobId 取回结果。没有识别到用户名会报 error，不伪造成功。

```powershell
curl.exe -X PUT "http://手机IP:8080/api/job" -H "Content-Type: application/json" --data-raw '{"email":"demo@example.com"}'
curl.exe "http://手机IP:8080/api/result?jobId=返回的jobId"
```

只保留一个当前任务，先取结果再发下一封。局域网服务无鉴权；iOS 挂起 App 时不可保证访问。发送任务不自动运行脚本，仍由手机选择运行。输入事件已发送不等于目标输入框已接受，须真机确认焦点和键盘布局。

## 构建与验证

本仓库根目录为 Theos 工程，可使用附带 GitHub Actions。交付源码压缩包内对应 src/。已有 Theos 环境时：

```bash
python3 -m pip install lupa==2.8
python3 -m unittest discover -s tests -v
python3 tools/verify_static.py .
make package FINALPACKAGE=1
python3 tools/verify_artifact.py packages/实际产物.deb
```

测试需要 Python 3、C 编译器、Node.js，Lua 执行用 lupa。Windows 可设 ATL_CC 为 zig.exe，测试自动使用 zig cc。缺失依赖会显式 skip，不能当成已执行。

Lua 5.3.6 源码随工程固定，来源和许可见 tweak/lib/lua53/README.ATLite.md。CI 验证快照后执行测试、构建、产物门禁。

## 当前边界

- 坐标为点；没有完整 AutoTouch/触动精灵兼容层。
- 有图色、OCR、点击滑动、ASCII邮箱输入、三项邮箱任务函数。
- findColors/appRun/appKill/vibrate/openURL/toast 仍是旧版占位，不属于本轮目标。
- 只开放 base/table/string/math/utf8；没有 os/io/debug/package/coroutine。使用这些库的旧脚本需调整。
- 脚本文本 1MiB、VM 32MiB、60 秒合作预算；同步 OCR/系统调用不能保证硬超时。
- A/B 仍是下一步共享引擎启动策略；当前源码仍在 SpringBoard 执行 Lua，不能说双模式已经完成。

详见 BUILD_STATUS.md、docs/LIGHTWEIGHT_PLAN.md、docs/LUA_API.md；其他历史研究文档不代表此版已验收。
