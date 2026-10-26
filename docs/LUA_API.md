# ATLite 0.3.11 轻量 API

当前坐标全部是点，非原生像素。不是 AutoTouch/触动精灵兼容声明。

```lua
tap(x,y)                              -- 按住随机60–120ms
swipe(x1,y1,x2,y2,durationMs)          -- 默认400ms，允许16..10000ms
touchDown(finger,x,y)
touchMove(finger,x,y)
touchUp(finger,x,y)                    -- finger 0..9
keyDown(usage)                        -- 旧consumer键码需真机确认
keyUp(usage)
usleep(us)                            -- 非负有限数，检查合作停止
msleep(ms)
stop()
screenWidth(); screenHeight(); rootDir()
log("message")                        -- print 同义

getColor(x,y)                         -- 0xRRGGBB；截图不可用时nil
findColor(rgb,tolerance)              -- 最多10点，四像素网格可能漏小色块
findImage("button.png",similarity)    -- {{x,y,score}}；只返回最佳目标
findText("用户名")                    -- {{中心x,中心y},...}
ocrText()                             -- {{text,x,y,width,height,confidence},...}
inputText("demo@example.com")         -- 仅可打印ASCII，已聚焦字段；返回已派发，不保证已填入

local job=getEmailJob()               -- {jobId,email}；无pending任务时nil；认领后processing
sendEmailResult(job.jobId,job.email,"alice",{"用户名：alice"})
failEmailJob(job.jobId,job.email,"没有识别到用户名")
```

模板可传 Images 内文件名或规范绝对路径，拒绝越界路径。搜图/搜字的正常无命中是空表；OCR链路失败或搜图计算超时抛错，可用 pcall 判断，不能都当空结果。

inputText 的 US HID 布局、App 焦点和屏幕输入效果必须真机确认。Unicode 输入不支持。示例 email_roundtrip.at 中配置输入/提交坐标和实际用户名识别规则；没有名字时不会由邮箱前缀猜一个。

脚本文本上限1MiB，VM上限32MiB，60秒合作预算；全分辨率NCC另外有2秒计算预算。OCR最多64块，每块511字节UTF-8，过长文字块跳过。同步OCR/系统IPC没有硬停止保证。

Lua库白名单：base/table/string/math/utf8；不开放 os/io/debug/package/coroutine/load/loadfile/dofile。Extensions.lua升为v3，旧版备份.bak后替换。

findColors/appRun/appKill/vibrate/openURL/toast仍是旧占位，返回nil并记日志；本轮不增加无关功能。
