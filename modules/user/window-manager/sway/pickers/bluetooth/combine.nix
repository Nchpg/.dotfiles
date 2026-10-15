{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.windowManager.sway.pickers.bluetooth.combine;
  c = config.lib.stylix.colors.withHashtag;

  # PipeWire n'a pas d'équivalent déclaratif simple à une sortie combinée
  # (combine-stream cible des noms de nœuds fixes) : on construit et lance à
  # la volée un mini contexte pipewire qui fait tourner un nœud virtuel
  # "sink" tant que le process vit, puis on le passe en sortie par défaut.
  # Tuer le process suffit à tout défaire (WirePlumber retombe sur
  # priority.session, vérifié en conditions réelles).
  #
  # stream.rules / matches / actions.create-stream est la syntaxe RÉELLEMENT
  # supportée par libpipewire-module-combine-stream (vérifié contre le
  # binaire installé) : `combine.streams` + `target.object` est ignoré
  # silencieusement, avec retombée sur TOUS les sinks du système.
  bt-combine = cfg.pkgs.writeShellApplication {
    name = "bt-combine";
    runtimeInputs = [
      cfg.pkgs.pipewire
      cfg.pkgs.wireplumber
      cfg.pkgs.gum
      cfg.pkgs.jq
      cfg.pkgs.coreutils
    ];
    text = ''
      ${myLib.theme.mkGumEnv { colors = config.lib.stylix.colors; }}

      state_dir="''${XDG_RUNTIME_DIR:-$HOME/.cache}"
      pid_file="$state_dir/bt-combine.pid"
      conf_file="$state_dir/bt-combine.conf"

      is_running() {
        [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null
      }

      stop_combine() {
        if [ -f "$pid_file" ]; then
          kill "$(cat "$pid_file")" 2>/dev/null || true
        fi
        rm -f "$pid_file" "$conf_file"
      }

      pause() { read -r -n1 -p "Entrée pour fermer..." _ || true; }

      if is_running; then
        if gum confirm "Sortie Bluetooth combinée active — l'arrêter ?"; then
          stop_combine
          gum style --foreground "${c.base0B}" "Sortie combinée arrêtée."
          pause
        fi
        exit 0
      fi

      # Sorties Bluetooth connectées : name\tdescription, une par ligne.
      mapfile -t sink_lines < <(
        pw-dump | jq -r '
          .[] | select(.info.props."media.class" == "Audio/Sink"
                       and .info.props."device.api" == "bluez5")
              | [.info.props."node.name",
                 (.info.props."node.description" // .info.props."node.name")]
              | @tsv
        '
      )

      if [ "''${#sink_lines[@]}" -lt 2 ]; then
        gum style --foreground "${c.base08}" \
          "Il faut au moins 2 sorties Bluetooth connectées (trouvé : ''${#sink_lines[@]}). Connecte-les d'abord (\$mod+b)."
        pause
        exit 1
      fi

      declare -A node_by_desc
      descs=()
      for line in "''${sink_lines[@]}"; do
        name="''${line%%$'\t'*}"
        desc="''${line#*$'\t'}"
        # Deux appareils au même nom : suffixe par le node.name pour rester
        # sélectionnable sans ambiguïté.
        if [ -n "''${node_by_desc[$desc]:-}" ]; then
          desc="$desc ($name)"
        fi
        node_by_desc["$desc"]="$name"
        descs+=("$desc")
      done

      selected=$(printf '%s\n' "''${descs[@]}" \
        | gum choose --no-limit --header "Sorties à combiner (espace = cocher, entrée = valider)") \
        || exit 0
      [ -z "$selected" ] && exit 0

      mapfile -t selected_descs <<< "$selected"
      if [ "''${#selected_descs[@]}" -lt 2 ]; then
        gum style --foreground "${c.base08}" "Sélectionne au moins 2 sorties."
        pause
        exit 1
      fi

      rules=""
      for desc in "''${selected_descs[@]}"; do
        name="''${node_by_desc[$desc]}"
        rules="$rules{ matches = [ { media.class = \"Audio/Sink\" node.name = \"$name\" } ] actions = { create-stream = {} } }
      "
      done

      cat > "$conf_file" <<EOF
      context.properties = { log.level = 2 }
      context.spa-libs = {
          audio.convert.* = audioconvert/libspa-audioconvert
          support.*       = support/libspa-support
      }
      context.modules = [
          { name = libpipewire-module-rt }
          { name = libpipewire-module-protocol-native }
          { name = libpipewire-module-client-node }
          { name = libpipewire-module-client-device }
          { name = libpipewire-module-adapter }
          { name = libpipewire-module-metadata }
          { name = libpipewire-module-session-manager }
          { name = libpipewire-module-link-factory }
          { name = libpipewire-module-combine-stream
            args = {
                combine.mode = sink
                node.name = "bt_combine"
                node.description = "Sortie Bluetooth combinée"
                combine.props = { audio.position = [ FL FR ] }
                stream.rules = [
                  $rules
                ]
            }
          }
      ]
      EOF

      pipewire -c "$conf_file" >/dev/null 2>&1 &
      disown
      echo $! > "$pid_file"

      # Création asynchrone côté pipewire : attend jusqu'à ~3s.
      node_id=""
      for _ in $(seq 1 30); do
        node_id=$(pw-dump | jq -r '.[] | select(.info.props."node.name" == "bt_combine") | .id' | head -1)
        [ -n "$node_id" ] && break
        sleep 0.1
      done

      if [ -z "$node_id" ]; then
        gum style --foreground "${c.base08}" "Échec : le sink combiné n'est jamais apparu."
        stop_combine
        pause
        exit 1
      fi

      wpctl set-default "$node_id"
      gum style --foreground "${c.base0B}" \
        "Sortie combinée active (''${#selected_descs[@]} appareils). Relance \$mod+Shift+b pour l'arrêter."
      pause
    '';
  };
in
{
  options.userSettings.windowManager.sway.pickers.bluetooth.combine = {
    # Suit bluetooth-picker : son message d'erreur renvoie vers $mod+b.
    enable =
      lib.mkEnableOption "sortie Bluetooth combinée (diffuse vers plusieurs appareils BT à la fois)"
      // {
        default = config.userSettings.windowManager.sway.pickers.bluetooth.enable;
      };
    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (myLib.desktop.mkFloatingTuiLauncher {
        name = "bt-combine";
        inherit config;
        exec = "${bt-combine}/bin/bt-combine";
        keybind = "$mod+Shift+b";
        title = "bt-combine";
        width = 900;
        height = 500;
      })
      { home.packages = [ bt-combine ]; }
    ]
  );
}
