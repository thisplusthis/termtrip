const std = @import("std");
const Io = std.Io;
const cpk = @import("cpk");

pub fn main(init: std.process.Init) !void {
    // All I/O (reading/writing files, stdout, etc.) flows through this `Io` instance.
    const io = init.io;
    // The arena lives for the whole program and is freed all at once when
    // we exit, which is all we need for the one grid of cells we allocate.
    const allocator = init.arena.allocator();

    // Stdout writes are buffered for efficiency, so we give it some scratch
    // space to work with. A full-screen grid can print a lot of escape
    // codes per frame, so we use a bigger buffer than a single line would need.
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    // Fill the whole terminal window, edge to edge.
    const size = cpk.terminalSize(io);
    const width = @max(1, size.columns);
    const height = @max(1, size.rows);

    // Runs until 'q' (or Ctrl+C) is pressed.
    try cpk.animateColorGrid(stdout_writer, io, allocator, width, height);
}
