{ config, lib, pkgs-stable, pkgs-unstable, inputs, ... }:

{
  config = lib.mkMerge [
    {
      home.packages = [
        inputs.claude-desktop.packages.x86_64-linux.claude-desktop
      ];
    }

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
        pkgs = pkgs-unstable;
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
        userEmail = "nathan.champagne@epita.fr";
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

      notifications = {
        enable = true;
      };

      vscode = {
        enable = true;
        pkgs = pkgs-unstable;
      };

      tig = {
        enable = true;
      };

      yazi = {
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