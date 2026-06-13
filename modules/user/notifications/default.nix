{ config, lib, ... }:

let
  cfg = config.userSettings.notifications;

  # Couleurs/police du thème stylix, réutilisées dans le CSS swaync ci-dessous
  # pour rester cohérent avec le reste du système.
  c = config.lib.stylix.colors.withHashtag;
  font = config.stylix.fonts.sansSerif.name;
  # Taille de police des notifs : un peu plus grande que la taille « popups »
  # de stylix, qui est petite pour les notifs.
  popupSize = toString (config.stylix.fonts.sizes.popups + 3);

  swayncStyle = ''
    * {
      font-family: "${font}";
      font-size: ${popupSize}px;
    }

    /* ---------- Popups ---------- */
    .notification-row { outline: none; }

    .notification {
      border-radius: 12px;
      margin: 6px 10px;
      background-color: ${c.base01};
      border: 1px solid ${c.base02};
      padding: 0;
    }
    .notification:hover { background-color: ${c.base02}; }
    .notification.critical { border: 1px solid ${c.base08}; }

    .notification-content { padding: 12px; border-radius: 12px; }

    .summary { font-weight: bold; font-size: 1.15em; color: ${c.base05}; }
    .time    { color: ${c.base04}; font-size: 0.85em; }
    .body    { color: ${c.base04}; }

    .close-button {
      background: transparent;
      color: ${c.base04};
      border-radius: 50%;
      margin: 4px;
      padding: 2px;
    }
    .close-button:hover { background-color: ${c.base08}; color: ${c.base00}; }

    .notification-action {
      border-radius: 8px;
      margin: 4px;
      background-color: ${c.base02};
      color: ${c.base05};
      border: 1px solid ${c.base03};
    }
    .notification-action:hover { background-color: ${c.base0D}; color: ${c.base00}; }

    /* ---------- Centre de notifications (Mod+n) ---------- */
    .blank-window { background: transparent; }

    .control-center {
      background-color: ${c.base00};
      border: 1px solid ${c.base02};
      border-radius: 16px;
      margin: 12px;
      padding: 14px;
    }
    .control-center .notification { background-color: ${c.base01}; }

    .widget-title {
      color: ${c.base05};
      font-size: 1.3em;
      margin: 4px 4px 12px 4px;
    }
    .widget-title button {
      background-color: ${c.base02};
      color: ${c.base05};
      border-radius: 8px;
      padding: 4px 10px;
      border: none;
    }
    .widget-title button:hover { background-color: ${c.base0D}; color: ${c.base00}; }

    .widget-dnd { color: ${c.base05}; margin: 6px 4px; }
    .widget-dnd > switch {
      border-radius: 12px;
      background-color: ${c.base02};
    }
    .widget-dnd > switch:checked { background-color: ${c.base0D}; }

    .notification-group-headers { color: ${c.base04}; font-weight: bold; }
  '';

  # Alerte de batterie faible : aucune app ne l'envoie, on la génère nous-mêmes.
  # Lance une notification (urgence critique sous le seuil critique) en évitant le
  # spam grâce à un fichier d'état, et se réarme une fois rebranché/rechargé.
  batteryAlert = cfg.pkgs.writeShellScript "battery-alert" ''
    set -eu
    notify=${cfg.pkgs.libnotify}/bin/notify-send
    low=${toString cfg.lowBatteryThreshold}
    verylow=${toString cfg.veryLowBatteryThreshold}
    crit=${toString cfg.criticalBatteryThreshold}

    for bat in /sys/class/power_supply/BAT*; do
      [ -e "$bat/capacity" ] && break
    done
    [ -e "$bat/capacity" ] || exit 0

    cap=$(cat "$bat/capacity")
    status=$(cat "$bat/status")
    state="''${XDG_RUNTIME_DIR:-/tmp}/battery-alert.state"
    last=$(cat "$state" 2>/dev/null || echo ok)

    # Détermine le palier courant (du plus grave au moins grave).
    bucket=ok; urgency=normal; icon=battery-low; title=""; body=""
    if [ "$cap" -le "$crit" ]; then
      bucket=crit; urgency=critical; icon=battery-caution
      title="Batterie critique"; body="Batterie à $cap% — branche le chargeur !"
    elif [ "$cap" -le "$verylow" ]; then
      bucket=verylow; urgency=critical; icon=battery-low
      title="Batterie très faible"; body="Batterie à $cap%"
    elif [ "$cap" -le "$low" ]; then
      bucket=low; urgency=normal; icon=battery-low
      title="Batterie faible"; body="Batterie à $cap%"
    fi

    # Notifie seulement en déchargement et au changement de palier (anti-spam).
    # -h ...:battery → remplace la notif batterie précédente au lieu d'empiler.
    if [ "$status" = "Discharging" ] && [ "$bucket" != ok ]; then
      if [ "$bucket" != "$last" ]; then
        "$notify" -u "$urgency" -i "$icon" \
          -h string:x-canonical-private-synchronous:battery \
          "$title" "$body"
      fi
      echo "$bucket" > "$state"
    else
      echo ok > "$state"
    fi
  '';
in {
  options = {
    userSettings.notifications = {
      enable = lib.mkEnableOption "notifications (swaync) + alerte batterie faible";
      pkgs = lib.mkOption {
        type = lib.types.attrs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
      lowBatteryThreshold = lib.mkOption {
        type = lib.types.ints.between 1 100;
        default = 20;
        description = "Seuil (%) « batterie faible » (notification normale).";
      };
      veryLowBatteryThreshold = lib.mkOption {
        type = lib.types.ints.between 1 100;
        default = 10;
        description = "Seuil (%) « batterie très faible » (urgence critique).";
      };
      criticalBatteryThreshold = lib.mkOption {
        type = lib.types.ints.between 1 100;
        default = 5;
        description = "Seuil (%) « batterie critique » (urgence critique, branche le chargeur).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # notify-send disponible sur le PATH (tests manuels, scripts).
    home.packages = [ cfg.pkgs.libnotify ];

    # Daemon de notifications : affiche les popups de toutes les apps (Discord,
    # navigateur, notify-send…) et fournit un centre de notifications (Mod+n).
    services.swaync.enable = true;
    # On fournit notre propre CSS (basé sur la palette stylix) → on désactive le
    # style stylix par défaut pour éviter le conflit sur services.swaync.style.
    stylix.targets.swaync.enable = false;
    services.swaync.style = swayncStyle;

    # Vérifie le niveau de batterie toutes les minutes.
    systemd.user.services.battery-alert = {
      Unit.Description = "Alerte de batterie faible";
      Service = {
        Type = "oneshot";
        ExecStart = "${batteryAlert}";
      };
    };
    systemd.user.timers.battery-alert = {
      Unit.Description = "Vérifie périodiquement le niveau de batterie";
      Timer = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
