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
              # zig
              zls
              zig_0_14

              # slang
              shader-slang

              # sdl3
              sdl3

              # vulkan debugging
              spirv-tools
              vulkan-tools
              vulkan-validation-layers
            ];
            shellHook = ''
              # export VK_LOADER_DEBUG=all
              export VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation
              export VK_LAYER_PATH=${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d
              export SDL_HINT_RENDER_VULKAN_DEBUG=1
            '';
          };
        };
    };
}
