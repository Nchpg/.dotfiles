{
  config,
  lib,
  osConfig,
  myLib,
  ...
}:

let
  cfg = config.userSettings.gui.wfRecorder;

  # Signal RTMIN du module rec de waybar (cf. waybar/scripts/rec.sh).
  recSignal = toString config.userSettings.windowManager.sway.waybar.signals.screenrec;

  # L'arrêt DOIT être un SIGINT, sinon le mp4 sort sans index.
  screenrec = cfg.pkgs.writeShellApplication {
    name = "screenrec";
    runtimeInputs = with cfg.pkgs; [
      cfg.package
      slurp
      wl-clipboard
      procps # pkill
      osConfig.programs.sway.package
      jq
    ];
    text = ''
      # -x : pas ce wrapper (son store path contient "wf-recorder")
      if pkill -INT -x wf-recorder 2>/dev/null; then
        exit 0
      fi

      mode="''${1:-region}"

      case "$mode" in
        region)
          geometry="$(slurp -d)" || exit 0
          target=(-g "$geometry")
          ;;
        screen)
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

      # Le module rec de waybar (scripts/rec.sh) affiche l'état, sans notification :
      #   start = « pid heure_de_départ_en_µs », tant que la capture tourne
      #   last  = « epoch chemin », une fois sauvegardé
      state_dir="''${XDG_RUNTIME_DIR:-/tmp}/screenrec"
      mkdir -p "$state_dir"

      dnd_set=false
      cleanup() {
        rm -f "$state_dir/start"
        if [ "$dnd_set" = true ]; then
          swaync-client -df >/dev/null
        fi
      }
      trap cleanup EXIT

      if command -v swaync-client >/dev/null; then
        if [ "$(swaync-client -D 2>/dev/null || echo false)" != true ]; then
          swaync-client -dn >/dev/null
          dnd_set=true
        fi
      fi

      # L'heure (µs, par date : EPOCHREALTIME prend la virgule de la locale) est prise juste
      # avant la capture, puis waybar est réveillé : 00:00 s'affiche à cet instant.
      # wf-recorder reste au premier plan, sinon il ignorerait le SIGINT d'arrêt.
      printf '%s %s\n' "$$" "$(date +%s%6N)" > "$state_dir/start"
      pkill -RTMIN+${recSignal} waybar || true

      wf-recorder ${lib.optionalString cfg.audio "--audio "}"''${target[@]}" -f "$file"

      rm -f "$state_dir/start"
      if [ "$dnd_set" = true ]; then
        swaync-client -df >/dev/null
        dnd_set=false
      fi
      printf '%s' "$file" | wl-copy
      printf '%s %s\n' "$(date +%s)" "$file" > "$state_dir/last"
      pkill -RTMIN+${recSignal} waybar || true
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
        description = "Encodeur logiciel (libx264) : VAAPI n'est pas fiable sur le GPU propriétaire.";
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
    home.packages = [ screenrec ];

    home.file.".config/sway/conf.d/wf-recorder.conf" =
      lib.mkIf config.userSettings.windowManager.sway.enable
        {
          text = ''
            bindsym $mod+Print exec screenrec region
            bindsym $mod+Shift+Print exec screenrec screen
          '';
        };
  };
}
