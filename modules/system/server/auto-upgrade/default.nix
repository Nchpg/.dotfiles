{
  config,
  lib,
  ...
}:

let
  cfg = config.systemSettings.autoUpgrade;

  derivedRebootWindow =
    let
      m = builtins.match "([0-9]{1,2}):[0-9]{2}" cfg.window;
      hour = lib.toIntBase10 (lib.head m);
      fmt = h: "${lib.fixedWidthString 2 "0" (toString (lib.mod h 24))}:00";
    in
    if m == null then
      null
    else
      {
        lower = fmt hour;
        upper = fmt (hour + 2);
      };
in
{
  options.systemSettings.autoUpgrade = {
    enable = lib.mkEnableOption "mises à jour automatiques du système";

    flake = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "github:Nchpg/.dotfiles#server-think";
      description = "Flake à construire, cible comprise (URL distante).";
    };

    reboot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Redémarre quand la mise à jour touche le noyau ou l'initrd.";
    };

    window = lib.mkOption {
      type = lib.types.str;
      default = "04:40";
      description = "Heure de passage, au format systemd (`OnCalendar`).";
    };

    rebootWindow = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            lower = lib.mkOption {
              type = lib.types.str;
              example = "04:00";
              description = "Début de la plage, `HH:MM`.";
            };
            upper = lib.mkOption {
              type = lib.types.str;
              example = "06:00";
              description = "Fin de la plage, `HH:MM`.";
            };
          };
        }
      );
      default = derivedRebootWindow;
      defaultText = lib.literalExpression "de l'heure pleine de `window` à deux heures plus tard, si `window` est de la forme HH:MM";
      description = "Plage hors de laquelle le redémarrage n'a pas lieu. Suit `window` par défaut.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.flake != null;
        message = "systemSettings.autoUpgrade.flake est requis : sans URL distante, l'unité reconstruirait la copie locale du dépôt, qui n'est pas forcément à jour.";
      }
      {
        assertion = !cfg.reboot || cfg.rebootWindow != null;
        message = "systemSettings.autoUpgrade : `window` (${cfg.window}) n'est pas de la forme HH:MM, la plage de redémarrage ne peut pas en être déduite. Renseigne rebootWindow.";
      }
    ];

    system.autoUpgrade = {
      enable = true;
      inherit (cfg) flake;
      dates = cfg.window;
      randomizedDelaySec = "30min";
      allowReboot = cfg.reboot;
      inherit (cfg) rebootWindow;
      operation = "switch";
    };

    systemSettings.notify.discord.units = [ "nixos-upgrade" ];

    # Sans --delete-older-than, les anciennes générations restent des racines du GC.
    nix.gc = {
      automatic = lib.mkDefault true;
      options = lib.mkDefault "--delete-older-than 30d";
    };
  };
}
