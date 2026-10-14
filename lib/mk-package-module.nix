# Module « un paquet derrière un interrupteur », répété à l'identique pour
# les outils sans configuration (broot, lazydocker, discord, codex…) :
# `enable` + `pkgs` + le paquet dans home.packages, rien d'autre.
#
# S'appelle depuis le default.nix du dossier du module, qui RESTE le module
# (check option-paths : dossier = chemin d'option) :
#
#   { config, lib, myLib, ... }:
#   myLib.mkPackageModule {
#     inherit config lib;
#     path = [ "tui" "broot" ];
#     description = "broot (navigateur d'arborescence)";
#   }
#
# Dès qu'un module a besoin d'autre chose (wrapper, override, fichier de
# config), il s'écrit en entier : ce helper ne prend volontairement aucune
# option de plus.
{
  config,
  lib,
  # Chemin sous userSettings, = le chemin du dossier sous modules/user.
  path,
  description,
  # Attribut du paquet dans `pkgs` ; par défaut le nom du module.
  package ? lib.last path,
  # Jeu de paquets par défaut (ex. pkgs-unstable pour un outil qui bouge vite).
  defaultPkgs ? config.userSettings.defaultPkgs,
}:
let
  cfg = lib.getAttrFromPath path config.userSettings;
in
{
  options.userSettings = lib.setAttrByPath path {
    enable = lib.mkEnableOption description;
    pkgs = import ./mk-pkgs-option.nix {
      inherit lib config;
      default = defaultPkgs;
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.${package} ];
  };
}
