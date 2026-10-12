# zcompress: fast compression codecs for Zig. `just --list` shows the recipes.

default: test

# Unit tests for every codec
test:
    ZTEST_VERBOSE=1 zig build test

# Fuzz every codec's targets for an iteration budget (K/M/G suffix, e.g.
# `just fuzz 1M`). ReleaseSafe only: a Debug-mode fuzz run hits
# ziglang/zig#30655. The budget is per fuzz target.
fuzz LIMIT="10M":
    zig build test -Doptimize=ReleaseSafe -Dfuzz --fuzz={{ LIMIT }}

# Lint Zig + Python: ziglint + zig fmt over the .ziglint.zon paths,
# ruff + ty over the scripts (uv-managed tooling, no project files)
lint:
    ziglint
    zig fmt --check src build.zig
    uvx ruff check --line-length 100 scripts
    uvx ruff format --check --line-length 100 scripts
    uvx ty check scripts

# Apply zig fmt
fmt:
    zig fmt src build.zig

# Decode very large zstd frames on a 32-bit target (wasm32-wasi under wasmtime)
check-32:
    zig build probe32 && wasmtime zig-out/bin/zstd-probe32.wasm

# Compile-only cross-target gate: every portable fallback path must compile
# (freestanding targets are excluded: the ztest runner needs an OS)
check-baseline:
    zig build check -Dtarget=x86_64-linux
    zig build check -Dtarget=x86-linux
    zig build check -Dtarget=arm-linux
    zig build check -Dtarget=riscv64-linux
    zig build check -Dtarget=wasm32-wasi

# Check gzip against python3's zlib, CPython's gzip module, and the gzip/gunzip CLIs
gzip-oracle:
    zig build gzip-oracle-harness
    uv run scripts/gzip_oracle.py

# Check zlib against python3's zlib in both directions, including the FDICT refusal
zlib-oracle:
    zig build zlib-oracle-harness
    uv run scripts/zlib_oracle.py

# Check flate (raw deflate) against python3's zlib in both directions
flate-oracle:
    zig build flate-oracle-harness
    uv run scripts/flate_oracle.py

# Generate the benchmark corpus in bench/corpus-gen/ and verify it against bench/corpus/SHA256SUMS
corpus:
    zig build corpus

# Local benchmarks (zig-benchmark). The numbers are not claims.
bench *ARGS:
    zig build bench -Doptimize=ReleaseFast -- {{ ARGS }}

# Run an example CLI (e.g. just example snappy encode README.md > out)
example example *args:
    zig build -Doptimize=ReleaseFast example-{{ example }} -- {{ args }}

# Clean build artifacts
clean:
    rm -rf zig-out .zig-cache zig-pkg bench/zig-out bench/.zig-cache bench/zig-pkg

# EC2 benchmark harness (bench/README.md). It shares fastmem's IAM user and
# launch templates (see bench.toml), so every recipe below runs under that AWS
# profile.
export AWS_PROFILE := env("AWS_PROFILE", "fastmem-bench")

# Run any harness command (e.g. just b ls, just b up c8g --ttl 2h, just b analyze <run-dir>)
[working-directory("bench")]
b *ARGS:
    uv run bench {{ ARGS }}

# Launch boxes (e.g. just bench-up c8g c7i, or just bench-up for every target)
[working-directory("bench")]
bench-up *TARGETS:
    uv run bench up {{ if TARGETS == "" { "c7i c8i c7a c8a c7g c8g c9g" } else { TARGETS } }}

# Terminate every box with this project's tag, including boxes the fastmem repo launched
[working-directory("bench")]
bench-down:
    uv run bench down --all

# Show the running boxes
[working-directory("bench")]
bench-ls:
    uv run bench ls

# Correctness gate on every running box (bench/README.md)
[working-directory("bench")]
bench-test *ARGS:
    uv run bench test {{ ARGS }}

# Measure on every running box (e.g. just bench-run --up --rounds 5 --label base)
[working-directory("bench")]
bench-run *ARGS:
    uv run bench run {{ ARGS }}

# Harness checks: lint, format, types
[working-directory("bench")]
bench-check:
    uv --preview-features format-command format
    uv --preview-features format-command format --check
    uv --preview-features check-command check
