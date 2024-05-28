const std = @import("std");
const zig3ds = @import("zig3ds");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    const zig3ds_dep = b.dependency("zig3ds", .{ .optimize = optimize });
    const build_helper = zig3ds.T3dsBuildHelper.find(zig3ds_dep, "build_helper");
    const libc_includer = zig3ds.CIncluder.find(zig3ds_dep, "libc");
    const libctru_includer = zig3ds.CIncluder.find(zig3ds_dep, "libctru");

    const elf = b.addExecutable(.{
        .name = "sample",
        .target = build_helper.target,
        .optimize = optimize,
    });
    build_helper.link(elf);

    elf.addCSourceFile(.{
        .file = .{ .path = "src/main.c" },
        .flags = &.{},
    });

    libc_includer.applyTo(&elf.root_module);
    elf.linkLibrary(zig3ds_dep.artifact("libc"));
    elf.linkLibrary(zig3ds_dep.artifact("libgloss_libsysbase"));
    elf.linkLibrary(zig3ds_dep.artifact("libm"));
    libctru_includer.applyTo(&elf.root_module);
    elf.linkLibrary(zig3ds_dep.artifact("libctru"));

    // elf -> 3dsx
    const output_3dsx = build_helper.to3dsx(elf);

    const output_3dsx_install = b.addInstallFileWithDir(output_3dsx, .bin, "sample.3dsx");
    const output_3dsx_path = b.getInstallPath(.bin, "sample.3dsx");
    b.getInstallStep().dependOn(&output_3dsx_install.step);

    // elf_to_3dsx
    const run_step = std.Build.Step.Run.create(b, b.fmt("citra run", .{}));
    run_step.addArg("citra");
    run_step.addArg(output_3dsx_path);
    run_step.step.dependOn(b.getInstallStep());
    const run_step_cmdl = b.step("run", "Run in citra");
    run_step_cmdl.dependOn(&run_step.step);
}
