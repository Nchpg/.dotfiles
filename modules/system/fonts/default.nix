{ pkgs-stable, ... }:

{
  # Polices système — source unique : modules/themes/fonts.nix (partagée avec
  # les deux modules Stylix, qui référencent ces familles par leur nom).
  fonts.packages = (import ../../themes/fonts.nix pkgs-stable).packages;
}
