const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The one exported module. Everything below is a developer step, so a
    // consumer's fetch graph stops at this module.
    const mod = b.addModule("protobuf", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (b.pkg_hash.len != 0) return;

    // testingx provides the test runner and the benchmark harness. It is lazy
    // because only the root build uses it, and the early return above means a
    // consumer never fetches it.
    const testingx_dep = b.lazyDependency("testingx", .{ .target = target }) orelse return;
    const runner: std.Build.Step.Compile.TestRunner = .{
        .path = testingx_dep.path("src/runner.zig"),
        .mode = .simple,
    };

    const test_step = b.step("test", "Run the unit tests");

    const mod_tests = b.addTest(.{ .root_module = mod, .test_runner = runner });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    passthruArgs(b, run_mod_tests);
    test_step.dependOn(&run_mod_tests.step);

    // The base64 adapter the guide shows, run against stdx so the snippet in
    // the guide cannot drift away from stdx's API. stdx is a lazy dependency:
    // only this module and the root build ask for it.
    if (b.lazyDependency("stdx", .{ .target = target })) |stdx_dep| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/stdx_base64.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "protobuf", .module = mod },
                    .{ .name = "stdx", .module = stdx_dep.module("stdx") },
                },
            }),
            .test_runner = runner,
        });
        const run = b.addRunArtifact(tests);
        passthruArgs(b, run);
        test_step.dependOn(&run.step);
    }

    // The interop tests compare against bytes protoc wrote, kept under
    // test/data. They are their own modules so the package itself does not
    // carry them.
    for ([_][]const u8{ "test/interop.zig", "test/etcd.zig" }) |path| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "protobuf", .module = mod },
                    .{ .name = "testingx", .module = testingx_dep.module("testingx") },
                },
            }),
            .test_runner = runner,
        });
        const run = b.addRunArtifact(tests);
        passthruArgs(b, run);
        test_step.dependOn(&run.step);
    }

    // The code the README and guide show. It is a test against the public
    // module, so a documented call cannot drift away from the API.
    const examples_mod = b.createModule(.{
        .root_source_file = b.path("docs/examples/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protobuf", .module = mod }},
    });
    const example_tests = b.addTest(.{ .root_module = examples_mod, .test_runner = runner });
    const run_example_tests = b.addRunArtifact(example_tests);
    passthruArgs(b, run_example_tests);
    test_step.dependOn(&run_example_tests.step);

    // Benchmarks. testingx's addBench builds the suite as ReleaseFast.
    if (b.lazyImport(@This(), "testingx")) |testingx_build| {
        const run_bench = testingx_build.addBench(b, .{
            .name = "bench-protobuf",
            .module = testingx_dep.module("testingx"),
            .root_source_file = b.path("bench/bench.zig"),
            .imports = &.{.{ .name = "protobuf", .module = mod }},
        });
        run_bench.addPassthruArgs();
        const bench_step = b.step("bench", "Run benchmarks (ReleaseFast)");
        bench_step.dependOn(&run_bench.step);
    }
}

/// `b.args` (removed in Zig 0.17) and `Run.addPassthruArgs` are the same
/// feature on either side of the split. Probe the build API, not the version.
fn passthruArgs(b: *std.Build, run: *std.Build.Step.Run) void {
    if (comptime @hasDecl(std.Build.Step.Run, "addPassthruArgs")) {
        run.addPassthruArgs();
    } else if (b.args) |args| {
        run.addArgs(args);
    }
}
