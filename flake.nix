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

              glibc

              # Audio backends
              alsa-lib # ALSA (libasound2)
              pulseaudio # PulseAudio (libpulse0)
              jack2 # JACK (libjack0)
              sndio # sndio
              # (OSS support is typically handled by alsa-lib’s OSS plugin)

              # X11 video & input
              xorg.libX11
              xorg.libXext
              xorg.libXrandr
              xorg.libXcursor
              xorg.libXfixes
              xorg.libXi
              libxkbcommon
              udev # libudev device enumeration
              ibus # Input Method support

              # Hardware‐accelerated graphics
              libdrm # DRM/GBM
              libgbm
              mesa # libGL, OpenGL/EGL/GLES
              vulkan-loader # Vulkan loader

              # “Recommends”-style deps (nice to have)
              dbus
              libayatana-appindicator # app indicator support

              # Optional extras
              pipewire
              liburing
              xdg-utils
            ];
          };
        };
    };
}
