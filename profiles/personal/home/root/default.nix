{ pkgs-stable, ... }:

{
  # Priorité normale (pas de mkDefault) : cf. profiles/personal/home/nchpg.
  config = {

    userSettings = {
      defaultPkgs = pkgs-stable;

      stylix = {
        enable = true;
        # Pas de `theme` : suit le thème système (systemSettings.stylix.theme),
        # donc bascule avec `theme dark|light`.
      };

      vim.enable = true;

      git = {
        enable = true;
        userName = "nathan.champagne";
        userEmailSops = "git/email";
      };

      shell = {
        zsh.enable = true;
        bash.enable = true;
        fish.enable = true;
      };
    };
  };
}
