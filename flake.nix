{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.follows = "baskingspot/flake-parts";
    baskingspot = {
      url = "github:baskingspot/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # imports and inputsFrom below mirror each other, except the toolchain
      # version: pick that once, in the import.
      imports = with inputs.baskingspot.flakeModules; [
        base
        docs
        zig."0.16"
      ];

      perSystem =
        { pkgs, config, ... }:
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = with config.devShells; [
              base
              docs
              zig
            ];

            packages = with pkgs; [
              uv
              oxfmt
              # nixpkgs' goperf is the golang.org/x/perf package. It supplies the
              # benchstat that the bench recipes use.
              goperf
              pv
              # The bench/ fleet harness (bench/README.md): opentofu reads the
              # shared fleet stack's outputs; go builds the klauspost competitor
              # driver; cmake configures the zlib-ng competitor build.
              opentofu
              go
              cmake
              # The 32-bit proof lane (`just check-32`): wasmtime runs the
              # wasm32-wasi probe where the large-total wraps are observable.
              wasmtime
              # The conformance lanes' reference CLI (brotli-notes.md's verified
              # incantations): the same tag as the C reference pin.
              brotli
              # The conformance lanes' reference CLIs (zstd-notes.md's verified
              # incantations, the gzip oracle's streaming rows): the flake pins
              # the oracles, not the box. zlib-the-library needs no system dep —
              # the Python oracles ride CPython's bundled zlib, and the
              # competitor arms are sha-pinned tarballs the harness builds
              # itself with zig cc.
              zstd
              gzip
            ];

            env = {
              UV_PYTHON = "${pkgs.python314}/bin/python3";
              UV_PYTHON_DOWNLOADS = "never";
            };
          };
        };
    };
}
