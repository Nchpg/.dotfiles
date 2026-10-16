{
  config,
  lib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.windowManager.sway;

  systemctl = "${config.systemd.package}/bin/systemctl";

  sessionVars = lib.concatStringsSep " " cfg.sessionVariables;

  # sway-session.target n'a que BindsTo : sans nettoyage, le login suivant ne relance rien et gnome-session refuse de démarrer.
  # `|| true` : le wrapper sway tourne sous `set -o errexit`.
  cleanupSession = ''
    ${systemctl} --user stop graphical-session.target sway-session.target || true
    ${systemctl} --user unset-environment ${sessionVars} || true
    ${systemctl} --user reset-failed || true
  '';

  # Construit à la main : bin/sway est remplacé et genFinalPackage ignorerait les options sur un symlinkJoin.
  swayBase = cfg.pkgs.sway.override {
    withGtkWrapper = true;
    isNixOS = true;
    extraSessionCommands = cleanupSession;
  };

  # Nettoie aussi à la sortie ; le wrapper amont finit par `exec sway`, impossible d'y mettre un trap.
  swayLauncher = cfg.pkgs.writeShellScript "sway-with-session-cleanup" ''
    # Ce lanceur bash exporte SHLVL, hérité par tous les enfants de sway.
    unset SHLVL

    export SWAY_UNSUPPORTED_GPU=true

    # Appels informatifs : pas de cleanup (il tuerait la session en cours).
    for arg in "$@"; do
      case "$arg" in
        -h | --help | -v | --version | -C | --validate | --get-socketpath)
          exec ${swayBase}/bin/sway "$@"
          ;;
      esac
    done

    ${swayBase}/bin/sway "$@"
    ret=$?
    ${cleanupSession}
    exit $ret
  '';

  swayPackage = cfg.pkgs.symlinkJoin {
    name = "sway-session-cleanup-${swayBase.version}";
    paths = [ swayBase ];
    postBuild = ''
      rm "$out/bin/sway"
      ln -s ${swayLauncher} "$out/bin/sway"
    '';
    inherit (swayBase) meta;

    # `providedSessions` (passthru) est requis par services.displayManager.sessionPackages.
    passthru = swayBase.passthru // {
      # genFinalPackage lit `pkg.override` sans garde ; le stub rend le paquet tel quel.
      override = _: swayPackage;
    };
  };
in
{
  options = {
    systemSettings.windowManager.sway = {
      enable = lib.mkEnableOption "Enable sway window manager";
      pkgs = lib.mkOption {
        type = lib.types.pkgs;
        default = pkgs-stable;
        description = "Pkgs to use";
      };
      sessionVariables = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        readOnly = true;
        default = [
          "WAYLAND_DISPLAY"
          "XDG_CURRENT_DESKTOP"
          "XDG_SESSION_TYPE"
          "SWAYSOCK"
        ];
        description = ''
          Variables importées dans le gestionnaire systemd user + D-Bus au démarrage de sway,
          retirées à sa sortie.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    programs.sway = {
      enable = true;
      package = swayPackage;
      extraPackages = [ ];
    };

    xdg.portal = {
      enable = true;
      wlr.enable = true;
      # Dès 2 écrans xdpw cherche un sélecteur absent de son PATH : le partage échoue sans erreur.
      wlr.settings.screencast = {
        chooser_type = "simple";
        chooser_cmd = "${lib.getExe cfg.pkgs.slurp} -f 'Monitor: %o' -or";
        # Multi-GPU : l'écran DisplayLink (evdi) est sur un autre device DRM.
        force_mod_linear = 1;
      };
      extraPortals = [ cfg.pkgs.xdg-desktop-portal-gtk ];

      # Sous `sway` et pas `common` : wlr plantait sous GDM/GNOME.
      config.sway = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.Screenshot" = [ "wlr" ];
        "org.freedesktop.impl.portal.ScreenCast" = [ "wlr" ];
      };
    };
  };
}
