const std = @import("std");

// Root workspace build script. Each screensaver below is its own
// self-contained Zig package (own build.zig / build.zig.zon) and can still be
// built the old way — `cd <project> && zig build run`. This file just wires
// all of them in as dependencies so a single one can be targeted from the
// repo root without `cd`-ing in first:
//
//   zig build glix               # build only glix, into ./zig-out/bin
//   zig build run-glix            # build and run only glix
//
// There's deliberately no "build everything" default — as more screensavers
// land here, a bare `zig build` shouldn't get slower with each one.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const Project = struct { name: []const u8, description: []const u8 };
    const projects = [_]Project{
        .{ .name = "glix", .description = "glitch-art Perlin noise flow field" },
        .{ .name = "matrix", .description = "Matrix-style digital rain" },
        .{ .name = "autom", .description = "cyclic cellular automaton" },
        .{ .name = "cpk", .description = "endlessly diffusing color grid" },
    };

    for (projects) |project| {
        const dep = b.dependency(project.name, .{ .target = target, .optimize = optimize });
        const exe = dep.artifact(project.name);

        // A dedicated install step for just this one executable, so
        // `zig build <name>` only builds *that* project — not wired into the
        // default step, so a bare `zig build` builds nothing (see above).
        const install = b.addInstallArtifact(exe, .{});

        const build_step = b.step(project.name, b.fmt("Build {s} ({s})", .{ project.name, project.description }));
        build_step.dependOn(&install.step);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(&install.step);
        if (b.args) |args| run_cmd.addArgs(args);

        const run_step = b.step(b.fmt("run-{s}", .{project.name}), b.fmt("Run {s} ({s})", .{ project.name, project.description }));
        run_step.dependOn(&run_cmd.step);
    }
}
