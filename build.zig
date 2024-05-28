const std = @import("std");

fn addTool(b: *std.Build, dep: *std.Build.Dependency, tool_name: []const u8, files: []const []const u8) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = tool_name,
        .target = b.resolveTargetQuery(.{}), // native
        .optimize = .ReleaseSafe,
    });

    exe.linkLibC();
    exe.linkLibCpp();
    exe.addCSourceFiles(.{
        .root = dep.path(""),
        .files = files,
        .flags = &.{
            b.fmt("-DPACKAGE_STRING=\"{s}\"", .{tool_name}),
            "-D__DATE__=\"disabled\"",
            "-D__TIME__=\"disabled\"",
            // "-fno-sanitize=undefined",
        },
    });
    exe.addIncludePath(dep.path(""));

    const insa = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "3dstools" } },
    });
    b.getInstallStep().dependOn(&insa.step);

    return exe;
}

const CIncluder = struct {
    //! addStaticLibrary + linkLibrary() has this functionality already
    //! however, it doesn't support define_macros, and it seems to be
    //! designed for one per build.zig. also, it probably doesn't support
    //! merging headers from a few different folders.

    // note: we'll have to expose these with a hack
    // https://github.com/ziglang/zig/issues/19859
    // find some u64 to hide a pointer in and use intFromPtr/ptrFromInt

    const DefineMacro = struct { []const u8, ?[]const u8 };
    owner: *std.Build,
    define_macros: []const DefineMacro,
    add_include_paths: []const std.Build.LazyPath,

    pub const Options = struct {
        define_macros: []const DefineMacro = &.{},
        add_include_paths: []const std.Build.LazyPath = &.{},
    };

    pub fn createCIncluder(b: *std.Build, options: Options) *CIncluder {
        const ci = b.allocator.create(CIncluder) catch @panic("oom");
        ci.* = .{
            .owner = b,
            .define_macros = b.allocator.dupe(DefineMacro, options.define_macros) catch @panic("oom"),
            .add_include_paths = b.allocator.dupe(std.Build.LazyPath, options.add_include_paths) catch @panic("oom"),
        };
        return ci;
    }

    pub fn expose(self: *const CIncluder, name: []const u8) void {
        const name_fmt = self.owner.fmt("__cincluder_{s}", .{name});
        const mod = self.owner.addModule(name_fmt, .{});
        // HACKHACKHACK
        mod.* = undefined;
        mod.owner = @ptrCast(@alignCast(@constCast(self)));
    }
    pub fn find(dep: *std.Build.Dependency, name: []const u8) *const CIncluder {
        const name_fmt = dep.builder.fmt("__cincluder_{s}", .{name});
        const modv = dep.module(name_fmt);
        // HACKHACKHACK
        return @ptrCast(@alignCast(modv.owner));
    }

    fn applyTo(self: *const CIncluder, mod: *std.Build.Module) void {
        for (self.define_macros) |m| mod.addCMacro(m[0], m[1] orelse "1");
        for (self.add_include_paths) |ip| mod.addIncludePath(ip);
    }
};

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    const target_3ds = b.resolveTargetQuery(std.Target.Query.parse(.{
        .arch_os_abi = "arm-freestanding-gnueabihf",
        .cpu_features = "mpcore",
    }) catch @panic("bad target"));

    // 1. we need 3dstools
    const @"3dstools_dep" = b.dependency("3dstools", .{});
    const @"3dstools_cxitool_dep" = b.dependency("3dstools-cxitool", .{});
    const general_tools_dep = b.dependency("general-tools", .{});
    // elf -> .3dsx
    const tool_3dsxtool = addTool(b, @"3dstools_dep", "3dsxtool", &[_][]const u8{
        "src/3dsxtool.cpp",
        "src/romfs.cpp",
    });
    // .3dsx -> .cia
    _ = addTool(b, @"3dstools_cxitool_dep", "cxitool", &[_][]const u8{
        "src/cxitool.cpp",
        "src/CxiBuilder.cpp",
        "src/CxiSettings.cpp",
        "src/CxiExeFS.cpp",
        "src/CxiRomFS.cpp",
        "src/blz.c",
        "src/3dsx_loader.cpp",
        "src/crypto.cpp",
        "src/polarssl/aes.c",
        "src/polarssl/rsa.c",
        "src/polarssl/sha1.c",
        "src/polarssl/sha2.c",
        "src/polarssl/base64.c",
        "src/polarssl/bignum.c",
        "src/YamlReader.cpp",
        "src/libyaml/api.c",
        "src/libyaml/dumper.c",
        "src/libyaml/emitter.c",
        "src/libyaml/loader.c",
        "src/libyaml/parser.c",
        "src/libyaml/reader.c",
        "src/libyaml/scanner.c",
        "src/libyaml/writer.c",
    });
    // .bin -> .s & .h
    const bin2s_tool = addTool(b, general_tools_dep, "bin2s", &[_][]const u8{
        "bin2s.c",
    });

    const libctru_dep = b.dependency("libctru", .{});
    const crtls_dep = b.dependency("devkitarm-crtls", .{});
    const newlib_dep = b.dependency("newlib", .{});
    const examples_dep = b.dependency("3ds-examples", .{});

    // libctru dependencies
    const bin2s_run_cmd = b.addRunArtifact(bin2s_tool);
    bin2s_run_cmd.addArg("-H");
    const default_font_bin_h = bin2s_run_cmd.addOutputFileArg("default_font_bin.h");
    bin2s_run_cmd.addArg("-n");
    bin2s_run_cmd.addArg("default_font_bin");
    bin2s_run_cmd.addFileArg(libctru_dep.path("libctru/data/default_font.bin"));
    const c_stdout = captureStdoutNamed(bin2s_run_cmd, "default_font_bin.s");

    const asm_os = b.addObject(.{
        .name = "3ds_asm_files",
        .target = target_3ds,
        .optimize = optimize,
    });
    {
        // libctru has asm files thar are '.s' but need to be '.S'

        // this run step is for error checking only.
        // https://github.com/ziglang/zig/issues/20086
        const asm_obj = std.Build.Step.Run.create(b, "3ds_asm_files");
        asm_obj.addArgs(&.{
            b.graph.zig_exe,
            "cc",
            "-c",
            "-target",
            try target_3ds.query.zigTriple(b.allocator),
            b.fmt("-mcpu={s}", .{try target_3ds.query.serializeCpuAlloc(b.allocator)}),
            "-I" ++ "src/asm_fix",
        });
        asm_obj.addArg("-o");
        _ = asm_obj.addOutputFileArg("3ds_asm_files.o");

        asm_os.addIncludePath(.{ .path = "src/asm_fix" });
        asm_os.step.dependOn(&asm_obj.step);
        const install_dir = std.Build.InstallDir{ .custom = "tmp" };

        const tmpdir = b.makeTempPath();
        var tmpdir_dir = try std.fs.cwd().openDir(tmpdir, .{});
        defer tmpdir_dir.close();
        for (libctru_s_files) |file| {
            const fpath = libctru_dep.path(b.fmt("libctru/source/{s}", .{file[0]}));

            const install_file = b.addInstallFileWithDir(fpath, install_dir, file[1]);

            asm_os.addAssemblyFile(.{
                .cwd_relative = b.getInstallPath(install_file.dir, install_file.dest_rel_path),
            });
            asm_os.step.dependOn(&install_file.step);

            asm_obj.addFileArg(.{
                .cwd_relative = b.getInstallPath(install_file.dir, install_file.dest_rel_path),
            });
            asm_obj.step.dependOn(&install_file.step);
        }
    }

    // c flags
    const cflags = &[_][]const u8{
        "-mtp=soft",
    };

    // newlib
    const libc_includer = CIncluder.createCIncluder(b, .{
        .define_macros = &.{
            .{ "_LIBC", null },
            .{ "__DYNAMIC_REENT__", null },
            .{ "GETREENT_PROVIDED", null },
            .{ "REENTRANT_SYSCALLS_PROVIDED", null },
            .{ "__DEFAULT_UTF8__", null },
            .{ "_LDBL_EQ_DBL", null },
            .{ "_HAVE_INITFINI_ARRAY", null },
            .{ "_MB_CAPABLE", null },
        },
        .add_include_paths = &.{
            newlib_dep.path("newlib/libc/sys/arm"),
            newlib_dep.path("newlib/libc/machine/arm"),
            newlib_dep.path("newlib/libc/include"),
        },
    });
    libc_includer.expose("libc");

    // libgloss_libsysbase
    const libgloss_libsysbase = b.addStaticLibrary(.{
        .name = "libgloss_libsysbase",
        .target = target_3ds,
        .optimize = optimize,
    });
    libc_includer.applyTo(&libgloss_libsysbase.root_module);
    libgloss_libsysbase.addIncludePath(.{ .path = "src/config_fix" });
    libgloss_libsysbase.addCSourceFiles(.{
        .root = newlib_dep.path("libgloss/libsysbase"),
        .files = libgloss_libsysbase_files,
        .flags = cflags ++ &[_][]const u8{
            "-D_BUILDING_LIBSYSBASE",
        },
    });

    // newlib (libc)
    const libc = b.addStaticLibrary(.{
        .name = "libc",
        .target = target_3ds,
        .optimize = optimize,
    });
    libc_includer.applyTo(&libc.root_module);
    libc.addCSourceFiles(.{
        .root = newlib_dep.path("newlib/libc"),
        .files = newlib_libc_files,
        .flags = cflags,
    });

    // libm
    const libm = b.addStaticLibrary(.{
        .name = "libm",
        .target = target_3ds,
        .optimize = optimize,
    });
    libc_includer.applyTo(&libm.root_module);
    libm.addCSourceFiles(.{
        .root = newlib_dep.path("newlib/libm"),
        .files = newlib_libm_files,
        .flags = cflags,
    });

    // libctru
    const libctru_includer = CIncluder.createCIncluder(b, .{
        .add_include_paths = &.{
            libctru_dep.path("libctru/include"),
        },
    });
    libctru_includer.expose("libctru");
    const libctru = b.addStaticLibrary(.{
        .name = "libctru",
        .target = target_3ds,
        .optimize = optimize,
    });
    {
        libc_includer.applyTo(&libctru.root_module);
        libctru_includer.applyTo(&libctru.root_module);

        libctru.addAssemblyFile(crtls_dep.path("3dsx_crt0.s"));

        libctru.addIncludePath(default_font_bin_h.dirname());
        libctru.addAssemblyFile(c_stdout);

        libctru.addObject(asm_os);

        libctru.addCSourceFiles(.{
            .root = libctru_dep.path("libctru/source"),
            .files = libctru_files,
            .flags = cflags,
        });
    }

    // 4. build the game
    const elf = b.addExecutable(.{
        .name = "sample",
        .target = target_3ds,
        .optimize = optimize,
    });
    // elf.defineCMacro("__3DS__", null);
    elf.addCSourceFile(.{
        .file = examples_dep.path("graphics/printing/hello-world/source/main.c"),
        .flags = cflags,
    });

    libc_includer.applyTo(&elf.root_module);
    libctru_includer.applyTo(&elf.root_module);
    elf.linkLibrary(libc);
    elf.linkLibrary(libgloss_libsysbase);
    elf.linkLibrary(libm);
    elf.linkLibrary(libctru);

    elf.linker_script = crtls_dep.path("3dsx.ld"); // -T 3dsx.ld%s

    elf.link_emit_relocs = true; // --emit-relocs
    elf.root_module.strip = false; // can't combine 'strip-all' with 'emit-relocs'
    // TODO: -d: They assign space to common symbols even if a relocatable output file is specified
    elf.link_gc_sections = true; // --gc-sections
    // TODO: --use-blx: The ‘--use-blx’ switch enables the linker to use ARM/Thumb BLX instructions (available on ARMv5t and above) in various situations.

    b.installArtifact(elf);

    // elf -> 3dsx
    const output_3dsx_name = b.fmt("{s}.3dsx", .{elf.name});
    const run_3dsxtool = b.addRunArtifact(tool_3dsxtool);
    run_3dsxtool.addFileArg(elf.getEmittedBin());
    const output_3dsx = run_3dsxtool.addOutputFileArg(output_3dsx_name);

    const output_3dsx_install = b.addInstallFileWithDir(output_3dsx, .bin, output_3dsx_name);
    const output_3dsx_path = b.getInstallPath(.bin, output_3dsx_name);
    b.getInstallStep().dependOn(&output_3dsx_install.step);
    // elf_to_3dsx

    const run_step = std.Build.Step.Run.create(b, b.fmt("run", .{}));
    run_step.addArg("citra");
    run_step.addArg(output_3dsx_path);
    run_step.step.dependOn(b.getInstallStep());
    const run_step_cmdl = b.step("run", "Run the app");
    run_step_cmdl.dependOn(&run_step.step);
}

fn captureStdoutNamed(run: *std.Build.Step.Run, name: []const u8) std.Build.LazyPath {
    std.debug.assert(run.stdio != .inherit);

    std.debug.assert(run.captured_stdout == null);

    const output = run.step.owner.allocator.create(std.Build.Step.Run.Output) catch @panic("OOM");
    output.* = .{
        .prefix = "",
        .basename = name,
        .generated_file = .{ .step = &run.step },
    };
    run.captured_stdout = output;
    return .{ .generated = &output.generated_file };
}

const libgloss_libsysbase_files = &[_][]const u8{
    "_exit.c",
    // "abort.c", // prefer newlib abort
    // "assert.c", // prefer newlib assert
    "build_argv.c",
    "chdir.c",
    "chmod.c",
    "clocks.c",
    "concatenate.c",
    "dirent.c",
    // "environ.c", // prefer newlib environ
    "execve.c",
    "fchmod.c",
    "flock.c",
    "fnmatch.c",
    "fork.c",
    "fpathconf.c",
    "fstat.c",
    "fsync.c",
    "ftruncate.c",
    "getpid.c",
    "getreent.c",
    "gettod.c",
    "handle_manager.c",
    "iosupport.c",
    "isatty.c",
    "kill.c",
    "link.c",
    "lseek.c",
    "lstat.c",
    "malloc_vars.c",
    "mkdir.c",
    "pthread.c",
    "nanosleep.c",
    "open.c",
    "pathconf.c",
    "read.c",
    "readlink.c",
    "realpath.c",
    "rename.c",
    "rmdir.c",
    "sbrk.c",
    "scandir.c",
    "sleep.c",
    "stat.c",
    "statvfs.c",
    "symlink.c",
    "syscall_support.c",
    "times.c",
    "truncate.c",
    "unlink.c",
    "usleep.c",
    "utime.c",
    "wait.c",
    "write.c",
};
const newlib_libm_files = &[_][]const u8{
    "common/acoshl.c",
    "common/acosl.c",
    "common/asinhl.c",
    "common/asinl.c",
    "common/atan2l.c",
    "common/atanhl.c",
    "common/atanl.c",
    "common/cbrtl.c",
    "common/ceill.c",
    "common/copysignl.c",
    "common/cosf.c",
    "common/coshl.c",
    "common/cosl.c",
    "common/erfcl.c",
    "common/erfl.c",
    "common/exp.c",
    "common/exp2.c",
    "common/exp2l.c",
    "common/exp_data.c",
    "common/expl.c",
    "common/expm1l.c",
    "common/fabsl.c",
    "common/fdiml.c",
    "common/floorl.c",
    "common/fmal.c",
    "common/fmaxl.c",
    "common/fminl.c",
    "common/fmodl.c",
    "common/frexpl.c",
    "common/hypotl.c",
    "common/ilogbl.c",
    "common/isgreater.c",
    "common/ldexpl.c",
    "common/lgammal.c",
    "common/llrintl.c",
    "common/llroundl.c",
    "common/log.c",
    "common/log10l.c",
    "common/log1pl.c",
    "common/log2.c",
    "common/log2_data.c",
    "common/log2l.c",
    "common/log_data.c",
    "common/logbl.c",
    "common/logl.c",
    "common/lrintl.c",
    "common/lroundl.c",
    "common/math_err.c",
    "common/math_errf.c",
    "common/modfl.c",
    "common/nanl.c",
    "common/nearbyintl.c",
    "common/nextafterl.c",
    "common/nexttoward.c",
    "common/nexttowardf.c",
    "common/nexttowardl.c",
    "common/pow.c",
    "common/pow_log_data.c",
    "common/powl.c",
    "common/remainderl.c",
    "common/remquol.c",
    "common/rintl.c",
    "common/roundl.c",
    "common/s_cbrt.c",
    "common/s_copysign.c",
    "common/s_exp10.c",
    "common/s_expm1.c",
    "common/s_fdim.c",
    "common/s_finite.c",
    "common/s_fma.c",
    "common/s_fmax.c",
    "common/s_fmin.c",
    "common/s_fpclassify.c",
    "common/s_ilogb.c",
    "common/s_infinity.c",
    "common/s_isinf.c",
    "common/s_isinfd.c",
    "common/s_isnan.c",
    "common/s_isnand.c",
    "common/s_llrint.c",
    "common/s_llround.c",
    "common/s_log1p.c",
    "common/s_log2.c",
    "common/s_logb.c",
    "common/s_lrint.c",
    "common/s_lround.c",
    "common/s_modf.c",
    "common/s_nan.c",
    "common/s_nearbyint.c",
    "common/s_nextafter.c",
    "common/s_pow10.c",
    "common/s_remquo.c",
    "common/s_rint.c",
    "common/s_round.c",
    "common/s_scalbln.c",
    "common/s_scalbn.c",
    "common/s_signbit.c",
    "common/s_trunc.c",
    "common/scalblnl.c",
    "common/scalbnl.c",
    "common/sf_cbrt.c",
    "common/sf_copysign.c",
    "common/sf_exp.c",
    "common/sf_exp10.c",
    "common/sf_exp2.c",
    "common/sf_exp2_data.c",
    "common/sf_expm1.c",
    "common/sf_fdim.c",
    "common/sf_finite.c",
    "common/sf_fma.c",
    "common/sf_fmax.c",
    "common/sf_fmin.c",
    "common/sf_fpclassify.c",
    "common/sf_ilogb.c",
    "common/sf_infinity.c",
    "common/sf_isinf.c",
    "common/sf_isinff.c",
    "common/sf_isnan.c",
    "common/sf_isnanf.c",
    "common/sf_llrint.c",
    "common/sf_llround.c",
    "common/sf_log.c",
    "common/sf_log1p.c",
    "common/sf_log2.c",
    "common/sf_log2_data.c",
    "common/sf_log_data.c",
    "common/sf_logb.c",
    "common/sf_lrint.c",
    "common/sf_lround.c",
    "common/sf_modf.c",
    "common/sf_nan.c",
    "common/sf_nearbyint.c",
    "common/sf_nextafter.c",
    "common/sf_pow.c",
    "common/sf_pow10.c",
    "common/sf_pow_log2_data.c",
    "common/sf_remquo.c",
    "common/sf_rint.c",
    "common/sf_round.c",
    "common/sf_scalbln.c",
    "common/sf_scalbn.c",
    "common/sf_trunc.c",
    "common/sincosf.c",
    "common/sincosf_data.c",
    "common/sinf.c",
    "common/sinhl.c",
    "common/sinl.c",
    "common/sl_finite.c",
    "common/sqrtl.c",
    "common/tanhl.c",
    "common/tanl.c",
    "common/tgammal.c",
    "common/truncl.c",
};
const newlib_libc_files = &[_][]const u8{
    "reent/closer.c",
    "reent/execr.c",
    "reent/fcntlr.c",
    // "reent/fstat64r.c",
    "reent/fstatr.c",
    "reent/getentropyr.c",
    "reent/getreent.c",
    "reent/gettimeofdayr.c",
    "reent/impure.c",
    "reent/isattyr.c",
    // "reent/linkr.c", // defines _dummy_link_syscalls when REENTRANT_SYSCALLS_PROVIDED
    // "reent/lseek64r.c",
    "reent/lseekr.c",
    "reent/mkdirr.c",
    // "reent/open64r.c",
    "reent/openr.c",
    "reent/readr.c",
    "reent/reent.c",
    "reent/renamer.c",
    "reent/sbrkr.c",
    // "reent/signalr.c", // defines _dummy_link_syscalls when REENTRANT_SYSCALLS_PROVIDED
    // "reent/stat64r.c",
    "reent/statr.c",
    "reent/timesr.c",
    "reent/unlinkr.c",
    "reent/writer.c",
    "string/bcmp.c",
    "string/bcopy.c",
    "string/bzero.c",
    "string/explicit_bzero.c",
    "string/ffsl.c",
    "string/ffsll.c",
    "string/fls.c",
    "string/flsl.c",
    "string/flsll.c",
    "string/gnu_basename.c",
    "string/index.c",
    "string/memccpy.c",
    "string/memchr.c",
    "string/memcmp.c",
    "string/memcpy.c",
    "string/memmem.c",
    "string/memmove.c",
    "string/mempcpy.c",
    "string/memrchr.c",
    "string/memset.c",
    "string/rawmemchr.c",
    "string/rindex.c",
    "string/stpcpy.c",
    "string/stpncpy.c",
    "string/strcasecmp.c",
    "string/strcasecmp_l.c",
    "string/strcasestr.c",
    "string/strcat.c",
    "string/strchr.c",
    "string/strchrnul.c",
    "string/strcmp.c",
    "string/strcoll.c",
    "string/strcoll_l.c",
    "string/strcpy.c",
    "string/strcspn.c",
    "string/strdup.c",
    "string/strdup_r.c",
    "string/strerror.c",
    "string/strerror_r.c",
    "string/strlcat.c",
    "string/strlcpy.c",
    "string/strlen.c",
    "string/strlwr.c",
    "string/strncasecmp.c",
    "string/strncasecmp_l.c",
    "string/strncat.c",
    "string/strncmp.c",
    "string/strncpy.c",
    "string/strndup.c",
    "string/strndup_r.c",
    "string/strnlen.c",
    "string/strnstr.c",
    "string/strpbrk.c",
    "string/strrchr.c",
    "string/strsep.c",
    "string/strsignal.c",
    "string/strspn.c",
    "string/strstr.c",
    "string/strtok.c",
    "string/strtok_r.c",
    "string/strupr.c",
    "string/strverscmp.c",
    "string/strxfrm.c",
    "string/strxfrm_l.c",
    "string/swab.c",
    "string/timingsafe_bcmp.c",
    "string/timingsafe_memcmp.c",
    "string/u_strerr.c",
    "string/wcpcpy.c",
    "string/wcpncpy.c",
    "string/wcscasecmp.c",
    "string/wcscasecmp_l.c",
    "string/wcscat.c",
    "string/wcschr.c",
    "string/wcscmp.c",
    "string/wcscoll.c",
    "string/wcscoll_l.c",
    "string/wcscpy.c",
    "string/wcscspn.c",
    "string/wcsdup.c",
    "string/wcslcat.c",
    "string/wcslcpy.c",
    "string/wcslen.c",
    "string/wcsncasecmp.c",
    "string/wcsncasecmp_l.c",
    "string/wcsncat.c",
    "string/wcsncmp.c",
    "string/wcsncpy.c",
    "string/wcsnlen.c",
    "string/wcspbrk.c",
    "string/wcsrchr.c",
    "string/wcsspn.c",
    "string/wcsstr.c",
    "string/wcstok.c",
    "string/wcswidth.c",
    "string/wcsxfrm.c",
    "string/wcsxfrm_l.c",
    "string/wcwidth.c",
    "string/wmemchr.c",
    "string/wmemcmp.c",
    "string/wmemcpy.c",
    "string/wmemmove.c",
    "string/wmempcpy.c",
    "string/wmemset.c",
    "string/xpg_strerror_r.c",
    "stdlib/_Exit.c",
    "stdlib/__adjust.c",
    "stdlib/__atexit.c",
    "stdlib/__call_atexit.c",
    "stdlib/__exp10.c",
    "stdlib/__ten_mu.c",
    "stdlib/_mallocr.c",
    "stdlib/a64l.c",
    "stdlib/abort.c",
    "stdlib/abs.c",
    "stdlib/aligned_alloc.c",
    "stdlib/arc4random.c",
    "stdlib/arc4random_uniform.c",
    "stdlib/assert.c",
    "stdlib/atexit.c",
    "stdlib/atof.c",
    "stdlib/atoff.c",
    "stdlib/atoi.c",
    "stdlib/atol.c",
    "stdlib/atoll.c",
    "stdlib/btowc.c",
    "stdlib/calloc.c",
    "stdlib/callocr.c",
    "stdlib/cfreer.c",
    "stdlib/cxa_atexit.c",
    "stdlib/cxa_finalize.c",
    "stdlib/div.c",
    "stdlib/drand48.c",
    "stdlib/dtoa.c",
    "stdlib/dtoastub.c",
    "stdlib/ecvtbuf.c",
    "stdlib/efgcvt.c",
    "stdlib/environ.c",
    "stdlib/envlock.c",
    "stdlib/eprintf.c",
    "stdlib/erand48.c",
    "stdlib/exit.c",
    "stdlib/freer.c",
    "stdlib/gdtoa-dmisc.c",
    "stdlib/gdtoa-gdtoa.c",
    "stdlib/gdtoa-gethex.c",
    "stdlib/gdtoa-gmisc.c",
    "stdlib/gdtoa-hexnan.c",
    "stdlib/gdtoa-ldtoa.c",
    "stdlib/getenv.c",
    "stdlib/getenv_r.c",
    "stdlib/getopt.c",
    "stdlib/getsubopt.c",
    "stdlib/imaxabs.c",
    "stdlib/imaxdiv.c",
    "stdlib/itoa.c",
    "stdlib/jrand48.c",
    "stdlib/l64a.c",
    "stdlib/labs.c",
    "stdlib/lcong48.c",
    "stdlib/ldiv.c",
    "stdlib/ldtoa.c",
    "stdlib/llabs.c",
    "stdlib/lldiv.c",
    "stdlib/lrand48.c",
    "stdlib/malign.c",
    "stdlib/malignr.c",
    "stdlib/mallinfor.c",
    "stdlib/malloc.c",
    "stdlib/mallocr.c",
    "stdlib/malloptr.c",
    "stdlib/mallstatsr.c",
    "stdlib/mblen.c",
    "stdlib/mblen_r.c",
    "stdlib/mbrlen.c",
    "stdlib/mbrtowc.c",
    "stdlib/mbsinit.c",
    "stdlib/mbsnrtowcs.c",
    "stdlib/mbsrtowcs.c",
    "stdlib/mbstowcs.c",
    "stdlib/mbstowcs_r.c",
    "stdlib/mbtowc.c",
    "stdlib/mbtowc_r.c",
    "stdlib/mlock.c",
    "stdlib/mprec.c",
    "stdlib/mrand48.c",
    "stdlib/msize.c",
    "stdlib/msizer.c",
    "stdlib/mstats.c",
    "stdlib/mtrim.c",
    // "stdlib/nano-mallocr.c", // newlib_nano_formatted_io
    "stdlib/nrand48.c",
    "stdlib/on_exit.c",
    "stdlib/on_exit_args.c",
    "stdlib/putenv.c",
    "stdlib/putenv_r.c",
    "stdlib/pvallocr.c",
    "stdlib/quick_exit.c",
    "stdlib/rand.c",
    "stdlib/rand48.c",
    "stdlib/rand_r.c",
    "stdlib/random.c",
    "stdlib/realloc.c",
    "stdlib/reallocarray.c",
    "stdlib/reallocf.c",
    "stdlib/reallocr.c",
    "stdlib/rpmatch.c",
    "stdlib/sb_charsets.c",
    "stdlib/seed48.c",
    "stdlib/setenv.c",
    "stdlib/setenv_r.c",
    "stdlib/srand48.c",
    "stdlib/strtod.c",
    "stdlib/strtodg.c",
    "stdlib/strtoimax.c",
    "stdlib/strtol.c",
    "stdlib/strtold.c",
    "stdlib/strtoll.c",
    "stdlib/strtoll_r.c",
    "stdlib/strtorx.c",
    "stdlib/strtoul.c",
    "stdlib/strtoull.c",
    "stdlib/strtoull_r.c",
    "stdlib/strtoumax.c",
    "stdlib/system.c",
    "stdlib/threads.c",
    "stdlib/utoa.c",
    "stdlib/valloc.c",
    "stdlib/vallocr.c",
    "stdlib/wcrtomb.c",
    "stdlib/wcsnrtombs.c",
    "stdlib/wcsrtombs.c",
    "stdlib/wcstod.c",
    "stdlib/wcstoimax.c",
    "stdlib/wcstol.c",
    // "stdlib/wcstold.c", // call to undeclared function 'strtold_l'
    "stdlib/wcstoll.c",
    "stdlib/wcstoll_r.c",
    "stdlib/wcstombs.c",
    "stdlib/wcstombs_r.c",
    "stdlib/wcstoul.c",
    "stdlib/wcstoull.c",
    "stdlib/wcstoull_r.c",
    "stdlib/wcstoumax.c",
    "stdlib/wctob.c",
    "stdlib/wctomb.c",
    "stdlib/wctomb_r.c",
    "errno/errno.c",
    "stdio/asiprintf.c",
    "stdio/asniprintf.c",
    "stdio/asnprintf.c",
    "stdio/asprintf.c",
    "stdio/clearerr.c",
    "stdio/clearerr_u.c",
    "stdio/diprintf.c",
    "stdio/dprintf.c",
    "stdio/fclose.c",
    "stdio/fcloseall.c",
    "stdio/fdopen.c",
    "stdio/feof.c",
    "stdio/feof_u.c",
    "stdio/ferror.c",
    "stdio/ferror_u.c",
    "stdio/fflush.c",
    "stdio/fflush_u.c",
    "stdio/fgetc.c",
    "stdio/fgetc_u.c",
    "stdio/fgetpos.c",
    "stdio/fgets.c",
    "stdio/fgets_u.c",
    "stdio/fgetwc.c",
    "stdio/fgetwc_u.c",
    "stdio/fgetws.c",
    "stdio/fgetws_u.c",
    "stdio/fileno.c",
    "stdio/fileno_u.c",
    "stdio/findfp.c",
    "stdio/fiprintf.c",
    "stdio/fiscanf.c",
    "stdio/flags.c",
    "stdio/fmemopen.c",
    "stdio/fopen.c",
    "stdio/fopencookie.c",
    "stdio/fprintf.c",
    "stdio/fpurge.c",
    "stdio/fputc.c",
    "stdio/fputc_u.c",
    "stdio/fputs.c",
    "stdio/fputs_u.c",
    "stdio/fputwc.c",
    "stdio/fputwc_u.c",
    "stdio/fputws.c",
    "stdio/fputws_u.c",
    "stdio/fread.c",
    "stdio/fread_u.c",
    "stdio/freopen.c",
    "stdio/fscanf.c",
    "stdio/fseek.c",
    "stdio/fseeko.c",
    "stdio/fsetlocking.c",
    "stdio/fsetpos.c",
    "stdio/ftell.c",
    "stdio/ftello.c",
    "stdio/funopen.c",
    "stdio/fvwrite.c",
    "stdio/fwalk.c",
    "stdio/fwide.c",
    "stdio/fwprintf.c",
    "stdio/fwrite.c",
    "stdio/fwrite_u.c",
    "stdio/fwscanf.c",
    "stdio/getc.c",
    "stdio/getc_u.c",
    "stdio/getchar.c",
    "stdio/getchar_u.c",
    "stdio/getdelim.c",
    "stdio/getline.c",
    "stdio/gets.c",
    "stdio/getw.c",
    "stdio/getwc.c",
    "stdio/getwc_u.c",
    "stdio/getwchar.c",
    "stdio/getwchar_u.c",
    "stdio/iprintf.c",
    "stdio/iscanf.c",
    "stdio/makebuf.c",
    "stdio/mktemp.c",
    // "stdio/nano-svfprintf.c", // newlib-nano-formatted-io
    // "stdio/nano-svfscanf.c",
    // "stdio/nano-vfprintf.c",
    // "stdio/nano-vfprintf_float.c",
    // "stdio/nano-vfprintf_i.c",
    // "stdio/nano-vfscanf.c",
    // "stdio/nano-vfscanf_float.c",
    // "stdio/nano-vfscanf_i.c",
    "stdio/open_memstream.c",
    "stdio/perror.c",
    "stdio/printf.c",
    "stdio/putc.c",
    "stdio/putc_u.c",
    "stdio/putchar.c",
    "stdio/putchar_u.c",
    "stdio/puts.c",
    "stdio/putw.c",
    "stdio/putwc.c",
    "stdio/putwc_u.c",
    "stdio/putwchar.c",
    "stdio/putwchar_u.c",
    "stdio/refill.c",
    "stdio/remove.c",
    "stdio/rename.c",
    "stdio/rewind.c",
    "stdio/rget.c",
    "stdio/scanf.c",
    "stdio/sccl.c",
    "stdio/setbuf.c",
    "stdio/setbuffer.c",
    "stdio/setlinebuf.c",
    "stdio/setvbuf.c",
    "stdio/sfputs_r.c",
    "stdio/sfputws_r.c",
    "stdio/siprintf.c",
    "stdio/siscanf.c",
    "stdio/sniprintf.c",
    "stdio/snprintf.c",
    "stdio/sprint_r.c",
    "stdio/sprintf.c",
    "stdio/sscanf.c",
    "stdio/ssprint_r.c",
    "stdio/ssputs_r.c",
    "stdio/ssputws_r.c",
    "stdio/sswprint_r.c",
    "stdio/stdio.c",
    "stdio/stdio_ext.c",
    "stdio/svfiprintf.c",
    "stdio/svfiscanf.c",
    "stdio/svfiwprintf.c",
    "stdio/svfiwscanf.c",
    "stdio/svfprintf.c",
    "stdio/svfscanf.c",
    "stdio/svfwprintf.c",
    "stdio/svfwscanf.c",
    "stdio/swprint_r.c",
    "stdio/swprintf.c",
    "stdio/swscanf.c",
    "stdio/tmpfile.c",
    "stdio/tmpnam.c",
    "stdio/ungetc.c",
    "stdio/ungetwc.c",
    "stdio/vasiprintf.c",
    "stdio/vasniprintf.c",
    "stdio/vasnprintf.c",
    "stdio/vasprintf.c",
    "stdio/vdiprintf.c",
    "stdio/vdprintf.c",
    "stdio/vfiprintf.c",
    "stdio/vfiscanf.c",
    "stdio/vfiwprintf.c",
    "stdio/vfiwscanf.c",
    "stdio/vfprintf.c",
    "stdio/vfscanf.c",
    "stdio/vfwprintf.c",
    "stdio/vfwscanf.c",
    "stdio/viprintf.c",
    "stdio/viscanf.c",
    "stdio/vprintf.c",
    "stdio/vscanf.c",
    "stdio/vsiprintf.c",
    "stdio/vsiscanf.c",
    "stdio/vsniprintf.c",
    "stdio/vsnprintf.c",
    "stdio/vsprintf.c",
    "stdio/vsscanf.c",
    "stdio/vswprintf.c",
    "stdio/vswscanf.c",
    "stdio/vwprintf.c",
    "stdio/vwscanf.c",
    "stdio/wbuf.c",
    "stdio/wbufw.c",
    "stdio/wprintf.c",
    "stdio/wscanf.c",
    "stdio/wsetup.c",
    "misc/__dprintf.c",
    "misc/ffs.c",
    "misc/fini.c",
    "misc/init.c",
    "misc/lock.c",
    "misc/unctrl.c",
    "signal/psignal.c",
    "signal/raise.c",
    "signal/signal.c",
    "signal/sig2str.c",
    "locale/locale.c",
    "locale/localeconv.c",
    "ctype/ctype_.c",
    "ctype/isalnum.c",
    "ctype/isalpha.c",
    "ctype/iscntrl.c",
    "ctype/isdigit.c",
    "ctype/islower.c",
    "ctype/isupper.c",
    "ctype/isprint.c",
    "ctype/ispunct.c",
    "ctype/isspace.c",
    "ctype/isxdigit.c",
    "ctype/tolower.c",
    "ctype/toupper.c",
    "search/bsearch.c",
    "search/ndbm.c",
    "search/qsort.c",
};

const libctru_s_files = &[_]struct { []const u8, []const u8 }{
    // cd ~/.cache/zig/p/1220500038392c32bc26f2a74ce2d3a0aa125a9f94d879006b0a5d3945f7f91890f5/libctru/source/
    // ls **/*.s | copy
    .{ "svc.s", "svc.S" },
    .{ "system/readtp.s", "readtp.S" },
    .{ "system/stack_adjust.s", "stack_adjust.S" },
};
const libctru_files = &[_][]const u8{
    // cd ~/.cache/zig/p/1220500038392c32bc26f2a74ce2d3a0aa125a9f94d879006b0a5d3945f7f91890f5/libctru/source/
    // ls **/*.{c,cpp} | copy
    "3dslink.c",
    "allocator/linear.cpp",
    "allocator/mappable.c",
    "allocator/mem_pool.cpp",
    "allocator/vram.cpp",
    "applets/error.c",
    "applets/miiselector.c",
    "applets/swkbd.c",
    "archive_dev.c",
    "console.c",
    "env.c",
    "errf.c",
    "font.c",
    "gdbhio.c",
    "gdbhio_dev.c",
    "gfx.c",
    "gpu/gpu.c",
    "gpu/gx.c",
    "gpu/gxqueue.c",
    "gpu/shaderProgram.c",
    "gpu/shbin.c",
    "ndsp/ndsp-channel.c",
    "ndsp/ndsp-filter.c",
    "ndsp/ndsp.c",
    "os-versionbin.c",
    "os.c",
    "path_buf.c",
    "romfs_dev.c",
    "services/ac.c",
    "services/am.c",
    "services/ampxi.c",
    "services/apt.c",
    "services/boss.c",
    "services/cam.c",
    "services/cdcchk.c",
    "services/cfgnor.c",
    "services/cfgu.c",
    "services/csnd.c",
    "services/dsp.c",
    "services/frd.c",
    "services/fs.c",
    "services/fspxi.c",
    "services/fsreg.c",
    "services/gspgpu.c",
    "services/gsplcd.c",
    "services/hid.c",
    "services/httpc.c",
    "services/ir.c",
    "services/irrst.c",
    "services/loader.c",
    "services/mcuhwc.c",
    "services/mic.c",
    "services/mvd.c",
    "services/ndm.c",
    "services/news.c",
    "services/nfc.c",
    "services/nim.c",
    "services/ns.c",
    "services/nwmext.c",
    "services/pmapp.c",
    "services/pmdbg.c",
    "services/ps.c",
    "services/ptmgets.c",
    "services/ptmsets.c",
    "services/ptmsysm.c",
    "services/ptmu.c",
    "services/pxidev.c",
    "services/pxipm.c",
    "services/qtm.c",
    "services/soc/soc_accept.c",
    "services/soc/soc_addglobalsocket.c",
    "services/soc/soc_bind.c",
    "services/soc/soc_closesocket.c",
    "services/soc/soc_closesockets.c",
    "services/soc/soc_common.c",
    "services/soc/soc_connect.c",
    "services/soc/soc_fcntl.c",
    "services/soc/soc_gai_strerror.c",
    "services/soc/soc_getaddrinfo.c",
    "services/soc/soc_gethostbyaddr.c",
    "services/soc/soc_gethostbyname.c",
    "services/soc/soc_gethostid.c",
    "services/soc/soc_gethostname.c",
    "services/soc/soc_getipinfo.c",
    "services/soc/soc_getnameinfo.c",
    "services/soc/soc_getnetworkopt.c",
    "services/soc/soc_getpeername.c",
    "services/soc/soc_getsockname.c",
    "services/soc/soc_getsockopt.c",
    "services/soc/soc_herror.c",
    "services/soc/soc_hstrerror.c",
    "services/soc/soc_inet_addr.c",
    "services/soc/soc_inet_aton.c",
    "services/soc/soc_inet_ntoa.c",
    "services/soc/soc_inet_ntop.c",
    "services/soc/soc_inet_pton.c",
    "services/soc/soc_init.c",
    "services/soc/soc_ioctl.c",
    "services/soc/soc_listen.c",
    "services/soc/soc_poll.c",
    "services/soc/soc_recv.c",
    "services/soc/soc_recvfrom.c",
    "services/soc/soc_select.c",
    "services/soc/soc_send.c",
    "services/soc/soc_sendto.c",
    "services/soc/soc_setsockopt.c",
    "services/soc/soc_shutdown.c",
    "services/soc/soc_shutdownsockets.c",
    "services/soc/soc_sockatmark.c",
    "services/soc/soc_socket.c",
    "services/srvpm.c",
    "services/sslc.c",
    "services/uds.c",
    "services/y2r.c",
    "srv.c",
    "synchronization.c",
    "system/allocateHeaps.c",
    "system/appExit.c",
    "system/appInit.c",
    "system/ctru_exit.c",
    "system/ctru_init.c",
    "system/initArgv.c",
    "system/syscalls.c",
    "thread.c",
    "util/decompress/decompress.c",
    "util/rbtree/rbtree_clear.c",
    "util/rbtree/rbtree_empty.c",
    "util/rbtree/rbtree_find.c",
    "util/rbtree/rbtree_init.c",
    "util/rbtree/rbtree_insert.c",
    "util/rbtree/rbtree_iterator.c",
    "util/rbtree/rbtree_minmax.c",
    "util/rbtree/rbtree_remove.c",
    "util/rbtree/rbtree_rotate.c",
    "util/rbtree/rbtree_size.c",
    "util/utf/decode_utf16.c",
    "util/utf/decode_utf8.c",
    "util/utf/encode_utf16.c",
    "util/utf/encode_utf8.c",
    "util/utf/utf16_to_utf32.c",
    "util/utf/utf16_to_utf8.c",
    "util/utf/utf32_to_utf16.c",
    "util/utf/utf32_to_utf8.c",
    "util/utf/utf8_to_utf16.c",
    "util/utf/utf8_to_utf32.c",
};
