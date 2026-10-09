{
  config,
  lib,
  myLib,
  osConfig,
  ...
}:

let
  cfg = config.userSettings.windowManager.sway.notifications;

  c = config.lib.stylix.colors.withHashtag;
  font = config.stylix.fonts.sansSerif.name;
  # Taille "popups" de stylix, un peu petite pour des notifs.
  popupSize = toString (config.stylix.fonts.sizes.popups + 3);

  # Icônes de notif aux couleurs du thème (cf. lib/mk-themed-icon.nix).
  icon = myLib.mkThemedIcon cfg.pkgs;

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

    /* GTK ignore `gap` : marge sur l'icône à la place. */
    .notification-content .image { margin-right: 18px; }
    /* Le style de base de swaync arrondit l'image (border-radius: 100px),
       fait pour les avatars : ça rogne les coins des icônes. Même
       sélecteur que lui pour passer devant. */
    .notification-row .notification-background .notification
      .notification-default-action .notification-content .image {
      border-radius: 0;
    }
    .notification-content .text-box { margin-left: 4px; }

    .summary { font-weight: bold; font-size: 1.15em; color: ${c.base05}; }
    .time    { color: ${c.base04}; font-size: 0.85em; }
    .body    { color: ${c.base04}; }

    .close-button {
      background: transparent;
      color: ${c.base04};
      border-radius: 50%;
      margin: 8px 12px 8px 8px;
      padding: 4px;
      min-width: 24px;
      min-height: 24px;
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

  # Aucune app n'envoie d'alerte batterie : générée ici, anti-spam via un
  # fichier d'état, réarmée une fois rebranché/rechargé.
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

    # Jaune -> orange -> rouge avec la gravité.
    icon_low=${icon "status/battery-low" c.base0A}
    icon_verylow=${icon "status/battery-low" c.base09}
    icon_caution=${icon "status/battery-caution" c.base08}

    # Détermine le palier courant (du plus grave au moins grave).
    bucket=ok; urgency=normal; icon="$icon_low"; title=""; body=""
    if [ "$cap" -le "$crit" ]; then
      bucket=crit; urgency=critical; icon="$icon_caution"
      title="Batterie critique"; body="Batterie à $cap% — branche le chargeur !"
    elif [ "$cap" -le "$verylow" ]; then
      bucket=verylow; urgency=critical; icon="$icon_verylow"
      title="Batterie très faible"; body="Batterie à $cap%"
    elif [ "$cap" -le "$low" ]; then
      bucket=low; urgency=normal; icon="$icon_low"
      title="Batterie faible"; body="Batterie à $cap%"
    fi

    # -h ...:battery remplace la notif précédente au lieu d'empiler.
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

  # Tunnel vers think (cf. systemSettings.vpn.client) : prévient quand le
  # serveur cesse de répondre, et quand il revient. Même test que le module
  # vpn de waybar (TCP 443 sur 10.8.0.1), mais dans un service à part :
  # waybar lance son script une fois PAR ÉCRAN, les notifs seraient doublées.
  #
  # Un changement d'état n'est notifié qu'une fois confirmé par deux tests
  # d'affilée : au réveil, le réseau met quelques secondes à revenir, et un
  # seul échec déclencherait une fausse alerte suivie d'un « rétabli ».
  vpnClient = osConfig.systemSettings.vpn.client.enable or false;

  vpnAlert = cfg.pkgs.writeShellScript "vpn-alert" ''
    set -u
    notify=${cfg.pkgs.libnotify}/bin/notify-send
    dir="''${XDG_RUNTIME_DIR:-/tmp}/vpn-alert"
    mkdir -p "$dir"

    if [ ! -d /sys/class/net/wg0 ]; then
      now=off
    elif ${cfg.pkgs.coreutils}/bin/timeout 2 ${cfg.pkgs.bash}/bin/bash -c 'exec 3<>/dev/tcp/10.8.0.1/443' 2>/dev/null; then
      now=on
    else
      now=down
    fi

    shown=$(cat "$dir/shown" 2>/dev/null || echo "")
    pending=$(cat "$dir/pending" 2>/dev/null || echo "")

    # Premier passage de la session : on prend l'état tel quel, sans notif.
    if [ -z "$shown" ]; then
      echo "$now" > "$dir/shown"
      exit 0
    fi

    if [ "$now" = "$shown" ]; then
      rm -f "$dir/pending"
      exit 0
    fi
    if [ "$now" != "$pending" ]; then
      echo "$now" > "$dir/pending"
      exit 0
    fi

    rm -f "$dir/pending"
    echo "$now" > "$dir/shown"
    sync=string:x-canonical-private-synchronous:vpn
    case "$now" in
      down) "$notify" -u normal -i ${icon "status/network-vpn-no-route" c.base08} -h "$sync" "VPN : think injoignable" \
              "Le tunnel est monté mais 10.8.0.1 ne répond plus. Nextcloud ne synchronise pas." ;;
      off)  "$notify" -u normal -i ${icon "status/network-vpn-disabled" c.base0A} -h "$sync" "VPN : tunnel arrêté" \
              "wg0 n'existe plus. sudo systemctl start wg-quick-wg0" ;;
      on)   "$notify" -u normal -i ${icon "status/network-vpn" c.base0B} -h "$sync" "VPN : think joignable" "Le tunnel fonctionne de nouveau." ;;
    esac
  '';
in
{
  options = {
    userSettings.windowManager.sway.notifications = {
      # Suit sway : sans ce daemon, ni popups desktop ni cloche waybar/$mod+n.
      enable = lib.mkEnableOption "notifications (swaync) + alerte batterie faible" // {
        default = config.userSettings.windowManager.sway.enable;
      };
      pkgs = myLib.mkPkgsOption { inherit lib config; };
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
    # Sans cet ordre, battery-alert compare les seuils dans le mauvais sens
    # et une bascule "critique" peut ne jamais se déclencher.
    assertions = [
      {
        assertion =
          cfg.criticalBatteryThreshold <= cfg.veryLowBatteryThreshold
          && cfg.veryLowBatteryThreshold <= cfg.lowBatteryThreshold;
        message = "userSettings.windowManager.sway.notifications : les seuils batterie doivent être croissants (criticalBatteryThreshold <= veryLowBatteryThreshold <= lowBatteryThreshold).";
      }
    ];

    home.packages = [ cfg.pkgs.libnotify ];

    services.swaync.enable = true;
    # CSS maison : désactive le style stylix par défaut (sinon conflit sur
    # services.swaync.style).
    stylix.targets.swaync.enable = false;
    services.swaync.style = swayncStyle;

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

    systemd.user.services.vpn-alert = lib.mkIf vpnClient {
      Unit.Description = "Alerte de perte du tunnel VPN vers think";
      Service = {
        Type = "oneshot";
        ExecStart = "${vpnAlert}";
      };
    };
    systemd.user.timers.vpn-alert = lib.mkIf vpnClient {
      Unit.Description = "Vérifie périodiquement que think répond dans le tunnel";
      Timer = {
        OnBootSec = "1min";
        OnUnitActiveSec = "30s";
        AccuracySec = "5s"; # défaut 1 min : le 30 s ne voudrait rien dire
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
