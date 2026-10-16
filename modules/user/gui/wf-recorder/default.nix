{
  config,
  lib,
  osConfig,
  myLib,
  ...
}:

let
  cfg = config.userSettings.gui.wfRecorder;

  icon = myLib.desktop.notifyIcon config cfg.pkgs;
  iconRec = icon "actions/media-record" (c: c.base08);
  iconDone = icon "actions/object-select" (c: c.base0B);

  # L'arrêt DOIT être un SIGINT, sinon le mp4 sort sans index.
  screenrec = cfg.pkgs.writeShellApplication {
    name = "screenrec";
    runtimeInputs = with cfg.pkgs; [
      cfg.package
      slurp
      libnotify
      wl-clipboard
      osConfig.programs.sway.package
      jq
      glib.bin # gdbus
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

      # La notif ne doit pas finir dans la vidéo (0.5 s : animation de sortie de swaync)
      id=$(notify-send -p -i ${iconRec} "Enregistrement démarré" "$(basename "$file")")
      sleep 1
      gdbus call --session --dest org.freedesktop.Notifications \
        --object-path /org/freedesktop/Notifications \
        --method org.freedesktop.Notifications.CloseNotification "$id" >/dev/null || true
      sleep 0.5

      if command -v swaync-client >/dev/null; then
        dnd_before=$(swaync-client -D 2>/dev/null || echo false)
        if [ "$dnd_before" != true ]; then
          swaync-client -dn >/dev/null
          trap 'swaync-client -df >/dev/null' EXIT
        fi
      fi

      wf-recorder ${lib.optionalString cfg.audio "--audio "}"''${target[@]}" -f "$file"

      printf '%s' "$file" | wl-copy
      # DND rétabli avant la notif de fin, sinon elle serait masquée
      if [ "''${dnd_before:-true}" != true ]; then
        swaync-client -df >/dev/null
        trap - EXIT
      fi
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
