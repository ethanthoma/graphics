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

              waylandSupport = true;
              x11Support = false;

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

              glfw3 =
                let
                  waylandCmakeFlag =
                    if waylandSupport then [ "-DGLFW_BUILD_WAYLAND=ON" ] else [ "-DGLFW_BUILD_WAYLAND=OFF" ];
                  x11CmakeFlag = if x11Support then [ "-DGLFW_BUILD_X11=ON" ] else [ "-DGLFW_BUILD_X11=OFF" ];
                in
                pkgs.stdenv.mkDerivation rec {
                  name = "glfw3";
                  version = "3.4";

                  cmakeFlags = [
                    waylandCmakeFlag
                    x11CmakeFlag
                    "-DCMAKE_CXX_FLAGS=-I${pkgs.libGL.dev}/include"
                    "-DCMAKE_LD_FLAGS=-L${pkgs.libGL.out}/lib"
                  ];

                  buildInputs =
                    [ ]
                    ++ pkgs.lib.optionals waylandSupport (
                      with pkgs;
                      [
                        wayland
                        libxkbcommon
                        libffi
                        wayland-scanner
                        wayland-protocols
                      ]
                    );

                  nativeBuildInputs = with pkgs; [
                    pkg-config
                    cmake
                  ];

                  src = pkgs.fetchFromGitHub {
                    owner = name;
                    repo = name;
                    rev = version;
                    hash = "sha256-FcnQPDeNHgov1Z07gjFze0VMz2diOrpbKZCsI96ngz0=";
                  };
                };
            in
            {
              src = cleanSource ./.;

              buildInputs = with pkgs; [ wayland.dev ];

              prePatch = ''
                substituteInPlace /build/source/build.zig \
                --replace-fail '@libGL@' "${pkgs.libGL.dev}/include" \
                --replace-fail '@libwayland@' "${pkgs.wayland.dev}/include"
              '';

              # this should be improved
              preBuild = ''
                mkdir -p /build/source/wgpu_native
                cp ${wgpu-native.out}/lib/* /build/source/wgpu_native

                mkdir -p /build/source/glfw3
                cp ${glfw3}/lib/libglfw3.a /build/source/glfw3
                cp ${glfw3}/include/GLFW/* /build/source/glfw3

                ls /build/source
              '';

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
        devShells.default = env.mkShell { };
      }
    ));
}
