{
  config,
  lib,
  osConfig,
  myLib,
  ...
}:

let
  cfg = config.userSettings.gui.displays;
  inherit (cfg) pkgs;

  # Wrapper qui SHADOW `nwg-displays` (toute invocation y passe, appelle le
  # vrai binaire par chemin store). Deux pièges GTK à contourner :
  #  1. nwg-displays se redimensionne lui-même ~0,5s APRÈS l'ouverture (reflow
  #     async) : on attend que la taille se STABILISE avant de forcer 1250x800.
  #  2. Le saut de taille pendant ce reflow est visible : la fenêtre naît
  #     hors-écran (cf. conf.d), fait son reflow là, et ce wrapper la ramène
  #     au centre une fois posée — d'où la nécessité que tout passe par lui.
  scriptDeps = [
    osConfig.programs.sway.package # swaymsg, swaynag
    pkgs.jq
    pkgs.gnugrep
    pkgs.coreutils # sleep, head
    pkgs.procps # pkill
  ];

  nwg-displays-wrapped = pkgs.writeShellApplication {
    name = "nwg-displays";
    runtimeInputs = scriptDeps;
    text = myLib.swayWaitSh + ''
      # Toggle ouvre/ferme. Pas de `grep -q` : il sortirait au premier match
      # et, sous pipefail, le SIGPIPE de swaymsg ferait échouer le test.
      if swaymsg -t get_tree | grep '"nwg-displays"' >/dev/null; then
        exec swaymsg '[app_id="nwg-displays"] kill'
      fi

      # Focus mémorisé AVANT le vol de focus par nwg-displays : le masquage
      # hors-écran rattache la fenêtre à l'écran le plus proche (souvent le
      # secondaire), donc on la renvoie explicitement sur l'écran focus.
      out="$(swaymsg -t get_outputs | jq -r '.[] | select(.focused).name')"

      ${pkgs.nwg-displays}/bin/nwg-displays >/dev/null 2>&1 &

      # Attend que la largeur×hauteur de la fenêtre se stabilise (cf.
      # sway_wait_stable, lib/sway-wait.sh). Bornée à 10s (40 x 0,25s) : si
      # nwg-displays crashe, on prévient au lieu de bloquer indéfiniment.
      if ! sway_wait_stable 40 0.25 '.. | objects | select(.app_id? == "nwg-displays").rect | "\(.width)x\(.height)"' >/dev/null; then
        swaynag -t error -m "nwg-displays : la fenêtre ne s'est pas stabilisée (timeout)."
        exit 1
      fi

      exec swaymsg "[app_id=\"nwg-displays\"] move container to output \"$out\", resize set 1250 800, move position center, focus; mode \"displays\""
    '';
  };

  # Clonage d'écran (Sway ne sait pas mirrorer nativement), $mod+Shift+o.
  mirror = pkgs.writeShellApplication {
    name = "mirror";
    runtimeInputs = scriptDeps ++ [ pkgs.wl-mirror ];
    text = ''
      # Toggle : arrête le miroir s'il tourne déjà.
      if pkill -x wl-mirror; then
        exit 0
      fi

      internal=$(swaymsg -t get_outputs \
        | jq -r '.[] | select(.name | test("^eDP")) | .name' | head -n1)
      external=$(swaymsg -t get_outputs \
        | jq -r '.[] | select(.active and (.name | test("^eDP") | not)) | .name' | head -n1)

      if [ -z "$external" ]; then
        swaynag -t warning -m "Clonage : aucun écran externe détecté."
        exit 1
      fi

      exec wl-mirror --fullscreen-output "$external" "$internal"
    '';
  };
in
{
  options.userSettings.gui.displays = {
    enable = lib.mkEnableOption "gestion des écrans externes / HDMI via la GUI nwg-displays";
    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    # Vrai paquet (pour .desktop/icône/binaire appelé par le wrapper) ET le
    # wrapper en hiPrio : les deux fournissent bin/nwg-displays, hiPrio fait
    # gagner le wrapper.
    home.packages = [
      (lib.hiPrio nwg-displays-wrapped)
      pkgs.nwg-displays
      pkgs.wlr-randr
      pkgs.wl-mirror # clonage d'écran (Sway ne sait pas mirrorer nativement)
    ];

    # ~/.config/sway/outputs (sauvegardé par nwg-displays) inclus pour que
    # Sway l'applique au démarrage et au branchement à chaud. Pas en
    # déclaratif : un home.file en ferait un symlink read-only, or
    # nwg-displays doit pouvoir l'écrire.

    home.file.".config/sway/conf.d/displays.conf".text = ''
      include ~/.config/sway/outputs

      # Naît hors-écran pour le reflow GTK initial (cf. wrapper plus haut).
      for_window [app_id="nwg-displays"] floating enable, border pixel 2, move position 100000 100000

      bindsym $mod+o exec nwg-displays
      bindsym $mod+Shift+o exec ${lib.getExe mirror}

      # Actif tant que nwg-displays est ouvert (fenêtre sans barre de titre :
      # ces trois binds sont ses seules voies de fermeture).
      mode "displays" {
        bindsym q [app_id="nwg-displays"] kill; mode default
        bindsym Escape [app_id="nwg-displays"] kill; mode default
        bindsym $mod+o [app_id="nwg-displays"] kill; mode default
      }
    '';
  };
}
