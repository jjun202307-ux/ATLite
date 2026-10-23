# ATLite

一个 AutoTouch 风格的 iOS 自动化框架（rootless 越狱），架构对齐 AutoTouch 8.6.3，方便后续按同样路线扩充功能。

> ⚠️ 仅用于自己的设备学习研究。脚本自动化请遵守目标应用的服务条款与当地法律。

## 工作流（MVP）

```
电脑写好 .at 脚本（Lua 语法，与 AutoTouch 同后缀）
        │  手机和电脑同一 Wi-Fi
        ▼
手机打开 ATLite App → 内置 HTTP 服务器自动启动
        │  浏览器访问 http://<手机IP>:8080
        ▼
网页里上传 / 管理 / 删除脚本（或用 curl PUT）
        ▼
App 里点脚本 → 「运行」
        ▼
App 发 Darwin 通知 → SpringBoard 里的 tweak 用
IOHIDEvent 合成真实触摸事件执行脚本
```

## 与 AutoTouch 的架构对照

| AutoTouch 8.6.3 | ATLite 对应实现 |
|---|---|
| 脚本引擎在 ATTweak.dylib（SpringBoard 进程） | ✅ 相同：Lua 5.3 在 tweak 内 |
| 脚本 `Scripts/*.at`（Lua 语法） | ✅ 相同后缀 `.at`，目录 `Library/ATLite/Scripts/` |
| `LuaLibraries/Extensions.lua` 预加载 API 糖 | ✅ 同机制（首次运行自动生成，可自行修改） |
| 内置 Web 服务器从电脑编辑脚本 | ✅ 相同定位：App 内置 HTTP 服务器（端口 8080） |
| App 管理器 + 进程通信指挥 tweak | ✅ 同构：command.json + Darwin 通知 |
| IOHIDEvent 模拟触摸/按键 | ✅ 同原理（dlsym 加载私有符号） |
| libATGraphic 找色/找图/OCR | ✅ MVP 已实现：CARenderServer 抓屏 + NCC 搜图 + Vision OCR（后续可升级 OpenCV） |

## Lua API（对齐 AutoTouch，可直接迁移手感）

```lua
-- 触摸/按键（AutoTouch 同名同参）
touchDown(0, 200, 300)   -- 手指id, x, y
usleep(50000)            -- 微秒（AutoTouch 语义）
touchMove(0, 250, 350)
touchUp(0, 250, 350)
tap(200, 300)            -- Extensions.lua 糖

keyDown(KEY_TYPE.VOLUME_DOWN_BUTTON)
usleep(50000)
keyUp(KEY_TYPE.VOLUME_DOWN_BUTTON)

-- 取色/搜色
local c = getColor(100, 100)      -- 返回 0xRRGGBB
local pts = findColor(0xFF5722, 16)  -- 颜色, 容差 → {{x,y},...}
findColorTap(0xFF5722)               -- 搜到就点

-- 搜图（模板图片放 Images/ 目录，网页上传自动归类）
local r = findImage("button.png", 0.9)  -- 文件名, 相似度 → {{x,y,score},...}（中心点）
findImageTap("button.png", 0.9)         -- 搜到就点

-- 搜字（Vision OCR，离线，中文+英文）
local r = findText("设置")   -- → {{x,y},...}
findTextTap("设置")          -- 搜到就点

screenWidth()   screenHeight()
rootDir()       stop()   log()
```

搜图原理：CARenderServer 抓屏（SpringBoard 进程内）→ 灰度化 → 1/4 缩放粗搜 → 原图精搜（NCC 模板匹配）。模板图片请从目标分辨率的截屏里裁剪，纯色/过小的图匹配不可靠。

已占位待实现（调用返回 nil）：`findColors / ocrText / inputText / dialog / appRun / openURL / vibrate / toast`。

## 项目结构

```
ATLite/
├── Makefile              # 根聚合（SUBPROJECTS = tweak app）
├── control               # deb 元信息
├── tweak/
│   ├── Makefile          # 链接 Lua 5.3 源码（CI 自动拉取）
│   ├── Tweak.x           # 引擎：IOHIDEvent 模拟 + Lua + 命令处理
│   └── ATLite.plist      # 注入过滤器（SpringBoard + UIKit，AutoTouch 同款）
├── app/
│   ├── Makefile
│   ├── Resources/Info.plist
│   └── Source/           # 脚本管理器 + HTTP 导入服务器
└── .github/workflows/build.yml
```

## 编译（全云端，Windows 无需本地工具链）

1. 在 GitHub 新建仓库，把本目录全部文件推上去
2. Actions 页签等构建完成 → Artifacts 下载 `atlite-deb/*.deb`
3. 传到手机（AirDrop / 网盘 / curl 均可），Filza 打开安装 → 注销

## 使用

1. 手机打开 **ATLite** App，记下页面显示的电脑访问地址
2. 电脑浏览器打开该地址 → 上传 `.at` 脚本
3. App 里点脚本 → 运行

也可以用命令行上传：

```bash
curl -X PUT "http://<手机IP>:8080/api/put?name=demo.at" --data-binary @demo.at
```

## 真机调试

- tweak 日志：`<jbroot>/var/mobile/Library/ATLite/logs/tweak.log`
- 首次跑不通按顺序排查：
  1. 日志里 `jbroot = ...` 是否正确（roothide 随机 jbroot 探测）
  2. 日志里 `IOHIDEvent ready: YES/NO`（NO 说明私有符号没加载全）
  3. 回放无反应但日志正常 → 检查坐标（横竖屏 / 显示缩放）
  4. roothide 用户如果 `/var/jb` 不存在，探测逻辑会找 `.jbroot-*`；再不行把实际路径发给我调整

## Roadmap（按 AutoTouch 路线扩充）

- [ ] 找色/找图（libATGraphic 同路线：OpenCV）
- [ ] OCR（Vision 框架 / 云端）
- [ ] 定时任务、开机自启（AutoTouch 的 timer 体系）
- [ ] Control Plane 远程管理（AutoTouch 8.x 的 Dashboard/配对码体系）
- [ ] 对话框/悬浮控制条（dialog API）
- [ ] 长脚本中断按钮（当前跑死循环只能注销）

## 已知限制（MVP）

- HTTP 服务器无鉴权，仅限可信局域网使用；App 退到后台服务器会暂停（iOS 机制）
- 键盘事件（keyDown/KEY_TYPE）的 usage page 需真机校准
- arm64e 设备上未实测，PAC 相关问题需要真机反馈
