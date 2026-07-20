# Source unique des polices, consommée par modules/system/fonts,
# modules/system/stylix et modules/user/stylix.
pkgs: rec {
  # /!\ stylix (ci-dessous) référence ces familles par leur nom : le rendu
  # GDM/session casse si elles manquent d'ici.
  packages = [
    pkgs.nerd-fonts.fira-code
    pkgs.twitter-color-emoji
    pkgs.fira-sans
  ];

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
