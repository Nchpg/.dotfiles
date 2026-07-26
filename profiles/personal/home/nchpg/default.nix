{
  pkgs-stable,
  pkgs-unstable,
  ...
}:

{
  config = {

    userSettings = {
      defaultPkgs = pkgs-stable;

      stylix = {
        enable = true;
        wallpaper = "custom-kyoto";
      };

      windowManager.sway = {
        waybar.enable = true;
        notifications.enable = true;
        rofi.enable = true;

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

      agents = {
        claude = {
          enable = true;
          statusline.enable = true;
          settings.preferredNotifChannel = "notifications_disabled";
        };

        kimiCode.enable = true;
        mammouthCode.enable = true;
        gemini.enable = true;
        opencode.enable = true;
        codex.enable = true;
        mistral.enable = true;
      };

      nixIndex.enable = true;

      dev = {
        python.enable = true;
        direnv.enable = true;
        vercelCli = {
          enable = true;
          claudePlugin.enable = true;
        };
        supabaseCli.enable = true;
        cloudflareCli = {
          enable = true;
          accountId = "32f7902412a9edeeb7fdce0691d2c653";
        };
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
      };

      gui = {
        displays.enable = true;
        pavucontrol.enable = true;
        mpv.enable = true;
        flameshot.enable = true;
        feh.enable = true;
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
    };
  };
}
