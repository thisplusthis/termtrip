const std = @import("std");

// The Zig build system runs this function to figure out what to build.
// (This targets the Zig 0.16 build API, where an executable is defined by a
// *module* that bundles the root source file, target, optimize mode and libc.)
pub fn build(b: *std.Build) void {
    // `-Dtarget=` / `-Doptimize=` come from these; defaults = host, Debug.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `termkit` is the terminal-takeover code (raw mode, winsize, quit
    // polling) shared by every screensaver in this repo — see
    // ../shared/termkit. It's not a published package, just a source
    // directory, so it's wired in directly as a module rather than through
    // the package manager.
    const termkit = b.createModule(.{
        .root_source_file = b.path("../shared/termkit/src/root.zig"),
        .target = target,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "autom",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // termkit talks to the terminal via POSIX (termios) and ioctl,
            // and this file's `selftest` writes straight to a libc fd, so we
            // must link the C library.
            .link_libc = true,
            .imports = &.{
                .{ .name = "termkit", .module = termkit },
            },
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
