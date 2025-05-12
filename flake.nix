{
  description = "Zig Development Environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{
      flake-parts,
      nixpkgs,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      perSystem =
        {
          pkgs,
          system,
          ...
        }:
        {
          formatter = pkgs.nixfmt-rfc-style;

          devShells.default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [
              # misc
              cmake
              git
              pkg-config

              # nix
              nil

              # debugger
              lldb

              # zig
              zls
              zig_0_14

              # slang
              shader-slang

              # sokol-zig
              alsa-lib
              libGL
              libxkbcommon

              xorg.libX11
              xorg.libXi
              xorg.libXcursor

              kdePackages.wayland
            ];
          };
        };
    };
}
