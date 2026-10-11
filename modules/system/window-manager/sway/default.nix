{
  config,
  lib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.windowManager.sway;

  systemctl = "${cfg.pkgs.systemd}/bin/systemctl";

  # Poussées dans le gestionnaire systemd user + D-Bus au démarrage de sway
  # (cf. config.template) : elles désignent un compositor précis, laissées
  # derrière elles pointent un mort.
  sessionVars = "WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE SWAYSOCK";

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
  # Patch local (./sway-smooth-lock.patch) : au verrouillage, sway pose un
  # fond noir opaque sur chaque sortie AVANT que le locker ait dessiné, d'où
  # un flash noir (~66 ms) avant le fondu de swaylock. Le fond n'apparaît plus
  # qu'une fois la surface du locker affichée sur la sortie. Garde-fous :
  #   - 200 ms sans image du locker -> fond opaque partout quand même ;
  #   - locker mort (abandon) -> fond rouge immédiat, comme en amont ;
  #   - sortie branchée après le timeout -> opaque d'emblée.
  # Pendant cette fenêtre, l'input va déjà au seul locker (seat.c) : le
  # bureau reste visible un instant mais n'est plus interactif.
  #
  # Conséquences : sway n'est plus servi par le cache (recompilé à chaque
  # bump, ~1 min), et un bump qui touche sway/lock.c fait échouer le build
  # sur l'application du patch — à rebaser alors, ou à retirer.
  #
  # Garde-fou : le patch n'est appliqué que si les fichiers qu'il modifie sont
  # EXACTEMENT ceux contre lesquels il a été écrit et testé (empreintes
  # ci-dessous, sources de sway 1.12). Un bump qui ne touche pas ces fichiers
  # passe sans rien demander ; un bump qui les touche arrête le build en les
  # nommant — même si le patch s'appliquerait encore, car un lock.c au sens
  # changé pourrait compiler ET mal se comporter. Dans ce cas : relire le
  # patch contre la nouvelle version, le retester (sway imbriqué : verrou
  # filmé, écran branché/débranché, locker tué), puis mettre à jour les
  # empreintes (`sha256sum` sur les sources non patchées).
  swayPatchedFiles = ''
    d147eebafe77eb2986a49dffa7a12f88d50e8793e158aa1a28192771a70a10f5  sway/lock.c
    80af1b5ae13164f4d09851201a931d8aea7a3838b093391fc94e8337e4c1d3e5  include/sway/server.h
  '';
  swayUnwrapped = cfg.pkgs.sway-unwrapped.overrideAttrs (old: {
    # prePatch : sources encore vierges, avant les patchs nixpkgs et le nôtre.
    prePatch = (old.prePatch or "") + ''
      if ! sha256sum --check --quiet <<'EOF'
      ${swayPatchedFiles}
      EOF
      then
        echo "sway-smooth-lock.patch : les fichiers ci-dessus ont changé dans sway ''${version}." >&2
        echo "Relire et retester le patch, puis mettre à jour swayPatchedFiles" >&2
        echo "(modules/system/window-manager/sway/default.nix)." >&2
        exit 1
      fi
    '';
    patches = (old.patches or [ ]) ++ [ ./sway-smooth-lock.patch ];
  });

  swayBase = cfg.pkgs.sway.override {
    sway-unwrapped = swayUnwrapped;
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
