//! Terminal.zig — everything that talks to the *terminal itself*.
//!
//! This file uses one of Zig's most important idioms: **a file is a struct**.
//! When you write top-level fields (like `io:` and `size:` below), the whole
//! file behaves as if it were wrapped in `struct { ... }`. The line
//!     const Terminal = @This();
//! gives that anonymous struct a name so we can write `Terminal.init(...)` and
//! return `Terminal` values. Other files import it with `@import("Terminal.zig")`.
//!
//! A "normal" terminal is in *cooked* (a.k.a. canonical) mode: it buffers a
//! whole line, echoes your keystrokes, and only hands the program the text once
//! you press Enter. That is great for shells and terrible for an animation. So
//! we flip the terminal into *raw* mode, take over the whole screen, hide the
//! cursor — and, crucially, put everything back exactly how we found it when we
//! are done (see `deinit`).

const std = @import("std");
const Io = std.Io;

// `std.posix` is Zig's portable wrapper around POSIX syscalls (tcgetattr, read…).
// `std.c` gives us the raw C-library constants that std.posix doesn't re-export,
// such as the `ioctl` request number and the `V.MIN`/`V.TIME` array indices.
const posix = std.posix;
const c = std.c;

const Terminal = @This();

// ---------------------------------------------------------------------------
// ANSI escape sequences.
//
// A terminal is controlled by writing magic byte sequences into it. They all
// start with the "escape" byte (0x1b) followed by `[`, which together are
// called the Control Sequence Introducer, or CSI. `esc` below is that prefix,
// and `++` is Zig's *compile-time* string concatenation, so each constant is a
// single fixed string baked into the binary — zero runtime cost.
// ---------------------------------------------------------------------------
const esc = "\x1b[";
const alt_screen_on = esc ++ "?1049h"; // switch to a fresh "alternate" screen…
const alt_screen_off = esc ++ "?1049l"; // …and later restore the user's scrollback
const cursor_hide = esc ++ "?25l";
const cursor_show = esc ++ "?25h";
const wrap_off = esc ++ "?7l"; // stop the cursor auto-wrapping past the last column
const wrap_on = esc ++ "?7h";
const clear = esc ++ "2J"; // erase the whole screen
const home = esc ++ "H"; // move the cursor to row 1, column 1
const reset_color = esc ++ "0m"; // back to the default foreground/background

// Sequences we send once on the way in and once on the way out. Concatenating
// them here means each transition is a *single* write.
const enter_sequence = alt_screen_on ++ cursor_hide ++ wrap_off ++ clear ++ home;
const leave_sequence = reset_color ++ cursor_show ++ wrap_on ++ alt_screen_off;

/// The width and height of the terminal, measured in character cells.
pub const Size = struct { cols: u16, rows: u16 };

// ---------------------------------------------------------------------------
// The struct fields. Each `Terminal` value carries the handful of things it
// needs to draw to and later restore the terminal.
// ---------------------------------------------------------------------------
io: Io, // the I/O interface (needed by the writer/flush machinery)
w: *Io.Writer, // where our escape codes are written
in_fd: posix.fd_t, // file descriptor we read keystrokes from (stdin)
out_fd: posix.fd_t, // file descriptor we ask for the window size (stdout)
original: posix.termios, // the terminal settings we must put back on exit
size: Size, // last known terminal size

/// Put the terminal into full-screen raw mode and return a handle to it.
///
/// The caller keeps the returned value alive and calls `deinit()` on it later
/// — the idiomatic Zig pattern is `var term = try Terminal.init(...); defer term.deinit();`.
pub fn init(io: Io, w: *Io.Writer) !Terminal {
    const in_fd = posix.STDIN_FILENO;
    const out_fd = posix.STDOUT_FILENO;

    // Read the current settings so we can (a) base raw mode on them and
    // (b) restore them verbatim when we quit.
    const original = try posix.tcgetattr(in_fd);

    // `termios` flags live in four bit-field groups. In Zig they are *packed
    // structs of bools*, which is lovely: instead of fiddling with bit masks
    // like `flags &= ~ECHO`, we just assign named booleans.
    var raw = original;
    raw.lflag.ECHO = false; // don't echo typed characters back to the screen
    raw.lflag.ICANON = false; // hand us each key immediately, not one line at a time
    raw.lflag.ISIG = false; // Ctrl-C / Ctrl-Z arrive as plain bytes instead of signals
    raw.lflag.IEXTEN = false; // disable implementation-defined input processing
    raw.iflag.IXON = false; // Ctrl-S / Ctrl-Q no longer freeze/thaw output
    raw.iflag.ICRNL = false; // don't translate carriage-return to newline on input
    raw.iflag.BRKINT = false; // a break condition won't send us a signal
    raw.iflag.INPCK = false; // no input parity checking
    raw.iflag.ISTRIP = false; // keep the 8th bit of every input byte
    raw.oflag.OPOST = false; // send our output bytes through untouched (no LF→CRLF, etc.)

    // Make reading input *non-blocking*: with both MIN and TIME set to 0, a
    // `read` returns instantly — with whatever bytes are waiting, or none at
    // all. That is exactly what an animation loop wants: peek for a keypress,
    // then get straight back to drawing. The `cc` array is indexed by the `V`
    // enum, so `@intFromEnum` turns the name into its slot number.
    raw.cc[@intFromEnum(c.V.MIN)] = 0;
    raw.cc[@intFromEnum(c.V.TIME)] = 0;

    // Apply the new settings. `.flush` (TCSAFLUSH) waits for pending output and
    // discards any unread input first, giving us a clean slate.
    try posix.tcsetattr(in_fd, .FLUSH, raw);

    var self: Terminal = .{
        .io = io,
        .w = w,
        .in_fd = in_fd,
        .out_fd = out_fd,
        .original = original,
        .size = winSize(out_fd),
    };

    // Take over the screen and show the first blank frame.
    try self.w.writeAll(enter_sequence);
    try self.w.flush();
    return self;
}

/// Undo everything `init` did. This is written to *never fail*: it is meant to
/// run from a `defer`, even while an error is unwinding, so it swallows errors
/// with `catch {}` — there is nothing useful we could do about them here, and
/// leaving the terminal wrecked would be far worse than a lost escape code.
pub fn deinit(self: *Terminal) void {
    self.w.writeAll(leave_sequence) catch {};
    self.w.flush() catch {};
    posix.tcsetattr(self.in_fd, .FLUSH, self.original) catch {};
}

/// Ask the kernel how big the terminal window currently is. Returns the last
/// known size (or a sane 80×24 default) if the query fails — e.g. when output
/// has been redirected to a file instead of a real terminal.
pub fn querySize(self: *Terminal) Size {
    return winSize(self.out_fd);
}

/// Peek at stdin and report whether the user asked to quit. Because input is
/// non-blocking (see `init`), this returns immediately every frame.
pub fn pollQuit(self: *Terminal) bool {
    var buf: [32]u8 = undefined;
    // `read` fills `buf` with any waiting bytes and returns how many there were
    // (possibly zero). If it errors, we simply treat it as "no key this frame".
    const n = posix.read(self.in_fd, &buf) catch return false;
    for (buf[0..n]) |ch| switch (ch) {
        'q', 'Q', 3 => return true, // 'q', 'Q', or Ctrl-C (byte 0x03)
        else => {},
    };
    return false;
}

/// The one bit of genuinely low-level plumbing: fetch the window size via the
/// `TIOCGWINSZ` ioctl. `ioctl` is a variadic C function, so we call it through
/// `std.c` and pass a pointer to a `winsize` struct for it to fill in.
fn winSize(out_fd: posix.fd_t) Size {
    var ws: posix.winsize = undefined;
    const rc = c.ioctl(out_fd, @intCast(c.T.IOCGWINSZ), &ws);
    if (rc == 0 and ws.col != 0 and ws.row != 0) {
        return .{ .cols = ws.col, .rows = ws.row };
    }
    return .{ .cols = 80, .rows = 24 };
}
