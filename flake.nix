{
  description = "Zig project flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    zig2nix = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:Cloudef/zig2nix";
    };
  };

  outputs =
    { nixpkgs, zig2nix, ... }:
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

        pkgs = nixpkgs.legacyPackages.${system};
      in
      with builtins;
      with env.lib;
      with env.pkgs.lib;
      rec {
        packages.target = genAttrs allTargetTriples (
          target:
          env.packageForTarget target (
            let
              pkgs = env.pkgsForTarget target;
            in
            {
              src = cleanSource ./.;

              buildInputs = with pkgs; [ wayland.dev ];

              zigPreferMusl = true;
              zigDisableWrap = true;
            }
          )
        );

        packages.default = packages.target.${system-triple}.override {
          zigPreferMusl = false;
          zigDisableWrap = false;
        };

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

        apps.bundle.default = apps.bundle.target.${system-triple};

        devShells.default = env.mkShell {
          packages = [
            zig2nix.outputs.packages.${system}.zon2nix
            pkgs.zls
            pkgs.wgsl-analyzer
          ];
        };
      }
    ));
}
