{
  description = "Zig project flake";

  inputs = {
    zig2nix.url = "github:Cloudef/zig2nix";
  };

  outputs =
    { zig2nix, ... }:
    let
      flake-utils = zig2nix.inputs.flake-utils;
    in
    (flake-utils.lib.eachDefaultSystem (
      system:
      let
        env = zig2nix.outputs.zig-env.${system} {
          zig = zig2nix.outputs.packages.${system}.zig.master.bin;
          enableVulkan = true;
          enableOpenGL = true;
          enableWayland = true;
        };

        system-triple = env.lib.zigTripleFromString system;
      in
      with builtins;
      with env.lib;
      with env.pkgs.lib;
      rec {
        # nix build .#target.{zig-target}
        # e.g. nix build .#target.x86_64-linux-gnu
        packages.target = genAttrs allTargetTriples (
          target:
          env.packageForTarget target (
            let
              pkgs = env.pkgsForTarget target;

              wgpu-native = pkgs.rustPlatform.buildRustPackage rec {
                pname = "wgpu-native";
                version = "22.1.0.5";

                src = pkgs.fetchFromGitHub {
                  owner = "gfx-rs";
                  repo = "wgpu-native";
                  rev = "ba1bf590786a1fe10c22a53fc46036fc97c70f7a";
                  hash = "sha256-DNnJN5LuzA3IVTpmkFQ/6YIgC4fJ0CDjB36ysDYA9iA=";
                  fetchSubmodules = true;
                };

                cargoHash = "";

                nativeBuildInputs = [ pkgs.llvmPackages.clang ];

                cargoLock = {
                  lockFile = "${src}/Cargo.lock";
                  outputHashes = {
                    "d3d12-22.0.0" = "sha256-Gtq0xYZoWNwW+BKVLqVVKGqc+4HjaD7NN1hlzyFP5g0=";
                  };
                };

                postInstall = ''
                  cp $src/ffi/wgpu.h $out/lib
                  cp $src/ffi/webgpu-headers/webgpu.h $out/lib
                '';

                LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
              };
            in
            {
              src = cleanSource ./.;

              buildInputs = with pkgs; [ wayland.dev ];

              preBuild = ''
                mkdir -p /build/source/include/wgpu-native-v${wgpu-native.version}
                cp ${wgpu-native.out}/lib/* /build/source/include/wgpu-native-v${wgpu-native.version}
              '';

              passthru = {
                inherit wgpu-native;
              };

              zigPreferMusl = true;
              zigDisableWrap = true;
            }
          )
        );

        # nix build .
        packages.default = packages.target.${system-triple}.override {
          zigPreferMusl = false;
          zigDisableWrap = false;
        };

        # For bundling with nix bundle for running outside of nix
        # example: https://github.com/ralismark/nix-appimage
        apps.bundle.target = genAttrs allTargetTriples (
          target:
          let
            pkg = packages.target.${target};
          in
          {
            type = "app";
            program = "${pkg}/bin/master";
          }
        );

        # default bundle
        apps.bundle.default = apps.bundle.target.${system-triple};

        # nix develop
        devShells.default =
          let
            pkg = packages.target.${system-triple};
            inherit (pkg) wgpu-native;

          in
          env.mkShell {
            shellHook = ''
              ln -s ${wgpu-native.out}/lib include/wgpu-native-v${wgpu-native.version}
            '';
          };
      }
    ));
}
