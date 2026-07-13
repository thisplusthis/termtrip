const std = @import("std");

// The Zig build system runs this function to figure out what to build.
// (This targets the Zig 0.16 build API, where an executable is defined by a
// *module* that bundles the root source file, target, optimize mode and libc.)
pub fn build(b: *std.Build) void {
    // `-Dtarget=` / `-Doptimize=` come from these; defaults = host, Debug.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "autom",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // We call libc functions (write/read/ioctl/nanosleep/termios), so
            // we must link the C library.
            .link_libc = true,
        }),
    });

    // `zig build` → puts the binary in zig-out/bin/autom.
    b.installArtifact(exe);

    // `zig build run` → build then launch it.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run the screensaver");
    run_step.dependOn(&run_cmd.step);
}
