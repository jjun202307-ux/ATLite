#pragma once
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <stddef.h>

// 1: read, 0: absent, -1: unreadable/invalid. Bounded, including growth races.
static int ATLReadStopFile(const char *path, unsigned char *buffer, size_t capacity, size_t *length) {
    if (!path || !*path || !buffer || !length) return -1;
    int fd = open(path, O_RDONLY | O_NONBLOCK);
    if (fd < 0) return errno == ENOENT ? 0 : -1;
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size < 0 || (unsigned long long)st.st_size > capacity) { close(fd); return -1; }
    size_t n = 0;
    while (n < capacity) {
        ssize_t got = read(fd, buffer + n, capacity - n);
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) { close(fd); return -1; }
        if (!got) break;
        n += (size_t)got;
    }
    unsigned char extra;
    ssize_t got;
    do { got = read(fd, &extra, 1); } while (got < 0 && errno == EINTR);
    close(fd);
    if (got != 0) return -1;
    *length = n;
    return 1;
}
