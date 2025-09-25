{
  description = "Zig project flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    devshell.url = "github:numtide/devshell";

    zig2nix = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:Cloudef/zig2nix";
    };
  };

  outputs =
    inputs@{ ... }:

    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.devshell.flakeModule ];

      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "i686-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      perSystem =
        { system, ... }:
        let
          pkgs = import inputs.nixpkgs {
            inherit system;
            config.allowUnfree = true;
            overlays = [ inputs.devshell.overlays.default ];
          };

          env = inputs.zig2nix.outputs.zig-env.${system} { };
        in
        {
          _module.args.pkgs = pkgs;

          packages.default = env.package rec {
            src = env.pkgs.lib.cleanSource ./.;

            nativeBuildInputs = [ ];
            buildInputs = [
              pkgs.glfw
              pkgs.wayland
              pkgs.vulkan-loader
              pkgs.libxkbcommon
            ];

            zigBuildZonLock = ./build.zig.zon2json-lock;
            zigWrapperLibs = buildInputs;

            zigPreferMusl = true;
            zigDisableWrap = false;
          };

          devshells.default = {
            packages = [
              env.pkgs.zls
              pkgs.wgsl-analyzer
              pkgs.claude-code
            ];

            commands = [
              { package = env.pkgs.zig; }
              {
                name = "claude";
                package = pkgs.claude-code;
              }
            ];

            env = [
              {
                name = "LD_LIBRARY_PATH";
                value = "${pkgs.lib.makeLibraryPath [
                  pkgs.vulkan-loader
                  pkgs.glfw
                  pkgs.wayland
                  pkgs.libxkbcommon
                ]}";
              }
              {
                name = "VK_LAYER_PATH";
                value = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
              }
            ];
          };
        };
    };
}
