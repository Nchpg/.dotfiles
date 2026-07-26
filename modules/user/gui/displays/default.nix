{
  config,
  lib,
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
  scriptPath = lib.makeBinPath [
    pkgs.sway # swaymsg, swaynag
    pkgs.jq
    pkgs.gnugrep
    pkgs.coreutils # sleep, head
    pkgs.procps # pkill
  ];

  nwg-displays-wrapped = pkgs.writeShellScriptBin "nwg-displays" ''
    export PATH="${scriptPath}:$PATH"

    # Toggle ouvre/ferme.
    if swaymsg -t get_tree | grep -q '"nwg-displays"'; then
      exec swaymsg '[app_id="nwg-displays"] kill'
    fi

    # Focus mémorisé AVANT le vol de focus par nwg-displays : le masquage
    # hors-écran rattache la fenêtre à l'écran le plus proche (souvent le
    # secondaire), donc on la renvoie explicitement sur l'écran focus.
    out="$(swaymsg -t get_outputs | jq -r '.[] | select(.focused).name')"

    ${pkgs.nwg-displays}/bin/nwg-displays >/dev/null 2>&1 &

    # Largeur×hauteur courante de la fenêtre (vide tant qu'elle n'existe pas).
    geo() {
      swaymsg -t get_tree \
        | jq -r '.. | objects | select(.app_id? == "nwg-displays").rect | "\(.width)x\(.height)"'
    }

    # Bornée à 10s (40 x 0,25s) : si nwg-displays crashe, on prévient au lieu
    # de bloquer indéfiniment.
    prev=""
    cur="$(geo)"
    tries=0
    while [ -z "$cur" ] || [ "$cur" != "$prev" ]; do
      tries=$((tries + 1))
      if [ "$tries" -ge 40 ]; then
        swaynag -t error -m "nwg-displays : la fenêtre ne s'est pas stabilisée (timeout)."
        exit 1
      fi
      sleep 0.25
      prev="$cur"
      cur="$(geo)"
    done

    exec swaymsg "[app_id=\"nwg-displays\"] move container to output \"$out\", resize set 1250 800, move position center, focus; mode \"displays\""
  '';
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
      pkgs.jq # parse la sortie JSON de swaymsg (wrapper + script clonage)
    ];

    # ~/.config/sway/outputs (sauvegardé par nwg-displays) inclus pour que
    # Sway l'applique au démarrage et au branchement à chaud. Pas en
    # déclaratif : un home.file en ferait un symlink read-only, or
    # nwg-displays doit pouvoir l'écrire.

    home.file.".config/sway/launchers/mirror" = {
      text = ''
        #!/bin/sh
        export PATH="${scriptPath}:${pkgs.wl-mirror}/bin:$PATH"

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
      executable = true;
    };

    home.file.".config/sway/conf.d/displays.conf".text = ''
      include ~/.config/sway/outputs

      # Naît hors-écran pour le reflow GTK initial (cf. wrapper plus haut).
      for_window [app_id="nwg-displays"] floating enable, border pixel 2, move position 100000 100000

      bindsym $mod+o exec nwg-displays
      bindsym $mod+Shift+o exec ~/.config/sway/launchers/mirror

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
