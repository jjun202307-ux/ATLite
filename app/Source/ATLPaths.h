#import <Foundation/Foundation.h>

// App 与 tweak 之间约定的 Darwin 通知名（tweak 侧同名常量 AT_DARWIN_NOTIFY）
extern NSString * const ATLDarwinNotifyName;

NSString *ATLJBRoot(void);
NSString *ATLBaseDir(void);
NSString *ATLScriptsDir(void);
NSString *ATLImagesDir(void);
NSString *ATLLogsDir(void);
NSString *ATLCommandPath(void);

// 日志文件候选路径（E24）：App 侧推导的 jbroot 与 tweak 侧可能不同（bundlePath vs dladdr），
// 逐个候选探测，避免"文件其实在，只是路径字符串不同"导致的调试盲区。
NSArray<NSString *> *ATLLogCandidatePaths(void);
// 第一个真实存在的日志路径；全都不存在时返回 nil
NSString *ATLExistingLogPath(void);
