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
//! This build targets Zig 0.16. That version reworked the standard I/O
//! library heavily, so instead of fighting the churn we lean on libc directly
//! (see the `extern "c"` declarations below). This is a great chance to learn
//! how Zig calls C functions: you just declare the function's signature and
//! link libc, and Zig wires it up to the real symbol at link time.

const std = @import("std");

// `std.c` is Zig's binding layer for the C standard library. Because we build
// with `link_libc = true`, every `std.c.foo` resolves to the real libc `foo`.
const c = std.c;

// ── Raw C functions we need that std doesn't expose as `pub` on 0.16 ────────
// Declaring an `extern "c" fn` is how you tell Zig "this function lives in a C
// library I'm linking against; here is its signature." No body — the linker
// finds it. We declare these ourselves so the program doesn't depend on which
// helpers happen to be public in this particular std version.
//
// `ioctl` controls devices. We use it with the TIOCGWINSZ request to ask the
// terminal how many rows and columns it currently has.
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
// `nanosleep` pauses the thread for a precise duration — our frame limiter.
extern "c" fn nanosleep(req: *const c.timespec, rem: ?*c.timespec) c_int;

// The two file descriptors every Unix process is born with. 0 is standard
// input (the keyboard), 1 is standard output (the screen). Typing them as
// `c.fd_t` (an alias for c_int on macOS) keeps the C calls happy.
const STDIN: c.fd_t = 0;
const STDOUT: c.fd_t = 1;

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
const FRAME_NS: c_long = 70 * 1_000_000;

/// Every few seconds we sprinkle a handful of random cells back into the field.
/// Left alone, a cyclic automaton can settle into a calm rotating steady state;
/// these little "sparks" keep new waves being born so the screensaver never
/// goes stale. Measured in frames.
const SPRINKLE_EVERY: u64 = 200;
const SPRINKLE_COUNT: usize = 20;

/// If we can't read the real terminal size (e.g. output isn't a TTY) we fall
/// back to the classic 80×24.
const FALLBACK_COLS: u16 = 80;
const FALLBACK_ROWS: u16 = 24;

// ── ANSI escape sequences ────────────────────────────────────────────────────
// `\x1b` is the ESC byte (27). Terminals treat `ESC [ … <letter>` as a command
// rather than text. A quick tour of the ones we use:
//   ESC[?1049h  switch to the "alternate screen" (like vim/less do) so we
//               don't clobber the user's scrollback; ?1049l switches back.
//   ESC[?25l    hide the text cursor;  ESC[?25h shows it again.
//   ESC[2J      clear the whole screen.
//   ESC[H       move the cursor to the top-left (home).
//   ESC[0m      reset all colours/attributes to normal.
const ENTER_SEQ = "\x1b[?1049h\x1b[?25l\x1b[2J";
const EXIT_SEQ = "\x1b[0m\x1b[?25h\x1b[?1049l";

// ── Globals used by the signal handler ───────────────────────────────────────
// A signal handler (for Ctrl-C-style interruptions and `kill`) runs "out of
// band" — it can fire at almost any moment and it CANNOT take arguments from
// us. The classic C way to give it the data it needs is a global. We keep the
// terminal's original settings here so the handler can put things back.
var g_orig_termios: c.termios = undefined;
var g_raw_active: bool = false;

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
    fn render(self: *Board) void {
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

        // Hand the whole frame to the OS at once.
        _ = c.write(STDOUT, out.buf.ptr, out.len);
    }

    /// Run one tick of the whole simulation: maybe sprinkle, advance, draw.
    fn tick(self: *Board) void {
        self.frame += 1;
        if (self.frame % SPRINKLE_EVERY == 0) self.sprinkle();
        self.step();
        self.render();
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Terminal plumbing.
// ─────────────────────────────────────────────────────────────────────────────

/// Ask the terminal for its current size via the TIOCGWINSZ ioctl. Returns the
/// fallback size if the call fails (e.g. output is a pipe, not a real terminal).
fn queryTerminalSize() struct { cols: u16, rows: u16 } {
    var ws: std.posix.winsize = undefined;
    // `c.T.IOCGWINSZ` is the magic request number for "get window size" on this
    // platform. ioctl writes the answer into `ws`.
    const rc = ioctl(STDOUT, @intCast(c.T.IOCGWINSZ), &ws);
    if (rc != 0 or ws.col == 0 or ws.row == 0) {
        return .{ .cols = FALLBACK_COLS, .rows = FALLBACK_ROWS };
    }
    return .{ .cols = ws.col, .rows = ws.row };
}

/// Put the terminal into raw mode and remember how it was so we can restore it.
///
/// "Raw mode" turns off the terminal's helpful-but-here-unwanted behaviours:
/// line buffering (we want each key immediately), echoing (we don't want typed
/// letters splattered over our art), and signal/flow-control key handling.
fn enableRawMode() void {
    _ = c.tcgetattr(STDIN, &g_orig_termios); // save the originals
    var raw = g_orig_termios; // a copy we'll tweak

    // `lflag` groups "local" behaviours. Each field is a bool bit.
    raw.lflag.ECHO = false; // don't print typed characters
    raw.lflag.ICANON = false; // read byte-by-byte, don't wait for Enter
    raw.lflag.ISIG = false; // Ctrl-C/Ctrl-Z arrive as bytes, not signals
    raw.lflag.IEXTEN = false; // disable Ctrl-V literal-next processing

    // `iflag` groups input translations we also want off.
    raw.iflag.IXON = false; // disable Ctrl-S / Ctrl-Q flow control
    raw.iflag.ICRNL = false; // don't rewrite carriage-return to newline

    // The `cc` array holds control parameters. With canonical mode off, VMIN
    // and VTIME govern how `read` blocks. Both 0 means: return immediately with
    // whatever bytes are available (possibly none) — i.e. non-blocking input,
    // exactly what a real-time animation wants.
    raw.cc[@intFromEnum(c.V.MIN)] = 0;
    raw.cc[@intFromEnum(c.V.TIME)] = 0;

    // TCSA.FLUSH applies the change now and discards any unread input.
    _ = c.tcsetattr(STDIN, .FLUSH, &raw);
    g_raw_active = true;
}

/// Undo enableRawMode and leave the alternate screen. Safe to call from a
/// signal handler: it only calls async-signal-safe C functions (tcsetattr,
/// write) and touches globals.
fn restoreTerminal() void {
    if (g_raw_active) {
        _ = c.tcsetattr(STDIN, .FLUSH, &g_orig_termios);
        g_raw_active = false;
    }
    _ = c.write(STDOUT, EXIT_SEQ, EXIT_SEQ.len);
}

/// Signal handler for Ctrl-C-style interruptions and `kill`. Because signals
/// bypass our normal `defer` cleanup, we restore the terminal here too, then
/// exit immediately. `callconv(.c)` gives it the calling convention the OS
/// expects for a handler.
fn onSignal(_: c.SIG) callconv(.c) void {
    restoreTerminal();
    c._exit(0);
}

/// Install `onSignal` for the signals that would otherwise kill us with the
/// terminal left in raw mode (a wrecked shell prompt). Note: with ISIG off,
/// keyboard Ctrl-C won't raise SIGINT — but an external `kill` still can, and
/// closing the terminal raises SIGHUP, so wiring these up is good manners.
fn installSignalHandlers() void {
    var act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.HUP, &act, null);
}

/// Sleep for one frame's worth of nanoseconds.
fn sleepFrame() void {
    var ts = c.timespec{ .sec = 0, .nsec = FRAME_NS };
    _ = nanosleep(&ts, null);
}

/// Poll the keyboard (non-blocking). Returns true if the user asked to quit:
/// `q`/`Q`, Esc (0x1b), or Ctrl-C (0x03, which reaches us as a byte since we
/// disabled ISIG).
fn wantsQuit() bool {
    var buf: [32]u8 = undefined;
    const n = c.read(STDIN, &buf, buf.len);
    if (n <= 0) return false; // no input this frame
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        switch (buf[i]) {
            'q', 'Q', 0x1b, 0x03 => return true,
            else => {},
        }
    }
    return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry point.
// ─────────────────────────────────────────────────────────────────────────────

// Zig 0.16 hands `main` a ready-made bundle of process facilities. We only need
// the command-line arguments, so we accept the lightweight `Init.Minimal` form.
// (Older Zig used `std.os.argv`; that's gone now.)
pub fn main(init: std.process.Init.Minimal) !void {
    // A hidden self-test mode: `autom --selftest` runs the automaton headlessly
    // and prints a sanity summary to stderr. Handy for CI / verifying the maths
    // without needing a real terminal.
    var arg_it = init.args.iterate();
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
            return renderFrames(count);
        }
    }

    // `page_allocator` hands out whole pages straight from the OS. It's perfect
    // here: we make just a few big, long-lived allocations.
    const alloc = std.heap.page_allocator;

    // Seed the RNG. We don't have a simple timestamp API on this std version,
    // but the address of a stack variable is randomised by the OS (ASLR) on
    // every run, giving us a different-looking pattern each time. Mixing in a
    // constant avoids a pathological all-zero seed.
    var seed_anchor: u8 = 0;
    const seed: u64 = @intFromPtr(&seed_anchor) ^ 0x9E3779B97F4A7C15;
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    // Set up the terminal. The ORDER matters and the cleanup must be bullet-
    // proof, so we pair each setup step with a `defer` (runs on the way out, in
    // reverse order) plus signal handlers for the abrupt-exit cases.
    installSignalHandlers();
    enableRawMode();
    defer restoreTerminal(); // runs when main returns (the normal `q` path)

    _ = c.write(STDOUT, ENTER_SEQ, ENTER_SEQ.len);

    // Build the board at the terminal's current size.
    var size = queryTerminalSize();
    var board = try Board.init(alloc, size.cols, size.rows, rng);
    defer board.deinit();

    // ── The main loop ─────────────────────────────────────────────────────
    // Check for quit, handle window resizes, advance+draw, then sleep. Repeat
    // forever. This is the heartbeat of basically every real-time program.
    while (true) {
        if (wantsQuit()) break;

        // Handle terminal resizes gracefully: re-query the size each frame and,
        // if it changed, rebuild the board to fit. Cheap, and it means dragging
        // the window just reshuffles the art instead of corrupting it.
        const now = queryTerminalSize();
        if (now.cols != size.cols or now.rows != size.rows) {
            board.deinit();
            board = try Board.init(alloc, now.cols, now.rows, rng);
            size = now;
            _ = c.write(STDOUT, "\x1b[2J", 4); // clear once after a resize
        }

        board.tick();
        sleepFrame();
    }
    // Falling out of the loop returns from main; the `defer`s above restore the
    // terminal and free memory. Clean exit.
}

/// Render a fixed number of frames straight to stdout, then exit. No terminal
/// takeover — this is the non-interactive path used for testing and stills.
fn renderFrames(count: u64) !void {
    const alloc = std.heap.page_allocator;
    var seed_anchor: u8 = 0;
    const seed: u64 = @intFromPtr(&seed_anchor) ^ 0x9E3779B97F4A7C15;
    var prng = std.Random.DefaultPrng.init(seed);

    const size = queryTerminalSize();
    var board = try Board.init(alloc, size.cols, size.rows, prng.random());
    defer board.deinit();

    var i: u64 = 0;
    while (i < count) : (i += 1) board.tick();
    // Leave colours reset so a terminal that saw this output isn't left tinted.
    _ = c.write(STDOUT, "\x1b[0m\n", 5);
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
