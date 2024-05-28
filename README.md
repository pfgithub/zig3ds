# not working yet

https://github.com/zig-homebrew/zig-3ds does work (with some updates for recent zig), but it requires devkitpro installed on the system

the goal of this project is to build for 3ds with zig as the only dependency

# status

it crashes on exit (due to ubsan, but the ubsan is blocking an actual infinite loop on exit)

notes:

- two patches are needed:
  - there is an `inline int` fn that does not have a return statement but supposedly returns errno. modify this to return 0
  - patch to libctru: `libctru/source/path_buf.h` right before `extern char __thread`: `#define __thread`
    - this is obviously wrong and will cause race conditions if multiple threads try to do path stuff at the same time
- when exiting the app (press 'Start' / 'M'), it crashes:
  - ReleaseFast fixes this
  - `-fno-sanitize=undefined` makes it hang instead of crash on exit
- zig doesn't seem to have an equivalent of `-mtp=soft`. this is likely bad? might break threadlocals
- both libgloss/libsysbase and newlib provide copies of the same functions:
  - `libgloss/libsysbase/unlink.c` defines `_unlink_r` to call `devoptab_list[dev]->unlink_r()`
  - `newlib/libc/reent/unlinkr.c` defines `_unlink_r` to call `_unlink`
- which one is the right one?