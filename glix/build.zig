const std = @import("std");

pub fn build(b: *std.Build) void {
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
        .name = "glix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // termkit talks to the terminal via POSIX (termios) and ioctl,
            // which on macOS must go through the system C library.
            .link_libc = true,
            .imports = &.{
                .{ .name = "termkit", .module = termkit },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run glix");
    run_step.dependOn(&run_cmd.step);
}
