{
  config,
  lib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.windowManager.sway;

  systemctl = "${config.systemd.package}/bin/systemctl";

  # Poussées dans le gestionnaire systemd user + D-Bus au démarrage de sway
  # (cf. config.template, qui les lit via sessionVariables) : elles désignent
  # un compositor précis, laissées derrière elles pointent un mort.
  sessionVars = lib.concatStringsSep " " cfg.sessionVariables;

  # sway-session.target n'a que BindsTo = graphical-session.target : ça fait
  # monter la cible au start mais rien ne la redescend quand sway se termine.
  # Le gestionnaire systemd user survit à la déconnexion (KillUserProcesses
  # = false, défaut NixOS) : sans ce nettoyage, au login suivant `start
  # sway-session.target` est un no-op (cible déjà active), waybar/swayidle/
  # wlsunset ne redémarrent jamais — pire, waybar tape l'ancien SWAYSOCK et
  # finit en start-limit-hit. Côté GNOME, gnome-session hérite d'un
  # XDG_CURRENT_DESKTOP=sway et refuse de démarrer.
  #
  # Idempotent (no-op sur session neuve). `|| true` obligatoire : le wrapper
  # sway tourne sous `set -o errexit`.
  cleanupSession = ''
    ${systemctl} --user stop graphical-session.target sway-session.target || true
    ${systemctl} --user unset-environment ${sessionVars} || true
    ${systemctl} --user reset-failed || true
  '';

  # Équivalent à ce que construirait le module NixOS (wrapper gtk,
  # XDG_CURRENT_DESKTOP, dbus) mais construit à la main : bin/sway est
  # remplacé plus bas, et genFinalPackage ne réapplique wrapperFeatures/
  # extraSessionCommands que sur un paquet encore overridable (pas un
  # symlinkJoin) — les options seraient silencieusement ignorées sinon.
  # sway-unwrapped est déjà le patché de overlays/sway.nix (fondu de
  # verrouillage sans flash noir) : cfg.pkgs vaut pkgs-stable par défaut,
  # seul jeu de paquets qui porte l'overlay.
  swayBase = cfg.pkgs.sway.override {
    withGtkWrapper = true; # = programs.sway.wrapperFeatures.gtk
    isNixOS = true;
    extraSessionCommands = cleanupSession;
  };

  # Le nettoyage au démarrage répare la session sway suivante, pas une
  # bascule sway -> GNOME : il faut AUSSI nettoyer à la sortie. Le wrapper
  # amont finit par `exec sway`, impossible d'y accrocher un trap — on
  # enveloppe une couche au-dessus.
  swayLauncher = cfg.pkgs.writeShellScript "sway-with-session-cleanup" ''
    # Ce lanceur est du bash (pas un exec direct, cf. ci-dessus) : bash
    # exporte SHLVL, que sway et tous ses enfants héritent ensuite (chaque
    # terminal ouvert démarrait à SHLVL=2). Le wrapper amont (makeBinaryWrapper)
    # ne posait pas ce problème. Purgé pour repartir de 1.
    unset SHLVL

    # Le pilote GPU propriétaire (nvidia) fait râler sway au démarrage et
    # refuse de se lancer sans cet aveu explicite. Équivalent au flag
    # --unsupported-gpu, mais posé ici pour couvrir aussi sway.desktop (GDM),
    # qui fait Exec=sway sans argument. Sway ne le lit que s'il détecte
    # effectivement un pilote propriétaire : no-op ailleurs.
    export SWAY_UNSUPPORTED_GPU=true

    # Appels informatifs (--validate, --version...) : sway sort SANS ouvrir de
    # session, donc pas de cleanupSession derrière (ça tuerait la session EN
    # COURS). Liste testée : -C/--validate coupait la session avant son ajout.
    # -V = --verbose (OUVRE une session, pas --version = -v) : retiré, il
    # était là par confusion. On balaie TOUS les arguments (pas juste $1) :
    # `sway -c fichier -C` est valide.
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

  # bin/sway remplacé par le lanceur ; le reste (dont sway.desktop, qui fait
  # Exec=sway résolu via PATH) est conservé : GDM et un lancement TTY passent
  # donc tous les deux par le nettoyage, une seule entrée "Sway" dans GDM.
  swayPackage = cfg.pkgs.symlinkJoin {
    name = "sway-session-cleanup-${swayBase.version}";
    paths = [ swayBase ];
    postBuild = ''
      rm "$out/bin/sway"
      ln -s ${swayLauncher} "$out/bin/sway"
    '';
    inherit (swayBase) meta;

    # passthru amont conservé : `providedSessions` en fait partie, requis par
    # services.displayManager.sessionPackages. L'écraser casse l'évaluation.
    passthru = swayBase.passthru // {
      # genFinalPackage lit `pkg.override` sans garde ; un symlinkJoin ne l'a
      # pas -> "attribute 'override' missing". Ce stub n'accepte aucun
      # argument nommé (intersection vide), donc genFinalPackage renvoie le
      # paquet tel quel — les deux options sont déjà dans swayBase.
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
          Variables importées dans le gestionnaire systemd user + D-Bus au
          démarrage de sway (config.template du module user) et retirées à sa
          sortie (cleanupSession) : une seule liste pour les deux.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    programs.sway = {
      enable = true;
      # wrapperFeatures/extraSessionCommands n'auraient aucun effet ici
      # (genFinalPackage ne les réapplique pas sur un symlinkJoin) : déjà
      # dans swayPackage.
      package = swayPackage;
      # Défaut NixOS = foot/swaylock/swayidle/wmenu/brightnessctl/grim/
      # pulseaudio, tous en doublon avec le côté user ou inutiles.
      extraPackages = [ ];
    };

    xdg.portal = {
      enable = true;
      wlr.enable = true; # backend Screencast/Screenshot pour wlroots
      # Dès 2 écrans, xdpw lance un sélecteur pour choisir celui à partager,
      # cherché dans son PATH systemd où il n'y en a aucun : le partage échoue
      # sans erreur côté appli ("no output found"). Clic sur l'écran voulu.
      wlr.settings.screencast = {
        chooser_type = "simple";
        chooser_cmd = "${lib.getExe cfg.pkgs.slurp} -f 'Monitor: %o' -or";
        # Recommandé multi-GPU : l'écran DisplayLink (evdi) est sur un autre
        # device DRM que l'iGPU.
        force_mod_linear = 1;
      };
      extraPortals = [ cfg.pkgs.xdg-desktop-portal-gtk ];

      # Sans routage explicite, avec plusieurs backends, FileChooser n'est
      # servi par personne (dialogue Qt moche dans flameshot).
      #
      # Sous `sway` (XDG_CURRENT_DESKTOP) et pas `common` : common s'applique
      # aussi à GDM et GNOME, où wlr ne marche pas (xdpw plantait à chaque
      # login GDM, capture/partage d'écran cassés sous GNOME).
      config.sway = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.Screenshot" = [ "wlr" ];
        "org.freedesktop.impl.portal.ScreenCast" = [ "wlr" ];
      };
    };
  };
}
