# termtrip

A collection of terminal screensavers, written in Zig with zero dependencies.
Each one takes over the terminal, draws until you tell it to stop, and gets
out of the way.

| Name | Description |
| --- | --- |
| [`glix`](glix) | A glitch-art screensaver: a drifting, endlessly zooming Perlin noise flow field, warped into swirls with chromatic aberration, pixel sorting, and optional bubbles / retro 8-bit modes. |
| [`matrix`](matrix) | Matrix-style digital rain. |
| [`autom`](autom) | A cyclic cellular automaton rendered as swirling waves of RGB color with a chunky 8-bit pixel look. |
| [`cpk`](cpk) | An animated, endlessly diffusing color grid. |

## Running one

Each screensaver is its own self-contained Zig package with its own
`build.zig`. `cd` into its directory and run it from there:

```bash
cd glix
zig build run -Doptimize=ReleaseFast
```

Or target one from the repo root without `cd`-ing in:

```bash
zig build run-glix -Doptimize=ReleaseFast   # build and run just glix
zig build glix                              # build just glix, into ./zig-out/bin
zig build                                   # build all four
```

`ReleaseFast` is recommended for the smoothest animation on all of these.

Every one of them quits on `q` (or `Ctrl+C`); most also quit on `Esc`.

## Requirements

- Zig 0.16+
- A truecolor-capable terminal (most modern terminal emulators)

## Layout

This is a monorepo: each screensaver keeps its own `build.zig`,
`build.zig.zon`, and git history from before it moved in here. There's no
shared code between them yet — as more screensavers get added, common bits
(raw-mode terminal setup, frame buffering, argument parsing) are good
candidates to pull out into a shared internal module.
