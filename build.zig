const std = @import("std");
const Build = std.Build;
const comptimePrint = std.fmt.comptimePrint;

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

    inline for (.{ "snappy", "flate", "gzip", "zlib", "zstd" }) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path(comptimePrint("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cli", .module = cli_mod },
                .{ .name = "zcompress", .module = zcompress_mod },
            },
        });
        const example = b.addExecutable(.{
            .name = name,
            .root_module = mod,
        });
        const run = b.addRunArtifact(example);
        run.has_side_effects = true;
        if (b.args) |args| run.addArgs(args);
        const example_step = b.step(
            comptimePrint("example-{s}", .{name}),
            comptimePrint("Run the {s} example CLI (encode|decode [FILE|-])", .{name}),
        );
        example_step.dependOn(&run.step);
        const example_tests = b.addTest(.{
            .root_module = mod,
            .test_runner = test_runner,
        });
        const run_example_tests = b.addRunArtifact(example_tests);
        run_example_tests.has_side_effects = true;
        test_step.dependOn(&run_example_tests.step);
    }

    // External-oracle harness (src/flate/oracle.zig): decodes one stream from
    // a file into a caller-sized buffer, for `just flate-oracle`. Installed,
    // not part of the module surface or the test/check steps.
    const flate_oracle_mod = b.createModule(.{
        .root_source_file = b.path("src/flate/oracle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcompress", .module = zcompress_mod },
        },
    });
    const flate_oracle = b.addExecutable(.{
        .name = "flate-oracle",
        .root_module = flate_oracle_mod,
    });
    const install_flate_oracle = b.addInstallArtifact(flate_oracle, .{});
    const flate_oracle_step = b.step(
        "flate-oracle-harness",
        "Install the flate oracle-lane harness (zig-out/bin/flate-oracle)",
    );
    flate_oracle_step.dependOn(&install_flate_oracle.step);

    // External-oracle harness (src/gzip/oracle.zig): decodes one member from
    // a file into a caller-sized buffer (and encodes an input at a chosen
    // level), for `just gzip-oracle`. Installed, not part of the module
    // surface or the test/check steps.
    const gzip_oracle_mod = b.createModule(.{
        .root_source_file = b.path("src/gzip/oracle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcompress", .module = zcompress_mod },
        },
    });
    const gzip_oracle = b.addExecutable(.{
        .name = "gzip-oracle",
        .root_module = gzip_oracle_mod,
    });
    const install_gzip_oracle = b.addInstallArtifact(gzip_oracle, .{});
    const gzip_oracle_step = b.step(
        "gzip-oracle-harness",
        "Install the gzip oracle-lane harness (zig-out/bin/gzip-oracle)",
    );
    gzip_oracle_step.dependOn(&install_gzip_oracle.step);

    // External-oracle harness (src/zlib/oracle.zig): decodes one stream from
    // a file into a caller-sized buffer (and encodes an input at a chosen
    // level), for `just zlib-oracle`. Installed, not part of the module
    // surface or the test/check steps.
    const zlib_oracle_mod = b.createModule(.{
        .root_source_file = b.path("src/zlib/oracle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcompress", .module = zcompress_mod },
        },
    });
    const zlib_oracle = b.addExecutable(.{
        .name = "zlib-oracle",
        .root_module = zlib_oracle_mod,
    });
    const install_zlib_oracle = b.addInstallArtifact(zlib_oracle, .{});
    const zlib_oracle_step = b.step(
        "zlib-oracle-harness",
        "Install the zlib oracle-lane harness (zig-out/bin/zlib-oracle)",
    );
    zlib_oracle_step.dependOn(&install_zlib_oracle.step);

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

    // The 32-bit probe (src/zstd/probe32.zig): decodes frames with very large
    // totals on a usize=32 target, where a 32-bit length wrap is observable.
    // It is built for wasm32-wasi in ReleaseSafe (a wrap panics) with an
    // explicit 8 MiB stack (the window buffer lives on it), and `just
    // check-32` runs it under wasmtime. It is a correctness check, not a
    // benchmark, so it sits outside the lazy benchmark block below and never
    // depends on the benchmark package.
    const probe32_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const probe32_mod = b.createModule(.{
        .root_source_file = b.path("src/zstd/probe32.zig"),
        .target = probe32_target,
        .optimize = .ReleaseSafe,
    });
    probe32_mod.addImport("fastmem", fastmem_mod);
    probe32_mod.addImport("zcompress", zcompress_mod);
    const probe32_exe = b.addExecutable(.{
        .name = "zstd-probe32",
        .root_module = probe32_mod,
    });
    probe32_exe.stack_size = 8 * 1024 * 1024;
    const install_probe32 = b.addInstallArtifact(probe32_exe, .{});
    const probe32_step = b.step(
        "probe32",
        "Build the 32-bit proof probe (wasm32-wasi; run under wasmtime)",
    );
    probe32_step.dependOn(&install_probe32.step);

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

        // zig-benchmark's addRunTest injects @import("benchmark") into the
        // bench root module and generates the runner executable.
        const snappy_bench_root = b.createModule(.{
            .root_source_file = b.path("src/snappy/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcompress", .module = zcompress_mod },
                .{ .name = "fastmem", .module = fastmem_mod },
            },
        });
        const run_snappy_bench = benchmark.addRunTest(b, .{
            .dependency = benchmark_dep,
            .root_module = snappy_bench_root,
        });
        if (b.args) |args| run_snappy_bench.addArgs(args);

        const flate_bench_root = b.createModule(.{
            .root_source_file = b.path("src/flate/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcompress", .module = zcompress_mod },
                .{ .name = "fastmem", .module = fastmem_mod },
            },
        });
        const run_flate_bench = benchmark.addRunTest(b, .{
            .dependency = benchmark_dep,
            .root_module = flate_bench_root,
        });
        if (b.args) |args| run_flate_bench.addArgs(args);

        const gzip_bench_root = b.createModule(.{
            .root_source_file = b.path("src/gzip/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcompress", .module = zcompress_mod },
                .{ .name = "fastmem", .module = fastmem_mod },
            },
        });
        const run_gzip_bench = benchmark.addRunTest(b, .{
            .dependency = benchmark_dep,
            .root_module = gzip_bench_root,
        });
        if (b.args) |args| run_gzip_bench.addArgs(args);

        const zlib_bench_root = b.createModule(.{
            .root_source_file = b.path("src/zlib/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcompress", .module = zcompress_mod },
                .{ .name = "fastmem", .module = fastmem_mod },
            },
        });
        const run_zlib_bench = benchmark.addRunTest(b, .{
            .dependency = benchmark_dep,
            .root_module = zlib_bench_root,
        });
        if (b.args) |args| run_zlib_bench.addArgs(args);

        // The zstd bench (src/zstd/bench.zig): decode only, over the
        // benchmark corpus's reference frames (bench/corpus-gen/, made by
        // `just corpus`), so the local rows match the harness's
        // zstd/decompress cells.
        const zstd_bench_root = b.createModule(.{
            .root_source_file = b.path("src/zstd/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcompress", .module = zcompress_mod },
                .{ .name = "fastmem", .module = fastmem_mod },
            },
        });
        const run_zstd_bench = benchmark.addRunTest(b, .{
            .dependency = benchmark_dep,
            .root_module = zstd_bench_root,
        });
        if (b.args) |args| run_zstd_bench.addArgs(args);

        const bench_step = b.step("bench", "Run codec benchmarks (use -Doptimize=ReleaseFast)");
        bench_step.dependOn(&run_snappy_bench.step);
        bench_step.dependOn(&run_flate_bench.step);
        bench_step.dependOn(&run_gzip_bench.step);
        bench_step.dependOn(&run_zlib_bench.step);
        bench_step.dependOn(&run_zstd_bench.step);
    }
}
