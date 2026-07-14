//! root.zig — the public face of the `matrix` module.
//!
//! By convention `root.zig` is the entry file of a Zig *module* (the build
//! script wires it up under the name "matrix"). It only re-exports the piece
//! that makes up the screensaver's own logic, so that `main.zig` can reach it
//! as `matrix.Matrix` without knowing which file it lives in. Terminal
//! handling itself is shared across every screensaver in this repo — see the
//! `termkit` module.

pub const Matrix = @import("Matrix.zig");

// Referencing the import inside a test block tells `zig build test` to pull in
// and run the tests defined in it too.
test {
    _ = Matrix;
}
