#import <Foundation/Foundation.h>

// 极简 HTTP 导入服务器（对齐 AutoTouch 内置 Web Server 的定位）
//  GET    /                       -> 网页版文件管理
//  GET    /api/list?dir=scripts   -> 脚本列表（dir=images 为模板图片）
//  GET    /api/get?name=x         -> 下载
//  PUT    /api/put?name=x         -> 上传/覆盖（按扩展名自动存 Scripts/ 或 Images/）
//  DELETE /api/del?name=x         -> 删除
@interface ATLWebServer : NSObject

- (instancetype)initWithRootPath:(NSString *)rootPath port:(uint16_t)port;
- (BOOL)start;
- (void)stop;
@property (nonatomic, readonly, assign, getter=isRunning) BOOL running;

@end
