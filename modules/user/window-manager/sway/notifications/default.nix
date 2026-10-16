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
  popupSize = toString (config.stylix.fonts.sizes.popups + 3);

  icon = myLib.desktop.notifyIcon config cfg.pkgs;

  swayncStyle = ''
    * {
      font-family: "${font}";
      font-size: ${popupSize}px;
    }

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

    /* GTK ignore `gap` */
    .notification-content .image { margin-right: 18px; }
    /* Même sélecteur que le style de base (avatars arrondis) pour passer devant */
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

  batteryAlert = cfg.pkgs.writeShellApplication {
    name = "battery-alert";
    runtimeInputs = [
      cfg.pkgs.coreutils
      cfg.pkgs.libnotify
    ];
    runtimeEnv = {
      LOW = toString cfg.lowBatteryThreshold;
      VERYLOW = toString cfg.veryLowBatteryThreshold;
      CRIT = toString cfg.criticalBatteryThreshold;
      ICON_LOW = icon "status/battery-low" (c: c.base0A);
      ICON_VERYLOW = icon "status/battery-low" (c: c.base09);
      ICON_CAUTION = icon "status/battery-caution" (c: c.base08);
    };
    text = builtins.readFile ../waybar/scripts/lib.sh + builtins.readFile ./battery-alert.sh;
  };

  vpnClient = osConfig.systemSettings.vpn.client.enable or false;
  inherit (cfg) vpnProbe;

  vpnAlert = cfg.pkgs.writeShellApplication {
    name = "vpn-alert";
    runtimeInputs = with cfg.pkgs; [
      bash # /dev/tcp de la sonde, sous timeout
      coreutils
      iproute2
      libnotify
      procps
    ];
    runtimeEnv = {
      VPN_IFACE = vpnProbe.iface;
      VPN_PEER = vpnProbe.peer;
      VPN_PORT = toString vpnProbe.port;
      WAYBAR_VPN_SIGNAL = toString config.userSettings.windowManager.sway.waybar.signals.vpn;
      ICON_DOWN = icon "status/network-vpn-no-route" (c: c.base08);
      ICON_OFF = icon "status/network-vpn-disabled" (c: c.base0A);
      ICON_ON = icon "status/network-vpn" (c: c.base0B);
    };
    text = builtins.readFile ./vpn-alert.sh;
  };
in
{
  options = {
    userSettings.windowManager.sway.notifications = {
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
      vpnProbe = lib.mkOption {
        type = lib.types.attrs;
        readOnly = true;
        default = {
          iface = "wg0";
          peer = osConfig.systemSettings.vpn.wireguard.serverAddress;
          # Port de Nextcloud
          port = 443;
          routed = if vpnClient then osConfig.systemSettings.vpn.client.allowedIPs else [ ];
        };
        description = "Paramètres de la sonde du tunnel VPN (vpn-alert), partagés avec waybar.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # battery-alert suppose les seuils croissants
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
    # Évite le conflit sur services.swaync.style
    stylix.targets.swaync.enable = false;
    services.swaync.style = swayncStyle;

    home.file.".config/sway/conf.d/notifications.conf" =
      lib.mkIf config.userSettings.windowManager.sway.enable
        {
          text = ''
            bindsym $mod+n exec swaync-client -t -sw
          '';
        };

    systemd.user.services.battery-alert = {
      Unit.Description = "Alerte de batterie faible";
      Service = {
        Type = "oneshot";
        ExecStart = lib.getExe batteryAlert;
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
        ExecStart = lib.getExe vpnAlert;
      };
    };
    systemd.user.timers.vpn-alert = lib.mkIf vpnClient {
      Unit.Description = "Vérifie périodiquement que think répond dans le tunnel";
      Timer = {
        OnBootSec = "1min";
        OnUnitActiveSec = "15s";
        AccuracySec = "3s";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
