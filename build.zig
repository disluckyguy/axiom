const std = @import("std");

const Scanner = @import("zig-wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = Scanner.create(b, .{});

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addCustomProtocol("protocols/wlr-layer-shell-unstable-v1.xml");
    scanner.addCustomProtocol("protocols/wlr-output-power-management-unstable-v1.xml");

    // Some of these versions may be out of date with what wlroots implements.
    // This is not a problem in practice though as long as axiom successfully compiles.
    // These versions control Zig code generation and have no effect on anything internal
    // to wlroots. Therefore, the only thing that can happen due to a version being too
    // old is that axiom fails to compile.
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_data_device_manager", 3);
    scanner.generate("xdg_wm_base", 2);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    const xkbcommon = b.dependency("zig-xkbcommon", .{}).module("xkbcommon");
    const pixman = b.dependency("zig-pixman", .{}).module("pixman");
    const wlroots = b.dependency("zig-wlroots", .{}).module("wlroots");

    wlroots.addImport("wayland", wayland);
    wlroots.addImport("xkbcommon", xkbcommon);
    wlroots.addImport("pixman", pixman);
    wlroots.addImport("wlroots", wlroots);

    scanner.generate("zwlr_layer_shell_v1", 4);
    scanner.generate("zwlr_output_power_manager_v1", 1);

    // We need to ensure the wlroots include path obtained from pkg-config is
    // exposed to the wlroots module for @cImport() to work. This seems to be
    // the best way to do so with the current std.Build API.
    wlroots.resolved_target = target;
    wlroots.linkSystemLibrary("wlroots-0.18", .{});

    const axiom = b.addExecutable(.{
        .name = "axiom",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    axiom.linkLibC();

    axiom.root_module.addImport("wayland", wayland);
    axiom.root_module.addImport("xkbcommon", xkbcommon);
    axiom.root_module.addImport("wlroots", wlroots);
    axiom.linkSystemLibrary("libinput");
    axiom.linkSystemLibrary("wayland-server");
    axiom.linkSystemLibrary("xkbcommon");
    axiom.linkSystemLibrary("pixman-1");

    // TODO: remove when https://github.com/ziglang/zig/issues/131 is implemented
    scanner.addCSource(axiom);

    b.installArtifact(axiom);

    const axiom_check = b.addExecutable(.{
        .name = "foo",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Any other code to define dependencies would
    // probably be here.

    axiom_check.linkLibC();

    axiom_check.root_module.addImport("wayland", wayland);
    axiom_check.root_module.addImport("xkbcommon", xkbcommon);
    axiom_check.root_module.addImport("wlroots", wlroots);
    axiom_check.linkSystemLibrary("libinput");
    axiom_check.linkSystemLibrary("wayland-server");
    axiom_check.linkSystemLibrary("xkbcommon");
    axiom_check.linkSystemLibrary("pixman-1");

    // These two lines you might want to copy
    // (make sure to rename 'exe_check')
    const check = b.step("check", "Check if foo compiles");
    check.dependOn(&axiom_check.step);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(axiom);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
