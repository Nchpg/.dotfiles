{ config, lib, ... }:

let
  cfg = config.userSettings.bluetoothPicker.combine;
  term = config.userSettings.terminal.default;
  c = config.lib.stylix.colors.withHashtag;

  # Sortie Bluetooth combinée : diffuse le même flux audio vers plusieurs
  # appareils Bluetooth à la fois. PipeWire n'a pas d'équivalent déclaratif
  # simple à ça (le module combine-stream cible des noms de nœuds fixes) :
  # ici on construit et lance à la volée un mini contexte pipewire (8 modules
  # de base + combine-stream) qui fait tourner un nœud virtuel "sink" tant
  # que le process vit, puis on le passe en sortie par défaut.
  #
  # Le process porte le sink : le tuer suffit à tout défaire proprement —
  # WirePlumber retombe alors sur son choix normal (priority.session, cf.
  # modules/system/audio) sans intervention supplémentaire (vérifié en
  # conditions réelles : default.audio.sink revient seul sur le haut-parleur
  # dès que le process meurt).
  #
  # stream.rules / matches / actions.create-stream est la syntaxe RÉELLEMENT
  # supportée par libpipewire-module-combine-stream (vérifié contre le
  # binaire pipewire installé) : un ancien souvenir de `combine.streams` +
  # `target.object` est silencieusement ignoré par le module, qui retombe
  # alors sur TOUS les sinks du système — d'où le risque, si cette syntaxe
  # est un jour retouchée, de combiner silencieusement bien plus que prévu.
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
      export GUM_CHOOSE_HEADER_FOREGROUND="${c.base0A}"
      export GUM_CHOOSE_CURSOR_FOREGROUND="${c.base0D}"
      export GUM_CHOOSE_SELECTED_FOREGROUND="${c.base0D}"
      export GUM_CHOOSE_ITEM_FOREGROUND="${c.base05}"
      export GUM_CONFIRM_SELECTED_FOREGROUND="${c.base0D}"

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

      # Sorties Bluetooth actuellement connectées (device.api=bluez5, sinks
      # audio réels) : name\tdescription, une par ligne.
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

      # Attend que le nœud apparaisse (jusqu'à ~3s) avant de le prendre pour
      # défaut : sa création est asynchrone côté pipewire.
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

  termCmd = import ../../../lib/mk-terminal-cmd.nix {
    inherit lib term;
    title = "bt-combine";
    exec = "${bt-combine}/bin/bt-combine";
  };
in
{
  options.userSettings.bluetoothPicker.combine = {
    # Défaut : suit bluetooth-picker (son message d'erreur renvoie vers
    # $mod+b pour connecter des appareils — sans lui, ce bind n'existe pas).
    # Surchargeable : mettre false pour désactiver juste la combinaison.
    enable =
      lib.mkEnableOption "sortie Bluetooth combinée (diffuse vers plusieurs appareils BT à la fois)"
      // {
        default = config.userSettings.bluetoothPicker.enable;
      };
    pkgs = import ../../../lib/mk-pkgs-option.nix { inherit lib config; };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (import ../../../lib/mk-floating-tui-launcher.nix {
        name = "bt-combine";
        scriptBody = "exec ${termCmd}";
        keybind = "$mod+Shift+b";
        title = "bt-combine";
        width = 900;
        height = 500;
      })
      { home.packages = [ bt-combine ]; }
    ]
  );
}
