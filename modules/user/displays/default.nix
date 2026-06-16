{ config, lib, ... }:

let
  cfg = config.userSettings.displays;
  pkgs = cfg.pkgs;

  # Wrapper qui SHADOW le binaire `nwg-displays`. Toute invocation — terminal,
  # rofi/.desktop, $mod+o, n'importe quoi — passe par cette logique unique, et
  # appelle le VRAI binaire par son chemin du store (pas de récursion). Sans ce
  # wrapper, lancer nwg-displays autrement que par notre script laissait la
  # fenêtre coincée hors-écran (cf. point 2 ci-dessous).
  #
  # Dimensionnement de nwg-displays (appli GTK). Deux pièges :
  #
  #  1. nwg-displays se redimensionne lui-même ~0,5 s APRÈS l'ouverture (reflow
  #     GTK async qui repousse la hauteur à celle de l'écran). Un `resize set`
  #     appliqué trop tôt se fait écraser → on attend que la taille se STABILISE
  #     (deux mesures identiques) avant de forcer 1250x800.
  #
  #  2. Pendant ce reflow, le saut de taille est VISIBLE. La parade : la fenêtre
  #     naît hors-écran (move position en for_window, voir conf.d → invisible,
  #     bordure comprise) ; elle y fait tout son reflow, et on ne la ramène au
  #     centre qu'une fois posée. C'est ce wrapper — et lui seul — qui fait ce
  #     "ramène au centre", d'où la nécessité que tout passe par lui.
  nwg-displays-wrapped = pkgs.writeShellScriptBin "nwg-displays" ''
    # Déjà ouvert ? on ferme. Sinon on ouvre. ($mod+o sert d'ouvre/ferme.)
    if swaymsg -t get_tree | grep -q '"nwg-displays"'; then
      exec swaymsg '[app_id="nwg-displays"] kill'
    fi

    # Écran actuellement focus, mémorisé AVANT de lancer nwg-displays (qui vole le
    # focus). Le masquage hors-écran rattache la fenêtre à l'écran le plus proche
    # du point (souvent le secondaire) → on la renvoie ensuite explicitement sur
    # cet écran, sinon `move position center` la centrerait sur le mauvais.
    out="$(swaymsg -t get_outputs | jq -r '.[] | select(.focused).name')"

    ${pkgs.nwg-displays}/bin/nwg-displays >/dev/null 2>&1 &

    # Largeur×hauteur courante de la fenêtre (vide tant qu'elle n'existe pas).
    geo() {
      swaymsg -t get_tree \
        | jq -r '.. | objects | select(.app_id? == "nwg-displays").rect | "\(.width)x\(.height)"'
    }

    # Attendre que la taille soit posée ET stable (le reflow GTK est passé).
    prev=""
    cur="$(geo)"
    while [ -z "$cur" ] || [ "$cur" != "$prev" ]; do
      sleep 0.25
      prev="$cur"
      cur="$(geo)"
    done

    # Sur l'écran focus, taille finale, centré, visible, focus, ET on entre dans
    # le mode "displays" (cf. conf.d) qui active la touche q pour fermer.
    exec swaymsg "[app_id=\"nwg-displays\"] move container to output \"$out\", resize set 1250 800, move position center, focus; mode \"displays\""
  '';
in {
  options.userSettings.displays = {
    enable = lib.mkEnableOption "gestion des écrans externes / HDMI via la GUI nwg-displays";
    pkgs = lib.mkOption {
      type = lib.types.attrs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };
  };

  config = lib.mkIf cfg.enable {
    # nwg-displays : interface graphique d'agencement des écrans (position en
    # drag & drop, résolution, taux de rafraîchissement, scale, rotation).
    # wlr-randr est le backend qu'il interroge sous wlroots/Sway pour lire et
    # appliquer l'état des sorties.
    #
    # On installe le VRAI paquet (pour son .desktop, son icône et le binaire
    # réel appelé par le wrapper) ET le wrapper en hiPrio : les deux fournissent
    # bin/nwg-displays, hiPrio fait gagner le wrapper sur cette collision, le
    # reste du paquet (share/applications, share/icons) est conservé.
    home.packages = [
      (lib.hiPrio nwg-displays-wrapped)
      pkgs.nwg-displays
      pkgs.wlr-randr
      pkgs.wl-mirror   # clonage d'écran (Sway ne sait pas mirrorer nativement)
      pkgs.jq          # parse la sortie JSON de swaymsg (wrapper + script clonage)
    ];

    # nwg-displays sauvegarde l'agencement dans ~/.config/sway/outputs. On
    # l'inclut ici pour que Sway l'applique au démarrage ET au branchement à
    # chaud d'un écran (Sway réévalue les directives `output` quand une sortie
    # apparaît → l'HDMI se positionne tout seul une fois sauvegardé).
    #
    # NB : on ne gère PAS ce fichier en déclaratif (un home.file en ferait un
    # symlink read-only, et nwg-displays ne pourrait plus l'écrire). Sway ignore
    # simplement l'include tant que tu n'as pas fait une première sauvegarde
    # depuis la GUI.

    # Clonage d'écran (toggle). Sway n'a pas de "mirror" natif : on recopie
    # l'écran interne (eDP) sur l'écran externe via wl-mirror, en plein écran sur
    # ce dernier. Re-appuyer coupe le miroir → retour en mode étendu.
    home.file.".config/sway/launchers/mirror" = {
      text = ''
        #!/bin/sh
        # Un miroir tourne déjà ? on l'arrête (toggle).
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

        # wl-mirror recopie $internal (positionnel) et se met en plein écran sur
        # $external (--fullscreen-output, qui implique --fullscreen).
        exec wl-mirror --fullscreen-output "$external" "$internal"
      '';
      executable = true;
    };

    home.file.".config/sway/conf.d/displays.conf".text = ''
      include ~/.config/sway/outputs

      # Flottant + bordure fine. On la fait NAÎTRE hors-écran (move position très
      # au-delà des sorties) : elle y fait son reflow GTK initial sans qu'on voie
      # le saut de taille. Le wrapper applique 1250x800 puis la ramène au centre
      # une fois posée (voir wrapper plus haut).
      for_window [app_id="nwg-displays"] floating enable, border pixel 2, move position 100000 100000

      # $mod+o ("o" comme output ; $mod+p est pris par volume-mixer) : ouvre /
      # ferme nwg-displays (le wrapper entre dans le mode "displays" ci-dessous).
      bindsym $mod+o exec nwg-displays

      # $mod+Shift+o : (dé)clone l'écran interne sur l'écran externe.
      bindsym $mod+Shift+o exec ~/.config/sway/launchers/mirror

      # Mode actif UNIQUEMENT tant que nwg-displays est ouvert (le wrapper y
      # entre, voir plus haut). La fenêtre n'a pas de barre de titre → ses seules
      # voies de fermeture passent par ce mode, donc on ressort toujours en
      # "default" : pas de mode coincé.
      #   q / Échap : ferment la fenêtre.
      #   $mod+o    : re-câblé pour fermer aussi (sinon le toggle serait inerte).
      mode "displays" {
        bindsym q [app_id="nwg-displays"] kill; mode default
        bindsym Escape [app_id="nwg-displays"] kill; mode default
        bindsym $mod+o [app_id="nwg-displays"] kill; mode default
      }
    '';
  };
}
