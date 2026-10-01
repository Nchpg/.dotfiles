{
  config,
  lib,
  osConfig,
  myLib,
  ...
}:

let
  cfg = osConfig.systemSettings.windowManager.sway;

  templateContent = builtins.readFile ./sway-config/config.template;

  # alacritty exige -e ; kitty et foot acceptent le programme directement.
  term = config.userSettings.terminal.default;
  # $XDG_RUNTIME_DIR (aligné sur les shells) : sway exec passe par sh -c, donc
  # bien expansé, toujours défini dans une session sway/wayland.
  tmuxCmd = "env TMUX_TMPDIR=$XDG_RUNTIME_DIR tmux new-session -A -s main";
  tmuxLaunch = if term == "alacritty" then "${term} -e ${tmuxCmd}" else "${term} ${tmuxCmd}";

  # Émis seulement si le module user `optPath` est activé : évite un bind mort
  # ou un daemon lancé dans le vide quand le programme n'est pas installé.
  # Chemin inexistant = ERREUR d'éval, pas un `false` silencieux, cf.
  # lib/option-enabled.nix.
  bindIf = optPath: str: lib.optionalString (myLib.optionEnabled config.userSettings optPath) str;

  tmuxBind = bindIf "tmux" "bindsym Control+Return exec ${tmuxLaunch}";
  firefoxBind = bindIf "browsers.firefox" "bindsym $mod+Shift+f exec firefox";

  # Nom de binaire résolu depuis le paquet (substituable : google-chrome-stable
  # / chromium / ungoogled), pas un chemin store : le PATH doit résoudre le
  # wrapper home-manager qui porte les flags Wayland.
  chromeBind = lib.optionalString config.userSettings.browsers.chrome.enable "bindsym $mod+Shift+c exec ${baseNameOf (lib.getExe config.userSettings.browsers.chrome.package)}";

  menuBind = bindIf "windowManager.sway.rofi" "bindsym $mod+d exec $menu";
  searchBind = bindIf "windowManager.sway.rofi" "bindsym XF86Search exec $menu";
  swayncBind = bindIf "windowManager.sway.notifications" "bindsym $mod+n exec swaync-client -t -sw";

  flameshotDaemon = bindIf "gui.flameshot" "exec QT_QPA_PLATFORM=wayland flameshot";

  # La surface de l'overlay couvre TOUT le layout (tous les écrans), mais
  # flameshot demande lui-même un plein écran sur UN output juste après le
  # map : sway y compresse l'image, et ça écrase un for_window. On attend
  # cette demande puis on repasse en `fullscreen global` (étalé 1:1).
  flameshotGui = cfg.pkgs.writeShellScript "flameshot-gui" ''
    QT_QPA_PLATFORM=wayland QT_QPA_PLATFORMTHEME=xdgdesktopportal flameshot gui &
    for _ in $(seq 40); do
      mode=$(swaymsg -t get_tree | ${lib.getExe cfg.pkgs.jq} '[.. | objects | select(.type == "con" and .name == "flameshot") | .fullscreen_mode] | first // empty')
      if [ "$mode" = 1 ]; then
        exec swaymsg '[title="^flameshot$"] border none, fullscreen enable global'
      fi
      sleep 0.05
    done
  '';
  flameshotBinds = bindIf "gui.flameshot" ''
    # QT_QPA_PLATFORM=wayland : copie via KSystemClipboard (wlr-data-control),
    # actif seulement en Wayland natif. QT_QPA_PLATFORMTHEME=xdgdesktopportal :
    # boîte "Save" via le sélecteur de fichiers GTK.
    # Lancé via flameshotGui (cf. plus haut) pour le multi-écran.
    bindsym Print exec ${flameshotGui}
    bindsym Shift+Print exec grim -g "$(slurp -d)" - | wl-copy
  '';

  # Toggle : le même bind démarre puis arrête l'enregistrement (cf. le script
  # screenrec du module wf-recorder). Print/Shift+Print restent à flameshot.
  wfRecorderBinds = bindIf "gui.wfRecorder" ''
    bindsym $mod+Print exec screenrec region
    bindsym $mod+Shift+Print exec screenrec screen
  '';

  # Résolu par stylix (thème actif ou surcharge userSettings.stylix.wallpaper).
  # Pas de ligne bg si stylix est coupé pour ce user.
  wallpaperBg = lib.optionalString (
    config.userSettings.stylix.enable && config.stylix.image != null
  ) "output * bg ${config.stylix.image} fill";

  # Args swaylock partagés par le bind clavier (@lockCmd@) et swayidle
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
        + cfg.pkgs.runCommand "lock-fallback.png" { nativeBuildInputs = [ cfg.pkgs.imagemagick ]; } ''
          magick ${config.stylix.image} -resize '1920x1080^' $out
        ''
      );

  lockArgs =
    "--screenshots --clock --indicator"
    + " --color ${config.lib.stylix.colors.base00}"
    + lockFallbackImage
    + " --indicator-radius 150 --indicator-thickness 7 --effect-blur 7x5"
    + " --effect-vignette 0.5:0.5 --ring-color bb00cc --key-hl-color 880033"
    + " --line-color 00000000 --inside-color 00000088 --separator-color 00000000"
    + " --fade-in 1";
  # Le bref noir (~66 ms) qui précédait le fondu venait de sway, pas de
  # swaylock : fond opaque posé dès la demande de verrouillage, jusqu'à la
  # première image du client. Supprimé par un patch de sway, cf.
  # modules/system/window-manager/sway (sway-smooth-lock.patch). Un
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
  swaylockBin = "${cfg.pkgs.swaylock-effects}/bin/swaylock";
  lockCmd = "${swaylockBin} ${lockArgs}";
  # -f (daemonize) requis : sinon le lock bloquerait l'événement before-sleep
  # (swayidle attend la fin de la commande avant de continuer).
  lockCmdIdle = "${swaylockBin} -f ${lockArgs} ${graceArgs}";
  lockCmdBeforeSleep = "${swaylockBin} -f ${lockArgs}";

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
  # et bloquer `sleep` empêcherait UPower d'agir à batterie critique
  # (CriticalPowerAction=HybridSleep) -> portable vidé jusqu'à la coupure
  # si awake est oublié sur batterie.
  #
  # Anneau orange du thème (au lieu du violet) et « Éveillé » sous l'heure :
  # on voit d'un coup d'œil que ce verrou-là garde la machine allumée.
  # swaylock garde la DERNIÈRE valeur d'une option répétée, d'où l'ajout
  # après lockArgs.
  awakeArgs =
    "--ring-color ${config.lib.stylix.colors.base09}"
    + " --key-hl-color ${config.lib.stylix.colors.base0A}"
    + " --datestr Éveillé";
  # Capot fermé : on éteint l'écran interne quand AUCUNE veille ne suit,
  # c'est-à-dire si :
  #   - `awake` tient son inhibiteur (repéré par son --who chez logind) ;
  #   - ou un autre écran est actif : logind ignore alors le capot
  #     (HandleLidSwitchDocked=ignore par défaut), l'écran resterait allumé.
  # Sinon la veille arrive et éteint tout : on n'y touche pas, l'écran doit
  # rester capturable par le swaylock de before-sleep (sinon fond de repli
  # au lieu du bureau flouté).
  lidCloseCmd = cfg.pkgs.writeShellScript "lid-close" ''
    if ${cfg.pkgs.systemd}/bin/systemd-inhibit --list --no-legend --no-pager \
      | ${cfg.pkgs.gawk}/bin/awk '$1 == "awake" { found = 1 } END { exit !found }' \
      || ${swaymsgBin} -t get_outputs \
      | ${lib.getExe cfg.pkgs.jq} -e '[.[] | select(.active and .name != "eDP-1")] | length > 0' >/dev/null; then
      exec ${swaymsgBin} output eDP-1 power off
    fi
  '';

  awake = cfg.pkgs.writeShellApplication {
    name = "awake";
    runtimeInputs = [ cfg.pkgs.systemd ];
    text = ''
      exec systemd-inhibit --what=handle-lid-switch --mode=block \
        --who=awake --why="Session verrouillée, éveillée capot fermé (awake)" \
        ${swaylockBin} ${lockArgs} ${awakeArgs}
    '';
  };

  finalConfigContent =
    lib.replaceStrings
      [
        "@terminal@"
        "@tmuxBind@"
        "@lockCmd@"
        "@lidCloseCmd@"
        "@wallpaperBg@"
        "@chromeBind@"
        "@firefoxBind@"
        "@menuBind@"
        "@searchBind@"
        "@swayncBind@"
        "@flameshotDaemon@"
        "@flameshotBinds@"
        "@wfRecorderBinds@"
      ]
      [
        config.userSettings.terminal.default
        tmuxBind
        lockCmd
        "${lidCloseCmd}"
        wallpaperBg
        chromeBind
        firefoxBind
        menuBind
        searchBind
        swayncBind
        flameshotDaemon
        flameshotBinds
        wfRecorderBinds
      ]
      templateContent;

  swaymsgBin = "${cfg.pkgs.sway}/bin/swaymsg";
in
{
  options.userSettings.windowManager.sway = {
    # Suit le sway SYSTÈME par défaut : mettre false pour un user sans
    # session sway (ex. root, cf. son profil).
    enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = "Config sway de ce user (défaut : suit le sway système).";
    };
  };

  config = lib.mkIf config.userSettings.windowManager.sway.enable {
    assertions = [
      {
        assertion = cfg.enable;
        message = "userSettings.windowManager.sway requiert systemSettings.windowManager.sway (le compositor vient du système).";
      }
    ];

    home.file.".config/sway/config" = {
      text = finalConfigContent;
    };

    home.file.".config/sway/brightness.sh" = {
      source = ./sway-config/brightness.sh;
      executable = true;
    };

    # Démarrée au lancement de sway (config.template), active
    # graphical-session.target via BindsTo : démarre/arrête les services
    # Wayland liés (cliphist, etc.) avec la session.
    systemd.user.targets.sway-session = {
      Unit = {
        Description = "sway compositor session";
        Documentation = [ "man:systemd.special(7)" ];
        BindsTo = [ "graphical-session.target" ];
        Wants = [ "graphical-session-pre.target" ];
        After = [ "graphical-session-pre.target" ];
      };
    };

    home.packages = with cfg.pkgs; [
      awake
      brightnessctl # remplace `light`, retiré en nixpkgs 26.05
      playerctl
      swaylock-effects
    ];

    # Lock après 10 min d'inactivité, écrans éteints après 15 min (rallumés au
    # premier input), et lock systématique avant mise en veille (sinon la
    # session revient déverrouillée au réveil).
    services.swayidle = {
      enable = true;
      package = cfg.pkgs.swayidle;
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
      ];
      events."before-sleep" = lockCmdBeforeSleep;
    };

    # Pas de stylix.targets.sway : ce target ne thémise que
    # wayland.windowManager.sway (module HM), qu'on n'utilise pas ici.
  };
}
