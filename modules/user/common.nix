{ pkgs-stable, ... }:

# Pas de util-linux ici : sa copie passerait devant celle de shadow (chfn, login...).
{
  home.packages = with pkgs-stable; [
    man-db
    man-pages
    man-pages-posix
  ];
}
