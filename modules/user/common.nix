{ lib, pkgs-stable, pkgs-unstable, stylix, inputs, ... }:
{
  home.packages =
    (with pkgs-stable; [
      discord
      pavucontrol
      mpv

      # Basic utilities
      util-linux
      coreutils
      man-db
      man-pages
      man-pages-posix

      nbfc-linux

      # pdftoppm (PDF -> image) et pdftotext, utilisés par la lecture de PDF
      poppler-utils
    ])
    ++ [
      # Claude Code via le flake dédié (toujours à jour, cf. flake.nix)
      inputs.claude-code.packages.x86_64-linux.default
    ];

  programs.direnv.enable = true;

}

