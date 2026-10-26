# Lua 5.3.6 vendor snapshot

Source: https://www.lua.org/ftp/lua-5.3.6.tar.gz
Upstream tar SHA-256: fc5fd69bb8736323f026672b1b7235da613d7177e72558893a0bdcd320466d60
33 production .c files + headers. lua.c/luac.c CLI entry points excluded.
Local patch: loslib.c disables system() when targeting iOS. ATLite only exposes
base/table/string/math/utf8; os/io/debug/package/coroutine are not opened.
Lua MIT license is included verbatim at the end of lua.h and applies to Lua files.
