const std = @import("std");
const zig3ds = @import("zig3ds");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    const zig3ds_dep = b.dependency("zig3ds", .{ .optimize = optimize });
    const build_helper = zig3ds.T3dsBuildHelper.find(zig3ds_dep, "build_helper");
    const libc_includer = zig3ds.CIncluder.find(zig3ds_dep, "c");
    const libctru_includer = zig3ds.CIncluder.find(zig3ds_dep, "ctru");

    const elf = b.addExecutable(.{
        .name = "sample",
        .target = build_helper.target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    build_helper.link(elf);

    libc_includer.applyTo(&elf.root_module);
    elf.linkLibrary(zig3ds_dep.artifact("c"));
    elf.linkLibrary(zig3ds_dep.artifact("m"));
    libctru_includer.applyTo(&elf.root_module);
    elf.linkLibrary(zig3ds_dep.artifact("ctru"));

    // elf -> 3dsx
    const output_3dsx = build_helper.to3dsx(elf);

    const output_3dsx_install = b.addInstallFileWithDir(output_3dsx, .bin, "sample.3dsx");
    const output_3dsx_path = b.getInstallPath(.bin, "sample.3dsx");
    b.getInstallStep().dependOn(&output_3dsx_install.step);

    const run_step = std.Build.Step.Run.create(b, b.fmt("citra run", .{}));
    run_step.addArg("citra");
    run_step.addArg(output_3dsx_path);
    run_step.step.dependOn(b.getInstallStep());
    const run_step_cmdl = b.step("run", "Run in citra");
    run_step_cmdl.dependOn(&run_step.step);
}
