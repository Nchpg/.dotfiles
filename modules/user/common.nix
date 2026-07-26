{ pkgs-stable, ... }:

# Strict minimum commun à TOUS les users (root et guest inclus) : utilitaires
# de base et pages de man. Les applications desktop/dev sont dans le module
# gaté modules/user/apps (userSettings.apps.*.enable).
{
  home.packages = with pkgs-stable; [
    util-linux
    coreutils
    man-db
    man-pages
    man-pages-posix
  ];
}
