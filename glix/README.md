# glix

A tiny, colorful glitch-art screensaver for your terminal, written in Zig
with zero dependencies.

Under the hood it's a 3D Perlin noise flow field (x, y, time) mapped to
hue/brightness that endlessly drifts and morphs, recursively domain-warped
into swirls and roughed up with chromatic aberration and pixel sorting. The
whole picture also slowly, endlessly zooms in — two crossfaded zoom passes
swap off right as each fades out of view, so it never has to visibly reset
and never runs out of fractal detail to dive into. Layered on top are random
"glitch bands" that periodically tear across the screen — shifting rows
sideways, inverting colors, and dropping in corrupted static — for that
databending look. A Lorenz attractor, integrated in real time, also nudges a
handful of these settings (swirliness, color fringing, hue speed, glitch
density) up and down as it chaotically orbits, so the vibe drifts and
occasionally lurches instead of holding at flat constants. There's also an
optional bubbles mode (off by default) where bubbles percolate up from the
bottom edge, swaying gently, float off the top, and pop into a bright
expanding ring whenever two of them collide.

There's also an optional retro/8-bit mode (also off by default,
`retro_8bit_enabled`) that reimagines the whole picture as if it were drawn
by an 8-bit game console: chunky low-res pixels, every color snapped to the
NES's palette with ordered (Bayer) dithering to fake extra gradient steps,
and solid block glyphs instead of ASCII shading.

Most of this is configurable — see the `TUNABLES` section at the top of
`src/main.zig` for every knob, with comments on what each one does.

## Run it

```bash
zig build run -Doptimize=ReleaseFast
```

(`ReleaseFast` is recommended for the smoothest animation; it also runs fine
in Debug mode, just choppier.)

## Controls

- Any key: trigger a glitch burst
- `q` / `Ctrl+C`: quit

## Requirements

- Zig 0.16+
- A truecolor-capable terminal (most modern terminal emulators)
