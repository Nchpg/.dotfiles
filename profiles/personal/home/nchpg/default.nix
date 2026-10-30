{ pkgs-unstable, ... }:

{
  config = {

    userSettings = {
      stylix.wallpaper = "custom-kyoto";

      windowManager.sway = {
        waybar.enable = true;
        notifications.enable = true;
        rofi.enable = true;
        session.enable = true;

        pickers = {
          cliphist.enable = true;
          wifi.enable = true;
          bluetooth.enable = true;
          volume.enable = true;
        };
      };

      editors = {
        vim.enable = true;

        neovim.enable = true;

        wakatime.enable = true;

        vscode = {
          enable = true;
          pkgs = pkgs-unstable;
        };
      };

      git = {
        enable = true;
        userName = "nathan.champagne";
        userEmailSops = "git/email";

        gh.enable = true;

        tig.enable = true;
      };

      ssh.waypipe.hosts = [
        "think"
        "think-lan"
      ];

      # Des adresses et non des noms DNS : ces alias servent quand dnsmasq est cassé.
      # `think-lan` (LAN seulement) sert de repli pour réparer le tunnel.
      ssh.hosts = {
        think = {
          HostName = "10.8.0.1";
          Port = 3249;
          User = "nchpg";
        };

        think-lan = {
          HostName = "192.168.1.32";
          Port = 3249;
          User = "nchpg";
        };
      };

      epita.afs = {
        enable = true;
        login = "nathan.champagne";
      };

      agents = {
        claude = {
          enable = true;
          statusline.enable = true;
          screenshots.enable = true;
          settings.preferredNotifChannel = "notifications_disabled";
        };

        kimiCode.enable = true;
        mammouthCode.enable = true;
        herdr.enable = true;
        gemini.enable = true;
        opencode.enable = true;
        codex.enable = true;
        mistral.enable = true;
      };

      nixIndex.enable = true;

      dev = {
        python.enable = true;
        direnv.enable = true;
        latex = {
          enable = true;
          pkgs = pkgs-unstable;
        };
        vercelCli = {
          enable = true;
          claudePlugin.enable = true;
        };
        supabaseCli.enable = true;
        difit.enable = true;

        # Pas de cloudflareCli : son secret est celui de lego (Zone:DNS:Edit), gram ne doit pas le lire.
      };

      browsers = {
        firefox.enable = true;
        chrome.enable = true;
      };

      apps = {
        discord.enable = true;

        teams = {
          enable = true;
          profiles.bouygues.tenantId = "bf2ec9bc-d21e-420c-8acf-29441b9f4d45";
        };

        spotify = {
          enable = true;
          theme = "default";
          tray.enable = true;
        };

        nextcloud.enable = true;

        artcraft.enable = true;

        claudeDesktop.enable = true;
      };

      gui = {
        displays.enable = true;
        pavucontrol.enable = true;
        mpv.enable = true;
        vlc.enable = true;
        flameshot.enable = true;
        wfRecorder.enable = true;
        feh.enable = true;
        defaultApps.enable = true;
      };

      tui = {
        btop = {
          enable = true;
          xeGpuSupport = true;
        };
        systemdManager.enable = true;
        task.enable = true;
        calendar.enable = true;
        yazi.enable = true;
        posting.enable = true;
        lgControl.enable = true;

        lazygit.enable = true;
        lazydocker.enable = true;
        lazysql.enable = true;
        ncdu.enable = true;
        broot.enable = true;
      };

      shell = {
        zsh.enable = true;
        fish.enable = true;
        bash.enable = true;
        default = "fish";
      };

      terminal = {
        kitty.enable = true;
        foot.enable = true;
        alacritty.enable = true;
        default = "kitty";
      };

      tmux.enable = true;

      cli.kat.enable = true;
    };
  };
}
