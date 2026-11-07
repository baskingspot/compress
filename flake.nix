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
      # imports and inputsFrom below mirror each other, including the
      # toolchain versions. Both build; the default is the current stable,
      # and `zig-old` is the previous one for the CI compatibility lane and
      # for local checks.
      imports = with inputs.baskingspot.flakeModules; [
        base
        docs
        zig."0.16"
        zig."0.17"
      ];

      perSystem =
        {
          pkgs,
          lib,
          config,
          ...
        }:
        let
          # Both shells carry the same tools, so a recipe runs the same way
          # on either compiler. ziglint-0-16 points the deprecation rule at
          # the oldest API surface the repo supports.
          packages = [
            config.packages."ziglint-0-16"
          ]
          ++ (with pkgs; [
            uv
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
          ])
          # `just test-be` runs the unit tests on a big-endian target;
          # qemu-user builds only for Linux hosts.
          ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.qemu-user ];

          env = {
            UV_PYTHON = "${pkgs.python315}/bin/python3";
            UV_PYTHON_DOWNLOADS = "never";
          };
        in
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells.docs
              config.devShells."zig-0-17"
            ];
            inherit packages env;
          };

          devShells.zig-old = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells.docs
              config.devShells."zig-0-16"
            ];
            inherit packages env;
          };
        };
    };
}
