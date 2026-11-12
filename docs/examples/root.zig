//! The code the guide shows, compiled with the module's own tests.
//!
//! Every file here is a test against the public `protobuf` module. `just
//! test` runs them, so an example cannot drift away from the API.

test {
    _ = @import("wire.zig");
    _ = @import("typed.zig");
    _ = @import("delimited.zig");
    _ = @import("ownership.zig");
}
