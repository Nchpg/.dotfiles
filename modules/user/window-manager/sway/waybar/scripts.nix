{ config, lib, ... }:

let
  sway = config.userSettings.windowManager.sway;
  cfg = sway.waybar;
  inherit (cfg) pkgs;

  libSh = builtins.readFile ./scripts/lib.sh;

  inherit (sway.notifications) vpnProbe;

  scripts = {
    "resources.sh".deps = [
      pkgs.coreutils
    ];
    "bluetooth.sh".deps = [
      pkgs.systemd
      pkgs.jq
    ];
    "nowplaying.sh".deps = [
      pkgs.playerctl
    ];
    "disk.sh".deps = [
      pkgs.coreutils
      pkgs.jq
    ];
    "weather.sh" = {
      deps = [
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
      ];
      env.WEATHER_DEFAULT_CITY = lib.head cfg.weatherCities;
    };
    "weather-city.sh" = {
      deps = [
        pkgs.coreutils
        pkgs.procps
        pkgs.systemd
      ];
      env.WAYBAR_WEATHER_SIGNAL = toString cfg.signals.weather;
    };
    "backlight.sh".deps = [
      pkgs.coreutils
      pkgs.brightnessctl
      pkgs.systemd
    ];
    "nightlight.sh" = {
      deps = [
        pkgs.coreutils
        pkgs.procps
        pkgs.systemd
      ];
      env.WAYBAR_BACKLIGHT_SIGNAL = toString cfg.signals.backlight;
    };
    "wlsunset-geo.sh" = {
      deps = [
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
        pkgs.wlsunset
      ];
      env = {
        WEATHER_DEFAULT_CITY = lib.head cfg.weatherCities;
        NIGHTLIGHT_FALLBACK_LAT = cfg.nightlight.fallbackCoords.lat;
        NIGHTLIGHT_FALLBACK_LON = cfg.nightlight.fallbackCoords.lon;
      };
    };
    "battery.sh" = {
      deps = [
        pkgs.systemd
      ];
      env = {
        BATTERY_LOW = toString sway.notifications.lowBatteryThreshold;
        BATTERY_VERYLOW = toString sway.notifications.veryLowBatteryThreshold;
      };
    };
    "vpn.sh".env = {
      VPN_IFACE = vpnProbe.iface;
      VPN_PEER = vpnProbe.peer;
      VPN_ROUTED = lib.concatStringsSep ", " vpnProbe.routed;
    };
  };

  mkScript =
    name: s:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = s.deps or [ ];
      runtimeEnv = s.env or null;
      inheritPath = false;
      text = libSh + builtins.readFile (./scripts + "/${name}");
    };

  scriptsPkg = pkgs.symlinkJoin {
    name = "waybar-scripts";
    paths = lib.mapAttrsToList mkScript scripts;
  };
in
{
  options.userSettings.windowManager.sway.waybar.scriptDir = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    description = "Dossier (store) des scripts empaquetés.";
  };

  # Hors mkIf : doit rester lisible même barre coupée
  config.userSettings.windowManager.sway.waybar.scriptDir = "${scriptsPkg}/bin";
}
