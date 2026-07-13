//! glix - a colorful, ever-changing glitch art screensaver for your terminal.
//!
//! The base picture is a Perlin-noise flow field mapped to hue/brightness,
//! recursively domain-warped into swirls, and endlessly zoomed into via two
//! crossfaded passes (see `sampleFields`), then roughed up with chromatic
//! aberration, pixel sorting, and corrupted static for that databending /
//! glitch-art texture. A Lorenz attractor also nudges a few settings up and
//! down over time (see `Lorenz`). There's also an optional
//! rotating-kaleidoscope fold (currently off by default -- see
//! `kaleido_enabled`).
//!
//! Controls: press any key for a little glitch burst, 'q' / Ctrl+C to quit.

const std = @import("std");
const Io = std.Io;
const noise = @import("noise.zig");

const posix = std.posix;

// ============================================================================
// TUNABLES -- the knobs worth turning to change the vibe. Everything below
// this section is plumbing and shouldn't need to change.
// ============================================================================

// --- Timing -----------------------------------------------------------------

/// Target frames per second. The render loop sleeps to hit this, but will
/// happily run slower on a slow terminal/machine instead of erroring.
const target_fps: f64 = 30.0;

// --- Base flow field ---------------------------------------------------------

/// How "zoomed in" the noise is along each axis and through time. Bigger
/// numbers = busier, smaller-scale patterns; smaller = broad, slow blobs.
const freq_x: f64 = 0.06;
const freq_y: f64 = 0.11;
const freq_t: f64 = 0.18;

/// How many `fbm` octaves feed the hue / brightness / detail fields. More
/// octaves = finer, more "fractal" self-similar detail layered on top of
/// the broad shape, at a small performance cost.
const hue_octaves: u32 = 5;
const brightness_octaves: u32 = 4;
const detail_octaves: u32 = 3;

/// Constant hue rotation over time, independent of the noise -- keeps the
/// palette cycling even where the noise field itself is calm.
const hue_drift_deg_per_sec: f64 = 26.0;

/// How raw noise (roughly [-1, 1]) gets mapped to hue/brightness/
/// saturation/character-density. Bigger "_scale" values = more dramatic
/// swings for the same amount of underlying noise change.
const hue_noise_scale: f64 = 200.0; // degrees of hue swing driven by the main field
const hue_detail_scale: f64 = 60.0; // extra degrees of hue swing from the detail field
const brightness_base: f64 = 0.5;
const brightness_range: f64 = 0.6;
const saturation_base: f64 = 0.8;
const saturation_range: f64 = 0.2;
const density_base: f64 = 0.5; // controls which `shade_ramp` character gets picked
const density_range: f64 = 0.5;

// --- Domain warp (bends the flow into swirls instead of a plain drift) -----
//
// Recursive: `q` warps (x, y), then `r` warps (x, y) by `q`, then the final
// displacement warps (x, y) by `r`. Each level feeds the next, so the
// distortion is self-similar at multiple scales -- swirls within swirls --
// instead of a single bend. See Inigo Quilez's writeup on recursive domain
// warping for the classic version of this idea.

const warp_freq_x: f64 = freq_x * 0.3;
const warp_freq_y: f64 = freq_y * 0.3;
const warp_freq_t: f64 = freq_t * 0.4;
const warp_octaves: u32 = 3;
const warp_feedback_strength: f64 = 5.0; // q -> r feedback; keep this gentle
const warp_strength: f64 = 24.0; // r -> final displacement -- THE swirliness knob

// --- Infinite zoom (an endless dive into the noise field) ------------------
//
// The coordinate fed to the main noise fields is continuously divided by a
// growing zoom factor, like pushing the camera into the picture forever.
// A fixed-octave noise field can't literally supply new detail forever
// though (see `sampleFields`'s doc comment for why), so this is faked with
// a classic "two crossfaded loops" trick: two independent zoom passes run
// out of phase with each other, each resetting back to 1x zoom right when
// it's fully faded out and invisible, while the other is mid-dive and
// fully visible. Because Perlin noise looks statistically the same
// everywhere, the handoff reads as "new fractal detail keeps revealing
// itself" rather than a reset. See
// https://en.wikipedia.org/wiki/Self-similarity.

const zoom_enabled: bool = true;
const zoom_cycle_seconds: f64 = 55.0; // how long one dive-and-reset cycle takes -- bigger = slower zoom
const zoom_octaves_per_cycle: f64 = 3.2; // how many 2x-zoom-doublings happen per cycle (deeper dive per loop)

// --- Kaleidoscope (folds space into a rotating, repeating mandala) ---------
//
// Before anything else is sampled, space is mirrored into N pie-slice
// wedges around the screen center and slowly rotated. Whatever pattern
// comes out of the noise afterwards repeats N times around the center,
// self-similar at every radius.

const kaleido_enabled: bool = false; // flip to true to bring the mandala fold back
const kaleido_aspect: f64 = 2.0; // terminal cells are ~2x taller than wide
const kaleido_rotate_speed: f64 = 0.12; // radians/second -- the mandala's spin rate
const kaleido_segments_min: u32 = 4; // random symmetry count, picked fresh per run
const kaleido_segments_max: u32 = 7;

// --- Chromatic aberration (colored fringing, like a busted CRT/VHS dub) ----
//
// The red and blue channels are re-sampled at a small coordinate offset
// from the green channel, so edges of noise features bleed colored
// fringes. Pulses gently everywhere, blows out hard inside glitch bands.

const chroma_base: f64 = 1.6; // constant fringe amount, everywhere
const chroma_wobble: f64 = 1.6; // how much the fringe amount pulses
const chroma_wobble_speed: f64 = 0.9;
const chroma_band_extra: f64 = 20.0; // extra fringe amount inside glitch bands
const chroma_delta_scale: f64 = 0.6; // how strongly the offset sample affects brightness

// --- Character sets ----------------------------------------------------------

/// Density ramp used for "clean" (non-corrupted) cells, light to heavy.
const shade_ramp = " .:-=+*#%@";

/// "Character-set chaos": corrupted cells don't just get ASCII glitch
/// symbols, they pull from box-drawing, block, braille, and half-width
/// katakana glyphs too, for a denser, more alien "corrupted data" texture.
/// (Half-width katakana is used deliberately -- it's single-width in
/// terminals, unlike full-width CJK, so the grid alignment stays intact.)
const corruption_glyphs = [_][]const u8{
    "#", "%", "&", "@", "$", "?", "0", "1", "/", "\\", "<", ">", "~", "^",
    "░",
    "▒",
    "▓",
    "█",
    "▀",
    "▄",
    "▌",
    "▐",
    "■",
    "□",
    "┼",
    "╬",
    "╫",
    "╪",
    "┤",
    "├",
    "┬",
    "┴",
    "┌",
    "┐",
    "└",
    "┘",
    "⠋",
    "⠙",
    "⠹",
    "⠸",
    "⠼",
    "⠴",
    "⠦",
    "⠧",
    "⠇",
    "⠏",
    "⣿",
    "⠿",
    "ｱ",
    "ｳ",
    "ｴ",
    "ｶ",
    "ｷ",
    "ｹ",
    "ｻ",
    "ﾆ",
    "ﾊ",
    "ﾎ",
    "ﾒ",
    "ﾜ",
};

// --- Retro / 8-bit mode -----------------------------------------------------
//
// Reimagines the whole picture as if it were being drawn by an 8-bit game
// console instead of a modern truecolor terminal:
//   1. Chunky pixels -- the underlying noise is sampled on a coarse grid
//      (`retro_pixel_scale` cells per "native pixel") instead of once per
//      terminal cell, then that value is repeated across the block, like a
//      low native resolution blown up to fill the screen.
//   2. A fixed, tiny palette -- every color gets snapped to its nearest
//      match in `nes_palette` (see `nesNearestColor`) instead of using the
//      full 24-bit range.
//   3. Ordered dithering -- a Bayer matrix (see `bayerDither`) perturbs
//      each native pixel's color by a small, patterned amount before that
//      snap, which is the classic trick 8-bit-era graphics used to fake
//      more colors/gradients than their palette actually had.
//   4. Solid glyphs -- no ASCII shading ramp; every cell is a filled block,
//      since in palette-based pixel art the color *is* the pixel.
// Off by default; independent of every other mode/toggle above.

const retro_8bit_enabled: bool = false;
const retro_pixel_scale: u16 = 2; // terminal cells per "native" chunky pixel, in both axes
const retro_dither_strength: f64 = 24.0; // max +/- brightness (0-255 scale) the dither pattern adds
const retro_glyph = "█"; // every cell in retro mode renders as a solid block

/// The NES's master palette: every color the PPU could output, keyed by
/// the classic 6-bit (0x00-0x3F) palette index. Several indices
/// duplicate pure black/white (the PPU's palette is a 4x16 grid where
/// the last column of each row is unused/black), which is harmless here
/// -- `nesNearestColor` just never has a reason to prefer one of those
/// duplicates over another. See https://www.nesdev.org/wiki/PPU_palettes.
const nes_palette = [64][3]u8{
    .{ 84, 84, 84 },    .{ 0, 30, 116 },    .{ 8, 16, 144 },    .{ 48, 0, 136 },
    .{ 68, 0, 100 },    .{ 92, 0, 48 },     .{ 84, 4, 0 },      .{ 60, 24, 0 },
    .{ 32, 42, 0 },     .{ 8, 58, 0 },      .{ 0, 64, 0 },      .{ 0, 60, 0 },
    .{ 0, 50, 60 },     .{ 0, 0, 0 },       .{ 0, 0, 0 },       .{ 0, 0, 0 },
    .{ 152, 150, 152 }, .{ 8, 76, 196 },    .{ 48, 50, 236 },   .{ 92, 30, 228 },
    .{ 136, 20, 176 },  .{ 160, 20, 100 },  .{ 152, 34, 32 },   .{ 120, 60, 0 },
    .{ 84, 90, 0 },     .{ 40, 114, 0 },    .{ 8, 124, 0 },     .{ 0, 118, 40 },
    .{ 0, 102, 120 },   .{ 0, 0, 0 },       .{ 0, 0, 0 },       .{ 0, 0, 0 },
    .{ 236, 238, 236 }, .{ 76, 154, 236 },  .{ 120, 124, 236 }, .{ 176, 98, 236 },
    .{ 228, 84, 236 },  .{ 236, 88, 180 },  .{ 236, 106, 100 }, .{ 212, 136, 32 },
    .{ 160, 170, 0 },   .{ 116, 196, 0 },   .{ 76, 208, 32 },   .{ 56, 204, 108 },
    .{ 56, 180, 204 },  .{ 60, 60, 60 },    .{ 0, 0, 0 },       .{ 0, 0, 0 },
    .{ 236, 238, 236 }, .{ 168, 204, 236 }, .{ 188, 188, 236 }, .{ 212, 178, 236 },
    .{ 236, 174, 236 }, .{ 236, 174, 212 }, .{ 236, 180, 176 }, .{ 228, 196, 144 },
    .{ 204, 210, 120 }, .{ 180, 222, 120 }, .{ 168, 226, 144 }, .{ 152, 226, 180 },
    .{ 160, 214, 228 }, .{ 160, 162, 160 }, .{ 0, 0, 0 },       .{ 0, 0, 0 },
};

/// Classic 4x4 ordered (Bayer) dithering matrix
/// (https://en.wikipedia.org/wiki/Dither#Ordered_dithering): each entry is
/// a threshold, spread as evenly as possible over its 4x4 tile so that
/// repeating this pattern across the screen simulates intermediate
/// brightness levels a limited palette can't represent directly.
const bayer_dither_4x4 = [4][4]u8{
    .{ 0, 8, 2, 10 },
    .{ 12, 4, 14, 6 },
    .{ 3, 11, 1, 9 },
    .{ 15, 7, 13, 5 },
};

/// Looks up a Bayer threshold for native-pixel coordinates `(px, py)`
/// (already divided down by `retro_pixel_scale`) and rescales it to
/// `+/- retro_dither_strength/2`, ready to add straight onto an 0-255
/// color channel before quantizing.
fn bayerDither(px: u16, py: u16) f64 {
    const level = bayer_dither_4x4[py % 4][px % 4];
    return (@as(f64, @floatFromInt(level)) / 15.0 - 0.5) * retro_dither_strength;
}

/// Clamps `v` to `[0, 255]` and rounds it to a `u8`, for snapping
/// dithered color math back into byte range before palette lookup.
fn clampToU8(v: f64) u8 {
    return @intFromFloat(std.math.clamp(@round(v), 0, 255));
}

/// Finds the closest color in `nes_palette` to `(r, g, b)` by squared
/// Euclidean distance in RGB space. A plain linear scan is plenty fast
/// here -- the palette only has 64 entries and this only runs when
/// `retro_8bit_enabled` is on.
fn nesNearestColor(r: u8, g: u8, b: u8) [3]u8 {
    var best_i: usize = 0;
    var best_dist: i32 = std.math.maxInt(i32);
    for (nes_palette, 0..) |c, i| {
        const dr = @as(i32, r) - @as(i32, c[0]);
        const dg = @as(i32, g) - @as(i32, c[1]);
        const db = @as(i32, b) - @as(i32, c[2]);
        const dist = dr * dr + dg * dg + db * db;
        if (dist < best_dist) {
            best_dist = dist;
            best_i = i;
        }
    }
    return nes_palette[best_i];
}

// --- Glitch bands (short-lived horizontal "tears" across the screen) -------

/// Master switch for all the "glitch" artifacts: bands (tearing, hue
/// shift, invert, pixel sorting, corrupted glyphs) and ambient static.
/// Off by default -- flip to true to bring the glitches back. The base
/// picture (Perlin flow field, domain warp, infinite zoom, chromatic
/// aberration, Lorenz-driven drift) is unaffected either way; a keypress
/// burst still won't spawn anything while this is off.
const glitch_enabled: bool = false;

const max_bands = 12; // how many bands can be active at once
const band_spawn_chance: f64 = 0.09; // chance per frame a new band appears on its own
const band_height_min: u16 = 1; // band height, in rows
const band_height_max: u16 = 3;
const band_shift_min: i32 = 3; // how far sideways a band shifts its rows, in cells
const band_shift_max: i32 = 14;
const band_life_min: i32 = 2; // how many frames a band lives (plus its `intensity`)
const band_life_max: i32 = 8;

// --- Pixel sorting (inside glitch bands) ------------------------------------
//
// Sorts a contiguous run of a band's already-rendered cells by brightness,
// producing streaky, melted-looking smears -- the classic "databending"
// effect.

const sort_chance: f64 = 0.88; // chance a spawned band also pixel-sorts
const sort_min_len_divisor: u16 = 2; // sorted run is at least (row width / this)

// --- Corruption / static -----------------------------------------------------

const band_corruption_chance: f64 = 0.5; // per-cell chance of a glitch glyph inside a band
const band_corruption_brightness_boost: f64 = 0.5;
const ambient_static_chance: f64 = 0.01; // per-cell chance of random static outside bands
const ambient_static_brightness_base: f64 = 0.6;
const ambient_static_brightness_range: f64 = 0.4;

// --- Keyboard-triggered burst -------------------------------------------------

const burst_band_count: u32 = 5; // how many bands a keypress spawns at once
const burst_band_intensity: i32 = 10; // extra lifetime given to burst-spawned bands
const burst_flash_frames: i32 = 6; // how many frames the screen-wide flash lasts
const flash_hue_shift_deg: f64 = 180.0;
const flash_brightness_boost: f64 = 0.3;

// --- Bubbles (drift up from the bottom and float off the top) --------------
//
// Small, faint circles that spawn at the bottom edge, rise slowly, sway
// gently side to side, and disappear once they've floated off the top.
// Purely a screen-space overlay applied after everything else (like the
// flash), so they sit "on top of" the noise/warp/zoom picture rather than
// perturbing it -- independent of `glitch_enabled`, since these aren't a
// glitch effect. Kept deliberately subtle and small for now; the knobs
// below are there to dial that up later.

const bubbles_enabled: bool = false;
const max_bubbles: u32 = 14; // how many can be on screen at once
const bubble_spawn_chance: f64 = 0.1; // chance per frame a new bubble appears at the bottom
const bubble_radius_min: f64 = 2.5; // radius in columns (see `bubbleEffectAt` for the aspect correction)
const bubble_radius_max: f64 = 4.5;
const bubble_rise_speed_min: f64 = 1.2; // rows/second -- how fast they float upward
const bubble_rise_speed_max: f64 = 9.0; // wide range: some drift lazily, some shoot up fast
const bubble_sway_amount_max: f64 = 2.0; // columns of side-to-side wobble as it rises
const bubble_sway_speed_min: f64 = 0.4; // radians/second
const bubble_sway_speed_max: f64 = 1.2;
const bubble_rim_thickness: f64 = 0.35; // fraction of the radius that renders as a bright "rim"
const bubble_rim_boost: f64 = 0.3; // brightness boost at the rim -- the shiny highlight
const bubble_fill_boost: f64 = 0.06; // gentle brightness boost inside -- keep subtle
const bubble_fill_desat: f64 = 0.12; // slightly washes out color inside/at a bubble
const bubble_glyph = "o"; // rim glyph -- plain and small on purpose

// --- Bubble collisions (pop into an expanding flash when two touch) --------

const bubble_collision_enabled: bool = true;
const max_explosions: u32 = 12; // concurrent burst effects
const explosion_life: f64 = 0.5; // seconds a burst ring takes to expand and fade out
const explosion_radius_mult: f64 = 1.7; // burst's max radius, relative to the colliding bubbles' combined radius
const explosion_ring_thickness: f64 = 1.6; // columns -- thickness of the expanding shockwave ring
const explosion_boost: f64 = 0.85; // brightness at the ring, fading to 0 over its life
const explosion_desat: f64 = 0.7; // how much the ring flashes toward white as it expands
const explosion_glyph = "*"; // burst glyph

// --- Chaos driver (a Lorenz attractor slowly warps some of the knobs above) -
//
// The classic chaotic ODE system (https://en.wikipedia.org/wiki/Lorenz_system)
// is integrated every frame; its three coordinates, each squashed to
// roughly [-1, 1], are used as `base +- amplitude` modulation for a few of
// the settings above. Unlike the Perlin noise everywhere else, this is a
// single global signal (not per-pixel) and it's a real dynamical system,
// not randomness: it's smooth and deterministic, it never exactly
// repeats, and it has actual structure -- it orbits one "wing" of the
// butterfly for a while, then unpredictably flips to the other -- so the
// knobs it drives drift for a bit and then occasionally lurch, rather
// than just jittering.

const lorenz_enabled: bool = false;
const lorenz_sigma: f64 = 10.0; // the attractor's classic parameters --
const lorenz_rho: f64 = 28.0; // these three specific values are what make
const lorenz_beta: f64 = 8.0 / 3.0; // it chaotic rather than settling down
const lorenz_time_scale: f64 = 0.5; // how fast simulated chaos-time runs vs. real seconds
const lorenz_step: f64 = 0.006; // fixed integration substep -- keep small, it's stiff-ish

// Roughly-observed extents of the classic attractor's two wings, used to
// squash its (x, y, z) into ~[-1, 1] before anything below uses them.
const lorenz_x_extent: f64 = 20.0;
const lorenz_y_extent: f64 = 27.0;
const lorenz_z_center: f64 = 25.0;
const lorenz_z_extent: f64 = 25.0;

// Which knobs the attractor drives, and by how much (added on top of the
// base value above, so e.g. the swirliness ranges roughly
// warp_strength +- chaos_warp_strength_amp).
const chaos_warp_strength_amp: f64 = 16.0; // swirliness breathing in and out
const chaos_chroma_amp: f64 = 2.5; // aberration intensity swings
const chaos_hue_drift_amp: f64 = 40.0; // hue speed sometimes surges or reverses
const chaos_band_spawn_amp: f64 = 0.06; // glitchiness surges during turbulent moments

// ============================================================================
// Everything below here is plumbing.
// ============================================================================

// ---------------------------------------------------------------------------
// Shared state between the render loop and the input-reading thread.
// ---------------------------------------------------------------------------

var quit_requested = std.atomic.Value(bool).init(false);
var burst_requests = std.atomic.Value(u32).init(0);

/// Runs on its own OS thread for the whole program's lifetime, blocked on
/// `read()` of stdin. `posix.read` here blocks the calling thread only,
/// so doing this on a background thread is what lets the render loop in
/// `main` keep animating at a steady frame rate instead of freezing
/// while waiting for a keypress. Quit keys set `quit_requested`; any
/// other key increments `burst_requests`; both are `std.atomic.Value`s
/// so the render loop can read them without a lock.
fn inputThreadMain() void {
    var byte: [1]u8 = undefined;
    while (true) {
        const n = posix.read(posix.STDIN_FILENO, &byte) catch return;
        if (n == 0) return;
        switch (byte[0]) {
            'q', 'Q', 0x03 => {
                quit_requested.store(true, .seq_cst);
                return;
            },
            else => {
                _ = burst_requests.fetchAdd(1, .seq_cst);
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Terminal setup helpers
// ---------------------------------------------------------------------------

/// Switches the terminal from the default "cooked"/canonical mode into
/// raw mode, and returns the original settings so the caller can restore
/// them on exit. In canonical mode the kernel line-buffers input (it
/// waits for Enter, handles Ctrl+C itself, echoes what you type, etc);
/// raw mode disables all of that so every keypress reaches `read()`
/// immediately and unprocessed, which is what lets `inputThreadMain`
/// react to a single keystroke instead of a whole line. Implemented via
/// POSIX `termios` flags (see
/// https://en.wikipedia.org/wiki/POSIX_terminal_interface).
fn enableRawMode() !posix.termios {
    const original = try posix.tcgetattr(posix.STDIN_FILENO);
    var raw = original;

    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;

    raw.oflag.OPOST = false;

    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;

    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
    return original;
}

const TermSize = struct { rows: u16, cols: u16 };

/// Asks the kernel for the terminal's current size via the `TIOCGWINSZ`
/// `ioctl` request (https://en.wikipedia.org/wiki/Ioctl) -- there's no
/// regular read/write/seek call for "how big is this terminal", so
/// `ioctl` is the standard escape hatch for this kind of device-specific
/// query. Falls back to a plausible default (80x24) if the call fails,
/// e.g. because stdout isn't actually a terminal.
fn terminalSize() TermSize {
    var ws: posix.winsize = undefined;
    const rc = std.c.ioctl(posix.STDOUT_FILENO, @intCast(std.c.T.IOCGWINSZ), &ws);
    if (rc != 0 or ws.row == 0 or ws.col == 0) return .{ .rows = 24, .cols = 80 };
    return .{ .rows = ws.row, .cols = ws.col };
}

// ---------------------------------------------------------------------------
// Color helpers
// ---------------------------------------------------------------------------

/// Clamps `v` into [0, 1]. Noise and color math throughout this file can
/// briefly overshoot the valid range (e.g. after adding a brightness
/// boost), so results get squeezed back before being turned into a color.
fn clamp01(v: f64) f64 {
    return @max(0.0, @min(1.0, v));
}

/// Converts an HSV color (hue in degrees, saturation/value in [0, 1])
/// into 8-bit RGB. The noise fields naturally produce a single scalar
/// "how strong is this" number per pixel, and it's much easier to turn
/// that into a pleasing, evenly-bright rainbow of colors by driving *hue*
/// with it (an angle around a color wheel) than by driving RGB directly.
/// See https://en.wikipedia.org/wiki/HSL_and_HSV.
fn hsvToRgb(hue_deg: f64, sat: f64, val: f64) [3]u8 {
    const h = @mod(hue_deg, 360.0) / 60.0;
    const c = val * sat;
    const x = c * (1.0 - @abs(@mod(h, 2.0) - 1.0));
    const m = val - c;

    var r: f64 = 0;
    var g: f64 = 0;
    var b: f64 = 0;

    if (h < 1.0) {
        r = c;
        g = x;
    } else if (h < 2.0) {
        r = x;
        g = c;
    } else if (h < 3.0) {
        g = c;
        b = x;
    } else if (h < 4.0) {
        g = x;
        b = c;
    } else if (h < 5.0) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }

    return .{
        @intFromFloat(@round((r + m) * 255.0)),
        @intFromFloat(@round((g + m) * 255.0)),
        @intFromFloat(@round((b + m) * 255.0)),
    };
}

// ---------------------------------------------------------------------------
// Fractal helpers: a folded, rotating kaleidoscope of space, and a
// recursive (feedback) domain warp sampled inside it.
// ---------------------------------------------------------------------------

/// Mirrors (x, y) into one `segments`-th slice of the circle around
/// (cx, cy), then rotates the whole thing over time. The result is that
/// whatever gets sampled downstream repeats `segments` times around the
/// center, like a mandala.
///
/// Technique: convert to polar coordinates
/// (https://en.wikipedia.org/wiki/Polar_coordinate_system) around the
/// center, subtract the current rotation from the angle, then fold the
/// angle into the first half of one `2*pi/segments` wedge (`@mod` plus a
/// reflection when past the wedge's midline). Converting back to
/// Cartesian afterwards means every wedge of the circle now samples the
/// *same* patch of the noise field, which is exactly the repeated,
/// mirror-symmetric imagery a real kaleidoscope produces with angled
/// mirrors -- see https://en.wikipedia.org/wiki/Kaleidoscope. The
/// `kaleido_aspect` scaling corrects for terminal cells being taller
/// than they are wide, so the wedges look regular instead of squashed.
fn kaleidoscopeFold(x: f64, y: f64, cx: f64, cy: f64, segments: f64, rotation: f64) [2]f64 {
    const dx = x - cx;
    const dy = (y - cy) * kaleido_aspect;

    const radius = @sqrt(dx * dx + dy * dy);
    var angle = std.math.atan2(dy, dx) - rotation;

    const slice = std.math.pi * 2.0 / segments;
    angle = @mod(angle, slice);
    if (angle > slice * 0.5) angle = slice - angle;

    return .{
        cx + @cos(angle) * radius,
        cy + (@sin(angle) * radius) / kaleido_aspect,
    };
}

/// One octave-bundle of the recursive domain warp: a noise field sampled
/// at (x, y, time), offset so that different calls don't correlate.
/// `off_x`/`off_y` just shift where in the noise field each call looks,
/// the cheapest way to get several "independent-looking" fields out of
/// one noise function.
fn warpField(x: f64, y: f64, tt: f64, off_x: f64, off_y: f64) f64 {
    return noise.fbm3(x * warp_freq_x + off_x, y * warp_freq_y + off_y, tt * warp_freq_t, warp_octaves, 0.5);
}

/// Recursive domain warp: `q` warps (x, y), then `r` warps (x, y) by `q`,
/// then the returned displacement warps (x, y) by `r`. Each level feeds
/// the next, so the resulting distortion is self-similar at multiple
/// scales instead of a single bend.
///
/// Technique: "domain warping" means distorting the *input coordinates*
/// to a noise function with another noise function, rather than
/// distorting its output -- instead of a plain drifting blob field, the
/// coordinates themselves get pushed around, producing swirls and
/// tendrils. Doing this recursively (feeding one warp's output as the
/// next warp's input, as here) is a small
/// https://en.wikipedia.org/wiki/Iterated_function_system -- repeatedly
/// composing the same kind of function with itself -- which is also
/// what makes classic fractals like the Mandelbrot set and IFS fractals
/// self-similar across scales (https://en.wikipedia.org/wiki/Fractal).
/// The underlying field being warped is `fbm3`'s fractal Brownian motion
/// (https://en.wikipedia.org/wiki/Fractional_Brownian_motion), so this
/// function stacks two different "fractal" ideas on top of each other.
///
/// `strength` scales the final displacement -- normally just
/// `warp_strength`, but `main` lets the Lorenz chaos driver breathe it up
/// and down over time instead of passing a flat constant.
fn recursiveWarp(x: f64, y: f64, t: f64, strength: f64) [2]f64 {
    const qx = warpField(x, y, t, 0.0, 0.0);
    const qy = warpField(x, y, t + 4.0, 91.7, 91.7);

    const rx = warpField(x + qx * warp_feedback_strength, y + qy * warp_feedback_strength, t + 8.0, 17.0, 17.0);
    const ry = warpField(x + qx * warp_feedback_strength, y + qy * warp_feedback_strength, t + 12.0, 108.0, 108.0);

    return .{ rx * strength, ry * strength };
}

// ---------------------------------------------------------------------------
// Chaos driver: a Lorenz attractor, integrated in real time, whose
// coordinates modulate a few of the TUNABLES above (see the "Chaos
// driver" section) so they drift and occasionally lurch instead of
// sitting at a flat constant.
// ---------------------------------------------------------------------------

/// State of the chaotic system (https://en.wikipedia.org/wiki/Lorenz_system):
///
///   dx/dt = sigma * (y - x)
///   dy/dt = x * (rho - z) - y
///   dz/dt = x * y - beta * z
///
/// With the classic (sigma=10, rho=28, beta=8/3) parameters this famously
/// never settles into a fixed point or a repeating cycle: it endlessly
/// circles one of two "wings" of the attractor and unpredictably jumps to
/// the other, while staying deterministic and bounded -- small, smooth,
/// structured motion rather than random jitter, which is exactly what
/// makes it interesting as a modulation source instead of just another
/// noise field.
const Lorenz = struct {
    x: f64 = 0.1,
    y: f64 = 0.0,
    z: f64 = 0.0,

    fn deriv(x: f64, y: f64, z: f64) [3]f64 {
        return .{
            lorenz_sigma * (y - x),
            x * (lorenz_rho - z) - y,
            x * y - lorenz_beta * z,
        };
    }

    /// Advances the system by `dt` chaos-time using fixed-size RK4 steps
    /// (https://en.wikipedia.org/wiki/Runge%E2%80%93Kutta_methods) --
    /// simple Euler integration would work too, but this system is
    /// "stiff" enough that Euler needs punishingly small steps to stay
    /// bounded; RK4 stays accurate at a much larger, cheaper step size.
    /// Returns the new (x, y, z), each squashed to roughly [-1, 1] using
    /// the attractor's typical extents (`lorenz_*_extent`).
    fn step(self: *Lorenz, dt: f64) [3]f64 {
        var remaining = dt;
        while (remaining > 1e-9) {
            const h = @min(lorenz_step, remaining);

            const k1 = deriv(self.x, self.y, self.z);
            const k2 = deriv(self.x + k1[0] * h * 0.5, self.y + k1[1] * h * 0.5, self.z + k1[2] * h * 0.5);
            const k3 = deriv(self.x + k2[0] * h * 0.5, self.y + k2[1] * h * 0.5, self.z + k2[2] * h * 0.5);
            const k4 = deriv(self.x + k3[0] * h, self.y + k3[1] * h, self.z + k3[2] * h);

            self.x += (k1[0] + 2.0 * k2[0] + 2.0 * k3[0] + k4[0]) * (h / 6.0);
            self.y += (k1[1] + 2.0 * k2[1] + 2.0 * k3[1] + k4[1]) * (h / 6.0);
            self.z += (k1[2] + 2.0 * k2[2] + 2.0 * k3[2] + k4[2]) * (h / 6.0);

            remaining -= h;
        }

        return .{
            @max(-1.5, @min(1.5, self.x / lorenz_x_extent)),
            @max(-1.5, @min(1.5, self.y / lorenz_y_extent)),
            @max(-1.5, @min(1.5, (self.z - lorenz_z_center) / lorenz_z_extent)),
        };
    }
};

// ---------------------------------------------------------------------------
// Infinite zoom: two crossfaded "dives" into the noise field, so the whole
// picture endlessly zooms in without ever visibly resetting or running out
// of detail. See the "Infinite zoom" TUNABLES comment for the idea.
// ---------------------------------------------------------------------------

/// One of the two crossfaded zoom passes at a single instant: `scale`
/// divides the sampled coordinate (bigger scale = deeper zoom), `offset`
/// shifts to a fresh, never-before-seen patch of the noise field each
/// cycle, and `weight` (0..1) is how visible this pass currently is.
const ZoomLayer = struct {
    weight: f64 = 1,
    scale: f64 = 1,
    offset: f64 = 0,
};

/// Computes one zoom pass `phase_offset` (0..1) out of sync with the
/// other. Both passes share the same `zoom_cycle_seconds` period but are
/// offset by half a cycle, so that whenever one is at its own seam
/// (`weight == 0`, about to snap from deepest zoom back to 1x) the other
/// is at the midpoint of its dive (`weight == 1`, fully visible and nowhere
/// near its own seam) -- the reset only ever happens while unseen.
fn zoomLayer(t: f64, phase_offset: f64) ZoomLayer {
    const cycle_pos = t / zoom_cycle_seconds + phase_offset;
    const cycle_index = @floor(cycle_pos);
    const phase = cycle_pos - cycle_index; // fract(cycle_pos), always in [0, 1)

    return .{
        // Triangle envelope: 0 at phase 0 and 1 (the seam), 1 at phase 0.5
        // (dead center of the dive, as far from either seam as possible).
        .weight = 1.0 - @abs(2.0 * phase - 1.0),
        // Grows from 1x at the start of the dive to 2^zoom_octaves_per_cycle
        // at the end, right before it resets.
        .scale = std.math.pow(f64, 2.0, phase * zoom_octaves_per_cycle),
        // A different, arbitrary patch of the (conceptually infinite)
        // noise field each cycle, so consecutive dives never repeat.
        .offset = cycle_index * 1013.0,
    };
}

const ZoomedFields = struct { hue_n: f64, val_n: f64, detail_n: f64 };

/// Samples the hue/brightness/detail noise fields that drive a pixel's
/// color, optionally blended between two zoom layers.
///
/// Why blending is needed at all: a finite-octave `fbm3` has a fixed
/// smallest visible feature size. Dividing the sampled coordinate by an
/// ever-growing zoom factor to "zoom in" pushes every existing octave's
/// apparent on-screen frequency toward zero -- exactly like walking up to
/// a wall mural, every brushstroke you could once see eventually looks
/// like a single flat color once you're a millimeter from it. There's no
/// finer detail *defined* beyond the last octave to reveal instead. Real
/// infinite fractals (Mandelbrot, etc.) sidestep this because they're
/// defined by literal infinite recursion; noise octaves are not.
///
/// The fix used here is cheaper than adding ever-more octaves forever:
/// run two independent zoom passes out of phase (`layer_a`/`layer_b`,
/// see `zoomLayer`) and crossfade between their results. Each pass zooms
/// for one cycle, then -- right as it finishes fading to invisible --
/// resets back to a shallow, richly-detailed 1x zoom and starts again
/// from a fresh patch of the field. Because Perlin/fBm noise is
/// statistically stationary (it looks equally "detailed" everywhere), the
/// swap reads as newly-revealed fractal detail rather than a loop. With
/// `zoom_enabled = false` this degrades to a single plain sample, exactly
/// the pre-zoom behavior.
fn sampleFields(wx: f64, wy: f64, t: f64, layer_a: ZoomLayer, layer_b: ZoomLayer) ZoomedFields {
    if (!zoom_enabled) {
        return .{
            .hue_n = noise.fbm3(wx * freq_x, wy * freq_y, t * freq_t, hue_octaves, 0.5),
            .val_n = noise.fbm3(wx * freq_x * 1.7 + 50, wy * freq_y * 1.7 + 50, t * freq_t * 1.3, brightness_octaves, 0.5),
            .detail_n = noise.fbm3(wx * freq_x * 0.5 + 300, wy * freq_y * 0.5 + 300, t * freq_t * 0.6, detail_octaves, 0.5),
        };
    }

    const ax = wx / layer_a.scale + layer_a.offset;
    const ay = wy / layer_a.scale + layer_a.offset;
    const bx = wx / layer_b.scale + layer_b.offset;
    const by = wy / layer_b.scale + layer_b.offset;

    return .{
        .hue_n = layer_a.weight * noise.fbm3(ax * freq_x, ay * freq_y, t * freq_t, hue_octaves, 0.5) +
            layer_b.weight * noise.fbm3(bx * freq_x, by * freq_y, t * freq_t, hue_octaves, 0.5),
        .val_n = layer_a.weight * noise.fbm3(ax * freq_x * 1.7 + 50, ay * freq_y * 1.7 + 50, t * freq_t * 1.3, brightness_octaves, 0.5) +
            layer_b.weight * noise.fbm3(bx * freq_x * 1.7 + 50, by * freq_y * 1.7 + 50, t * freq_t * 1.3, brightness_octaves, 0.5),
        .detail_n = layer_a.weight * noise.fbm3(ax * freq_x * 0.5 + 300, ay * freq_y * 0.5 + 300, t * freq_t * 0.6, detail_octaves, 0.5) +
            layer_b.weight * noise.fbm3(bx * freq_x * 0.5 + 300, by * freq_y * 0.5 + 300, t * freq_t * 0.6, detail_octaves, 0.5),
    };
}

// ---------------------------------------------------------------------------
// A single rendered terminal cell, buffered per-row so effects like pixel
// sorting can see (and reorder) a whole run of cells before anything is
// written out.
// ---------------------------------------------------------------------------

const Cell = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    glyph: []const u8 = " ",
    /// Perceptual brightness of (r, g, b), used to order cells for pixel
    /// sorting. Computed with the ITU-R BT.601 luma weights
    /// (0.299R + 0.587G + 0.114B) rather than a plain average, because
    /// human vision is much more sensitive to green than red or blue --
    /// see https://en.wikipedia.org/wiki/Luma_(video).
    luma: f64 = 0,
};

// ---------------------------------------------------------------------------
// Glitch bands: short-lived horizontal "tears" across the screen.
// ---------------------------------------------------------------------------

/// A short-lived horizontal "tear": a run of rows that, while active,
/// gets rendered with a sideways pixel shift, a hue rotation, optional
/// color inversion, per-cell glyph corruption, and (sometimes) pixel
/// sorting. `Bands` (below) owns a fixed pool of these and recycles
/// expired ones. See `Bands.spawn`.
const GlitchBand = struct {
    row_start: u16 = 0,
    height: u16 = 0,
    x_shift: i32 = 0,
    hue_shift: f64 = 0,
    invert: bool = false,
    frames_left: i32 = 0,
    // Pixel sorting: sort a contiguous run of the row's already-rendered
    // cells by brightness, producing streaky, melted-looking smears --
    // the classic "databending" effect.
    sort: bool = false,
    sort_start: u16 = 0,
    sort_len: u16 = 0,
    sort_desc: bool = false,
};

const Bands = struct {
    slots: [max_bands]GlitchBand = [_]GlitchBand{.{}} ** max_bands,

    /// Ages every active band by one frame, letting expired ones
    /// (`frames_left` reaching 0) become free slots for `spawn` to reuse.
    fn tick(self: *Bands) void {
        for (&self.slots) |*band| {
            if (band.frames_left > 0) band.frames_left -= 1;
        }
    }

    /// Fills the first free (expired) slot with a freshly randomized
    /// band: a horizontal strip that gets shifted sideways, hue-rotated,
    /// optionally inverted, and possibly marked for pixel sorting (see
    /// `lumaLessThan`/`lumaGreaterThan`). Modeling glitches as short-lived
    /// "damaged strips" like this evokes the look of corrupted video
    /// signals and databent image/media files -- see
    /// https://en.wikipedia.org/wiki/Glitch_art. Does nothing if every
    /// slot is already occupied.
    fn spawn(self: *Bands, random: std.Random, rows: u16, cols: u16, intensity: i32) void {
        for (&self.slots) |*band| {
            if (band.frames_left > 0) continue;
            band.row_start = random.intRangeLessThan(u16, 0, rows);
            band.height = random.intRangeAtMost(u16, band_height_min, band_height_max);
            const shift_mag = random.intRangeAtMost(i32, band_shift_min, band_shift_max);
            band.x_shift = if (random.boolean()) shift_mag else -shift_mag;
            band.hue_shift = random.float(f64) * 360.0;
            band.invert = random.boolean();
            band.frames_left = intensity + random.intRangeAtMost(i32, band_life_min, band_life_max);

            band.sort = random.float(f64) < sort_chance;
            if (band.sort and cols > 4) {
                band.sort_start = random.intRangeLessThan(u16, 0, cols - 4);
                const max_len = cols - band.sort_start;
                const min_len = @max(4, max_len / sort_min_len_divisor);
                band.sort_len = random.intRangeAtMost(u16, min_len, max_len);
                band.sort_desc = random.boolean();
            } else {
                band.sort_len = 0;
            }
            return;
        }
    }

    /// Returns the active band (if any) covering terminal row `row`, so
    /// the renderer knows whether/how to distort that row.
    fn effectAt(self: *const Bands, row: u16) ?GlitchBand {
        for (self.slots) |band| {
            if (band.frames_left <= 0) continue;
            if (row >= band.row_start and row < band.row_start + band.height) return band;
        }
        return null;
    }
};

/// Comparator for ascending-brightness pixel sorting: `std.mem.sort`
/// with this reorders a run of cells from darkest to lightest.
///
/// Technique ("pixel sorting"): take a contiguous run of already-rendered
/// pixels/cells and reorder them by some property (here, brightness)
/// instead of leaving them in raster order. Because neighboring noise
/// samples tend to have similar brightness, sorting doesn't scramble the
/// image into noise -- it produces long, smooth brightness gradients that
/// look like the image has been smeared or melted sideways, a signature
/// look in glitch art / databending. See
/// https://en.wikipedia.org/wiki/Glitch_art.
fn lumaLessThan(_: void, a: Cell, b: Cell) bool {
    return a.luma < b.luma;
}

/// Same as `lumaLessThan` but descending (lightest to darkest), used for
/// variety so not every sorted band streaks in the same direction.
fn lumaGreaterThan(_: void, a: Cell, b: Cell) bool {
    return a.luma > b.luma;
}

// ---------------------------------------------------------------------------
// Bubbles: small circles that percolate up from the bottom and float off.
// ---------------------------------------------------------------------------

/// One drifting bubble. Position is tracked in fractional screen-space:
/// `x` in columns, `y` in rows, both counting from the top-left like the
/// terminal grid itself. `y` decreases every frame (rising); `x` gets a
/// gentle sinusoidal wobble (see `bubbleEffectAt`) rather than a random
/// walk, so the motion reads as "floaty" instead of jittery.
const Bubble = struct {
    x: f64 = 0,
    y: f64 = 0,
    radius: f64 = 0,
    rise_speed: f64 = 0,
    sway_amount: f64 = 0,
    sway_speed: f64 = 0,
    sway_phase: f64 = 0,
    alive: bool = false,
};

/// The result of testing a screen cell against the bubble pool: whether
/// it landed on a bubble's bright "rim" or its fainter interior, plus how
/// much to nudge that cell's brightness/saturation.
const BubbleEffect = struct {
    rim: bool,
    val_boost: f64,
    desat: f64,
};

const Bubbles = struct {
    slots: [max_bubbles]Bubble = [_]Bubble{.{}} ** max_bubbles,

    /// Advances every alive bubble upward by `rise_speed * dt` rows, and
    /// retires any that have fully floated off the top of the screen
    /// (freeing its slot for `spawn` to reuse).
    fn tick(self: *Bubbles, dt: f64) void {
        for (&self.slots) |*bub| {
            if (!bub.alive) continue;
            bub.y -= bub.rise_speed * dt;
            if (bub.y + bub.radius < 0) bub.alive = false;
        }
    }

    /// Fills the first free slot with a freshly randomized bubble
    /// starting just below the bottom edge, so it appears to "percolate
    /// up" into view rather than popping in already fully formed. Does
    /// nothing if every slot is already occupied (this is what keeps the
    /// on-screen count capped at `max_bubbles`).
    fn spawn(self: *Bubbles, random: std.Random, rows: u16, cols: u16) void {
        for (&self.slots) |*bub| {
            if (bub.alive) continue;
            bub.alive = true;
            bub.x = random.float(f64) * @as(f64, @floatFromInt(cols));
            bub.y = @as(f64, @floatFromInt(rows - 1)) + random.float(f64);
            bub.radius = bubble_radius_min + random.float(f64) * (bubble_radius_max - bubble_radius_min);
            bub.rise_speed = bubble_rise_speed_min + random.float(f64) * (bubble_rise_speed_max - bubble_rise_speed_min);
            bub.sway_amount = random.float(f64) * bubble_sway_amount_max;
            bub.sway_speed = bubble_sway_speed_min + random.float(f64) * (bubble_sway_speed_max - bubble_sway_speed_min);
            bub.sway_phase = random.float(f64) * std.math.pi * 2.0;
            return;
        }
    }

    /// Checks every pair of alive bubbles for overlap (their visual,
    /// swayed centers -- same convention as `bubbleEffectAt` -- within
    /// the sum of their radii) and "pops" any that touch: both are
    /// killed and an `Explosion` is spawned at their midpoint, sized off
    /// their combined radius. O(max_bubbles^2), but that pool is small
    /// (tens of slots) so this is cheap to run once per frame.
    fn checkCollisions(self: *Bubbles, explosions: *Explosions, random: std.Random, t: f64) void {
        for (0..self.slots.len) |i| {
            const a = &self.slots[i];
            if (!a.alive) continue;
            const sway_a = @sin(t * a.sway_speed + a.sway_phase) * a.sway_amount;

            for (i + 1..self.slots.len) |j| {
                const b = &self.slots[j];
                if (!b.alive) continue;
                const sway_b = @sin(t * b.sway_speed + b.sway_phase) * b.sway_amount;

                const dx = (a.x + sway_a) - (b.x + sway_b);
                const dy = (a.y - b.y) * kaleido_aspect;
                const dist = @sqrt(dx * dx + dy * dy);
                if (dist > a.radius + b.radius) continue;

                explosions.spawn(
                    (a.x + sway_a + b.x + sway_b) * 0.5,
                    (a.y + b.y) * 0.5,
                    (a.radius + b.radius) * explosion_radius_mult,
                    random.float(f64) * 360.0,
                );
                a.alive = false;
                b.alive = false;
                break; // `a` is gone now -- move on to the next `i`
            }
        }
    }
};

/// Tests screen cell `(fx, fy)` against every alive bubble and reports
/// the strongest hit (rim beats fill; first match wins otherwise, which
/// is fine since bubbles are sparse and the effect is subtle).
///
/// Distance is computed the same way as `kaleidoscopeFold`'s aspect
/// correction: terminal cells are about twice as tall as they are wide,
/// so the vertical delta is scaled up by `kaleido_aspect` before taking
/// the Euclidean distance. Without that correction a "circle" measured
/// in raw row/column units would render as a tall oval.
fn bubbleEffectAt(bubbles: *const Bubbles, fx: f64, fy: f64, t: f64) ?BubbleEffect {
    for (bubbles.slots) |bub| {
        if (!bub.alive) continue;
        const sway = @sin(t * bub.sway_speed + bub.sway_phase) * bub.sway_amount;
        const dx = fx - (bub.x + sway);
        const dy = (fy - bub.y) * kaleido_aspect;
        const dist = @sqrt(dx * dx + dy * dy);
        if (dist > bub.radius) continue;

        const rim_start = bub.radius * (1.0 - bubble_rim_thickness);
        if (dist >= rim_start) {
            return .{ .rim = true, .val_boost = bubble_rim_boost, .desat = bubble_fill_desat * 0.5 };
        }
        return .{ .rim = false, .val_boost = bubble_fill_boost, .desat = bubble_fill_desat };
    }
    return null;
}

// ---------------------------------------------------------------------------
// Explosions: the flash left behind when two bubbles collide.
// ---------------------------------------------------------------------------

/// A single burst: an expanding, fading ring centered on where two
/// bubbles collided. `age`/`life` drive both the current radius (grows
/// from 0 to `max_radius` over its lifetime) and the brightness (starts
/// at full and fades to nothing), so it reads as a quick "pop" rather
/// than a static marker.
const Explosion = struct {
    x: f64 = 0,
    y: f64 = 0,
    max_radius: f64 = 0,
    age: f64 = 0,
    life: f64 = 0,
    hue: f64 = 0,
    alive: bool = false,
};

const ExplosionEffect = struct {
    hue_shift: f64,
    val_boost: f64,
    desat: f64,
};

const Explosions = struct {
    slots: [max_explosions]Explosion = [_]Explosion{.{}} ** max_explosions,

    /// Ages every active burst and retires ones that have finished
    /// expanding and fading (`age` reaching `life`).
    fn tick(self: *Explosions, dt: f64) void {
        for (&self.slots) |*ex| {
            if (!ex.alive) continue;
            ex.age += dt;
            if (ex.age >= ex.life) ex.alive = false;
        }
    }

    /// Fills the first free slot with a new burst at `(x, y)`. Called by
    /// `Bubbles.checkCollisions` when two bubbles touch; does nothing if
    /// every slot is already occupied.
    fn spawn(self: *Explosions, x: f64, y: f64, max_radius: f64, hue: f64) void {
        for (&self.slots) |*ex| {
            if (ex.alive) continue;
            ex.* = .{ .x = x, .y = y, .max_radius = max_radius, .age = 0, .life = explosion_life, .hue = hue, .alive = true };
            return;
        }
    }
};

/// Tests screen cell `(fx, fy)` against every alive burst. A burst is
/// only "hit" while the cell sits within its expanding ring (between
/// `cur_radius - explosion_ring_thickness` and `cur_radius`), which is
/// what makes it look like an outward-traveling shockwave rather than a
/// solid disc. Brightness/desaturation fade linearly with age, so the
/// ring dims out right as it stops expanding.
fn explosionEffectAt(explosions: *const Explosions, fx: f64, fy: f64) ?ExplosionEffect {
    for (explosions.slots) |ex| {
        if (!ex.alive) continue;
        const progress = clamp01(ex.age / ex.life);
        const cur_radius = ex.max_radius * progress;

        const dx = fx - ex.x;
        const dy = (fy - ex.y) * kaleido_aspect;
        const dist = @sqrt(dx * dx + dy * dy);
        if (dist > cur_radius or dist < cur_radius - explosion_ring_thickness) continue;

        const fade = 1.0 - progress;
        return .{ .hue_shift = ex.hue, .val_boost = explosion_boost * fade, .desat = explosion_desat * fade };
    }
    return null;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

/// Entry point: sets up the terminal and input thread, then runs the
/// render loop until quit is requested.
///
/// Per-frame pipeline for each cell, in order:
///   1. `bands.effectAt` -- is this row inside a glitch band, and if so
///      shift its x sample sideways (see `GlitchBand`).
///   2. `kaleidoscopeFold` -- fold the sample position into a rotating
///      mandala wedge.
///   3. `recursiveWarp` -- recursively warp that folded position into
///      swirls-within-swirls.
///   4. Three `noise.fbm3` calls turn the (folded, warped) position into
///      hue/brightness/detail scalars, which `hsvToRgb` turns into RGB.
///      Two extra offset brightness samples (`val_r_n`/`val_b_n`) produce
///      the chromatic aberration fringe (see below).
///   5. Band/static corruption and the keypress "flash" perturb hue/value
///      further and may replace the glyph with a `corruption_glyphs`
///      entry.
///   6. Once a whole row is buffered in `row_buf`, an active band may
///      pixel-sort a run of it (see `lumaLessThan`) before it's written
///      out with ANSI truecolor escapes
///      (https://en.wikipedia.org/wiki/ANSI_escape_code).
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const size = terminalSize();
    const rows = size.rows;
    const cols = size.cols;

    const frame_ns: u64 = @intFromFloat(1_000_000_000.0 / target_fps);

    const original_termios = try enableRawMode();
    defer posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original_termios) catch {};

    var stdout_buffer: [1 << 16]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    // ANSI/DEC private-mode escapes (https://en.wikipedia.org/wiki/ANSI_escape_code):
    // ?1049h switches to the alternate screen buffer (so the user's
    // previous terminal content is restored on exit instead of being
    // scrolled away), ?25l hides the cursor, and 2J clears the screen.
    // The `defer` below reverses both on exit.
    try out.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J");
    try out.flush();
    defer {
        out.writeAll("\x1b[?25h\x1b[?1049l") catch {};
        out.flush() catch {};
    }

    const input_thread = try std.Thread.spawn(.{}, inputThreadMain, .{});
    input_thread.detach();

    const seed: u64 = @truncate(@as(u96, @bitCast(Io.Timestamp.now(io, .real).nanoseconds)));
    noise.init(seed);
    var prng = std.Random.DefaultPrng.init(seed ^ 0x9e3779b97f4a7c15);
    const random = prng.random();

    var bands: Bands = .{};
    var flash_frames: i32 = 0;
    var bubbles: Bubbles = .{};
    var explosions: Explosions = .{};

    const row_buf = try init.arena.allocator().alloc(Cell, cols);

    // Pick a random mandala symmetry for this run.
    const kaleido_segments: f64 = @floatFromInt(random.intRangeAtMost(u32, kaleido_segments_min, kaleido_segments_max));
    const center_x: f64 = @as(f64, @floatFromInt(cols)) * 0.5;
    const center_y: f64 = @as(f64, @floatFromInt(rows)) * 0.5;

    var t: f64 = 0;
    var last = Io.Timestamp.now(io, .awake);

    // Nudge the Lorenz attractor off the exact origin (which is a fixed
    // point of the system -- it would just sit there forever) with a
    // small random offset, so every run's chaos drifts differently.
    var lorenz: Lorenz = .{
        .x = 0.1 + random.float(f64) * 2.0 - 1.0,
        .y = random.float(f64) * 2.0 - 1.0,
        .z = random.float(f64) * 2.0 - 1.0,
    };
    var hue_drift_deg: f64 = 0;

    // Randomize where in its cycle the zoom starts, so different runs
    // don't dive in lockstep. Both layers are shifted by the *same*
    // amount so they stay exactly half a cycle apart -- that fixed
    // separation is what keeps their crossfade seamless (see `zoomLayer`).
    const zoom_t_offset = random.float(f64) * zoom_cycle_seconds;

    while (!quit_requested.load(.seq_cst)) {
        const now = Io.Timestamp.now(io, .awake);
        const dt_ns = last.durationTo(now).nanoseconds;
        last = now;
        const dt: f64 = @as(f64, @floatFromInt(dt_ns)) / 1_000_000_000.0;
        const frame_dt = @min(dt, 0.1);
        t += frame_dt;

        // Step the chaos driver and turn its (x, y, z) into modulation
        // for a few of the TUNABLES above -- see "Chaos driver".
        const chaos = if (lorenz_enabled) lorenz.step(frame_dt * lorenz_time_scale) else [3]f64{ 0, 0, 0 };
        const warp_strength_now = warp_strength + chaos[0] * chaos_warp_strength_amp;
        const band_spawn_chance_now = @max(0.0, band_spawn_chance + chaos[2] * chaos_band_spawn_amp);
        hue_drift_deg += frame_dt * (hue_drift_deg_per_sec + chaos[2] * chaos_hue_drift_amp);

        // The two crossfaded infinite-zoom passes (see "Infinite zoom" and
        // `sampleFields`), recomputed once per frame since they don't vary
        // per-pixel.
        const zoom_t = t + zoom_t_offset;
        const zoom_a = zoomLayer(zoom_t, 0.0);
        const zoom_b = zoomLayer(zoom_t, 0.5);

        bands.tick();

        const bursts = burst_requests.swap(0, .seq_cst);
        if (glitch_enabled) {
            if (bursts > 0) {
                flash_frames = burst_flash_frames;
                var i: u32 = 0;
                while (i < burst_band_count) : (i += 1) bands.spawn(random, rows, cols, burst_band_intensity);
            } else if (random.float(f64) < band_spawn_chance_now) {
                bands.spawn(random, rows, cols, 0);
            }
        }
        if (flash_frames > 0) flash_frames -= 1;

        if (bubbles_enabled) {
            bubbles.tick(frame_dt);
            if (bubble_collision_enabled) bubbles.checkCollisions(&explosions, random, t);
            if (random.float(f64) < bubble_spawn_chance) bubbles.spawn(random, rows, cols);
            explosions.tick(frame_dt);
        }

        try out.writeAll("\x1b[H");

        var y: u16 = 0;
        while (y < rows) : (y += 1) {
            const band = bands.effectAt(y);

            // Chromatic aberration grows a lot inside an active band, so
            // corrupted rows look like the color signal itself is tearing.
            // The chaos driver's `y` also swings it up and down over time.
            const chroma = chroma_base + @sin(t * chroma_wobble_speed) * chroma_wobble +
                chaos[1] * chaos_chroma_amp + (if (band != null) chroma_band_extra else 0.0);

            var x: u16 = 0;
            while (x < cols) : (x += 1) {
                var sample_x: f64 = @floatFromInt(x);
                if (band) |b| {
                    const shifted = @as(i32, x) + b.x_shift;
                    const wrapped = @mod(shifted, @as(i32, cols));
                    sample_x = @floatFromInt(wrapped);
                }
                var fy: f64 = @floatFromInt(y);

                // Retro mode's "chunky pixels": snap the sampling
                // coordinates down to a coarse grid so every
                // `retro_pixel_scale`-sized block of cells samples the
                // exact same point and ends up the same color -- see
                // "Retro / 8-bit mode" above.
                if (retro_8bit_enabled) {
                    const xu: u16 = @intFromFloat(sample_x);
                    sample_x = @floatFromInt(xu - (xu % retro_pixel_scale));
                    fy = @floatFromInt(y - (y % retro_pixel_scale));
                }

                // Fold space into a rotating mandala before sampling
                // anything -- everything downstream repeats `kaleido_segments`
                // times around the center, self-similar at every radius.
                // Disabled by default (see `kaleido_enabled`): falls straight
                // through to the plain, unfolded noise field.
                const folded = if (kaleido_enabled)
                    kaleidoscopeFold(sample_x, fy, center_x, center_y, kaleido_segments, t * kaleido_rotate_speed)
                else
                    [2]f64{ sample_x, fy };
                const fx = folded[0];
                const fyw = folded[1];

                // Recursively warp the folded coordinate -- swirls within
                // swirls -- before feeding it to the main pattern. The
                // strength itself breathes in and out with the chaos
                // driver's `x` instead of staying a flat constant.
                const warp = recursiveWarp(fx, fyw, t, warp_strength_now);
                const wx = fx + warp[0];
                const wy = fyw + warp[1];

                // Sample the main pattern -- optionally as an endless
                // crossfaded zoom instead of a single fixed-scale sample.
                const fields = sampleFields(wx, wy, t, zoom_a, zoom_b);
                const hue_n = fields.hue_n;
                const val_n = fields.val_n;
                const detail_n = fields.detail_n;

                // Chromatic aberration (https://en.wikipedia.org/wiki/Chromatic_aberration):
                // real lenses (and cheap video/scan hardware) focus
                // different wavelengths slightly differently, so edges
                // pick up colored fringes. Faked here by re-sampling the
                // brightness field at a small x offset for red/blue while
                // green uses the un-offset sample -- the difference from
                // the base value becomes each channel's fringe amount.
                const val_r_n = noise.fbm3((wx + chroma) * freq_x * 1.7 + 50, wy * freq_y * 1.7 + 50, t * freq_t * 1.3, brightness_octaves, 0.5);
                const val_b_n = noise.fbm3((wx - chroma) * freq_x * 1.7 + 50, wy * freq_y * 1.7 + 50, t * freq_t * 1.3, brightness_octaves, 0.5);
                const delta_r = (val_r_n - val_n) * chroma_delta_scale;
                const delta_b = (val_b_n - val_n) * chroma_delta_scale;

                var hue = @mod(hue_n * hue_noise_scale + hue_drift_deg + detail_n * hue_detail_scale, 360.0);
                var val = clamp01(brightness_base + val_n * brightness_range);
                var sat = clamp01(saturation_base + detail_n * saturation_range);
                const density = clamp01(density_base + detail_n * density_range);
                const shade_idx: usize = @intFromFloat(density * @as(f64, @floatFromInt(shade_ramp.len - 1)));
                var glyph: []const u8 = shade_ramp[shade_idx .. shade_idx + 1];

                if (band) |b| {
                    hue = @mod(hue + b.hue_shift, 360.0);
                    if (b.invert) val = 1.0 - val;
                    if (random.float(f64) < band_corruption_chance) {
                        glyph = corruption_glyphs[random.uintLessThan(usize, corruption_glyphs.len)];
                        val = clamp01(val + random.float(f64) * band_corruption_brightness_boost);
                    }
                } else if (glitch_enabled and random.float(f64) < ambient_static_chance) {
                    hue = random.float(f64) * 360.0;
                    val = clamp01(ambient_static_brightness_base + random.float(f64) * ambient_static_brightness_range);
                    glyph = corruption_glyphs[random.uintLessThan(usize, corruption_glyphs.len)];
                }

                if (flash_frames > 0) {
                    hue = @mod(hue + flash_hue_shift_deg, 360.0);
                    val = clamp01(val + flash_brightness_boost);
                }

                // Bubbles are a screen-space overlay: tested against the
                // raw (unwarped, unshifted) cell coordinates so they drift
                // in a straight line up the terminal regardless of what
                // the noise/warp/glitch pipeline is doing underneath.
                if (bubbles_enabled) {
                    const bfx: f64 = @floatFromInt(x);
                    const bfy: f64 = @floatFromInt(y);
                    if (explosionEffectAt(&explosions, bfx, bfy)) |eff| {
                        hue = @mod(hue + eff.hue_shift, 360.0);
                        val = clamp01(val + eff.val_boost);
                        sat = clamp01(sat - eff.desat);
                        glyph = explosion_glyph;
                    } else if (bubbleEffectAt(&bubbles, bfx, bfy, t)) |eff| {
                        if (eff.rim) glyph = bubble_glyph;
                        val = clamp01(val + eff.val_boost);
                        sat = clamp01(sat - eff.desat);
                    }
                }

                if (retro_8bit_enabled) glyph = retro_glyph;

                const rgb_r = hsvToRgb(hue, sat, clamp01(val + delta_r));
                const rgb_g = hsvToRgb(hue, sat, val);
                const rgb_b = hsvToRgb(hue, sat, clamp01(val + delta_b));
                var r = rgb_r[0];
                var g = rgb_g[1];
                var b = rgb_b[2];

                // Ordered dithering + palette snap -- see "Retro / 8-bit
                // mode". The dither pattern is indexed by *native* pixel
                // (divided down by `retro_pixel_scale`) so it lines up
                // with the chunky-pixel grid instead of flickering
                // independently inside each block.
                if (retro_8bit_enabled) {
                    const dither = bayerDither(x / retro_pixel_scale, y / retro_pixel_scale);
                    const snapped = nesNearestColor(
                        clampToU8(@as(f64, @floatFromInt(r)) + dither),
                        clampToU8(@as(f64, @floatFromInt(g)) + dither),
                        clampToU8(@as(f64, @floatFromInt(b)) + dither),
                    );
                    r = snapped[0];
                    g = snapped[1];
                    b = snapped[2];
                }

                row_buf[x] = .{
                    .r = r,
                    .g = g,
                    .b = b,
                    .glyph = glyph,
                    .luma = 0.299 * @as(f64, @floatFromInt(r)) + 0.587 * @as(f64, @floatFromInt(g)) + 0.114 * @as(f64, @floatFromInt(b)),
                };
            }

            if (band) |b| {
                if (b.sort and b.sort_len > 1) {
                    const slice = row_buf[b.sort_start .. b.sort_start + b.sort_len];
                    if (b.sort_desc) {
                        std.mem.sort(Cell, slice, {}, lumaGreaterThan);
                    } else {
                        std.mem.sort(Cell, slice, {}, lumaLessThan);
                    }
                }
            }

            for (row_buf) |cell| {
                try out.print("\x1b[38;2;{d};{d};{d}m{s}", .{ cell.r, cell.g, cell.b, cell.glyph });
            }
            if (y + 1 < rows) try out.writeAll("\r\n");
        }

        try out.flush();

        const frame_elapsed = last.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
        if (frame_elapsed < frame_ns) {
            Io.sleep(io, Io.Duration.fromNanoseconds(@intCast(frame_ns - frame_elapsed)), .awake) catch {};
        }
    }
}
