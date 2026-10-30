# compress: compression codecs for Zig. `just --list` shows the recipes.

# The EC2 benchmark harness (bench/README.md) shares fastmem's IAM user and
# launch templates (see bench.toml), so its recipes run under that AWS profile.
export AWS_PROFILE := env("AWS_PROFILE", "baskingspot-bench")

[private]
default:
    @just --list

[doc("Unit tests for every codec, under the testingx plain-text runner")]
[group("test")]
test:
    TESTINGX_FORMAT=verbose zig build test

[doc("Fuzz every codec's targets for an iteration budget with a K, M, or G suffix, for example `just fuzz 1M`. The budget is per fuzz target. ReleaseSafe only, because a Debug fuzz run hits ziglang/zig#30655")]
[group("test")]
fuzz LIMIT="10M":
    zig build test -Doptimize=ReleaseSafe -Dfuzz --fuzz={{ LIMIT }}

[doc("Lint Zig, Python, Nix, Markdown, the workflows, and this justfile: ziglint, the ast-grep rules, zig fmt, ruff, ty, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint
    baskingspot-lint src
    zig fmt --check src build.zig demo
    uv run scripts/check_binary_files.py
    uvx ruff check --line-length 100 scripts
    uvx ruff format --check --line-length 100 scripts
    uvx ty check scripts
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md docs/content
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src build.zig demo
    uvx ruff format --line-length 100 scripts
    nix fmt
    oxfmt README.md AGENTS.md docs/content
    just --fmt

[doc("Compile-only cross-target gate: it catches 32-bit usize, shift, and overflow bugs and non-portable codegen. The targets differ most from the dev box, and freestanding targets are excluded because the testingx runner needs an OS. It is not a supported-platform claim")]
[group("test")]
check-baseline:
    just check-target x86_64-linux
    just check-target aarch64-linux
    just check-target x86-linux
    just check-target arm-linux
    just check-target riscv64-linux
    just check-target wasm32-wasi

[doc("Compile-only check for one target, such as `just check-target x86-linux`. CI runs one job per target")]
[group("test")]
check-target TARGET:
    zig build check -Dtarget={{ TARGET }}

[doc("Decode very large streams on a 32-bit target, with wasm32-wasi under wasmtime: the zstd probe's frames and the brotli probe's streams over 4 GiB")]
[group("test")]
check-32:
    zig build probe32
    wasmtime zig-out/bin/zstd-probe32.wasm
    wasmtime zig-out/bin/brotli-probe32.wasm

[doc("Everything CI runs: the unit tests, lint, the cross-target compile gate, and the docs build")]
[group("ci")]
ci: test lint check-baseline bench-check doc

[private]
api:
    docgen --root src/root.zig --title compress --repo-url https://github.com/baskingspot/compress --rev main --format json --out docs/data

[doc("Build the site into zig-out/site/compress/: the guide (Zola, from docs/), the API reference (docgen JSON rendered by the theme's api.html) under api/, and the static marks. The router in baskingspot/site serves /compress/... from it")]
[group("docs")]
doc: api
    baskingspot-docs build compress

[doc("Edit the site with live reload (http://127.0.0.1:1111)")]
[group("docs")]
guide: api
    baskingspot-docs serve compress

[doc("Deploy the rendered site to Cloudflare as an assets-only Worker (config in wrangler.jsonc). Needs CLOUDFLARE_API_TOKEN in the environment, plus CLOUDFLARE_ACCOUNT_ID if the token can see more than one account")]
[group("docs")]
doc-deploy: doc
    wrangler deploy

[doc("Check gzip against python3's zlib, CPython's gzip module, and the gzip and gunzip CLIs")]
[group("conformance")]
gzip-oracle:
    zig build gzip-oracle-harness
    uv run scripts/gzip_oracle.py

[doc("Check zlib against python3's zlib in both directions, including the FDICT refusal")]
[group("conformance")]
zlib-oracle:
    zig build zlib-oracle-harness
    uv run scripts/zlib_oracle.py

[doc("Check flate, raw deflate, against python3's zlib in both directions, and level 6 against klauspost/compress byte for byte")]
[group("conformance")]
flate-oracle:
    zig build flate-oracle-harness
    go build -C scripts/klauspost_flate -o ../../zig-out/bin/flate-klauspost .
    uv run scripts/flate_oracle.py

[doc("Check snappy framed streams against klauspost/compress's snappy-compatible s2, both directions")]
[group("conformance")]
snappy-oracle:
    zig build snappy-oracle-harness
    go build -C scripts/snappy_klauspost -o ../../zig-out/bin/snappy-klauspost .
    uv run scripts/snappy_oracle.py

[doc("Check zstd against the reference CLI and klauspost/compress. klauspost makes the strict Window_Size check that the C decoder does not")]
[group("conformance")]
zstd-oracle:
    zig build zstd-oracle-harness
    go build -C scripts/zstd_klauspost -o ../../zig-out/bin/zstd-klauspost .
    uv run scripts/zstd_oracle.py

[doc("Check brotli against the pinned reference CLI, brotli 1.2.0, and andybalholm/brotli, in both directions: decode the CLI's streams, and encode at quality 3 with byte parity to the CLI's file form")]
[group("conformance")]
brotli-oracle:
    zig build brotli-oracle-harness
    go build -C scripts/brotli_go -o ../../zig-out/bin/brotli-go .
    uv run scripts/brotli_oracle.py

[doc("Generate the benchmark corpus in bench/corpus-gen/ and verify it against bench/corpus/SHA256SUMS")]
[group("bench")]
corpus:
    zig build corpus

[doc("Local benchmarks with testingx. The numbers are not claims")]
[group("bench")]
bench *ARGS:
    zig build bench -- {{ ARGS }}

[doc("Record a fleet run's absolute throughput in docs/slop/results/scorecard-<date>.json, for example `just scorecard 20261017T115529Z-encoder-seats`")]
[group("bench")]
scorecard RUN:
    uv run --project bench python bench/scorecard.py {{ RUN }}

[doc("Regenerate the light and dark throughput charts in docs/static/ from the newest scorecard")]
[group("bench")]
plot:
    uv run --project bench python bench/plot_throughput.py

[doc("Run a codec's example CLI, for example `just example snappy encode README.md > out`")]
[group("dev")]
example CODEC *ARGS:
    zig build -Doptimize=ReleaseFast example-{{ CODEC }} -- {{ ARGS }}

[doc("Build the browser demo and serve it at http://127.0.0.1:8080")]
[group("dev")]
wasm-demo:
    zig build wasm-demo
    python3 -m http.server 8080 --bind 127.0.0.1 --directory zig-out/demo

[doc("Remove build artifacts")]
[group("dev")]
clean:
    rm -rf zig-out .zig-cache zig-pkg bench/zig-out bench/.zig-cache bench/zig-pkg

[doc("Run any harness command, for example `just b ls`, `just b up c8g --ttl 2h`, or `just b analyze RUN_DIR`")]
[group("harness")]
[working-directory("bench")]
b *ARGS:
    uv run bench {{ ARGS }}

[doc("Launch boxes, for example `just bench-up c8g c7i`. With no targets it launches every target")]
[group("harness")]
[working-directory("bench")]
bench-up *TARGETS:
    uv run bench up {{ if TARGETS == "" { "c7i c8i c7a c8a c7g c8g c9g" } else { TARGETS } }}

[doc("Terminate every box with this project's tag, including boxes the fastmem repo launched")]
[group("harness")]
[working-directory("bench")]
bench-down:
    uv run bench down --all

[doc("Show the running boxes")]
[group("harness")]
[working-directory("bench")]
bench-ls:
    uv run bench ls

[doc("Run the correctness gate on every running box (bench/README.md)")]
[group("harness")]
[working-directory("bench")]
bench-test *ARGS:
    uv run bench test {{ ARGS }}

[doc("Measure on every running box, for example `just bench-run --up --rounds 5 --label base`")]
[group("harness")]
[working-directory("bench")]
bench-run *ARGS:
    uv run bench run {{ ARGS }}

[doc("Check the harness: lint, format, and types")]
[group("harness")]
[working-directory("bench")]
bench-check:
    uv lock --check
    uv run ruff check .
    uv run ruff format --check .
    uv run ty check
