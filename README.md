# not working yet

https://github.com/zig-homebrew/zig-3ds does work (with some updates for recent zig), but it requires devkitpro installed on the system

the goal of this project is to build for 3ds with zig as the only dependency

current status:

- working through newlib build issues

notes:

- zig is llvm, devkitpro is for gcc
- so far, one patch to newlib is required to add `return 0` to an `int` fn that doesn't have a return statement
- likely another will be needed in `stdio/nano-vfprintf.c:551:17`: "using the result of an assignment as a condition without parentheses"
- https://github.com/ziglang/zig/issues/20086
  - should be able to fix this by removing .func / .endfunc because they're only used for debug info