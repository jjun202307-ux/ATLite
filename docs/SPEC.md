> 历史资料：保留原始研究与决策记录，不代表 v0.3.11 当前实现。以 TECHNICAL.md 与 LIGHTWEIGHT_PLAN.md 为准。

# ATLite 规格书（v0.3.0）

> ⚠️ **历史文档**：本文是 v0.3.0 时代的规格来源，仅作演变参考。
> **当前实现的权威描述见 [TECHNICAL.md](TECHNICAL.md)**，脚本 API 见 [LUA_API.md](LUA_API.md)。
> 下表之外的架构已变化（新增日志查看器、强停、探针、抓屏改用 RenderDisplay 等），以 TECHNICAL.md 为准。

## 应用框架（保留不变）

```
┌─────────────────────────────────────────────┐
│ SpringBoard 进程                             │
│  └─ ATLiteTweak.dylib（ellekit 注入）        │
│      ├─ Lua 5.3 引擎（内嵌 33 个 .c）        │
│      ├─ IOHIDEvent 触摸/按键合成             │
│      ├─ CARenderServer 抓屏                  │
│      ├─ Vision OCR / NCC 搜图 / 找色         │
│      └─ Darwin 通知监听（command.json 驱动） │
└─────────────────────────────────────────────┘
┌─────────────────────────────────────────────┐
│ ATLite.app（管理器，无录制功能）             │
│  ├─ 脚本列表 + 运行/删除                     │
│  ├─ :8080 HTTP 文件管理（PC 导入脚本/模板）  │
│  └─ 首次启动释放内置 test.at 自检脚本        │
└─────────────────────────────────────────────┘
```

## 要实现的功能（用户需求逐条）

1. **电脑写脚本 → 局域网导入手机 → 手机直接运行**（无录制）
2. **触摸/按键模拟**：touchDown/touchMove/touchUp（多指）、keyDown/keyUp（HOME/音量/电源）、tap 糖
3. **拟人化**：坐标抖动（down/up ±2pt、move ±1pt）、随机时间戳（±1ms + tap 按住 60–120ms）、随机接触面积（major 3.5–6.0mm / minor 2.5–4.5mm）
4. **搜图搜字搜色**：findImage（NCC 模板）、findText（Vision OCR 中英文）、findColor/getColor
5. **坐标语义**：Lua 层一律用点坐标（getScreenSize 返回点；内部像素转换见 RESEARCH C3）
6. **可安装可启动**：图标、entitlements、uicache 注册、arm64e 架构包（RESEARCH A 节逐条）
7. **开箱可测**：test.at 随包、首启自动释放、App 内一键运行

## 版本

0.3.0（control / Info.plist / tweak 日志三处同步）
