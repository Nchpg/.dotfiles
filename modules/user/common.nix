{ lib, pkgs-stable, pkgs-unstable, stylix,... }:
{
  home.packages =
    (with pkgs-stable; [
      discord
      pavucontrol

      # Basic utilities
      util-linux
      coreutils
      man-db
      man-pages  
      man-pages-posix
    ])
    ++
    (with pkgs-unstable; [

    ]);


}

