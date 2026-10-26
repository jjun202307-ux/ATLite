# 0.3.11 源码开发版

## 轻量邮箱流程

- 单一当前任务：局域网发送邮箱、脚本认领、OCR读用户名、回传结果；防止处理中被新任务覆盖。
- inputText：只支持可打印ASCII的HID输入，主要用于邮箱；需要目标输入框焦点与真机验证。
- ocrText 返回文本/框/置信度；提供 email_roundtrip.at，可配置点位和用户名匹配规则。
- swipe 简单滑动辅助；tap/swipe 遇到合作取消也尽力释放触点。

## 修复

- Lua 初始化注册函数时栈索引错误、非法编码空指针路径、内存预算、单实例和finally清理。
- 长睡眠和NCC合作预算、停止文件生命周期、触摸/键盘释放。
- IOHIDFloat double ABI、IOSurfaceUnlock指针签名、ARGB alpha、纳秒到ticks换算和递增事件时间。
- 模板采样错位漏检，改为可测的全分辨率NCC基线，限制2秒计算。
- Lua分配失败前释放native图像，错误对象不在保护调用外做数字转字符串分配。
- HTTP线程/连接上限、绝对网络超时、完整body校验、文件名DOM转义、单次解码和非阻塞监听。
- 普通权限探针取代默认setuid；stdout归属明确，有限回收，不用begin冒充完成；P2路径修复。
- Lua源码快照固定随包，CI执行行为测试和实际Mach-O产物检查。

## 未完成/未验证

- 没有新版deb，未执行完整Objective-C/Theos编译或iPhone验收。
- A/B独立引擎拉起和保活尚未实现，当前仍在SpringBoard执行Lua。
- 没有复杂兼容层、云平台、队列后台、录制或授权系统。
