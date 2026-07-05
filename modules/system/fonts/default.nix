{ pkgs-stable, ... }:

{
  # Polices système. /!\ Les modules Stylix (système et user) référencent ces
  # familles par leur nom : les retirer d'ici casserait le rendu GDM/session.
  fonts.packages = [
    pkgs-stable.nerd-fonts.fira-code
    pkgs-stable.twitter-color-emoji
    pkgs-stable.fira-sans
  ];
}
