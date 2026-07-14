//! By convention, root.zig is the root source file when making a package.
//!
//! This module fills the terminal with a looping pink-purple-green-yellow
//! spectrum, blended directly in RGB. Each cell's position along that
//! spectrum comes from `Life`, a little simulation where every cell
//! continuously diffuses into its neighbors, gets nudged by randomness, and
//! occasionally spawns a brand new blob of color out of nowhere -- together,
//! these are what make the whole screen feel like it's full of living,
//! moving cells.

const std = @import("std");
const Io = std.Io;
const termkit = @import("termkit");

/// A simple RGB color: three bytes (0-255) for red, green, and blue. This is
/// still what we ultimately need, since terminals expect RGB escape codes.
const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

/// Clamps `x` into the valid 0-255 byte range, then converts it to a `u8`.
/// Floating point math can drift slightly outside 0-255 (e.g. 255.00001),
/// so we clamp before converting to avoid a crash.
fn toByte(x: f32) u8 {
    return @intFromFloat(std.math.clamp(x, 0.0, 255.0));
}

/// Blends from `a` toward `b` by fraction `t` (0.0 = stay at `a`, 1.0 = jump
/// all the way to `b`). Also known as "linear interpolation".
fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Same idea as `lerp`, but for a single RGB byte.
fn lerpByte(a: u8, b: u8, t: f32) u8 {
    return toByte(lerp(@floatFromInt(a), @floatFromInt(b), t));
}

/// Eases `current` toward `target` by fraction `amount`. Used every frame of
/// the animation so colors drift into their new value instead of snapping to
/// it, which is what produces the smeared, "bleeding" trail effect.
fn blendToward(current: Color, target: Color, amount: f32) Color {
    return .{
        .r = lerpByte(current.r, target.r, amount),
        .g = lerpByte(current.g, target.g, amount),
        .b = lerpByte(current.b, target.b, amount),
    };
}

/// The anchor colors, in order. A cell's color is always a blend of two
/// neighboring anchors -- see `colorAt`. This loops (Yellow blends back
/// into Pink), so there's no seam anywhere around the spectrum.
const spectrum = [_]Color{
    .{ .r = 255, .g = 0, .b = 128 }, // Pink
    .{ .r = 128, .g = 0, .b = 255 }, // Purple
    .{ .r = 0, .g = 255, .b = 0 }, // Green
    .{ .r = 255, .g = 255, .b = 0 }, // Yellow
};

/// How far `t` ranges before `colorAt` wraps it back to the start -- equal
/// to the number of anchors, since the spectrum loops all the way around.
const spectrum_range: f32 = spectrum.len;

/// Picks a color along the looping spectrum. `t` of `0` is pure pink, `1`
/// is pure purple, `2` is pure green, `3` is pure yellow, and `4` loops
/// back to pure pink again; anything in between blends smoothly toward the
/// next anchor. Any `t`, even negative or huge, wraps into range first.
fn colorAt(t: f32) Color {
    const wrapped = wrapToSpectrum(t);
    const index: usize = @intFromFloat(@floor(wrapped));
    const next_index = (index + 1) % spectrum.len;
    const fraction = wrapped - @floor(wrapped);
    return blendToward(spectrum[index], spectrum[next_index], fraction);
}

/// How much each cell blends toward its neighbors' average every step.
/// Kept low so blobs stay distinct and speckled instead of melting into a
/// soft, blurry haze -- higher values spread and merge color faster, but
/// look mushier. Try tweaking this!
const diffusion_rate: f32 = 0.18;
/// How big a random nudge each cell gets every step, in spectrum units.
/// This is what keeps cells restlessly drifting instead of settling into a
/// static pattern -- the "move around randomly" part.
const jitter_amount: f32 = 0.3;
/// Fraction of all cells that spontaneously become a brand new color each
/// step, out of nowhere -- the "reproduce" part.
const spawn_rate: f32 = 0.002;

/// Blends `current` partway toward `neighbor_average` by `diffusion_rate`.
/// Pulled out as its own tiny function so it's easy to unit test on its
/// own, away from `Life`'s randomness.
fn diffuse(current: f32, neighbor_average: f32) f32 {
    return lerp(current, neighbor_average, diffusion_rate);
}

/// Wraps `value` back into `0..spectrum_range`, so a value past one end of
/// the (looping) spectrum reappears at the other end instead of getting
/// stuck or jumping discontinuously.
fn wrapToSpectrum(value: f32) f32 {
    return @mod(value + spectrum_range, spectrum_range);
}

/// A little simulation: one "position along the spectrum" value per cell,
/// which evolves every `step`. Three simple rules, applied
/// together, are what give the whole grid its restless, organic motion:
///
/// 1. Diffusion: each cell eases toward the average of its 4 neighbors,
///    so blobs of color spread outward and merge into each other.
/// 2. Jitter: each cell also gets a small random nudge, so nothing ever
///    settles into a static, unmoving pattern.
/// 3. Spawning: a few random cells become a brand new color out of
///    nowhere each step, like new life appearing.
///
/// The grid wraps at its edges (the cell left of column 0 is the last
/// column, and so on), so blobs can drift clean off one side and back in
/// the other rather than bouncing off a wall.
const Life = struct {
    width: usize,
    height: usize,
    current: []f32,
    scratch: []f32,

    fn init(allocator: std.mem.Allocator, width: usize, height: usize, random: std.Random) !Life {
        const current = try allocator.alloc(f32, width * height);
        errdefer allocator.free(current);
        const scratch = try allocator.alloc(f32, width * height);

        for (current) |*value| value.* = random.float(f32) * spectrum_range;

        return .{ .width = width, .height = height, .current = current, .scratch = scratch };
    }

    fn deinit(life: *Life, allocator: std.mem.Allocator) void {
        allocator.free(life.current);
        allocator.free(life.scratch);
    }

    fn step(life: *Life, random: std.Random) void {
        const width = life.width;
        const height = life.height;

        for (0..height) |row| {
            // Wrapping neighbor rows/columns: e.g. the row above row 0 is
            // the last row, so blobs can drift off one edge and back in
            // the other.
            const up = (row + height - 1) % height;
            const down = (row + 1) % height;
            for (0..width) |col| {
                const left = (col + width - 1) % width;
                const right = (col + 1) % width;

                const neighbor_average = (life.current[up * width + col] +
                    life.current[down * width + col] +
                    life.current[row * width + left] +
                    life.current[row * width + right]) / 4.0;

                const jitter = (random.float(f32) * 2.0 - 1.0) * jitter_amount;
                const next = diffuse(life.current[row * width + col], neighbor_average) + jitter;
                life.scratch[row * width + col] = wrapToSpectrum(next);
            }
        }
        std.mem.swap([]f32, &life.current, &life.scratch);

        const spawn_count: usize = @intFromFloat(@as(f32, @floatFromInt(life.current.len)) * spawn_rate);
        for (0..spawn_count) |_| {
            const index = random.uintLessThan(usize, life.current.len);
            life.current[index] = random.float(f32) * spectrum_range;
        }
    }
};

/// Moves the cursor back up to the top-left of the `height`-row grid we just
/// drew, so the *next* frame overwrites this one in place instead of
/// scrolling the terminal. We never print a trailing newline after the
/// grid's last row (see `animateColorGrid`), so the cursor is still sitting
/// on that last row when this runs -- only `height - 1` lines up is needed.
fn cursorToGridTop(writer: *Io.Writer, height: usize) Io.Writer.Error!void {
    try writer.print("\x1b[{d}F", .{height -| 1});
}

/// Animates the color grid until the user presses 'q' (or Ctrl+C): a `Life`
/// simulation drives each cell's position along the ROYGBIV spectrum, and
/// the displayed color only slowly catches up to that target instead of
/// snapping to it. That lag is what turns Life's per-cell updates into a
/// smeared, bleeding trail rather than a flickery, pixel-by-pixel change.
///
/// `width` and `height` are runtime values (typically the user's whole
/// terminal, from `term.size`), so `allocator` is used to size the grid of
/// "what's currently on screen" to match. `term` is expected to already be in
/// raw full-screen mode (see `termkit.Terminal.init`, called by `main`).
pub fn animateColorGrid(term: *termkit.Terminal, allocator: std.mem.Allocator, width: usize, height: usize) !void {
    const writer = term.w;
    // How much of each cell's *target* color it adopts each frame. Small
    // values make colors lag behind and bleed into each other as they move;
    // `1.0` would snap instantly, with no smear at all. Kept high so the
    // display tracks Life closely instead of looking soft and blurry.
    // Try tweaking this!
    const catch_up_rate: f32 = 0.75;
    const frame_delay: Io.Duration = .fromMilliseconds(33); // ~30 frames/sec.

    // Change this to get a different, but equally organic, starting point.
    var prng = std.Random.DefaultPrng.init(1);
    const random = prng.random();

    var life = try Life.init(allocator, width, height, random);
    defer life.deinit(allocator);

    // What's actually being displayed right now, per cell, stored as one
    // long row-by-row slice (cell `(col, row)` lives at `row * width +
    // col`). Each frame eases this toward Life's target instead of
    // replacing it outright.
    const cells = try allocator.alloc(Color, width * height);
    defer allocator.free(cells);
    for (life.current, cells) |position, *cell| cell.* = colorAt(position);

    var is_first_frame = true;
    while (!term.pollQuit()) {
        if (!is_first_frame) try cursorToGridTop(writer, height);
        is_first_frame = false;

        life.step(random);

        for (0..height) |row| {
            for (0..width) |col| {
                const index = row * width + col;
                const target = colorAt(life.current[index]);
                const blended = blendToward(cells[index], target, catch_up_rate);
                cells[index] = blended;
                try writer.print("\x1b[48;2;{d};{d};{d}m ", .{ blended.r, blended.g, blended.b });
            }
            try writer.print("\x1b[0m", .{}); // Reset styling at the end of the row.
            // Skip the newline after the very last row: the grid is exactly
            // as tall as the terminal, so one more newline here would push
            // the cursor past the bottom and scroll the whole screen up.
            if (row != height - 1) try writer.print("\n", .{});
        }

        // Push this frame out to the terminal now, rather than leaving it
        // sitting in the buffer while we sleep.
        try writer.flush();

        try term.io.sleep(frame_delay, .awake);
    }
}

test "colorAt: exactly on an anchor returns that anchor's own color" {
    try std.testing.expectEqual(spectrum[0], colorAt(0)); // Pink
    try std.testing.expectEqual(spectrum[2], colorAt(2)); // Green
}

test "colorAt: halfway between pink and purple blends evenly" {
    try std.testing.expectEqual(Color{ .r = 191, .g = 0, .b = 191 }, colorAt(0.5));
}

test "colorAt: a full loop through the spectrum lands back on the first anchor" {
    try std.testing.expectEqual(spectrum[0], colorAt(spectrum_range));
}

test "colorAt: wraps around seamlessly, with no jump at the loop point" {
    try std.testing.expectEqual(colorAt(0.5), colorAt(spectrum_range + 0.5));
}

test "blendToward: partial amount lands strictly between the two colors" {
    const start = Color{ .r = 0, .g = 0, .b = 0 };
    const target = Color{ .r = 200, .g = 100, .b = 50 };
    const halfway = blendToward(start, target, 0.5);
    try std.testing.expectEqual(Color{ .r = 100, .g = 50, .b = 25 }, halfway);
}

test "diffuse: blends partway toward the neighbor average" {
    try std.testing.expectEqual(lerp(1.0, 3.0, diffusion_rate), diffuse(1.0, 3.0));
}

test "wrapToSpectrum: values already in range are unchanged" {
    try std.testing.expectApproxEqAbs(3.0, wrapToSpectrum(3.0), 0.0001);
}

test "wrapToSpectrum: a value just past the end wraps back to the start" {
    try std.testing.expectApproxEqAbs(0.1, wrapToSpectrum(spectrum_range + 0.1), 0.0001);
}

test "wrapToSpectrum: a value just below zero wraps to just below the end" {
    try std.testing.expectApproxEqAbs(spectrum_range - 0.1, wrapToSpectrum(-0.1), 0.0001);
}

test "Life.init: seeds every cell within the spectrum's range" {
    var prng = std.Random.DefaultPrng.init(7);
    var life = try Life.init(std.testing.allocator, 5, 4, prng.random());
    defer life.deinit(std.testing.allocator);

    for (life.current) |value| {
        try std.testing.expect(value >= 0 and value <= spectrum_range);
    }
}

test "Life.step: every cell stays within the spectrum's range after many steps" {
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    var life = try Life.init(std.testing.allocator, 5, 4, random);
    defer life.deinit(std.testing.allocator);

    for (0..50) |_| life.step(random);

    for (life.current) |value| {
        try std.testing.expect(value >= 0 and value <= spectrum_range);
    }
}
