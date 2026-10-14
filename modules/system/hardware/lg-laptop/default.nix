{
  config,
  lib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.hardware.lgLaptop;
  inherit (pkgs-stable) bash coreutils;

  # Modifiable sans root via le TUI ; la limite batterie est gérée à part par
  # un service systemd (cf. plus bas).
  fanMode = "/sys/devices/platform/lg-laptop/fan_mode";

  # Attribut vendeur LG (pas charge_control_end_threshold, qui le reflète
  # seulement) : vérifié inscriptible et effectif sur cette machine.
  threshold = "/sys/devices/platform/lg-laptop/battery_care_limit";
in
{
  options = {
    systemSettings.hardware.lgLaptop = {
      enable = lib.mkEnableOption "réglages LG (driver lg-laptop) accessibles sans root";
      batteryCareLimit = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            80
            100
          ]
        );
        default = null;
        example = 80;
        description = ''
          Plafond de charge batterie réappliqué à chaque démarrage (80 ou 100).
          Défaut null = on ne crée pas le service, on n'écrit rien (le firmware
          décide ; en pratique 100 au boot). Mettre 80 pour préserver la batterie.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Accès en écriture (groupe wheel) à fan_mode, pour que le TUI lg-control
    # puisse le changer sans mot de passe.
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="platform", KERNEL=="lg-laptop", RUN+="${coreutils}/bin/chgrp wheel ${fanMode}", RUN+="${coreutils}/bin/chmod g+w ${fanMode}"
    '';

    # Les valeurs sysfs LG ne persistent pas au reboot : réécrites par un
    # oneshot (plus fiable qu'une règle udev, trop tôt pour l'EC). Pas non
    # plus une règle tmpfiles `w` : elle passe à sysinit, sans attendre que
    # udev ait chargé le driver, et un chemin encore absent est sauté sans
    # erreur.
    systemd.services.lg-battery-care-limit = lib.mkIf (cfg.batteryCareLimit != null) {
      description = "Applique la limite de charge batterie LG";
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = threshold; # driver non chargé -> skip propre
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${bash}/bin/bash -c 'echo ${toString cfg.batteryCareLimit} > ${threshold}'";
      };
    };
  };
}
