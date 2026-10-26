#import "ATLEmailJob.h"
#import <sys/file.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

static const NSUInteger ATLEmailMaxJSON = 1024 * 1024;
static void ATLEmailError(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"ATLEmailJob" code:code
        userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL ATLText(id value, NSUInteger max, BOOL empty) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *s = value;
    return (empty || s.length > 0) && s.length <= max &&
        [s dataUsingEncoding:NSUTF8StringEncoding] != nil &&
        [s rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static BOOL ATLEmailValid(id email) {
    if (!ATLText(email, 254, NO)) return NO;
    NSString *pattern = @"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$";
    NSRegularExpression *r = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSString *s = email;
    NSString *local = [s componentsSeparatedByString:@"@"].firstObject;
    return local.length <= 64 && ![local hasPrefix:@"."] && ![local hasSuffix:@"."] &&
        ![local containsString:@".."] && [r numberOfMatchesInString:s options:0 range:NSMakeRange(0,s.length)] == 1;
}
static int ATLEmailLock(NSString *base, NSError **error) {
    if (!ATLText(base, 4096, NO)) { ATLEmailError(error,400,@"invalid base path"); return -1; }
    NSString *path = [base stringByAppendingPathComponent:@"email-job.lock"];
    int fd = open(path.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) { ATLEmailError(error,500,@"cannot open job lock"); return -1; }
    // A single nonblocking attempt is finite and lets callers retry explicitly.
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        int reason = errno; close(fd);
        ATLEmailError(error, reason == EWOULDBLOCK || reason == EAGAIN ? 409 : 500, @"job lock busy or unavailable");
        return -1;
    }
    return fd;
}
static void ATLEmailUnlock(int fd) { flock(fd,LOCK_UN); close(fd); }
// All callers hold the same separate lock inode while reading/replacing the JSON file.
static NSDictionary *ATLRead(NSString *base, NSError **error) {
    NSString *path = [base stringByAppendingPathComponent:@"email-job.json"];
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) { ATLEmailError(error, errno == ENOENT ? 404 : 500,@"job not found or unreadable"); return nil; }
    @try {
        struct stat st;
        if (fstat(fd,&st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > ATLEmailMaxJSON) {
            ATLEmailError(error,500,@"invalid job file size"); return nil;
        }
        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
        NSUInteger off = 0;
        while (off < data.length) {
            ssize_t n = read(fd,(char *)data.mutableBytes + off,data.length-off);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { ATLEmailError(error,500,@"short job read"); return nil; }
            off += (NSUInteger)n;
        }
        id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![value isKindOfClass:NSDictionary.class] || !ATLText(value[@"jobId"],80,NO) ||
            !ATLEmailValid(value[@"email"]) || ![@[@"pending",@"processing",@"done",@"error",@"cancelled"] containsObject:value[@"status"]]) {
            ATLEmailError(error,500,@"invalid job record"); return nil;
        }
        if ([value[@"status"] isEqual:@"done"]) {
            id lines = value[@"ocrLines"];
            if (!ATLText(value[@"username"],256,NO) || ![lines isKindOfClass:NSArray.class] || [lines count] > 100) {
                ATLEmailError(error,500,@"invalid completed result"); return nil;
            }
            for (id line in lines) if (!ATLText(line,2048,YES)) {
                ATLEmailError(error,500,@"invalid OCR result"); return nil;
            }
        }
        if ([value[@"status"] isEqual:@"error"] && !ATLText(value[@"failure"],2048,NO)) {
            ATLEmailError(error,500,@"invalid failure result"); return nil;
        }
        return value;
    } @finally { close(fd); }
}
static BOOL ATLWrite(NSString *base, NSDictionary *job, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:job options:0 error:nil];
    if (!data || data.length > ATLEmailMaxJSON) { ATLEmailError(error,400,@"job JSON too large"); return NO; }
    if (![data writeToFile:[base stringByAppendingPathComponent:@"email-job.json"] options:NSDataWritingAtomic error:nil]) {
        ATLEmailError(error,500,@"cannot save job"); return NO;
    }
    return YES;
}
NSDictionary *ATLEmailReadJob(NSString *base, NSError **error) {
    if (error) *error = nil;
    int fd = ATLEmailLock(base,error); if (fd < 0) return nil;
    @try {
        NSDictionary *job = ATLRead(base,error); return job;
    } @finally { ATLEmailUnlock(fd); }
}
NSDictionary *ATLEmailCreateJob(NSString *base, NSString *email, NSError **error) {
    if (error) *error = nil;
    if (!ATLEmailValid(email)) { ATLEmailError(error,400,@"invalid ASCII email"); return nil; }
    int fd = ATLEmailLock(base,error); if (fd < 0) return nil;
    @try {
        NSError *readError = nil; NSDictionary *old = ATLRead(base,&readError);
        NSDictionary *job = nil;
        if (!old && readError.code != 404) { if (error) *error = readError; }
        else if (old && [@[@"pending",@"processing"] containsObject:old[@"status"]]) ATLEmailError(error,409,@"current job still active");
        else {
            job = @{@"jobId":NSUUID.UUID.UUIDString,@"email":email,@"status":@"pending"};
            if (!ATLWrite(base,job,error)) job = nil;
        }
        return job;
    } @finally { ATLEmailUnlock(fd); }
}
NSDictionary *ATLEmailClaimJob(NSString *base, NSError **error) {
    if (error) *error = nil;
    int fd = ATLEmailLock(base,error); if (fd < 0) return nil;
    @try {
        NSDictionary *old = ATLRead(base,error); NSMutableDictionary *job = nil;
        if (old && ![old[@"status"] isEqual:@"pending"]) ATLEmailError(error,409,@"job is not pending");
        else if (old) { job = old.mutableCopy; job[@"status"] = @"processing"; if (!ATLWrite(base,job,error)) job = nil; }
        return job;
    } @finally { ATLEmailUnlock(fd); }
}
BOOL ATLEmailFinishJob(NSString *base, NSString *jobId, NSString *email, NSString *username,
    NSArray<NSString *> *ocrLines, NSString *failure, NSError **error) {
    if (error) *error = nil;
    BOOL valid = ATLText(jobId,80,NO) && ATLEmailValid(email);
    if (failure) valid = valid && ATLText(failure,2048,NO);
    else {
        valid = valid && ATLText(username,256,NO) &&
            [[username stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] length] > 0 &&
            [ocrLines isKindOfClass:NSArray.class] && ocrLines.count <= 100;
        if (valid) for (id line in ocrLines) if (!ATLText(line,2048,YES)) { valid = NO; break; }
    }
    if (!valid) { ATLEmailError(error,400,@"invalid result"); return NO; }
    int fd = ATLEmailLock(base,error); if (fd < 0) return NO;
    @try {
        NSDictionary *old = ATLRead(base,error); BOOL ok = NO;
        if (old && (![old[@"jobId"] isEqual:jobId] || ![old[@"email"] isEqual:email] || ![old[@"status"] isEqual:@"processing"]))
            ATLEmailError(error,409,@"stale job or job is not processing");
        else if (old) {
            NSMutableDictionary *job = old.mutableCopy;
            job[@"status"] = failure ? @"error" : @"done";
            if (failure) job[@"failure"] = failure;
            else { job[@"username"] = username; job[@"ocrLines"] = ocrLines; }
            ok = ATLWrite(base,job,error);
        }
        return ok;
    } @finally { ATLEmailUnlock(fd); }
}
BOOL ATLEmailCancelJob(NSString *base, NSString *jobId, NSError **error) {
    if (error) *error = nil;
    if (!ATLText(jobId,80,NO)) { ATLEmailError(error,400,@"invalid jobId"); return NO; }
    int fd = ATLEmailLock(base,error); if (fd < 0) return NO;
    @try {
        NSDictionary *old = ATLRead(base,error); BOOL ok = NO;
        if (old && ![old[@"jobId"] isEqual:jobId]) ATLEmailError(error,409,@"stale jobId");
        else if (old) {
            NSMutableDictionary *job = old.mutableCopy; job[@"status"] = @"cancelled";
            [job removeObjectForKey:@"username"]; [job removeObjectForKey:@"ocrLines"]; [job removeObjectForKey:@"failure"];
            ok = ATLWrite(base,job,error);
        }
        return ok;
    } @finally { ATLEmailUnlock(fd); }
}
