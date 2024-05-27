# not working yet

https://github.com/zig-homebrew/zig-3ds does work (with some updates for recent zig), but it requires devkitpro installed on the system

the goal of this project is to build for 3ds with zig as the only dependency

current status:

- working through newlib build issues

notes:

- zig is llvm, devkitpro is for gcc
- so far, one patch to newlib is required to add `return 0` to an `int` fn that doesn't have a return statement

current issue:

- both libgloss/libsysbase and newlib provide copies of the same functions:
  - `libgloss/libsysbase/unlink.c` defines `_unlink_r` to call `devoptab_list[dev]->unlink_r()`
  - `newlib/libc/reent/unlinkr.c` defines `_unlink_r` to call `_unlink`
- which one is the right one?
  - how does the makefile handle this? because one of them definitely goes into libsysbase_a_SOURCES and one of them definitely goes into libc_a_SOURCES, and presumably those libraries get linked together