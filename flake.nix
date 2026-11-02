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
      # toolchain version. Both versions build; the default is the current
      # stable, and `zig-old` is the previous one for the CI compatibility
      # lane and for local checks.
      imports = with inputs.baskingspot.flakeModules; [
        base
        docs
        terraform
        zig."0.16"
        zig."0.17"
      ];

      perSystem =
        { pkgs, config, ... }:
        let
          project =
            with pkgs;
            [
              # Bench harness (bench/): a uv project on Python 3.14. uv owns
              # the Python deps; nix owns the interpreter and system tools.
              python315
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
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.qemu-user ]
            ++ [ config.packages."ziglint-0-16" ];
          env = {
            # Keep uv on the nix interpreter; never download a Python.
            UV_PYTHON = "${pkgs.python315}/bin/python3";
            UV_PYTHON_DOWNLOADS = "never";
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ];
          };
        in
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells.docs
              config.devShells.terraform
              config.devShells."zig-0-17"
            ];
            packages = project;
            inherit env;
          };

          devShells.zig-old = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells.docs
              config.devShells.terraform
              config.devShells."zig-0-16"
            ];
            packages = project;
            inherit env;
          };
        };
    };
}
