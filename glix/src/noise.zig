//! Classic (Ken Perlin -style) 3D noise, plus fractal Brownian motion (fbm)
//! built on top of it. The permutation table is shuffled once at startup
//! from a seed, so every run gets a different (but still smooth) noise field.
//!
//! Background reading:
//!   - Perlin noise: https://en.wikipedia.org/wiki/Perlin_noise
//!   - Fractional/fractal Brownian motion: https://en.wikipedia.org/wiki/Fractional_Brownian_motion

const std = @import("std");

var perm: [512]u8 = undefined;

/// Seeds the noise field. Builds the identity permutation `0..255` and
/// shuffles it with a Fisher-Yates shuffle
/// (https://en.wikipedia.org/wiki/Fisher%E2%80%93Yates_shuffle), which is
/// what makes each run's noise field different while still being smooth
/// (the *values* 0-255 don't change, only their order, so the lattice
/// stays a valid permutation). The table is duplicated to 512 entries so
/// callers never have to wrap indices themselves.
///
/// Must be called once before `noise3`/`fbm3` are used.
pub fn init(seed: u64) void {
    var base: [256]u8 = undefined;
    for (&base, 0..) |*v, i| v.* = @intCast(i);

    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().shuffle(u8, &base);

    for (0..512) |i| perm[i] = base[i % 256];
}

/// Perlin's "ease curve", used to smooth the fractional part of each
/// coordinate before interpolating between lattice corners. This is the
/// 6t^5-15t^4+10t^3 "smootherstep" (Ken Perlin's improved version of the
/// plain cubic smoothstep): unlike a linear blend, its first *and second*
/// derivatives are zero at t=0 and t=1, so neighboring noise cells join
/// with no visible seams or kinks. See
/// https://en.wikipedia.org/wiki/Smoothstep.
fn fade(t: f64) f64 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

/// Linear interpolation between `a` and `b` at position `t` (0..1). See
/// https://en.wikipedia.org/wiki/Linear_interpolation. `noise3` nests
/// three of these (one per axis) to blend the 8 corners of a cube.
fn lerp(t: f64, a: f64, b: f64) f64 {
    return a + t * (b - a);
}

/// Turns a lattice-corner hash into one of 12 pseudo-random gradient
/// directions and dots it with the offset vector (x, y, z) from that
/// corner. This is the "gradient" half of gradient noise: rather than
/// interpolating stored values (value noise), Perlin noise interpolates
/// the dot product of a per-corner gradient with the direction to the
/// sample point, which avoids the axis-aligned blockiness plain value
/// noise produces. See https://en.wikipedia.org/wiki/Perlin_noise.
fn grad(hash: u8, x: f64, y: f64, z: f64) f64 {
    const h = hash & 15;
    const u = if (h < 8) x else y;
    const v: f64 = if (h < 4) y else if (h == 12 or h == 14) x else z;
    return (if (h & 1 == 0) u else -u) + (if (h & 2 == 0) v else -v);
}

/// Maps a (non-negative) float coordinate to a 0-255 lattice index.
fn latticeIndex(v: f64) usize {
    const i: i64 = @intFromFloat(@floor(v));
    return @intCast(@mod(i, 256));
}

/// Classic 3D Perlin noise, returns a value roughly in [-1, 1].
/// Coordinates should be non-negative for `latticeIndex` to behave.
///
/// Technique: for the unit cube containing (x, y, z), look up (via
/// `perm`) a pseudo-random gradient for each of its 8 corners, evaluate
/// each with `grad`, and blend the 8 results with `fade`-smoothed
/// trilinear interpolation (`lerp`, applied along x, then y, then z).
/// The result is a continuous, smoothly-varying field with no visible
/// grid structure -- the foundation everything else in this program
/// samples from. See https://en.wikipedia.org/wiki/Perlin_noise.
pub fn noise3(x: f64, y: f64, z: f64) f64 {
    const xi = latticeIndex(x);
    const yi = latticeIndex(y);
    const zi = latticeIndex(z);

    const xf = x - @floor(x);
    const yf = y - @floor(y);
    const zf = z - @floor(z);

    const u = fade(xf);
    const v = fade(yf);
    const w = fade(zf);

    const a: usize = @as(usize, perm[xi]) + yi;
    const aa: usize = @as(usize, perm[a]) + zi;
    const ab: usize = @as(usize, perm[a + 1]) + zi;
    const b: usize = @as(usize, perm[xi + 1]) + yi;
    const ba: usize = @as(usize, perm[b]) + zi;
    const bb: usize = @as(usize, perm[b + 1]) + zi;

    return lerp(
        w,
        lerp(
            v,
            lerp(u, grad(perm[aa], xf, yf, zf), grad(perm[ba], xf - 1, yf, zf)),
            lerp(u, grad(perm[ab], xf, yf - 1, zf), grad(perm[bb], xf - 1, yf - 1, zf)),
        ),
        lerp(
            v,
            lerp(u, grad(perm[aa + 1], xf, yf, zf - 1), grad(perm[ba + 1], xf - 1, yf, zf - 1)),
            lerp(u, grad(perm[ab + 1], xf, yf - 1, zf - 1), grad(perm[bb + 1], xf - 1, yf - 1, zf - 1)),
        ),
    );
}

/// Fractal Brownian motion: sums several "octaves" of `noise3`, each at
/// double the previous frequency and (by default) half the previous
/// amplitude, for a richer, more organic looking field with detail at
/// multiple scales -- the same broad-strokes-plus-fine-detail structure
/// as coastlines, clouds, and mountain ranges. Returns a value roughly
/// in [-1, 1] (normalized by the total amplitude summed, `max_amp`).
/// This is the graphics-world usage of the term; see
/// https://en.wikipedia.org/wiki/Fractional_Brownian_motion.
pub fn fbm3(x: f64, y: f64, z: f64, octaves: u32, persistence: f64) f64 {
    var total: f64 = 0;
    var freq: f64 = 1;
    var amp: f64 = 1;
    var max_amp: f64 = 0;

    var i: u32 = 0;
    while (i < octaves) : (i += 1) {
        total += noise3(x * freq, y * freq, z * freq) * amp;
        max_amp += amp;
        amp *= persistence;
        freq *= 2.0;
    }
    return total / max_amp;
}
