#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <limits.h>
#include <string.h>
#include <time.h>
#include "../shared/ATLOCRProtocol.h"

// Theos SDK compatibility declarations, same runtime API as the existing bridge.
@interface VNRecognizedText (ATLWorkerSDKCompat)
- (NSArray<VNRecognizedText *> *)topCandidates:(NSUInteger)count;
@property(nonatomic,readonly) CGRect boundingBox;
@property(nonatomic,readonly) NSString *string;
@property(nonatomic,readonly) float confidence;
@end
@interface VNRecognizeTextRequest (ATLWorkerLanguages)
- (NSArray<NSString *> *)supportedRecognitionLanguagesAndReturnError:(NSError **)error;
@end

static int ATLReply(NSString *requestID, BOOL ok, NSArray *lines,
                    NSString *code, NSString *message) {
    NSMutableDictionary *reply=[@{@"version":@ATL_OCR_PROTOCOL_VERSION,
        @"requestId":requestID ?: @"invalid",@"ok":@(ok)} mutableCopy];
    if (ok) {
        reply[@"mode"]=@"accurate";reply[@"languages"]=@[@"zh-Hans",@"en-US"];
        reply[@"lines"]=lines ?: @[];
    } else { reply[@"errorCode"]=code ?: @"VISION_FAILED";reply[@"errorMessage"]=message ?: @"OCR failed"; }
    NSData *data=[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
    if (!data || data.length>ATL_OCR_OUTPUT_LIMIT) return 65;
    size_t sent=0;
    while (sent<data.length) {
        ssize_t n=write(STDOUT_FILENO,(const char *)data.bytes+sent,data.length-sent);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) return 74;
        sent+=(size_t)n;
    }
    return 0; // A handled Vision failure is represented by ok=false, not a fake success.
}
static double ATLWorkerNow(void) {
    struct timespec time;clock_gettime(CLOCK_MONOTONIC,&time);
    return (double)time.tv_sec+time.tv_nsec/1e9;
}

int main(int argc,char **argv) {
    @autoreleasepool {
        if (argc!=5 || strcmp(argv[1],"--request-id") || strcmp(argv[3],"--parent")) return 64;
        NSString *requestID=[NSString stringWithUTF8String:argv[2]];
        if (!requestID.length || requestID.length>80) return 64;
        char *end=NULL;errno=0;long owner=strtol(argv[4],&end,10);
        if (errno || !end || *end || owner<=1 || owner>INT_MAX || getppid()!=(pid_t)owner) return 125;
        // A parent respring must not leave a stuck orphan Vision worker.
        dispatch_source_t watch=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0));
        if (!watch) return 71;
        dispatch_source_set_timer(watch,dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),200*NSEC_PER_MSEC,20*NSEC_PER_MSEC);
        double deadline=ATLWorkerNow()+ATL_OCR_TIMEOUT;
        dispatch_source_set_event_handler(watch,^{
            if (getppid()!=(pid_t)owner) _exit(125);
            if (ATLWorkerNow()>=deadline) _exit(124);
        });
        dispatch_resume(watch);
        CGImageSourceRef source=NULL;CGImageRef image=NULL;
        int result=70;
        @try {
            struct stat st;
            if (fstat(STDIN_FILENO,&st) || !S_ISREG(st.st_mode) || st.st_size<=0 || st.st_size>ATL_OCR_INPUT_LIMIT)
                return ATLReply(requestID,NO,nil,@"INPUT_INVALID",@"Expected bounded regular PNG input");
            NSMutableData *input=[NSMutableData dataWithLength:(NSUInteger)st.st_size];
            NSUInteger offset=0;
            while (offset<input.length) {
                ssize_t n=read(STDIN_FILENO,(char *)input.mutableBytes+offset,input.length-offset);
                if (n<0 && errno==EINTR) continue;
                if (n<=0) return ATLReply(requestID,NO,nil,@"INPUT_INVALID",@"Incomplete image input");
                offset+=(NSUInteger)n;
            }
            source=CGImageSourceCreateWithData((__bridge CFDataRef)input,NULL);
            NSDictionary *properties=source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL)) : nil;
            unsigned long long w=[properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue];
            unsigned long long h=[properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue];
            if (!w || !h || w>8192 || h>8192 || w*h>ATL_OCR_PIXEL_LIMIT)
                return ATLReply(requestID,NO,nil,@"INPUT_INVALID",@"Invalid or excessive image dimensions");
            image=CGImageSourceCreateImageAtIndex(source,0,NULL);
            if (!image) return ATLReply(requestID,NO,nil,@"INPUT_INVALID",@"Image decode failed");
            VNRecognizeTextRequest *request=[[VNRecognizeTextRequest alloc] init];
            request.recognitionLevel=VNRequestTextRecognitionLevelAccurate;
            request.recognitionLanguages=@[@"zh-Hans",@"en-US"];
            request.usesLanguageCorrection=NO;
            // Default accelerated request; CPU-only failed on the actual device.
            request.usesCPUOnly=NO;
            NSError *error=nil;
            NSArray *supported=nil;
            if (@available(iOS 15.0, macOS 12.0, *)) {
                supported=[request supportedRecognitionLanguagesAndReturnError:&error];
            } else {
                supported=[VNRecognizeTextRequest supportedRecognitionLanguagesForTextRecognitionLevel:request.recognitionLevel
                    revision:request.revision error:&error];
            }
            if (!supported || ![supported containsObject:@"zh-Hans"] || ![supported containsObject:@"en-US"])
                return ATLReply(requestID,NO,nil,@"LANGUAGE_UNSUPPORTED",error.localizedDescription ?: @"Accurate Chinese/English unavailable");
            VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
            if (![handler performRequests:@[request] error:&error])
                return ATLReply(requestID,NO,nil,@"VISION_FAILED",error.localizedDescription);
            NSMutableArray *lines=[NSMutableArray array];
            for (VNRecognizedText *observation in request.results) {
                if (lines.count>=ATL_OCR_LINE_LIMIT) break;
                VNRecognizedText *candidate=[observation topCandidates:1].firstObject;
                NSString *text=candidate.string;
                if (!text.length || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>ATL_OCR_TEXT_LIMIT) continue;
                CGRect box=observation.boundingBox;
                [lines addObject:@{@"text":text,@"x":@(box.origin.x),@"y":@(1-box.origin.y-box.size.height),
                    @"width":@(box.size.width),@"height":@(box.size.height),@"confidence":@(candidate.confidence)}];
            }
            result=ATLReply(requestID,YES,lines,nil,nil);
        } @catch (NSException *exception) {
            result=ATLReply(requestID,NO,nil,@"VISION_FAILED",exception.reason);
        } @finally {
            if (image) CGImageRelease(image);
            if (source) CFRelease(source);
            dispatch_source_cancel(watch);
        }
        return result;
    }
}
