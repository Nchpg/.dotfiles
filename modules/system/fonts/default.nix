{
  pkgs-stable,
  themes,
  ...
}:

{
  # Polices système — source unique : themes/fonts.nix (partagée avec
  # les deux modules Stylix, qui référencent ces familles par leur nom).
  fonts.packages = (themes.fontsFor pkgs-stable).packages;
}
