{ config, lib, ... }:

let
  cfg = config.userSettings.shell.zsh;
in
{
  options = {
    userSettings.shell.zsh = {
      enable = lib.mkEnableOption "Enable zsh";
      pkgs = import ../../../../lib/mk-pkgs-option.nix { inherit lib config; };
    };
  };
  config = lib.mkIf cfg.enable {
    programs.zsh = {
      enable = true;
      package = cfg.pkgs.zsh;
      enableCompletion = true;
      # Confort aligné sur fish : suggestion grise depuis l'historique +
      # coloration des commandes pendant la frappe.
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      history = {
        ignoreDups = true;
        extended = true;
      };
      initContent = builtins.concatStringsSep "\n" [
        (builtins.readFile ../common)
        (builtins.readFile ../common-posix)
        config.userSettings.shell.devShellAliases
        (builtins.readFile ./.zshrc)
      ];
    };
  };
}
