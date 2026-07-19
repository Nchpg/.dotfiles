{
  config,
  lib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.window-manager.sway;

  systemctl = "${cfg.pkgs.systemd}/bin/systemctl";

  # Variables poussées dans le gestionnaire systemd user + D-Bus au démarrage de
  # sway (cf. modules/user/sway/sway-config/config.template). Elles désignent un
  # compositor précis : laissées derrière, elles pointent un mort.
  sessionVars = "WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE SWAYSOCK";

  # Redescend la session graphique et purge l'environnement hérité.
  #
  # sway-session.target n'a que BindsTo = graphical-session.target : ça fait
  # MONTER la cible graphique au start, mais rien ne la fait redescendre quand
  # sway se termine. Or le gestionnaire systemd user survit à la déconnexion —
  # logind tourne avec KillUserProcesses=false (défaut NixOS), donc il laisse
  # les process du user en vie et user@$UID.service reste debout d'un login à
  # l'autre. Sans ce nettoyage l'état traverse donc le logout : au login sway
  # suivant `start sway-session.target` est un no-op (cible déjà active) et
  # waybar/swayidle/wlsunset ne redémarrent jamais — pire, waybar tape l'ancien
  # SWAYSOCK, crashe en boucle et finit en start-limit-hit. Côté GNOME,
  # gnome-session hérite d'un XDG_CURRENT_DESKTOP=sway et d'une cible graphique
  # déjà montée, et refuse de démarrer.
  #
  # Idempotent : sur une session neuve les cibles sont inactives et les stop
  # sont des no-op. `|| true` obligatoire, le wrapper sway tourne sous
  # `set -o errexit`.
  cleanupSession = ''
    ${systemctl} --user stop graphical-session.target sway-session.target || true
    ${systemctl} --user unset-environment ${sessionVars} || true
    ${systemctl} --user reset-failed || true
  '';

  # Paquet sway équivalent à ce que construirait le module NixOS (wrapper gtk,
  # XDG_CURRENT_DESKTOP, dbus), avec le nettoyage AVANT le lancement du
  # compositor. On le construit à la main parce qu'on remplace ensuite
  # bin/sway : `programs.sway.package` passe par genFinalPackage, qui ne
  # réapplique `wrapperFeatures`/`extraSessionCommands` que sur un paquet
  # encore overridable — un symlinkJoin ne l'est plus, les options seraient
  # silencieusement ignorées.
  swayBase = cfg.pkgs.sway.override {
    withGtkWrapper = true; # = programs.sway.wrapperFeatures.gtk
    isNixOS = true;
    extraSessionCommands = cleanupSession;
  };

  # Le nettoyage au démarrage ne suffit pas : il répare la session sway
  # suivante, pas une bascule sway -> GNOME. Il faut donc AUSSI nettoyer à la
  # sortie. Le wrapper amont finit par `exec sway`, on ne peut pas y accrocher
  # de trap : on enveloppe une couche au-dessus.
  swayLauncher = cfg.pkgs.writeShellScript "sway-with-session-cleanup" ''
    # Appels informatifs : sway répond puis sort SANS ouvrir de session, donc on
    # ne doit pas dérouler cleanupSession derrière — sinon la commande tue la
    # session EN COURS (cibles arrêtées, WAYLAND_DISPLAY/SWAYSOCK désimportés,
    # barre et services de session avec).
    #
    # -C/--validate manquait : `sway --validate` pour vérifier sa config depuis
    # un terminal coupait donc la session. C'est le cas qui a mordu.
    #
    # -V est --verbose et OUVRE une session (c'est -v qui est --version) : il
    # était dans la liste par confusion, ce qui faisait démarrer `sway -V` en
    # sautant le nettoyage. Retiré.
    #
    # On balaie TOUS les arguments et pas seulement $1 : `sway -c fichier -C`
    # est valide, et une garde sur $1 le laisse passer.
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

  # bin/sway remplacé par le lanceur. Le reste du paquet (etc/sway/config,
  # share/backgrounds, share/wayland-sessions/sway.desktop) est conservé tel
  # quel : le .desktop fait `Exec=sway`, résolu via PATH -> ce lanceur. GDM et
  # un lancement manuel depuis un TTY passent donc tous les deux par le
  # nettoyage, et il n'y a toujours qu'une seule entrée « Sway » dans GDM.
  swayPackage = cfg.pkgs.symlinkJoin {
    name = "sway-session-cleanup-${swayBase.version}";
    paths = [ swayBase ];
    postBuild = ''
      rm "$out/bin/sway"
      ln -s ${swayLauncher} "$out/bin/sway"
    '';
    inherit (swayBase) meta;

    # On repart du passthru amont : `providedSessions` en fait partie, et
    # services.displayManager.sessionPackages le vérifie (type « package with
    # provided sessions »). L'écraser casse l'évaluation.
    passthru = swayBase.passthru // {
      # genFinalPackage (nixos/modules/programs/wayland/lib.nix) lit
      # `pkg.override` sans garde pour décider s'il peut réappliquer
      # wrapperFeatures/extraSessionCommands. Un symlinkJoin n'a pas cet
      # attribut -> « attribute 'override' missing » à l'évaluation. Ce stub
      # n'accepte aucun argument nommé, donc l'intersection est vide et
      # genFinalPackage renvoie le paquet tel quel : exactement ce qu'on veut,
      # les deux options sont déjà appliquées dans swayBase.
      override = _: swayPackage;
    };
  };
in
{
  options = {
    systemSettings.window-manager.sway = {
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
      # Le wrapper gtk et le nettoyage de session sont déjà dans swayPackage
      # (cf. let) — wrapperFeatures/extraSessionCommands n'auraient aucun effet
      # ici, genFinalPackage ne les réapplique pas sur un symlinkJoin.
      package = swayPackage;
      # Le défaut du module NixOS installe foot, swaylock, swayidle, wmenu,
      # brightnessctl, grim et pulseaudio (!) — tous en doublon avec le côté
      # user (modules/user/{terminal,sway,flameshot}) ou inutiles (pipewire).
      extraPackages = [ ];
    };

    # Partage d'écran (Discord/Chrome) sur Wayland : active xdg-desktop-portal
    # avec le backend wlroots + PipeWire. programs.sway route déjà ScreenCast/
    # Screenshot vers wlr ; ici on active le portail et on s'assure que gtk est
    # présent pour le reste (FileChooser, etc.).
    xdg.portal = {
      enable = true;
      wlr.enable = true; # backend Screencast/Screenshot pour wlroots
      extraPortals = [ cfg.pkgs.xdg-desktop-portal-gtk ];

      # Routage des interfaces de portail. Sans ça, avec XDG_CURRENT_DESKTOP=sway
      # et plusieurs backends, FileChooser n'est servi par personne (dialogue Qt
      # moche dans flameshot). On met gtk par défaut (joli sélecteur de fichiers)
      # tout en gardant wlr pour la capture/partage d'écran.
      config.common = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.Screenshot" = [ "wlr" ];
        "org.freedesktop.impl.portal.ScreenCast" = [ "wlr" ];
      };
    };
  };
}
