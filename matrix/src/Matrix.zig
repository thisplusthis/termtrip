//! Matrix.zig — the "digital rain" simulation and how to paint it.
//!
//! Like `Terminal.zig`, this file *is* a struct (see `@This()` below). It knows
//! nothing about raw mode or key handling — it only models falling glyph
//! streaks and renders them to a writer. Keeping the simulation separate from
//! the terminal plumbing is the "DRY, single-responsibility" idea in practice:
//! each file has exactly one job.
//!
//! The mental model:
//!   * The screen is a grid of character cells, `cols` wide and `rows` tall.
//!   * Each *column* of the screen owns one falling streak (a `Column`).
//!   * A streak has a bright leading glyph (the "head") and a tail of dimmer
//!     glyphs fading to black behind (above) it.
//!   * We remember which glyph lives in every cell in `grid`, so the tail stays
//!     stable frame-to-frame instead of flickering into random noise.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Matrix = @This();

// --- Tunables: change these to taste ---------------------------------------
const min_speed = 0.25; // slowest a streak's head falls, in rows per frame
const max_speed = 1.15; // fastest a streak's head falls, in rows per frame

// Frame-local escape codes (kept here so this file doesn't depend on Terminal).
const home = "\x1b[H"; // move cursor to the top-left before painting a frame
const reset_color = "\x1b[0m"; // clear color at the end of a frame

// The glyphs that fall. Half-width katakana are the iconic look of the film's
// title sequence; each occupies exactly one terminal cell, as do the digits and
// punctuation, which keeps our grid perfectly rectangular. The array is indexed
// by a `u8`, so keep it under 256 entries (a test at the bottom enforces this).
const glyphs = [_][]const u8{
    "ｦ", "ｱ", "ｲ", "ｳ", "ｴ", "ｵ", "ｶ", "ｷ", "ｸ", "ｹ", "ｺ", "ｻ", "ｼ", "ｽ", "ｾ", "ｿ",
    "ﾀ", "ﾁ", "ﾂ", "ﾃ", "ﾄ", "ﾅ", "ﾆ", "ﾇ", "ﾈ", "ﾉ", "ﾊ", "ﾋ", "ﾌ", "ﾍ", "ﾎ", "ﾏ",
    "ﾐ", "ﾑ", "ﾒ", "ﾓ", "ﾔ", "ﾕ", "ﾖ", "ﾗ", "ﾘ", "ﾙ", "ﾚ", "ﾛ", "ﾜ", "ﾝ",
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    ":", ".", "=", "*", "+", "-", "<", ">",
};

/// One falling streak. Positions are stored as `f32` so a streak can advance a
/// fractional number of rows per frame — that's what gives us a spread of
/// believable falling speeds instead of everything moving in lockstep.
const Column = struct {
    head: f32, // vertical position of the bright leading glyph (in rows)
    speed: f32, // rows the head descends each frame
    length: u16, // number of glyphs in the fading tail
    last_row: i32, // the highest row we've already assigned a fresh glyph to
};

// --- Struct fields ---------------------------------------------------------
gpa: Allocator, // where `columns` and `grid` are allocated from
prng: std.Random.DefaultPrng, // the pseudo-random number generator (seeded once)
cols: u16,
rows: u16,
columns: []Column, // one streak per screen column; len == cols
grid: []u8, // glyph index per cell, row-major: grid[y * cols + x]

/// Build a Matrix sized for the given terminal. `seed` makes each run's rain
/// unique; `main` derives it from the wall clock.
pub fn init(gpa: Allocator, seed: u64, cols: u16, rows: u16) !Matrix {
    var self: Matrix = .{
        .gpa = gpa,
        .prng = std.Random.DefaultPrng.init(seed),
        .cols = 0,
        .rows = 0,
        .columns = &.{}, // start empty; `resize` does the real allocation
        .grid = &.{},
    };
    try self.resize(cols, rows);
    return self;
}

/// Release the memory we own. Safe to call once, from a `defer`.
pub fn deinit(self: *Matrix) void {
    if (self.columns.len != 0) self.gpa.free(self.columns);
    if (self.grid.len != 0) self.gpa.free(self.grid);
}

/// Resize (or first-time allocate) the grid to `cols`×`rows` and re-seed every
/// column. Called on startup and whenever the user resizes their terminal.
pub fn resize(self: *Matrix, cols: u16, rows: u16) !void {
    if (self.columns.len != 0) self.gpa.free(self.columns);
    if (self.grid.len != 0) self.gpa.free(self.grid);

    self.cols = cols;
    self.rows = rows;
    self.columns = try self.gpa.alloc(Column, cols);
    self.grid = try self.gpa.alloc(u8, @as(usize, cols) * rows);

    const rand = self.prng.random();
    // Fill every cell with a random glyph up front so newly-lit cells always
    // have *something* to show even before a head has visited them.
    for (self.grid) |*cell| cell.* = rand.uintLessThan(u8, glyphs.len);
    for (self.columns) |*col| col.* = self.spawn();
}

/// Advance the whole simulation by one frame.
pub fn update(self: *Matrix) void {
    const rand = self.prng.random();
    const cw: usize = self.cols;
    const rows_i: i32 = self.rows;
    const rows_f: f32 = @floatFromInt(self.rows);

    for (self.columns, 0..) |*col, x| {
        col.head += col.speed;
        const head_row: i32 = @intFromFloat(@floor(col.head));

        // A fast streak can cross several whole rows in one frame. Give each
        // newly-revealed row its own fresh glyph so no cell is skipped and the
        // tail behind the head stays put.
        var row = col.last_row + 1;
        while (row <= head_row) : (row += 1) {
            if (row >= 0 and row < rows_i) {
                self.grid[@as(usize, @intCast(row)) * cw + x] = rand.uintLessThan(u8, glyphs.len);
            }
        }
        col.last_row = head_row;

        // Once the entire streak (head *and* tail) has fallen off the bottom,
        // recycle this column into a brand-new streak starting above the screen.
        if (col.head - @as(f32, @floatFromInt(col.length)) > rows_f) {
            col.* = self.spawn();
        }
    }

    // Shimmer: rewrite a few random glyphs somewhere along the streaks each
    // frame. This is the subtle flicker that makes the rain feel "alive".
    const shimmer = self.cols / 6 + 1;
    var i: u16 = 0;
    while (i < shimmer) : (i += 1) {
        const x: usize = rand.uintLessThan(u16, self.cols);
        const col = self.columns[x];
        const head_row: i32 = @intFromFloat(@floor(col.head));
        const back = rand.uintLessThan(u16, col.length); // how far up the tail
        const row = head_row - @as(i32, back);
        if (row >= 0 and row < rows_i) {
            self.grid[@as(usize, @intCast(row)) * cw + x] = rand.uintLessThan(u8, glyphs.len);
        }
    }
}

/// Paint the current frame to `w`. We write the *entire* screen every frame;
/// the caller assembles it in a buffer and flushes once, so there is no flicker.
pub fn draw(self: *Matrix, w: *Io.Writer) !void {
    const cw: usize = self.cols;
    try w.writeAll(home);

    // A whole-screen worth of 24-bit color escapes is a lot of bytes. Most
    // neighbouring cells share a color, though, so we remember the last color
    // we emitted and only send a new escape when it actually changes. `-1` is
    // an impossible color value, so the very first cell always emits one.
    var last_r: i16 = -1;
    var last_g: i16 = -1;
    var last_b: i16 = -1;

    var y: usize = 0;
    while (y < self.rows) : (y += 1) {
        // Rows are separated by CR+LF. We disabled output post-processing in the
        // terminal, so we must spell out both bytes ourselves: `\r` returns to
        // column 1, `\n` moves down one line.
        if (y != 0) try w.writeAll("\r\n");

        var x: usize = 0;
        while (x < cw) : (x += 1) {
            const col = self.columns[x];
            const head_row: i32 = @intFromFloat(@floor(col.head));
            const dist = head_row - @as(i32, @intCast(y)); // 0 == head, larger == further up the tail

            if (dist >= 0 and dist < col.length) {
                const rgb = colorFor(@intCast(dist), col.length);
                if (@as(i16, rgb[0]) != last_r or @as(i16, rgb[1]) != last_g or @as(i16, rgb[2]) != last_b) {
                    // Select a 24-bit ("true color") foreground: CSI 38;2;R;G;B m
                    try w.print("\x1b[38;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] });
                    last_r = rgb[0];
                    last_g = rgb[1];
                    last_b = rgb[2];
                }
                try w.writeAll(glyphs[self.grid[y * cw + x]]);
            } else {
                // Outside every streak: a plain space. Spaces show no ink, so the
                // leftover foreground color doesn't matter and we skip the escape.
                try w.writeByte(' ');
            }
        }
    }
    try w.writeAll(reset_color);
}

// --- Private helpers -------------------------------------------------------

/// Create a fresh streak for a column. It starts *above* the visible area
/// (a negative head) so streaks enter at staggered times rather than all at
/// once — the further above, the longer the delay before it reappears.
fn spawn(self: *Matrix) Column {
    const rand = self.prng.random();
    const rows_f: f32 = @floatFromInt(self.rows);

    const speed = min_speed + rand.float(f32) * (max_speed - min_speed);
    const min_len: u16 = @max(6, self.rows / 4);
    const max_len: u16 = @max(min_len + 1, self.rows);
    const length = rand.intRangeAtMost(u16, min_len, max_len);

    const gap = rand.float(f32) * rows_f * 1.5; // how far above the screen to start
    const head = -gap;
    return .{
        .head = head,
        .speed = speed,
        .length = length,
        .last_row = @intFromFloat(@floor(head)),
    };
}

/// Map a cell's distance-behind-the-head to an RGB color. Distance 0 is the
/// bright near-white head; everything behind fades from vivid green down to a
/// dim, almost-black green at the tip of the tail.
fn colorFor(dist: u16, length: u16) [3]u8 {
    if (dist == 0) return .{ 205, 255, 205 }; // the leading glyph: pale, glowing white-green

    // `t` runs from ~1 just behind the head to ~0 at the end of the tail.
    const t = 1.0 - @as(f32, @floatFromInt(dist)) / @as(f32, @floatFromInt(length));
    const green: u8 = @intFromFloat(50.0 + t * 205.0); // 50 (dim) … 255 (bright)
    return .{ 0, green, 0 };
}

// --- Tests -----------------------------------------------------------------
// Run with `zig build test`. These are cheap, pure-function checks — no
// terminal required — which is exactly why the simulation is worth isolating.

test "colorFor: head is bright, tail fades away from it" {
    const head = colorFor(0, 20);
    try std.testing.expectEqual(@as(u8, 255), head[1]); // head is maximally bright

    const near = colorFor(1, 20); // just behind the head
    const far = colorFor(19, 20); // near the tip of the tail
    try std.testing.expect(near[1] > far[1]); // closer to the head means brighter green
}

test "glyph table fits in a u8 index" {
    try std.testing.expect(glyphs.len <= 255);
}
