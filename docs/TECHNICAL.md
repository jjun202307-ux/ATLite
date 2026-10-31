# ATLite 当前技术说明

最近构建为 0.3.15 调试版，真机尚未验收，验证边界见 ../BUILD_STATUS.md。

App：脚本列表、前台局域网服务、日志、普通权限探针。SpringBoard tweak：Lua、HID、抓屏、Vision OCR。shared/ATLEmailJob.* 是唯一共享邮箱记录实现，不新增网络服务或数据库。

## 执行

App 写 command.json 的 cmd/script/commandId 字段，run 携带 stopSnapshot，并发 Darwin 通知；通知回调串行处理，最近4096个编号去重。只有 SpringBoard 接收。run 先用 CAS 取得唯一槽；已有任务直接拒绝，不等待后强行并发。stop 增加停止代次并保留唯一 stop.flag，状态等脚本实际退出后才空闲。

Lua 使用限额分配器，文本 UTF-8 校验、文本模式加载和保护执行。初始化、脚本错误和清理均有明确路径；活动触点/按键、VM、截图和状态在结束时清理。base/table/string/math/utf8 为当前白名单。合作 hook 与 sleep/NCC 检查 deadline；不是进程外硬终止。

## 图像与输入

0.3.15 根路径解析同时识别 MobileSubstrate 与其 canonical usr/lib/TweakInject 路径；App 探针独立创建结果目录。屏幕读取在主线程限时获取尺寸。RenderDisplay 运行于专用队列，调用方限时等待；超时迟到的 surface 会释放，当前进程停用后续抓屏。复制像素采用 AvoidSync 只读锁；ARGB/BGRA 转换后 alpha 固定255。

NCC 使用 ATCore.h 中同一份可编译测试的全分辨率实现，最小2×2，纯色不匹配，搜索预算2秒；不再使用会相位漏检的四分之一样本硬阈值。大范围大模板可能超时；不把超时伪装成无目标。

OCR 同步执行，最多64块，每块511字节UTF-8。固定结果暂存与图片 finally 清理在 Lua 结果表分配之前完成。ocrText 返回原文/框/置信度，findText 用同一条链路定位。

IOHIDFloat 使用 double；IOSurfaceUnlock 使用 uint32_t* seed。时间基换算按 ns×denom/numer，节流后生成递增时间戳。inputText 使用 page0x07 的US可打印ASCII按键，不是通用中文输入方案。最终是否输入目标 App 必须真机确认。

## 邮箱任务

email-job.json 保存最近一个任务；独立 email-job.lock 用非阻塞 flock，JSON 原子替换。状态 pending→processing→done/error，cancelled 为显式取消。完成时校验 jobId、邮箱与 processing 状态，避免旧任务回写新邮箱。finally 释放锁。文本长度、UTF-8 和控制字符均验证。

PUT /api/job 创建，GET /api/job 看当前状态，GET /api/result?jobId=...取匹配任务，DELETE /api/job?jobId=...取消记录。取消记录不等于停止脚本。App 挂起期间 HTTP 不保证可达。

## A/B

原 A=App按需拉起，B=SpringBoard桥接保活仍是设计，详见 LIGHTWEIGHT_PLAN.md。当前无 daemon，不能宣称已实现双模式。两模式最终共享所有核心功能，不增加两套邮箱流程。
