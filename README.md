zig3ds allows you to develop applications for 3ds with only zig and no other system dependencies.

# Usage

Must use zig version 0.13.0-dev.274+c0da92f71

Once mach nominates its next zig version, we will use `2024.5.0-mach` instead: https://machengine.org/about/nominated-zig/. `2024.3.0-mach` cannot be used because of missing `build.zig` features.

Setup:

1. Download `example/` from this repo
2. Run: `zig fetch --save git+https://github.com/pfgithub/zig3ds#main`
3. Done!

Build your application with `zig build`, or run it with `zig build run` if `citra` is in your PATH. Output file is in `zig-out/bin/sample.3dsx`.

# Adding libraries

zig3ds currently supports [citro3d](https://github.com/devkitPro/citro3d) and [citro2d](https://github.com/devkitPro/citro3d). citro3d is required to use citro2d.

```zig
const citro3d_includer = zig3ds.CIncluder.find(zig3ds_dep, "citro3d");
const citro2d_includer = zig3ds.CIncluder.find(zig3ds_dep, "citro2d");

citro3d_includer.applyTo(&elf.root_module);
elf.linkLibrary(zig3ds_dep.artifact("citro3d"));
citro2d_includer.applyTo(&elf.root_module);
elf.linkLibrary(zig3ds_dep.artifact("citro2d"));
```

# Known Issues

- [ ] Zig doesn't seem to have an equivalent of `-mtp=soft`. This is probably bad?
- [ ] A [bad patch](https://github.com/pfgithub/libctru/commit/13e35d7f19c51c334bf575fcf80b653edc0a0abe) is applied to libctru to disable its threadlocals because otherwise it doesn't compile. This patch breaks multithreaded use of any libctru functions that use path buffers. The error:
  - ```
    error: ld.lld: libctru.a(path_buf.o) has an STT_TLS symbol but doesn't have an SHF_TLS section
    ```
- [ ] [3dsx.ld](https://github.com/devkitPro/devkitarm-crtls/blob/master/3dsx.ld) specifies a bss alignment of 4, but lld wants align(8)
  - ```
    error: warning(link): unexpected LLD stderr:
    ld.lld: warning: address (0x159e88) of section .bss is not a multiple of alignment (64)
    ```
- [ ] Zig doesn't yet know it's linking libc, so things like `std.heap.c_alloator` probably can't be used.
- [ ] `-fno-sanitize=undefined` is required to prevent a crash in `graphics/printing/system-font` and to prevent crashes on exit in all programs. 
- [ ] both libgloss/libsysbase and newlib provide copies of the same functions. Which one is the right one? I chose newlib/libc:
  - `libgloss/libsysbase/unlink.c` defines `_unlink_r` to call `devoptab_list[dev]->unlink_r()`
  - `newlib/libc/reent/unlinkr.c` defines `_unlink_r` to call `_unlink`

# TODO Features

- [ ] Support emitting `.cia` files. This maybe requires `cxitool` and `makerom`.

# Alternatives

[zig-3ds](https://github.com/zig-homebrew/zig-3ds) also lets you use zig to compile for 3ds, but 