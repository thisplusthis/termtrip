//! autom — a terminal screensaver built from a *cyclic cellular automaton*
//! rendered in a bright RGB spectrum with a chunky, 8-bit pixel look.
//!
//! ── What is this file? ────────────────────────────────────────────────────
//! It's a single Zig program. Run it in a terminal and it takes over the
//! screen, drawing swirling waves of colour that organise themselves out of
//! random noise. Press `q` (or Esc / Ctrl-C) to quit.
//!
//! ── Teaching notes (read me if you're new to Zig) ─────────────────────────
//! Zig is a low-level language with no hidden control flow and no garbage
//! collector. That means WE are responsible for talking to the operating
//! system and for freeing every byte we allocate. To keep a terminal program
//! honest we have to:
//!   1. Put the terminal into "raw mode" so keystrokes reach us instantly
//!      (no waiting for Enter) and aren't echoed back.
//!   2. Draw using ANSI escape codes — little text commands like "\x1b[H"
//!      that move the cursor and set colours.
//!   3. Carefully restore the terminal when we leave, even if we're killed.
//!
//! This build targets Zig 0.16. Raw mode, window-size queries, and quit
//! detection all go through `termkit`, the terminal-handling module shared by
//! every screensaver in this repo (see ../shared/termkit) — this file only
//! deals with the automaton itself and the ANSI colour codes that draw it.

const std = @import("std");
const Io = std.Io;
const termkit = @import("termkit");

// `std.c` is Zig's binding layer for the C standard library, needed here only
// for the two headless debug writes in `selftest` (see below).
const c = std.c;

// ── Tunable knobs ───────────────────────────────────────────────────────────
// These `const`s are the whole personality of the screensaver. Change them and
// rebuild to get a different feel. Grouping them here (instead of scattering
// magic numbers through the code) is a habit worth forming.

/// How many distinct "states" a cell can be in. In a cyclic automaton the
/// states form a ring: 0 → 1 → 2 → … → N-1 → 0. We map each state onto a hue
/// around the colour wheel, so more states = a smoother rainbow but slower to
/// organise into spirals. 16 is a nice, vivid, retro sweet spot.
const N_STATES: u8 = 16;

/// Which cells count as a cell's "neighbours". This is a comptime constant, so
/// the choice is baked in at build time and the unused branch in `step()` costs
/// nothing.
///
///   .von_neumann → the 4 orthogonal cells (N, S, E, W). Fewer neighbours means
///                  waves march along the axes, giving blocky, crystalline,
///                  diamond-shaped fronts — a very "pixel-art / 8-bit" feel.
///   .moore       → all 8 surrounding cells (adds the diagonals). Rounder,
///                  smoother spiral arms.
const Neighborhood = enum { von_neumann, moore };
const NEIGHBORHOOD: Neighborhood = .von_neumann;

/// The "cyclic CA" rule: a cell in state `s` looks at its neighbours; if at
/// least THRESHOLD of them are in the *next* state `(s+1) mod N`, the cell
/// advances to that next state. Threshold 1 keeps the field lively and reliably
/// grows the rotating cores that make this pattern mesmerising.
const THRESHOLD: u32 = 1;

/// Nanoseconds to sleep between frames. 70ms ≈ 14 frames per second — smooth
/// enough to feel alive, slow enough to sip CPU. (1 ms = 1_000_000 ns.)
const FRAME_NS: u64 = 70 * 1_000_000;

/// Every few seconds we sprinkle a handful of random cells back into the field.
/// Left alone, a cyclic automaton can settle into a calm rotating steady state;
/// these little "sparks" keep new waves being born so the screensaver never
/// goes stale. Measured in frames.
const SPRINKLE_EVERY: u64 = 200;
const SPRINKLE_COUNT: usize = 20;

/// A tiny RGB colour. `u8` fields (0–255 each) match how terminals expect
/// 24-bit "truecolor" values.
const Rgb = struct { r: u8, g: u8, b: u8 };

// ─────────────────────────────────────────────────────────────────────────────
// Colour: turn a state number into a bright spectrum colour.
// ─────────────────────────────────────────────────────────────────────────────

/// Convert HSV (hue, saturation, value) to RGB.
///
/// Why HSV? Because "walk around the rainbow" is trivial in HSV — you just
/// sweep the hue from 0 to 360 degrees while keeping saturation and value
/// pinned at maximum. That's exactly the bright, punchy spectrum we want.
/// Doing the same sweep directly in RGB would be a mess of special cases.
///
/// `h` is in degrees [0,360); `s` and `v` are in [0,1].
fn hsvToRgb(h: f32, s: f32, v: f32) Rgb {
    // The hue circle is split into six 60° sectors. `hp` says which sector
    // we're in (0–5) and how far through it we are.
    const hp = h / 60.0;
    const sector: f32 = @floor(hp);
    const f = hp - sector; // fractional position within the sector

    // These three are the building blocks of the standard HSV→RGB formula.
    const p = v * (1.0 - s);
    const q = v * (1.0 - s * f);
    const t = v * (1.0 - s * (1.0 - f));

    // Pick which of v/p/q/t goes to each channel based on the sector.
    var rf: f32 = 0;
    var gf: f32 = 0;
    var bf: f32 = 0;
    switch (@as(u32, @intFromFloat(sector)) % 6) {
        0 => { rf = v; gf = t; bf = p; },
        1 => { rf = q; gf = v; bf = p; },
        2 => { rf = p; gf = v; bf = t; },
        3 => { rf = p; gf = q; bf = v; },
        4 => { rf = t; gf = p; bf = v; },
        else => { rf = v; gf = p; bf = q; },
    }

    // Scale the 0–1 floats up to 0–255 bytes. `@intFromFloat` truncates, so we
    // add 0.5 first to round to nearest — sharper colours.
    return .{
        .r = @intFromFloat(rf * 255.0 + 0.5),
        .g = @intFromFloat(gf * 255.0 + 0.5),
        .b = @intFromFloat(bf * 255.0 + 0.5),
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Out: a hand-rolled output buffer.
// ─────────────────────────────────────────────────────────────────────────────
//
// Writing to the terminal one tiny piece at a time (one `write` syscall per
// colour code) would be painfully slow — the screen would tear and flicker.
// Instead we assemble the ENTIRE frame into one big byte buffer and hand it to
// the OS in a single `write`. This struct is that buffer plus a cursor (`len`)
// marking how much we've filled. We size the buffer generously up front so
// these appends never overflow (see Board.render for the capacity maths).

const Out = struct {
    buf: []u8,
    len: usize = 0,

    /// Append a slice of bytes. `@memcpy` copies `s.len` bytes into the buffer
    /// starting at our current cursor, then we advance the cursor.
    fn put(self: *Out, s: []const u8) void {
        @memcpy(self.buf[self.len..][0..s.len], s);
        self.len += s.len;
    }

    /// Append a single byte (handy for separators like ';').
    fn putByte(self: *Out, b: u8) void {
        self.buf[self.len] = b;
        self.len += 1;
    }

    /// Append a small unsigned integer as decimal ASCII (e.g. 255 → "255").
    /// We build the digits back-to-front in a scratch array, then copy them in
    /// the right order. Writing this by hand avoids depending on the churny
    /// std formatting API and is plenty fast.
    fn putUint(self: *Out, value: u32) void {
        var tmp: [10]u8 = undefined;
        var n = value;
        var i: usize = tmp.len;
        if (n == 0) {
            i -= 1;
            tmp[i] = '0';
        } else {
            while (n > 0) {
                i -= 1;
                tmp[i] = '0' + @as(u8, @intCast(n % 10));
                n /= 10;
            }
        }
        self.put(tmp[i..]);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Board: the cellular automaton itself.
// ─────────────────────────────────────────────────────────────────────────────
//
// A cellular automaton is a grid of cells that all update at once according to
// a simple local rule. Ours is a *cyclic* automaton (invented by David
// Griffeath). The magic is that dead-simple rule + random start reliably
// self-organises into spiralling waves — emergent complexity from nothing.
//
// ── The half-block rendering trick ──────────────────────────────────────────
// Terminal character cells are about twice as tall as they are wide. To get
// square-ish "pixels" and double our vertical resolution, we print the Unicode
// upper-half-block glyph "▀". Its FOREGROUND colour fills the top half of the
// cell and its BACKGROUND colour fills the bottom half. So each character on
// screen shows TWO stacked pixels. That's why the pixel grid is `cols` wide but
// `rows * 2` tall.

const Board = struct {
    alloc: std.mem.Allocator,

    // Pixel-grid dimensions.
    width: usize, // = terminal columns
    height: usize, // = terminal rows * 2

    // Character-cell dimensions (what we actually query from the terminal).
    cols: u16,
    rows: u16,

    // Two grids of cell states. Cellular automata must compute the whole next
    // generation from the current one *without* letting early updates affect
    // later ones — so we read from `cur` and write into `next`, then swap. This
    // is the classic "double buffering" pattern.
    cur: []u8,
    next: []u8,

    // The assembled-frame byte buffer (see Out above).
    outbuf: []u8,

    // state → colour lookup, computed once at startup.
    palette: [N_STATES]Rgb,

    // Our random number generator and a frame counter for timed sprinkling.
    rng: std.Random,
    frame: u64 = 0,

    /// Allocate all the buffers for a given terminal size and paint the initial
    /// random noise. Returns a ready-to-run Board.
    fn init(alloc: std.mem.Allocator, cols: u16, rows: u16, rng: std.Random) !Board {
        const width: usize = cols;
        const height: usize = @as(usize, rows) * 2; // two pixels per character row

        const cur = try alloc.alloc(u8, width * height);
        const next = try alloc.alloc(u8, width * height);

        // Worst-case bytes we might emit for one frame:
        //   per cell: fg code (≤19) + bg code (≤19) + glyph (3) = 41
        //   per row : a cursor-move like "\x1b[123;1H"          ≈ 10
        //   plus a little slack for the home + reset sequences.
        const capacity = width * height * 41 + @as(usize, rows) * 10 + 64;
        const outbuf = try alloc.alloc(u8, capacity);

        var board = Board{
            .alloc = alloc,
            .width = width,
            .height = height,
            .cols = cols,
            .rows = rows,
            .cur = cur,
            .next = next,
            .outbuf = outbuf,
            .palette = undefined,
            .rng = rng,
        };

        board.buildPalette();
        board.seed();
        return board;
    }

    /// Free everything we allocated. Zig has no GC, so this must be called
    /// (we use `defer board.deinit()` at the call site to guarantee it).
    fn deinit(self: *Board) void {
        self.alloc.free(self.cur);
        self.alloc.free(self.next);
        self.alloc.free(self.outbuf);
    }

    /// Precompute the state→colour table: evenly space N_STATES hues around the
    /// full 360° colour wheel at maximum saturation and brightness.
    fn buildPalette(self: *Board) void {
        var i: usize = 0;
        while (i < N_STATES) : (i += 1) {
            const hue = @as(f32, @floatFromInt(i)) / @as(f32, N_STATES) * 360.0;
            self.palette[i] = hsvToRgb(hue, 1.0, 1.0);
        }
    }

    /// Fill the grid with uniformly random states — the primordial soup the
    /// spirals will crystallise out of.
    fn seed(self: *Board) void {
        for (self.cur) |*cell| {
            // intRangeLessThan(T, lo, hi) → a value in [lo, hi).
            cell.* = self.rng.intRangeLessThan(u8, 0, N_STATES);
        }
    }

    /// Scatter a few random cells to keep the pattern regenerating forever.
    /// Von Neumann spirals in particular love to crystallise into a calm
    /// rotating steady state; these sparks seed fresh wavefronts so the art
    /// never looks frozen. We scale the count with the grid so a huge screen
    /// gets proportionally more (but always at least SPRINKLE_COUNT).
    fn sprinkle(self: *Board) void {
        const n = @max(SPRINKLE_COUNT, self.cur.len / 300);
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const idx = self.rng.uintLessThan(usize, self.cur.len);
            self.cur[idx] = self.rng.intRangeLessThan(u8, 0, N_STATES);
        }
    }

    /// Advance the automaton by one generation.
    ///
    /// For every cell we count how many of its neighbours (see NEIGHBORHOOD)
    /// are already in the state we'd advance *to*. If that count meets
    /// THRESHOLD, the cell moves forward one step around the colour ring;
    /// otherwise it waits. The grid wraps around at the edges (a torus), so
    /// waves flow off one side and back on the other with no seams — ideal for
    /// a screensaver.
    fn step(self: *Board) void {
        const w = self.width;
        const h = self.height;

        var y: usize = 0;
        while (y < h) : (y += 1) {
            // Precompute the wrapped row indices above and below this row.
            const y_up = if (y == 0) h - 1 else y - 1;
            const y_dn = if (y == h - 1) 0 else y + 1;

            var x: usize = 0;
            while (x < w) : (x += 1) {
                const s = self.cur[y * w + x];
                // The state this cell is "hungry" for. `% N_STATES` closes the
                // ring so state N-1 advances back to 0.
                const want: u8 = (s + 1) % N_STATES;

                const x_lf = if (x == 0) w - 1 else x - 1;
                const x_rt = if (x == w - 1) 0 else x + 1;

                // Tally neighbours in the wanted state. The 4 orthogonal cells
                // (up/down/left/right) are always counted; the 4 diagonals are
                // added only for the Moore neighbourhood. Because NEIGHBORHOOD
                // is comptime-known, the `if` below is resolved at build time —
                // the von Neumann build simply never contains the diagonal
                // reads.
                var count: u32 = 0;
                if (self.cur[y_up * w + x] == want) count += 1; // north
                if (self.cur[y_dn * w + x] == want) count += 1; // south
                if (self.cur[y * w + x_lf] == want) count += 1; // west
                if (self.cur[y * w + x_rt] == want) count += 1; // east
                if (NEIGHBORHOOD == .moore) {
                    if (self.cur[y_up * w + x_lf] == want) count += 1; // NW
                    if (self.cur[y_up * w + x_rt] == want) count += 1; // NE
                    if (self.cur[y_dn * w + x_lf] == want) count += 1; // SW
                    if (self.cur[y_dn * w + x_rt] == want) count += 1; // SE
                }

                // Write the result into the OTHER buffer so this generation's
                // updates can't contaminate each other.
                self.next[y * w + x] = if (count >= THRESHOLD) want else s;
            }
        }

        // Swap the buffers: next becomes current for the following frame. This
        // is just a pointer swap — no data is copied.
        const tmp = self.cur;
        self.cur = self.next;
        self.next = tmp;
    }

    /// Build one full frame of ANSI output and send it to the terminal in a
    /// single write.
    fn render(self: *Board, w: *Io.Writer) !void {
        var out = Out{ .buf = self.outbuf };

        // Jump to the top-left. We overwrite every cell every frame, so there's
        // no need to clear first — that would only cause flicker.
        out.put("\x1b[H");

        // Track the last colours we emitted. Terminals remember the current
        // fg/bg, so if the next pixel is the same colour we can skip re-sending
        // the (long!) escape code. In spiral patterns neighbouring pixels very
        // often match, so this dramatically shrinks each frame. -1 is an
        // impossible colour, forcing the first pixel of every frame to emit.
        var last_fg: i32 = -1;
        var last_bg: i32 = -1;

        var cy: usize = 0;
        while (cy < self.rows) : (cy += 1) {
            // Position at column 1 of this screen row. Being explicit about the
            // row avoids relying on line-wrap behaviour, which varies between
            // terminals.
            out.put("\x1b[");
            out.putUint(@as(u32, @intCast(cy + 1)));
            out.put(";1H");

            var cx: usize = 0;
            while (cx < self.cols) : (cx += 1) {
                // Top pixel drives the glyph's foreground, bottom its background.
                const top_state = self.cur[(2 * cy) * self.width + cx];
                const bot_state = self.cur[(2 * cy + 1) * self.width + cx];

                // Pack each state into a single int so we can cheaply compare
                // against what we last sent.
                const fg_key: i32 = top_state;
                const bg_key: i32 = bot_state;

                if (fg_key != last_fg) {
                    const col = self.palette[top_state];
                    // ESC[38;2;R;G;Bm = set foreground to a 24-bit colour.
                    out.put("\x1b[38;2;");
                    out.putUint(col.r);
                    out.putByte(';');
                    out.putUint(col.g);
                    out.putByte(';');
                    out.putUint(col.b);
                    out.putByte('m');
                    last_fg = fg_key;
                }
                if (bg_key != last_bg) {
                    const col = self.palette[bot_state];
                    // ESC[48;2;R;G;Bm = set background to a 24-bit colour.
                    out.put("\x1b[48;2;");
                    out.putUint(col.r);
                    out.putByte(';');
                    out.putUint(col.g);
                    out.putByte(';');
                    out.putUint(col.b);
                    out.putByte('m');
                    last_bg = bg_key;
                }

                // The upper-half-block. In the source this is UTF-8 bytes
                // E2 96 80; the terminal draws top half in fg, bottom in bg.
                out.put("▀");
            }
        }

        // Hand the whole frame to the terminal at once.
        try w.writeAll(out.buf[0..out.len]);
        try w.flush();
    }

    /// Run one tick of the whole simulation: maybe sprinkle, advance, draw.
    fn tick(self: *Board, w: *Io.Writer) !void {
        self.frame += 1;
        if (self.frame % SPRINKLE_EVERY == 0) self.sprinkle();
        self.step();
        try self.render(w);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Entry point.
// ─────────────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // A hidden self-test mode: `autom --selftest` runs the automaton headlessly
    // and prints a sanity summary to stderr. Handy for CI / verifying the maths
    // without needing a real terminal.
    var arg_it = init.minimal.args.iterate();
    _ = arg_it.skip(); // argv[0] is our own program name — skip it
    if (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--selftest")) return selftest();
        // `autom --frames N` renders exactly N frames to stdout and exits (no
        // raw mode / alt screen). Useful for piping into a file to verify the
        // renderer, or just to grab a still. N defaults to 3.
        if (std.mem.eql(u8, arg, "--frames")) {
            var count: u64 = 3;
            if (arg_it.next()) |num| {
                count = std.fmt.parseInt(u64, num, 10) catch 3;
            }
            return renderFrames(io, count);
        }
    }

    // `page_allocator` hands out whole pages straight from the OS. It's
    // perfect here: we make just a few big, long-lived allocations, and
    // explicitly free/reallocate them ourselves on a resize (see the main
    // loop below) rather than relying on an arena.
    const alloc = std.heap.page_allocator;

    const seed: u64 = @truncate(@as(u96, @bitCast(Io.Timestamp.now(io, .real).nanoseconds)));
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var stdout_buffer: [1 << 16]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const w = &stdout_writer.interface;

    // Take over the terminal: raw mode, alternate screen, hidden cursor. Also
    // installs the signal handlers that guarantee the terminal is restored
    // even if we're killed — see `termkit.Terminal`.
    var term = try termkit.Terminal.init(io, w);
    defer term.deinit();

    // Build the board at the terminal's current size.
    var size = term.size;
    var board = try Board.init(alloc, size.cols, size.rows, rng);
    defer board.deinit();

    const frame_delay = Io.Duration.fromNanoseconds(FRAME_NS);

    // ── The main loop ─────────────────────────────────────────────────────
    // Check for quit, handle window resizes, advance+draw, then sleep. Repeat
    // forever. This is the heartbeat of basically every real-time program.
    while (true) {
        if (term.pollQuit()) break;

        // Handle terminal resizes gracefully: re-query the size each frame and,
        // if it changed, rebuild the board to fit. Cheap, and it means dragging
        // the window just reshuffles the art instead of corrupting it.
        const now = term.querySize();
        if (now.cols != size.cols or now.rows != size.rows) {
            board.deinit();
            board = try Board.init(alloc, now.cols, now.rows, rng);
            size = now;
            try w.writeAll("\x1b[2J"); // clear once after a resize
            try w.flush();
        }

        try board.tick(w);
        io.sleep(frame_delay, .awake) catch break;
    }
    // Falling out of the loop returns from main; the `defer`s above restore the
    // terminal and free memory. Clean exit.
}

/// Render a fixed number of frames straight to stdout, then exit. No terminal
/// takeover — this is the non-interactive path used for testing and stills.
fn renderFrames(io: Io, count: u64) !void {
    const alloc = std.heap.page_allocator;
    const seed: u64 = @truncate(@as(u96, @bitCast(Io.Timestamp.now(io, .real).nanoseconds)));
    var prng = std.Random.DefaultPrng.init(seed);

    var stdout_buffer: [1 << 16]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const w = &stdout_writer.interface;

    const size = termkit.Terminal.queryStdoutSize();
    var board = try Board.init(alloc, size.cols, size.rows, prng.random());
    defer board.deinit();

    var i: u64 = 0;
    while (i < count) : (i += 1) try board.tick(w);
    // Leave colours reset so a terminal that saw this output isn't left tinted.
    try w.writeAll("\x1b[0m\n");
    try w.flush();
}

/// Headless correctness check used by `--selftest`. It exercises the exact same
/// allocation, seeding and step() code the real run uses, on a small grid, and
/// reports that the automaton is actually evolving (not frozen or crashing).
fn selftest() !void {
    const alloc = std.heap.page_allocator;
    var prng = std.Random.DefaultPrng.init(12345); // fixed seed = reproducible
    const rng = prng.random();

    var board = try Board.init(alloc, 40, 20, rng);
    defer board.deinit();

    // Count how many cells change over one step after warming up a bit — a
    // healthy automaton keeps churning.
    var s: usize = 0;
    while (s < 30) : (s += 1) board.step();

    // Snapshot, step once more, and diff.
    const before = try alloc.dupe(u8, board.cur);
    defer alloc.free(before);
    board.step();
    var changed: usize = 0;
    for (board.cur, before) |a, b| {
        if (a != b) changed += 1;
    }

    const stderr_msg = "selftest: grid 40x20 (pixels 40x40), ran 31 steps OK\n";
    _ = c.write(2, stderr_msg, stderr_msg.len);

    // Report the change count so a human can eyeball that it's non-trivial.
    var out = Out{ .buf = before }; // reuse the buffer as scratch for the number
    out.len = 0;
    out.put("selftest: cells changed on last step = ");
    out.putUint(@intCast(changed));
    out.putByte('\n');
    _ = c.write(2, out.buf.ptr, out.len);
}
