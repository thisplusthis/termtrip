//! termkit — shared terminal takeover code for the termtrip screensavers.
//!
//! Every screensaver in this repo needs the same handful of things: put the
//! terminal into raw full-screen mode, ask it how big it is, notice when the
//! user wants to quit, and put everything back the way it was found — even if
//! the process gets killed. This module is that code, pulled out once so it's
//! not reimplemented (slightly differently) in every project.

pub const Terminal = @import("Terminal.zig");

test {
    _ = Terminal;
}
