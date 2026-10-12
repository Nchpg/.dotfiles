{ config, lib, ... }:

# Les scripts d'alimentation des modules waybar (~/.config/waybar/scripts/*).
# Séparés de default.nix, qui décrit la BARRE : ici on ne fait qu'empaqueter
# des scripts shell autonomes, avec leurs dépendances propres, et default.nix
# ne les connaît que par leur chemin (`cfg.scriptDir`).
#
# Module à part entière et pas un simple helper : sous modules/, tout .nix est
# importé comme module (cf. lib/import-all.nix). Il contribue donc aux MÊMES
# options que default.nix, dont il partage `enable` et `pkgs`.
let
  cfg = config.userSettings.windowManager.sway.waybar;
  inherit (cfg) pkgs;

  libSh = builtins.readFile ./scripts/lib.sh;

  # PATH préfixé par leurs binaires (store) : robuste si la session change de
  # PATH, celui-ci reste ajouté en repli pour le reste.
  scriptDeps = {
    "resources.sh" = [
      pkgs.coreutils
      pkgs.gawk
    ];
    "bluetooth.sh" = [
      pkgs.coreutils
      pkgs.systemd # busctl
      pkgs.jq
    ];
    "nowplaying.sh" = [
      pkgs.coreutils
      pkgs.playerctl
    ];
    # jq : lecture du JSON santé NVMe publié par nvme-health-export.
    "disk.sh" = [
      pkgs.coreutils
      pkgs.jq
    ];
    "weather.sh" = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    "backlight.sh" = [
      pkgs.coreutils
      pkgs.brightnessctl
      pkgs.systemd
    ];
    "wlsunset-geo.sh" = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      pkgs.wlsunset
    ];
    "battery.sh" = [
      pkgs.coreutils
      pkgs.systemd # busctl
    ];
    # `timeout` vient de coreutils, la connexion TCP de test est un builtin bash.
    "vpn.sh" = [
      pkgs.coreutils
      pkgs.iproute2
      pkgs.gawk
    ];
  };

  # Shebang bash épinglé + PATH déterministe + lib.sh + corps du script (son
  # propre `#!/usr/bin/env bash` devient un simple commentaire en milieu de fichier).
  mkScript =
    name:
    ''
      #!${pkgs.bash}/bin/bash
      export PATH=${lib.makeBinPath scriptDeps.${name}}:$PATH
    ''
    + libSh
    + builtins.readFile (./scripts + "/${name}");
in
{
  options.userSettings.windowManager.sway.waybar.scriptDir = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    description = ''
      Dossier des scripts installés par ce module. Lu par default.nix (`exec`
      des modules custom) et par l'unité systemd wlsunset-geo : une seule
      définition du chemin, pas de divergence possible.
    '';
  };

  config = {
    # Hors du mkIf : `scriptDir` doit rester lisible même barre coupée (option
    # readOnly, pas un effet de bord).
    userSettings.windowManager.sway.waybar.scriptDir =
      "${config.home.homeDirectory}/.config/waybar/scripts";

    home.file = lib.mkIf cfg.enable (
      lib.listToAttrs (
        map (
          n:
          lib.nameValuePair ".config/waybar/scripts/${n}" {
            text = mkScript n;
            executable = true;
          }
        ) (builtins.attrNames scriptDeps)
      )
    );
  };
}
