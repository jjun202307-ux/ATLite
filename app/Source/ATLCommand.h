#import <Foundation/Foundation.h>

// 向 tweak 发送命令（写 command.json + post Darwin 通知）。
// 注意：命令只是"投递"，真正执行在 SpringBoard 进程里的 tweak 侧。
void ATLSendCommand(NSString *action, NSString *scriptNameOrNil);

// E26 强停：额外落 stop.flag 文件作为兜底通道 ——
// 通知可能送不达（SpringBoard 忙到不处理回调），但文件检查是脚本自己做的，一定能看到。
void ATLSendStop(void);
