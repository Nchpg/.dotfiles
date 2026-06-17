{ config, lib, pkgs-stable, pkgs-unstable, inputs, ... }:

{
  config = lib.mkMerge [
    (lib.mkDefault {
    nixpkgs.config.allowUnfree = true;

    userSettings = {
      defaultPkgs = pkgs-stable;

      stylix = {
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

      gh = {
        enable = true;
        # Renseigne ton login GitHub si tu veux qu'il apparaisse dans hosts.yml.
        # user = "nchpg";
      };

      wakatime = {
        enable = true;
      };

      firefox = {
        enable = true;
      };

      chrome = {
        enable = true;
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
    })
  ];
}
