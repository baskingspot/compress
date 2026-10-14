const std = @import("std");
const Build = std.Build;
const comptimePrint = std.fmt.comptimePrint;

/// The codecs with an example CLI (examples/<codec>.zig). brotli's is
/// decode-only.
const example_codecs = [_][]const u8{ "brotli", "snappy", "flate", "gzip", "zlib", "zstd" };

/// The codecs with a local bench (src/<codec>/bench.zig).
const bench_codecs = [_][]const u8{ "snappy", "flate", "gzip", "zlib", "zstd", "brotli" };

/// The codecs with an oracle harness (src/<codec>/oracle.zig): every codec
/// except snappy, whose conformance rides the flate family's lanes.
const oracle_codecs = [_][]const u8{ "brotli", "flate", "gzip", "zlib", "zstd" };

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `--fuzz` test runs need the default test runner (the server protocol
    // that ztest's `.mode = .simple` skips), so ztest is only used for
    // normal test runs.
    const fuzz_mode =
        b.option(bool, "fuzz", "Enable fuzzing (uses the default test runner)") orelse false;

    // fastmem: the copy and fill primitive every codec uses (`fastmem.copy`,
    // `fastmem.move`, `fastmem.set`).
    const fastmem_dep = b.dependency("fastmem", .{
        .target = target,
        .optimize = optimize,
    });
    const fastmem_mod = fastmem_dep.module("fastmem");

    // One module, `zcompress`, rooted at src/root.zig. Codecs are
    // namespaces under it (`zcompress.snappy`, `zcompress.flate`). The shared
    // code in `src/internal/` is reached by relative import: it is not a
    // module and is not re-exported.
    const zcompress_mod = b.addModule("zcompress", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zcompress_mod.addImport("fastmem", fastmem_mod);

    // ztest: plain-text test runner. Lazy — only fetched when the test step
    // is actually built, not when consumers use zcompress as a dependency.
    const ztest_dep = b.lazyDependency("ztest", .{});
    const test_runner: ?Build.Step.Compile.TestRunner = if (fuzz_mode) null else if (ztest_dep) |z|
        .{ .path = z.path("src/test_runner.zig"), .mode = .simple }
    else
        null;
    const test_step = b.step("test", "Run unit tests");

    // Example CLIs, one per codec (examples/), sharing examples/cli.zig. Run:
    //   zig build example-snappy -- encode README.md > out
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("examples/cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    inline for (example_codecs) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path(comptimePrint("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cli", .module = cli_mod },
                .{ .name = "zcompress", .module = zcompress_mod },
            },
        });
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = mod,
        });
        const run = b.addRunArtifact(exe);
        run.has_side_effects = true;
        if (b.args) |args| run.addArgs(args);
        const step = b.step(
            comptimePrint("example-{s}", .{name}),
            comptimePrint("Run the {s} example CLI (encode|decode [FILE|-])", .{name}),
        );
        step.dependOn(&run.step);
        const example_tests = b.addTest(.{
            .root_module = mod,
            .test_runner = test_runner,
        });
        const run_example_tests = b.addRunArtifact(example_tests);
        run_example_tests.has_side_effects = true;
        test_step.dependOn(&run_example_tests.step);
    }

    inline for (oracle_codecs) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path(comptimePrint("src/{s}/oracle.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcompress", .module = zcompress_mod },
            },
        });
        const exe = b.addExecutable(.{
            .name = comptimePrint("{s}-oracle", .{name}),
            .root_module = mod,
        });
        const install = b.addInstallArtifact(exe, .{});
        const step = b.step(
            comptimePrint("{s}-oracle-harness", .{name}),
            comptimePrint(
                "Install the {s} oracle-lane harness (zig-out/bin/{s}-oracle)",
                .{ name, name },
            ),
        );
        step.dependOn(&install.step);
    }

    // Unit tests: one test executable over the one module, covering every
    // codec's tests and the barrel's own. ztest still reports each test by
    // name.
    const zcompress_tests = b.addTest(.{
        .root_module = zcompress_mod,
        .test_runner = test_runner,
    });
    const run_zcompress_tests = b.addRunArtifact(zcompress_tests);
    run_zcompress_tests.has_side_effects = true; // always run tests, don't cache
    test_step.dependOn(&run_zcompress_tests.step);

    // Compile-only gate: compiles the module's test binary without running
    // it, for cross-target checks (the portable fallbacks only compile on
    // non-native targets):
    //   zig build check -Dtarget=x86_64-linux
    const check_step = b.step("check", "Compile the tests without running (cross-target gate)");
    check_step.dependOn(&zcompress_tests.step);

    // The benchmark driver for the bench/ harness (bench/README.md): one
    // binary with the zcompress one-shot rows and the std.compress rows,
    // cross-built per EC2 target by the harness and uploaded to the boxes.
    // `-Drev` stamps the measured revision into the meta record.
    const rev =
        b.option([]const u8, "rev", "Revision label for the fleet bench driver") orelse "dev";
    const fleet_options = b.addOptions();
    fleet_options.addOption([]const u8, "rev", rev);
    const fleet_bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/zig/bench_zcompress.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcompress", .module = zcompress_mod },
            .{ .name = "fastmem", .module = fastmem_mod },
        },
    });
    fleet_bench_mod.addOptions("build_options", fleet_options);
    const fleet_bench = b.addExecutable(.{
        .name = "bench-zcompress",
        .root_module = fleet_bench_mod,
    });
    const install_fleet_bench = b.addInstallArtifact(fleet_bench, .{});
    const fleet_bench_step = b.step(
        "fleet-bench",
        "Install the fleet benchmark driver (zig-out/bin/bench-zcompress)",
    );
    fleet_bench_step.dependOn(&install_fleet_bench.step);

    // The benchmark corpus generator (bench/README.md): deterministic,
    // byte-identical across hosts. It writes the gitignored bench/corpus-gen/
    // and verifies every file against the committed bench/corpus/SHA256SUMS.
    // Run from the repo root: `zig build corpus`.
    const corpus_mod = b.createModule(.{
        .root_source_file = b.path("bench/zig/corpus.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcompress", .module = zcompress_mod },
            .{ .name = "fastmem", .module = fastmem_mod },
        },
    });
    const corpus_tool = b.addExecutable(.{
        .name = "corpus",
        .root_module = corpus_mod,
    });
    const run_corpus = b.addRunArtifact(corpus_tool);
    run_corpus.has_side_effects = true;
    if (b.args) |args| run_corpus.addArgs(args);
    const corpus_step = b.step(
        "corpus",
        "Generate + verify the fleet corpus (bench/corpus-gen/)",
    );
    corpus_step.dependOn(&run_corpus.step);

    // Competitor sources for the benchmark harness (bench/README.md): the C
    // arms build libdeflate, zlib-ng, google/snappy, and zstd from release
    // tarballs pinned by url+hash in bench/build.zig.zon. The bench/ build
    // root fetches them (zig's fetcher verifies each hash) and installs the
    // trees under bench/zig-out/bench-src/<name>/ for the harness's zig-cc and
    // cmake builds. This step only delegates to that build root. The
    // dependencies stay out of this build graph on purpose: a
    // `b.lazyDependency` call here would mark them needed at configure time,
    // and the build runner fetches every marked dependency on any invocation,
    // `zig build test` included. The call site triggers the fetch, not the
    // requested step.
    const bench_vendor_step = b.step(
        "bench-vendor",
        "Materialize the pinned bench competitor sources (bench/zig-out/bench-src/)",
    );
    const zig_exe: []const u8 = b.graph.zig_exe;
    const bench_vendor = b.addSystemCommand(&.{ zig_exe, "build", "bench-vendor" });
    bench_vendor.setCwd(b.path("bench"));
    bench_vendor_step.dependOn(&bench_vendor.step);

    // The 32-bit probes (src/zstd/probe32.zig, src/brotli/probe32.zig): decode
    // inputs whose totals run past 2^32 on a usize=32 target, where a 32-bit
    // wrap is observable. Both are built for wasm32-wasi in ReleaseSafe (a
    // wrap panics) with an explicit 8 MiB stack (the codecs' scratch lives on
    // it), and `just check-32` runs them under wasmtime. They are correctness
    // checks, not benchmarks, so they sit outside the lazy benchmark block
    // below and never depend on the benchmark package.
    const probe32_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const probe32_step = b.step(
        "probe32",
        "Build the 32-bit proof probes (wasm32-wasi; run under wasmtime)",
    );
    inline for (.{ "zstd", "brotli" }) |name| {
        const probe32_mod = b.createModule(.{
            .root_source_file = b.path(comptimePrint("src/{s}/probe32.zig", .{name})),
            .target = probe32_target,
            .optimize = .ReleaseSafe,
        });
        probe32_mod.addImport("fastmem", fastmem_mod);
        probe32_mod.addImport("zcompress", zcompress_mod);
        const probe32_exe = b.addExecutable(.{
            .name = comptimePrint("{s}-probe32", .{name}),
            .root_module = probe32_mod,
        });
        probe32_exe.stack_size = 8 * 1024 * 1024;
        probe32_step.dependOn(&b.addInstallArtifact(probe32_exe, .{}).step);
    }

    // Benchmarks. The benchmark dependency is lazy in the zon: while it is
    // unfetched, b.lazyImport returns null and no bench step is defined. The
    // call itself still marks the dependency needed, and the build runner
    // fetches every marked lazy dependency on any invocation, so a cold
    // cache's first `zig build`, whatever the step, fetches benchmark before
    // this block runs again.
    if (b.lazyImport(@This(), "benchmark")) |benchmark| {
        // The dependency is lazy in the zon, so it must come through
        // lazyDependency. lazyImport already confirmed it is fetched, so
        // this call returns non-null.
        const benchmark_dep = b.lazyDependency("benchmark", .{
            .target = target,
            .optimize = optimize,
        }).?;

        const bench_step = b.step("bench", "Run codec benchmarks (use -Doptimize=ReleaseFast)");

        // zig-benchmark's addRunTest injects @import("benchmark") into each
        // bench root module and generates the runner executable: one module
        // per codec over src/<codec>/bench.zig with the shared import set
        // (zcompress + fastmem). The brotli bench is decode-only (over the
        // generated corpus streams); see src/brotli/bench.zig.
        inline for (bench_codecs) |name| {
            const bench_root = b.createModule(.{
                .root_source_file = b.path(comptimePrint("src/{s}/bench.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zcompress", .module = zcompress_mod },
                    .{ .name = "fastmem", .module = fastmem_mod },
                },
            });
            const run_bench = benchmark.addRunTest(b, .{
                .dependency = benchmark_dep,
                .root_module = bench_root,
            });
            if (b.args) |args| run_bench.addArgs(args);
            bench_step.dependOn(&run_bench.step);
        }
    }
}
