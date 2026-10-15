{ config, lib, ... }:

# Les scripts d'alimentation des modules waybar (./scripts/*). Séparés de
# default.nix, qui décrit la BARRE : ici on ne fait qu'empaqueter des scripts
# shell autonomes, avec leurs dépendances propres, et default.nix ne les
# connaît que par leur chemin (`cfg.scriptDir`).
#
# Module à part entière et pas un simple helper : sous modules/, tout .nix est
# importé comme module (cf. lib/modules/import-all.nix). Il contribue donc aux MÊMES
# options que default.nix, dont il partage `enable` et `pkgs`.
let
  sway = config.userSettings.windowManager.sway;
  cfg = sway.waybar;
  inherit (cfg) pkgs;

  libSh = builtins.readFile ./scripts/lib.sh;

  # Sonde VPN : vpn-alert (notifications) en est la seule ; vpn.sh n'en lit
  # que l'état, et ces valeurs pour ses textes.
  inherit (sway.notifications) vpnProbe;

  # Par script : ses dépendances (PATH = elles seules, sans repli sur celui de
  # la session : une dépendance oubliée casse au premier lancement, pas un
  # jour où le PATH de la session change) et ses paramètres (variables
  # d'environnement, posées par writeShellApplication).
  scripts = {
    "resources.sh".deps = [
      pkgs.coreutils # nproc, sleep
    ];
    "bluetooth.sh".deps = [
      pkgs.systemd # busctl
      pkgs.jq
    ];
    "nowplaying.sh".deps = [
      pkgs.playerctl
    ];
    # jq : lecture du JSON santé NVMe publié par nvme-health-export.
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
        pkgs.procps # pkill
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
        pkgs.procps # pkill
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
        pkgs.systemd # busctl
      ];
      # Seuils de couleur = ceux des notifications batterie.
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

  # lib.sh + corps du script (son propre `#!/usr/bin/env bash` devient un
  # simple commentaire en milieu de fichier). shellcheck au build.
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
    description = ''
      Dossier (store) des scripts empaquetés par ce module. Lu par default.nix
      (`exec` des modules custom, actions de menu) et par nightlight.nix
      (unité wlsunset) : une seule définition du chemin, pas de divergence
      possible.
    '';
  };

  # Hors de tout mkIf : `scriptDir` doit rester lisible même barre coupée
  # (option readOnly, pas un effet de bord). Rien n'est construit tant que
  # personne ne le lit.
  config.userSettings.windowManager.sway.waybar.scriptDir = "${scriptsPkg}/bin";
}
