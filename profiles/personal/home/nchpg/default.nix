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

      # `ssh think` plutôt que le port et l'adresse à retaper.
      #
      # DES ADRESSES et non `think.lan.nathanchampagne.com`, à dessein : ces
      # alias servent surtout les jours où quelque chose est cassé sur le
      # serveur, et dnsmasq en fait partie. Un nom y ajouterait précisément la
      # dépendance qu'on veut éviter, alors que les adresses sont statiques par
      # construction.
      #
      # DEUX ENTRÉES, parce qu'aucune adresse ne marche partout depuis que le
      # tunnel ne route plus que `10.8.0.0/24` (cf. systemSettings.vpn.client) :
      #
      #   10.8.0.1     l'adresse de think DANS le tunnel. Joignable de partout,
      #                y compris à la maison — le tunnel est monté en permanence
      #                et la box fait le retour en épingle sur son IP publique.
      #                Elle cesse de répondre si WireGuard est à terre.
      #   192.168.1.32 l'adresse sur le LAN. Ne répond qu'à la maison, puisque
      #                le tunnel ne la route pas, mais elle ne dépend de rien
      #                d'autre que du commutateur.
      #
      # `think` porte la première : c'est celle qui marche le plus souvent, et
      # c'est le nom qu'on tape sans réfléchir. `think-lan` est le repli du cas
      # précis où c'est le tunnel lui-même qu'il faut aller réparer, cas où
      # l'autre alias serait par définition inutilisable.
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

      # AFS du CRI depuis la maison : `afs mount` prend le ticket Kerberos si
      # besoin puis monte ~/mnt/afs (cf. modules/user/epita/afs).
      epita.afs = {
        enable = true;
        login = "nathan.champagne";
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
        latex = {
          enable = true;
          pkgs = pkgs-unstable;
        };
        vercelCli = {
          enable = true;
          claudePlugin.enable = true;
        };
        supabaseCli.enable = true;

        # `cloudflareCli` RETIRÉ, et pas seulement parce qu'il ne servait plus.
        #
        # Le secret qu'il déclarait était `cloudflare/api_token`, le MÊME que
        # lego lit en root sur think pour la validation DNS-01 — donc un jeton
        # qui porte Zone:DNS:Edit sur la zone. Le déclarer ici le scellait aussi
        # pour la clé de COMPTE de gram, où il n'y a plus ni frontière root ni
        # frontière de machine : n'importe quel code tournant sous ce compte
        # pouvait repointer `cloud.` et `auth.`, se faire émettre des
        # certificats valides pour le domaine par DNS-01, et intercepter tout le
        # chemin public. C'est précisément la menace que modules/system/sops
        # décrit et referme partout ailleurs.
        #
        # Si wrangler redevient nécessaire ici, ce n'est PAS en rallumant cette
        # ligne telle quelle : il faut un jeton distinct, à la portée de
        # Workers/Pages, sous `cloudflare/wrangler_token` — c'est désormais le
        # défaut du module, justement pour que le rallumer ne puisse plus
        # redonner le jeton d'ACME.
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

        # Synchronisation avec think. À configurer une fois sur
        # `https://cloud.nathanchampagne.com` — le nom résout vers le LAN à la
        # maison, donc la synchro passe en direct sans tunnel ni portail.
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
