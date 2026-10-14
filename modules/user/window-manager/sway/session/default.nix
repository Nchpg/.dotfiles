{
  config,
  lib,
  osConfig,
  myLib,
  ...
}:

let
  cfg = config.userSettings.windowManager.sway.session;

  kitty = config.userSettings.terminal.kitty.enable;
  # Icônes de notif aux couleurs du thème, comme batterie et VPN (repli
  # sans stylix intégré, cf. lib/notify-icon.nix).
  icon = myLib.notifyIcon config cfg.pkgs;

  # Sway n'a aucune gestion de session : rien ne retient quelle fenêtre était
  # sur quel workspace. `sway-session save` photographie l'arbre (workspace,
  # app, commande, dossier courant du shell), `restore` relance chaque
  # PROCESSUS une fois et range ses fenêtres à leur place.
  #
  # Un processus, pas une fenêtre : Firefox ou Chrome ont toutes leurs
  # fenêtres sous le même pid et les rouvrent eux-mêmes (restauration de
  # session du navigateur). Les relancer une fois par fenêtre ouvrirait N
  # navigateurs. Le CONTENU (onglets, sessions tmux) reste l'affaire de
  # chaque app, sauf pour kitty : sway-session y relance le programme au
  # premier plan s'il est dans `resume` (Claude Code repris sur sa
  # conversation), sinon y réaffiche le scrollback lu par la socket de
  # contrôle de kitty.
  #
  # Appariement fenêtre <-> place sauvegardée : d'abord par pid (le
  # processus qu'on vient de lancer), parce que deux kitty démarrés ensemble
  # peuvent mapper dans le désordre et échanger leurs workspaces. Repli sur
  # l'app_id quand le pid ne dit rien (lancé via gio, qui sort aussitôt, ou
  # app mono-instance qui délègue à un processus déjà là). Quand plusieurs
  # places attendent le même processus (N fenêtres Firefox), le titre
  # départage : le navigateur rouvre ses onglets, la fenêtre reprend le titre
  # qu'elle avait. Sans titre identique au bout de `settle` secondes, on
  # prend dans l'ordre.
  sway-session = cfg.pkgs.writeShellApplication {
    name = "sway-session";
    runtimeInputs =
      with cfg.pkgs;
      [
        osConfig.programs.sway.package # swaymsg
        jq
        coreutils
        gawk
        util-linux # setsid
        glib.bin # gio launch, pour les apps relancées par leur .desktop
        libnotify
      ]
      ++ lib.optional kitty config.programs.kitty.package; # kitten @ get-text
    runtimeEnv = {
      SESSION_IGNORE = builtins.toJSON cfg.ignore;
      SESSION_LAUNCHERS = builtins.toJSON cfg.launchers;
      SESSION_RESUME = builtins.toJSON cfg.resume;
      SESSION_SETTLE = toString cfg.settle;
      SESSION_TIMEOUT = toString cfg.timeout;
      ICON_SAVE = icon "actions/document-save" (c: c.base0B);
      ICON_RESTORE = icon "actions/document-revert" (c: c.base0D);
      ICON_WARNING = icon "status/dialog-warning" (c: c.base0A);
    };
    # Le JSON des options contient des guillemets : shellcheck croit à des
    # quotes shell mal placées dans runtimeEnv, alors que c'est la donnée.
    excludeShellChecks = [
      "SC2089"
      "SC2090"
    ];
    text = builtins.readFile ./sway-session.sh;
  };
in
{
  options = {
    userSettings.windowManager.sway.session = {
      enable = lib.mkEnableOption "sauvegarde/restauration des fenêtres sway ($mod+F5 / $mod+Shift+F5)";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
      ignore = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "pavucontrol" ];
        description = "app_id (ou classe X11) jamais sauvegardés.";
      };
      launchers = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          discord = "discord --start-minimized";
        };
        description = ''
          Commande (sh -c) à lancer pour un app_id donné, à la place de celle
          relevée dans /proc. Pour une app que ni son nom de binaire ni son
          .desktop ne permettent de relancer.
        '';
      };
      resume = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "claude"
          "nvim"
          "vim"
          "hx"
          "nano"
          "htop"
          "btop"
          "yazi"
          "lazygit"
          "man"
          "less"
        ];
        description = ''
          Programmes relancés avec leurs arguments s'ils tournaient au premier
          plan d'un terminal kitty au moment du save. Liste fermée : relancer
          n'importe quoi (un `make deploy`, un `rm`) serait dangereux. Claude
          Code est repris sur sa conversation (`--resume <id>`).
        '';
      };
      timeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60;
        description = "Secondes d'attente des fenêtres à la restauration (navigateurs lents au démarrage).";
      };
      settle = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = ''
          Secondes pendant lesquelles les fenêtres d'un même processus
          (N fenêtres Firefox) ne sont placées que si leur titre correspond à
          celui sauvegardé. Au-delà, placées dans l'ordre.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ sway-session ];

    # Photo des fenêtres avant un reboot, puis tout relancer et ranger à sa
    # place.
    home.file.".config/sway/conf.d/session.conf" =
      lib.mkIf config.userSettings.windowManager.sway.enable
        {
          text = ''
            bindsym $mod+F5 exec sway-session save
            bindsym $mod+Shift+F5 exec sway-session restore
          '';
        };

    # Socket de contrôle par fenêtre kitty, pour lire son scrollback au save.
    # socket-only : pilotable par les processus de l'utilisateur via le
    # fichier (droits de XDG_RUNTIME_DIR), pas par les séquences d'échappement
    # qu'afficherait un programme. Nom = pid de kitty, celui de la fenêtre.
    programs.kitty.settings = lib.mkIf kitty {
      allow_remote_control = "socket-only";
      listen_on = "unix:\${XDG_RUNTIME_DIR}/kitty-{kitty_pid}";
    };
  };
}
