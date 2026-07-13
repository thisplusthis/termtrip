//! main.zig — the entry point and animation loop.
//!
//! This file is deliberately thin: it wires the pieces together and runs the
//! per-frame loop. All the interesting logic lives in the `matrix` module
//! (`Terminal` for talking to the terminal, `Matrix` for the rain itself).

const std = @import("std");
const Io = std.Io;

// Import the module the build script exposes under the name "matrix".
const matrix = @import("matrix");

// How long to pause between frames. 45 ms ≈ 22 frames per second — smooth to
// the eye without spinning the CPU.
const frame_delay = Io.Duration.fromMilliseconds(45);

// Zig 0.16's entry point receives an `Init` value that hands us the process's
// I/O interface, an arena allocator, and command-line arguments. Returning `!void`
// means any error we don't handle is reported by the runtime for us.
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // The arena allocator frees everything at once when the process exits, which
    // is perfect for a program whose allocations all live for the whole run.
    const arena = init.arena.allocator();

    // We render each frame into this buffer and flush it to the terminal in a
    // single write. One write per frame is what keeps the animation flicker-free.
    // 4 MiB comfortably holds a full-color frame for any realistic terminal size.
    const frame_buffer = try arena.alloc(u8, 1 << 22);
    var stdout: Io.File.Writer = .init(.stdout(), io, frame_buffer);
    const w = &stdout.interface;

    // Enter full-screen raw mode. `defer` guarantees the terminal is restored
    // on *every* exit path — normal return, an error, or a caught quit — so the
    // user never ends up staring at a broken shell.
    var term = try matrix.Terminal.init(io, w);
    defer term.deinit();

    // Seed the generator from the wall-clock time so no two runs look alike.
    const now = Io.Timestamp.now(io, .real);
    const seed: u64 = @truncate(@as(u96, @bitCast(now.nanoseconds)));

    var rain = try matrix.Matrix.init(arena, seed, term.size.cols, term.size.rows);
    defer rain.deinit();

    // The animation loop. Each pass draws exactly one frame.
    while (true) {
        // 1. Quit the instant the user presses `q` (or Ctrl-C).
        if (term.pollQuit()) break;

        // 2. Adapt live if the terminal window was resized.
        const size = term.querySize();
        if (size.cols != rain.cols or size.rows != rain.rows) {
            try rain.resize(size.cols, size.rows);
        }

        // 3. Step the simulation forward and paint it in one flush.
        rain.update();
        try rain.draw(w);
        try w.flush();

        // 4. Breathe. If the sleep is cancelled, treat it as a request to stop.
        io.sleep(frame_delay, .awake) catch break;
    }
}
