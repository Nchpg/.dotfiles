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
  icon = myLib.desktop.notifyIcon config cfg.pkgs;

  sway-session = cfg.pkgs.writeShellApplication {
    name = "sway-session";
    runtimeInputs =
      with cfg.pkgs;
      [
        osConfig.programs.sway.package
        jq
        coreutils
        gawk
        util-linux
        glib.bin # gio launch
        libnotify
      ]
      ++ lib.optional kitty config.programs.kitty.package;
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
    # Faux positifs : les guillemets du JSON sont de la donnée
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
        description = "Commande (sh -c) lancée pour un app_id, à la place de celle relevée dans /proc.";
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
          plan de kitty au moment du save. Liste fermée par sécurité. Claude
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
        description = "Secondes pendant lesquelles les fenêtres d'un même processus ne sont placées que si leur titre correspond ; ensuite dans l'ordre.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ sway-session ];

    home.file.".config/sway/conf.d/session.conf" =
      lib.mkIf config.userSettings.windowManager.sway.enable
        {
          text = ''
            bindsym $mod+F5 exec sway-session save
            bindsym $mod+Shift+F5 exec sway-session restore
          '';
        };

    # socket-only : pas via séquences d'échappement
    programs.kitty.settings = lib.mkIf kitty {
      allow_remote_control = "socket-only";
      listen_on = "unix:\${XDG_RUNTIME_DIR}/kitty-{kitty_pid}";
    };
  };
}
