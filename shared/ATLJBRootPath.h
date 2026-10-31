#ifndef ATL_JBROOT_PATH_H
#define ATL_JBROOT_PATH_H
#include <stddef.h>
#include <string.h>

// dladdr resolves the DynamicLibraries symlink to usr/lib/TweakInject on device.
// A virtual /usr/lib path has no physical bootstrap prefix and is not a root.
static inline size_t ATLRootPrefixLengthForTweakPath(const char *path) {
    if (!path) return 0;
    const char *suffixes[] = {
        "/Library/MobileSubstrate/DynamicLibraries/ATLiteTweak.dylib",
        "/usr/lib/TweakInject/ATLiteTweak.dylib"
    };
    size_t length = strlen(path);
    for (size_t i = 0; i < sizeof(suffixes)/sizeof(suffixes[0]); i++) {
        size_t suffixLength = strlen(suffixes[i]);
        if (path[0] == '/' && length > suffixLength &&
            !strcmp(path + length - suffixLength, suffixes[i])) return length - suffixLength;
    }
    return 0;
}
#endif
