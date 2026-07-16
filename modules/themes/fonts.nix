# Source unique des polices : la liste installée côté système (fonts.packages)
# et le bloc `stylix.fonts`, consommés par modules/system/fonts,
# modules/system/stylix et modules/user/stylix. Changer de police = éditer ce
# fichier uniquement.
#
# Fichier régulier (pas un dossier) : il est donc invisible pour l'énumération
# des thèmes (readDir filtré sur type == "directory") et n'est pas auto-importé
# (lib/import-all.nix ne parcourt que modules/system et modules/user).
pkgs: rec {
  # À installer dans fonts.packages — /!\ stylix (ci-dessous) référence ces
  # familles par leur nom : le rendu GDM/session casse si elles manquent.
  packages = [
    pkgs.nerd-fonts.fira-code
    pkgs.twitter-color-emoji
    pkgs.fira-sans
  ];

  # Bloc prêt à l'emploi pour `stylix.fonts` (système ET user : même rendu
  # sur GDM et dans la session).
  stylix = {
    monospace = {
      name = "FiraCode Nerd Font";
      package = pkgs.nerd-fonts.fira-code;
    };
    serif = {
      name = "Fira Sans";
      package = pkgs.fira-sans;
    };
    sansSerif = {
      name = "Fira Sans";
      package = pkgs.fira-sans;
    };
    emoji = {
      name = "Twitter Color Emoji";
      package = pkgs.twitter-color-emoji;
    };
    sizes = {
      terminal = 16;
      applications = 10;
      desktop = 10;
    };
  };
}
