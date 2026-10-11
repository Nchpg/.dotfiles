{ pkgs-stable, ... }:

# Strict minimum commun à TOUS les users (root et guest inclus) : pages de man.
# Pas de coreutils/util-linux ici : déjà fournis par le système, et la copie
# du profil user passait DEVANT (chfn, login, nologin... de util-linux au lieu
# de ceux de shadow). Les applications desktop/dev sont dans le module
# gaté modules/user/apps (userSettings.apps.*.enable).
{
  home.packages = with pkgs-stable; [
    man-db
    man-pages
    man-pages-posix
  ];
}
