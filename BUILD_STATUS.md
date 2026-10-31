# ATLite 0.3.15 调试构建状态

2026-10-31：macOS CI 构建成功，64 项测试（无跳过）、131 项静态检查、29 项 deb 检查通过。

构建提交：3510205ec7016b79a5018785a5fc319bb1b9c68c。CI：https://github.com/jjun202307-ux/ATLite/actions/runs/41194326827

deb SHA-256：b2cbafdd27ac7f95db684927e333b56aa8579dd2eb175504f677d4ed6f63d68b。

已 SSH 登录 iPhone 11 / iOS 16.6，确认原安装 0.3.14。手机隔离测试进程已复现原插件因不识别 canonical TweakInject 路径而禁用；0.3.15 补齐解析与 libroot 显式加载，并修复诊断目录创建和错误注入提示。

修复包已上传手机 /var/mobile/ATLite_0.3.15_iphoneos-arm64e.deb，尚未安装；当前 mobile SSH 无 sudo 免密权限，root 公钥未配置。待管理员安装与重启桌面后继续测试真正 SpringBoard 的加载、脚本、抓屏取色、OCR、点击滑动与邮箱往返。不能把本记录视为整机验收通过。

0.3.13/0.3.14 变更及两次截图详见 docs/DEVICE_DEBUG_2026-10-31.md；历史源代码快照保留。
