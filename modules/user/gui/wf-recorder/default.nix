{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.gui.wfRecorder;

  # Icônes de notif aux couleurs du thème (cf. lib/mk-themed-icon.nix).
  c = config.lib.stylix.colors.withHashtag;
  iconRec = myLib.mkThemedIcon cfg.pkgs "actions/media-record" c.base08;
  iconDone = myLib.mkThemedIcon cfg.pkgs "actions/object-select" c.base0B;

  # Un seul script pour les deux binds Sway : le mode arrive en argument.
  # Sémantique TOGGLE — le même bind démarre puis arrête, parce qu'un
  # wf-recorder lancé par `exec` sway n'a pas de terminal où faire Ctrl-C.
  # L'arrêt DOIT être un SIGINT (pas SIGTERM/SIGKILL) : c'est le seul signal
  # sur lequel wf-recorder ferme proprement le conteneur, sinon le mp4 sort
  # sans index et reste illisible.
  screenrec = cfg.pkgs.writeShellApplication {
    name = "screenrec";
    runtimeInputs = with cfg.pkgs; [
      cfg.package
      slurp
      libnotify
      wl-clipboard
      sway # swaymsg, pour l'output focus
      jq
    ];
    text = ''
      # -x : ne matche que le process wf-recorder lui-même, pas ce wrapper
      # (qui a "wf-recorder" dans son store path et serait tué avec lui).
      if pkill -INT -x wf-recorder 2>/dev/null; then
        exit 0
      fi

      mode="''${1:-region}"

      case "$mode" in
        region)
          # slurp annulé (Échap) renvoie non-zéro : on sort sans rien enregistrer.
          geometry="$(slurp -d)" || exit 0
          target=(-g "$geometry")
          ;;
        screen)
          # Sans -o, wf-recorder échoue dès qu'il y a plusieurs sorties.
          output="$(swaymsg -t get_outputs | jq -r '.[] | select(.focused) | .name')"
          target=(-o "$output")
          ;;
        *)
          echo "usage: screenrec [region|screen]" >&2
          exit 1
          ;;
      esac

      mkdir -p ${lib.escapeShellArg cfg.outputDir}
      file=${lib.escapeShellArg cfg.outputDir}/"rec-$(date +%F-%H%M%S).mp4"

      notify-send -t 2000 -i ${iconRec} "Enregistrement démarré" "$(basename "$file")"
      wf-recorder ${lib.optionalString cfg.audio "--audio "}"''${target[@]}" -f "$file"

      # Chemin dans le presse-papier : la notif swaync disparaît, pas le chemin.
      printf '%s' "$file" | wl-copy
      notify-send -i ${iconDone} "Enregistrement sauvegardé" "$file"
    '';
  };
in
{
  options = {
    userSettings.gui.wfRecorder = {
      enable = lib.mkEnableOption "wf-recorder (capture vidéo, wlroots natif sous Sway)";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
      package = lib.mkOption {
        type = lib.types.package;
        default = cfg.pkgs.wf-recorder;
        defaultText = "pkgs.wf-recorder";
        description = ''
          Encodeur logiciel (libx264) par défaut. wl-screenrec encoderait en
          VAAPI, mais le GPU de cette machine est sur pilote proprio où VAAPI
          n'est pas fiable : wf-recorder reste le choix qui marche partout.
        '';
      };
      audio = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Ajoute --audio (capture la sortie PipeWire par défaut).";
      };
      outputDir = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/Videos";
        defaultText = "\${config.home.homeDirectory}/Videos";
        description = "Dossier de destination des enregistrements (créé à la volée).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Intégration Sway (binds $mod+Print / $mod+Shift+Print) dans sway-config,
    # pas ici — même découpage que le module flameshot.
    home.packages = [ screenrec ];
  };
}
