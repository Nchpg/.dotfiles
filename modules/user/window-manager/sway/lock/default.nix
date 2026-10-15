{
  config,
  lib,
  osConfig,
  myLib,
  ...
}:

# Verrouillage de la session sway : swaylock (patché), verrou d'inactivité
# et avant la veille (swayidle), `awake`, et le capot. Binds dans
# ~/.config/sway/conf.d/lock.conf.
let
  cfg = config.userSettings.windowManager.sway.lock;
  inherit (cfg) pkgs;

  # swaymsg du sway système (patché, cf. overlays/sway) : pas un second
  # sway tiré de pkgs à côté.
  swaymsgBin = "${osConfig.programs.sway.package}/bin/swaymsg";

  # Args swaylock partagés par le bind clavier (lockBindCmd) et swayidle
  # ci-dessous : une seule définition, pas de divergence possible.
  # Écran SANS capture (branché pendant le verrouillage) : swaylock prend
  # l'image par défaut (--image sans nom de sortie) et lui applique les mêmes
  # effets (flou, vignette) qu'aux captures. Sans elle, couleur unie
  # (--color, blanche par défaut, d'où le base00 ci-dessous). Fond d'écran stylix réduit à 1920 px au build :
  # le flou est calculé au verrouillage, sur TOUTES les images, une image
  # 4K le rallongerait. --color en dernier recours (pas de fond d'écran).
  lockFallbackImage =
    lib.optionalString (config.userSettings.stylix.enable && config.stylix.image != null)
      (
        " --image "
        + pkgs.runCommand "lock-fallback.png" { nativeBuildInputs = [ pkgs.imagemagick ]; } ''
          magick ${config.stylix.image} -resize '1920x1080^' $out
        ''
      );

  # Sans --screenshots : seulement pour remplacer un verrou existant avant
  # la veille (cf. lockCmdBeforeSleep), où la capture serait l'écran rouge.
  lockArgsNoCapture =
    "--clock --indicator"
    + " --color ${config.lib.stylix.colors.base00}"
    + lockFallbackImage
    + " --indicator-radius 150 --indicator-thickness 7 --effect-blur 7x5"
    + " --effect-vignette 0.5:0.5 --ring-color bb00cc --key-hl-color 880033"
    + " --line-color 00000000 --inside-color 00000088 --separator-color 00000000";
  lockArgs = "--screenshots " + lockArgsNoCapture;
  # Fondu net -> flou, pour les verrous qu'on VOIT se poser. Pas sur
  # before-sleep : la veille gèle le fondu en cours et il reprend à
  # l'ouverture du capot, ce qui donne l'illusion que le verrou se pose
  # au réveil (il est posé avant la veille). Sans fondu, swaylock rend aussi
  # la main dès le verrouillage (avec, -f attend fondu + 0,5 s) : la veille
  # part plus vite.
  fadeArgs = "--fade-in 1";
  # Le bref noir (~66 ms) qui précédait le fondu venait de sway, pas de
  # swaylock : fond opaque posé dès la demande de verrouillage, jusqu'à la
  # première image du client. Supprimé par un patch de sway, cf.
  # overlays/sway (sway-smooth-lock.patch). Un
  # assombrissement préalable (chayang) avait été essayé avant : pire, le
  # bureau revient en pleine luminosité pendant la capture + le flou.
  # Délai de grâce (n'importe quel input déverrouille) pour le SEUL verrou
  # d'inactivité, où il rattrape un verrou non voulu. Le timer de swaylock
  # est en CLOCK_MONOTONIC, figé pendant la suspension : une grâce en cours
  # au moment de la veille reste entière au réveil, et ouvrir le capot puis
  # bouger la souris déverrouille sans mot de passe. D'où aucune grâce :
  #   - sur before-sleep (la veille suit immédiatement) ;
  #   - sur le bind manuel : Ctrl+Échap puis capot fermé dans les 2 s est un
  #     geste naturel, et ce verrou-là est voulu, la grâce n'y sert à rien.
  # Reste une fenêtre de 2 s sur l'inactivité (verrou auto puis capot fermé
  # aussitôt), jugée négligeable.
  graceArgs = "--grace 2";
  # swaylock-effects patché (./swaylock-effects-defer-ack.patch) : brancher
  # ou débrancher un écran pendant le verrouillage envoie des configures
  # rapprochés ; sans tampon libre, swaylock acquittait la nouvelle taille et
  # validait la surface sans image à cette taille -> erreur de protocole,
  # sway le tue, écran rouge sans issue (reboot forcé). Le patch n'acquitte
  # qu'une fois un tampon à la bonne taille attaché, comme swaylock amont.
  #
  # Même garde-fou que le patch de sway (lib/mk-guarded-patch.nix) : build
  # arrêté si un des fichiers patchés change (relire, retester au sway
  # imbriqué avec `swaymsg create_output` pendant le verrou, mettre à jour
  # les empreintes).
  swaylockPackage = myLib.mkGuardedPatch {
    package = pkgs.swaylock-effects;
    patch = ./swaylock-effects-defer-ack.patch;
    files = {
      "main.c" = "091f2a07579124c1a7f30977432edbde45bef2243fd81248cdbfbabf4b136956";
      "render.c" = "4cfb98b4f31231217a090a7ca6ec9131976ce6f28bfcb45a726a56c5fcbc125e";
      "include/swaylock.h" = "deaf48855906eccb3ede3ef15a05bad64fed8d93fa0615b7492566ed1f71b673";
    };
    where = "modules/user/window-manager/sway/lock/default.nix";
  };
  swaylockBin = "${swaylockPackage}/bin/swaylock";
  pgrep = "${pkgs.procps}/bin/pgrep";
  pkill = "${pkgs.procps}/bin/pkill";
  sleep = "${pkgs.coreutils}/bin/sleep";
  ps = "${pkgs.procps}/bin/ps";
  user = config.home.username;
  lockCmd = "${swaylockBin} ${lockArgs} ${fadeArgs}";
  # Bind Ctrl+Échap (--locked) : ne lance un swaylock que s'il n'en tourne
  # aucun. Verrouille en temps normal ; sur l'écran rouge (swaylock mort),
  # en relance un pour déverrouiller ; sans effet sous un verrou vivant.
  # -u : seulement les swaylock de CE compte, sinon un processus « swaylock »
  # d'un autre utilisateur (guest) ferait croire au verrou et Ctrl+Échap ne
  # verrouillerait plus rien.
  lockBindCmd = "${pgrep} -u ${user} -x swaylock >/dev/null || ${lockCmd}";
  # -f (daemonize) requis : sinon le lock bloquerait l'événement before-sleep
  # (swayidle attend la fin de la commande avant de continuer).
  lockCmdIdle = "${swaylockBin} -f ${lockArgs} ${fadeArgs} ${graceArgs}";
  # Avant la veille, on REMPLACE un swaylock encore dans sa grâce par un
  # verrou sans grâce : un verrou d'inactivité (grâce 2 s) posé juste avant
  # la veille gardait sinon sa grâce gelée jusqu'au réveil (cf. graceArgs),
  # et le swaylock de before-sleep échouait (« already locked »). Un verrou
  # de plus de 3 s n'a plus de grâce : on le garde tel quel. SIGTERM (défaut
  # de pkill) tue swaylock SANS déverrouiller (seul SIGUSR1 déverrouille) :
  # sway passe le verrou en « abandonné » (écran rouge, toujours verrouillé)
  # et accepte le nouveau en remplacement. Ce nouveau verrou ne capture pas
  # l'écran (lockArgsNoCapture) : la capture serait ce fond rouge, flouté.
  # Si le remplacement échouait, on reste sur l'écran rouge verrouillé, levé
  # par Ctrl+Échap : pas de fuite.
  # `sleep` et `ps` en chemins absolus, {1..40} au lieu de `seq` : le PATH
  # du service swayidle n'a pas coreutils.
  lockCmdBeforeSleep = pkgs.writeShellScript "lock-before-sleep" ''
    pids=$(${pgrep} -u ${user} -x swaylock)
    if [ -n "$pids" ]; then
      for pid in $pids; do
        age=$(${ps} -o etimes= -p "$pid") || continue
        [ "$age" -lt 3 ] || exit 0
      done
      ${pkill} -u ${user} -x swaylock
      for _ in {1..40}; do
        ${pgrep} -u ${user} -x swaylock >/dev/null || break
        ${sleep} 0.05
      done
      exec ${swaylockBin} -f ${lockArgsNoCapture}
    fi
    exec ${swaylockBin} -f ${lockArgs}
  '';

  # `awake` : verrouille ET garde la machine éveillée capot fermé (session
  # Claude Code pilotée à distance, par ex.). L'inhibiteur logind vit
  # exactement le temps du verrouillage : swaylock tourne au premier plan
  # (pas de -f) sous systemd-inhibit, donc déverrouiller termine swaylock,
  # libère l'inhibiteur, et le capot retrouve son comportement normal
  # (veille). Rien à désactiver, impossible de l'oublier actif.
  # Pas de délai de grâce : ouvrir le capot et toucher une touche ne doit
  # pas suffire à déverrouiller.
  #
  # N'inhibe QUE le capot, pas `sleep` : rien d'autre ne met en veille ici,
  # et bloquer `sleep` empêcherait UPower d'agir à batterie critique -> portable
  # vidé jusqu'à la coupure si awake est oublié sur batterie. (Action réelle :
  # extinction. HybridSleep, le défaut NixOS, exige un swap disque pour
  # `resume` ; avec zram seul, UPower retombe sur PowerOff.)
  #
  # Anneau orange du thème (au lieu du violet) et « Éveillé » sous l'heure :
  # on voit d'un coup d'œil que ce verrou-là garde la machine allumée.
  # swaylock garde la DERNIÈRE valeur d'une option répétée, d'où l'ajout
  # après lockArgs.
  awakeArgs =
    "--ring-color ${config.lib.stylix.colors.base09}"
    + " --key-hl-color ${config.lib.stylix.colors.base0A}"
    + " --datestr Éveillé";

  awake = pkgs.writeShellApplication {
    name = "awake";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      exec systemd-inhibit --what=handle-lid-switch --mode=block \
        --who=awake --why="Session verrouillée, éveillée capot fermé (awake)" \
        ${swaylockBin} ${lockArgs} ${fadeArgs} ${awakeArgs}
    '';
  };

  # Écran interne : le premier dont le nom commence par eDP (même règle que le
  # clonage d'écran de gui/displays), plutôt qu'un eDP-1 en dur.
  internalOutput = ''
    internal=$(swaymsg -t get_outputs | jq -r '[.[] | select(.name | test("^eDP"))][0].name // empty')
    [ -n "$internal" ] || exit 0
  '';

  # Capot fermé : on éteint l'écran interne quand AUCUNE veille ne suit,
  # c'est-à-dire si :
  #   - `awake` tient son inhibiteur (repéré par son --who chez logind) ;
  #   - ou un autre écran est actif : logind ignore alors le capot
  #     (HandleLidSwitchDocked=ignore par défaut), l'écran resterait allumé.
  # Sinon la veille arrive et éteint tout : on n'y touche pas, l'écran doit
  # rester capturable par le swaylock de before-sleep (sinon fond de repli
  # au lieu du bureau flouté).
  lidClose = pkgs.writeShellApplication {
    name = "lid-close";
    runtimeInputs = [
      osConfig.programs.sway.package # swaymsg
      pkgs.systemd
      pkgs.gawk
      pkgs.jq
    ];
    text = internalOutput + ''
      if systemd-inhibit --list --no-legend --no-pager \
        | awk '$1 == "awake" && $3 == "${user}" { found = 1 } END { exit !found }' \
        || swaymsg -t get_outputs \
        | jq -e --arg internal "$internal" '[.[] | select(.active and .name != $internal)] | length > 0' >/dev/null; then
        exec swaymsg output "$internal" power off
      fi
    '';
  };
  lidOpen = pkgs.writeShellApplication {
    name = "lid-open";
    runtimeInputs = [
      osConfig.programs.sway.package # swaymsg
      pkgs.jq
    ];
    text = internalOutput + ''
      exec swaymsg output "$internal" power on
    '';
  };
in
{
  options.userSettings.windowManager.sway.lock = {
    # Suit sway : une session sway sans verrou ne se verrouille jamais, ni
    # à l'inactivité ni avant la veille.
    enable = lib.mkEnableOption "verrouillage de la session sway (swaylock, swayidle, awake)" // {
      default = config.userSettings.windowManager.sway.enable;
    };
    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        home.packages = [
          awake
          swaylockPackage
        ];

        home.file.".config/sway/conf.d/lock.conf".text = ''
          # --locked : marche AUSSI écran verrouillé, donc sur l'écran rouge (verrou
          # abandonné, swaylock mort) : relance un swaylock, que sway accepte en
          # remplacement -> écran de mot de passe au lieu d'un reboot forcé. Sans
          # effet si un swaylock tourne déjà (garde pgrep, cf. lockBindCmd).
          bindsym --locked Control+Escape exec ${lockBindCmd}

          # Capot fermé sans veille (cf. `awake`) : l'écran interne ne s'éteint
          # pas tout seul (rétroéclairage allumé contre le clavier). --locked :
          # doit marcher écran verrouillé, c'est justement le cas d'awake.
          # Éteint SEULEMENT si awake est actif (cf. lidClose) : sinon la
          # veille suit, et un écran déjà éteint fait échouer la capture de
          # swaylock (before-sleep) -> fond de repli au lieu du bureau flouté.
          bindswitch --locked lid:on exec ${lib.getExe lidClose}
          bindswitch --locked lid:off exec ${lib.getExe lidOpen}
        '';

        # Lock après 10 min d'inactivité, écrans éteints après 15 min (rallumés au
        # premier input), mise en veille après 30 min, et lock systématique avant
        # mise en veille (sinon la session revient déverrouillée au réveil). Sans
        # la veille, un portable laissé ouvert tirait 5-8 W indéfiniment, écran
        # noir.
        services.swayidle = {
          enable = true;
          package = pkgs.swayidle;
          timeouts = [
            {
              timeout = 600;
              command = lockCmdIdle;
            }
            {
              timeout = 900;
              command = "${swaymsgBin} 'output * power off'";
              resumeCommand = "${swaymsgBin} 'output * power on'";
            }
            {
              timeout = 1800;
              command = "systemctl suspend";
            }
          ];
          events."before-sleep" = "${lockCmdBeforeSleep}";
        };
      }

      # Entrée rofi : la tasse en orange (base09), la couleur de l'anneau de ce
      # verrou-là, pour l'associer d'un coup d'œil.
      (lib.mkIf config.userSettings.windowManager.sway.rofi.enable (
        myLib.mkRofiAction {
          inherit config;
          name = "awake";
          label = "Awake";
          comment = "Verrouiller en restant éveillé capot fermé";
          exec = "awake";
          color = config.lib.stylix.colors.withHashtag.base09;
          path = "M4 10 h12 v4 a5 5 0 0 1 -5 5 h-2 a5 5 0 0 1 -5 -5 z M16 11 h1.5 a2.5 2.5 0 0 1 0 5 H16 M8 3 v4 M12 3 v4";
        }
      ))
    ]
  );
}
