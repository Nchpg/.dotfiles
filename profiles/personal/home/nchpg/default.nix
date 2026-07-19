{
  pkgs-stable,
  pkgs-unstable,
  ...
}:

{
  # Priorité normale (pas de mkDefault) : le profil est la couche d'intention
  # finale, les modules fournissent les défauts via `default =` de leurs
  # options ou mkDefault. Référence pour guest/default.nix et root/default.nix,
  # qui renvoient ici plutôt que de répéter cette explication.
  config = {

    userSettings = {
      defaultPkgs = pkgs-stable;

      stylix = {
        enable = true;
        # Fond perso (l'ex-wallpaper.png de la config sway, désormais dans le
        # registre modules/themes/wallpapers.nix) : fixe quel que soit le
        # thème. Commenter pour suivre le fond du thème actif.
        wallpaper = "custom-kyoto";
      };

      # Apps desktop (discord, mpv, ...) + direnv — cf. modules/user/desktop-apps.
      desktopApps = {
        enable = true;
      };

      # Barre de la session sway (cf. modules/user/waybar).
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

      btCombine = {
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
        # Outils de confort dev (lazydocker, lazysql, broot, ncdu, feh).
        devTools.enable = true;
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
