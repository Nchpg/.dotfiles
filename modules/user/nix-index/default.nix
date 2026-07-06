{ config, lib, ... }:

# nix-locate, comma et les suggestions command-not-found, via la base
# hebdomadaire pré-construite de nix-index-database (module HM importé dans
# profiles/default.nix). Remplace le command-not-found des channels, coupés
# dans modules/system/configuration.nix (nix.channel.enable = false).
let
  cfg = config.userSettings.nixIndex;
in
{
  options = {
    userSettings.nixIndex = {
      enable = lib.mkEnableOption "nix-index (nix-locate, comma, suggestions command-not-found)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Installe nix-index (base pré-construite incluse) et branche le hook
    # command-not-found des shells (bash/zsh/fish) : commande inconnue →
    # « fourni par le paquet X ». `nix-locate bin/foo` : quel paquet fournit
    # ce fichier.
    programs.nix-index.enable = true;
    # `, cmd args` : exécute un programme une fois, sans l'installer.
    programs.nix-index-database.comma.enable = true;
  };
}
