{
  pkgs-stable,
  pkgs-unstable,
  ...
}:

{
  # Priorité normale (pas de mkDefault) : le profil est la couche d'intention
  # finale. Référence pour guest/default.nix et root/default.nix.
  config = {

    userSettings = {
      defaultPkgs = pkgs-stable;

      stylix = {
        enable = true;
        # Fixe quel que soit le thème. Commenter pour suivre le fond actif.
        wallpaper = "custom-kyoto";
      };

      desktopApps = {
        enable = true;
      };

      waybar = {
        enable = true;
      };

      vim = {
        enable = true;
      };

      neovim = {
        enable = true;
        # Aligné sur pkgs-stable : sinon le wrapper (stable) et les plugins
        # (unstable) tirent deux luajit différents -> conflit de buildEnv.
      };

      tmux = {
        enable = true;
      };

      btop = {
        enable = true;
        xeGpuSupport = true; # driver xe, non supporté par btop amont
      };

      git = {
        enable = true;
        userName = "nathan.champagne";
        userEmailSops = "git/email";
      };

      agents = {
        claude = {
          enable = true;
          statusline.enable = true;
          settings.preferredNotifChannel = "notifications_disabled"; # coupe les popups desktop
        };

        kimiCode.enable = true;
        mammouthCode.enable = true;
        gemini.enable = true;
        opencode.enable = true;
        codex.enable = true;
        mistral.enable = true;
      };

      gh = {
        enable = true;
        # user = "nchpg"; # affiché dans hosts.yml si renseigné
      };

      wakatime = {
        enable = true;
      };

      nixIndex = {
        enable = true;
      };

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
        # Deep-link tenant Bouygues (accès invité, switcher d'orga cassé sous
        # Electron) : GUID issu du lien d'invitation.
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
