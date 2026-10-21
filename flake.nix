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
        terraform
        zig."0.16"
      ];

      perSystem =
        { pkgs, config, ... }:
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = with config.devShells; [
              base
              docs
              terraform
              zig
            ];

            packages =
              with pkgs;
              [
                # Bench harness (bench/): a uv project on Python 3.14. uv owns
                # the Python deps; nix owns the interpreter and system tools.
                python314
                uv
                # Fleet: the AWS CLI for ad-hoc inspection, ssh/rsync for box
                # transport.
                awscli2
                openssh
                rsync
                jq
                # Cross-arch disassembly of local builds and pulled glibc
                # objects: llvm-objdump reads x86_64 and aarch64 alike.
                llvmPackages.bintools-unwrapped
                shellcheck
                # numpy and matplotlib ship manylinux wheels; their C++ runtime
                # is not in the nix Python.
                stdenv.cc.cc.lib
              ]
              # User-mode qemu runs cross-built x86 test binaries on the arm
              # dev host (AVX2 only: it lacks AVX-512). Linux only.
              ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.qemu-user ];

            # Keep uv on the nix interpreter; never download a Python.
            env = {
              UV_PYTHON = "${pkgs.python314}/bin/python3";
              UV_PYTHON_DOWNLOADS = "never";
              LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ];
            };
          };
        };
    };
}
