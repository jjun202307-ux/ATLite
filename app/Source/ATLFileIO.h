#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

// Diagnostics must remain writable when the SpringBoard plugin never initialized.
static inline BOOL ATLWriteDiagnosticResult(NSString *text, NSString *path, NSError **error) {
    if (!text || !path.isAbsolutePath) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInvalidFileNameError userInfo:nil];
        return NO;
    }
    if (![[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    return [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:error];
}

// Bounded regular-file read: never allocate or decode the full log.
static inline NSString *ATLReadLogTail(NSString *path, NSUInteger limit) {
    if (!limit || !path.length) return nil;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return nil;
    NSString *result = nil;
    @try {
        struct stat st;
        if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0) return nil;
        off_t start = st.st_size > (off_t)limit ? st.st_size - (off_t)limit : 0;
        NSUInteger length = (NSUInteger)(st.st_size - start);
        NSMutableData *data = [NSMutableData dataWithLength:length];
        NSUInteger offset = 0;
        while (offset < length) {
            ssize_t n = pread(fd, (char *)data.mutableBytes + offset, length - offset, start + offset);
            if (n < 0 && errno == EINTR) continue;
            if (n < 0) return nil;
            if (n == 0) break; // concurrent truncation
            offset += (NSUInteger)n;
        }
        data.length = offset;
        NSUInteger skip = 0;
        if (start > 0) {
            const unsigned char *bytes = data.bytes;
            while (skip < data.length && skip < 3 && (bytes[skip] & 0xc0) == 0x80) skip++;
        }
        result = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(skip,data.length-skip)] encoding:NSUTF8StringEncoding];
        if (result && start > 0) result = [@"...（省略前部）\n" stringByAppendingString:result];
    } @finally { close(fd); }
    return result;
}

static inline int ATLDeleteFile(NSString *path) {
    NSError *error = nil;
    if ([[NSFileManager defaultManager] removeItemAtPath:path error:&error]) return 200;
    return [error.domain isEqual:NSCocoaErrorDomain] && error.code == NSFileNoSuchFileError ? 404 : 500;
}
