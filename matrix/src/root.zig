//! root.zig — the public face of the `matrix` module.
//!
//! By convention `root.zig` is the entry file of a Zig *module* (the build
//! script wires it up under the name "matrix"). It only re-exports the two
//! pieces that make up the screensaver, so that `main.zig` can reach them as
//! `matrix.Terminal` and `matrix.Matrix` without knowing which files they live
//! in. Re-exporting from a single root keeps the module's surface small and
//! tidy — a common Zig pattern.

pub const Terminal = @import("Terminal.zig");
pub const Matrix = @import("Matrix.zig");

// Referencing the imports inside a test block tells `zig build test` to pull in
// and run the tests defined in those files too.
test {
    _ = Terminal;
    _ = Matrix;
}
