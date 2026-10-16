pkgs: rec {
  # Doit contenir les familles référencées par `stylix` ci-dessous.
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
