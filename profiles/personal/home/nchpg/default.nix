{
  pkgs-stable,
  pkgs-unstable,
  ...
}:

{
  # Pas de mkDefault ici : le profil est la couche d'intention finale, il
  # définit en priorité normale (les modules fournissent les défauts via
  # `default =` de leurs options ou mkDefault).
  config = {

    userSettings = {
      defaultPkgs = pkgs-stable;

      stylix = {
        enable = true;
      };

      # Apps desktop (discord, mpv, ...) + direnv — cf. modules/user/desktop-apps.
      desktopApps = {
        enable = true;
      };

      # Barre waybar (remplace la swaybar native : mêmes blocs + tray,
      # cf. modules/user/waybar).
      waybar = {
        enable = true;
      };

      vim = {
        enable = true;
      };

      neovim = {
        enable = true;
        # Aligné sur pkgs-stable : sinon le wrapper neovim (stable, via HM) et les
        # plugins (unstable) tirent deux luajit différents → conflit de buildEnv.
        # neovim est en 0.12.2 sur la 26.05, donc rien à gagner côté unstable.
      };

      tmux = {
        enable = true;
      };

      btop = {
        enable = true;
        # GPU Intel piloté par le driver `xe` (non supporté par btop amont).
        # Voir modules/user/btop pour le détail (PR #1457).
        xeGpuSupport = true;
      };

      git = {
        enable = true;
        userName = "nathan.champagne";
        userEmailSops = "git/email";
      };

      claude = {
        enable = true;
        # Barre de statut : modèle, coût, contexte, rate limits.
        statusline.enable = true;
        # Coupe les notifs desktop de Claude Code (popups « kitty »).
        settings.preferredNotifChannel = "notifications_disabled";
      };

      gh = {
        enable = true;
        # Renseigne ton login GitHub si tu veux qu'il apparaisse dans hosts.yml.
        # user = "nchpg";
      };

      wakatime = {
        enable = true;
      };

      # nix-locate + comma + suggestions command-not-found (base pré-construite).
      nixIndex = {
        enable = true;
      };

      # python + uv hors devshell (scripts ponctuels, uv run/uvx) —
      # cf. modules/user/python.
      python = {
        enable = true;
      };

      firefox = {
        enable = true;
      };

      chrome = {
        enable = true;
      };

      teams = {
        enable = true;
        # Instance isolée dédiée au tenant invité Bouygues SA, deep-linkée sur
        # son tenantId pour atterrir direct dans Bouygues (le switcher d'orga de
        # Teams v2 ne sait pas basculer vers un tenant invité dans Electron).
        # Lancée via `teams-for-linux-bouygues`. GUID issu du lien
        # d'invitation reçu (paramètre `tenant=`).
        profiles.bouygues.tenantId = "bf2ec9bc-d21e-420c-8acf-29441b9f4d45";
      };

      flameshot = {
        enable = true;
      };

      displays = {
        enable = true;
      };

      notifications = {
        enable = true;
      };

      cliphist = {
        enable = true;
      };

      wifiPicker = {
        enable = true;
      };

      bluetoothPicker = {
        enable = true;
      };

      volumeMixer = {
        enable = true;
      };

      lgControl = {
        enable = true;
      };

      rofi = {
        enable = true;
      };

      vscode = {
        enable = true;
        pkgs = pkgs-unstable;
      };

      spotify = {
        enable = true;
        theme = "default";
        # Icône de tray Spotify (SNI maison, visible dans waybar quand Spotify
        # tourne).
        tray.enable = true;
      };

      tig = {
        enable = true;
      };

      yazi = {
        enable = true;
      };

      posting = {
        enable = true;
      };

      taskTui = {
        enable = true;
      };

      calendarTui = {
        enable = true;
      };

      systemdManagerTui = {
        enable = true;
      };

      shell = {
        zsh = {
          enable = true;
        };
        fish = {
          enable = true;
        };
        bash = {
          enable = true;
        };
        default = "fish";
      };

      terminal = {
        kitty = {
          enable = true;
        };
        foot = {
          enable = true;
        };
        alacritty = {
          enable = true;
        };
        default = "kitty";
      };
    };
  };
}
