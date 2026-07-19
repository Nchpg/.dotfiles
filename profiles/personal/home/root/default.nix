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

      # root ne se connecte pas en session graphique : pas de config sway
      # (le défaut suivrait le sway système, cf. modules/user/sway).
      sway.enable = false;

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
        # Pas de préférence particulière pour root (pas de session graphique) :
        # explicite plutôt que de dépendre du repli implicite de
        # modules/user/shell/default.nix (premier shell activé par ordre
        # alphabétique, actuellement bash).
        default = "bash";
      };
    };
  };
}
