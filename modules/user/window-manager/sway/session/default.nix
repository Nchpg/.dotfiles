{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.windowManager.sway.session;

  # Icônes de notif aux couleurs du thème, comme batterie et VPN (cf.
  # lib/mk-themed-icon.nix). Sans stylix, `colors` n'est pas évaluable : on
  # garde le nom Adwaita, que swaync affiche en blanc.
  themed = config.userSettings.stylix.enable;
  kitty = config.userSettings.terminal.kitty.enable;
  c = config.lib.stylix.colors.withHashtag;
  icon =
    name: color:
    if themed then "${myLib.mkThemedIcon cfg.pkgs name (color c)}" else "${baseNameOf name}-symbolic";
  icons = {
    save = icon "actions/document-save" (c: c.base0B);
    restore = icon "actions/document-revert" (c: c.base0D);
    warning = icon "status/dialog-warning" (c: c.base0A);
  };

  # Sway n'a aucune gestion de session : rien ne retient quelle fenêtre était
  # sur quel workspace. `sway-session save` photographie l'arbre (workspace,
  # app, commande, dossier courant du shell), `restore` relance chaque
  # PROCESSUS une fois et range ses fenêtres à leur place.
  #
  # Un processus, pas une fenêtre : Firefox ou Chrome ont toutes leurs
  # fenêtres sous le même pid et les rouvrent eux-mêmes (restauration de
  # session du navigateur). Les relancer une fois par fenêtre ouvrirait N
  # navigateurs. Le CONTENU (onglets, sessions tmux) reste l'affaire de
  # chaque app, sauf pour kitty : sway-session y relance le programme au
  # premier plan s'il est dans `resume` (Claude Code repris sur sa
  # conversation), sinon y réaffiche le scrollback lu par la socket de
  # contrôle de kitty.
  #
  # Appariement fenêtre <-> place sauvegardée : d'abord par pid (le
  # processus qu'on vient de lancer), parce que deux kitty démarrés ensemble
  # peuvent mapper dans le désordre et échanger leurs workspaces. Repli sur
  # l'app_id quand le pid ne dit rien (lancé via gio, qui sort aussitôt, ou
  # app mono-instance qui délègue à un processus déjà là). Quand plusieurs
  # places attendent le même processus (N fenêtres Firefox), le titre
  # départage : le navigateur rouvre ses onglets, la fenêtre reprend le titre
  # qu'elle avait. Sans titre identique au bout de `settle` secondes, on
  # prend dans l'ordre.
  sway-session = cfg.pkgs.writeShellApplication {
    name = "sway-session";
    runtimeInputs =
      with cfg.pkgs;
      [
        sway
        jq
        coreutils
        gawk
        util-linux # setsid
        glib.bin # gio launch, pour les apps relancées par leur .desktop
        libnotify
      ]
      ++ lib.optional kitty config.programs.kitty.package; # kitten @ get-text
    text = ''
      state="''${XDG_STATE_HOME:-$HOME/.local/state}/sway-session.json"
      ignore=${lib.escapeShellArg (builtins.toJSON cfg.ignore)}
      launchers=${lib.escapeShellArg (builtins.toJSON cfg.launchers)}
      resume=${lib.escapeShellArg (builtins.toJSON cfg.resume)}
      # Scrollbacks et scripts de relance des terminaux, refait à chaque save.
      snapdir="''${state%.json}.d"

      # Icône, titre, corps.
      notify() { notify-send -a sway-session -i "$1" "''${@:2}" || true; }

      # Fenêtres (vues, pas les conteneurs de split) hors scratchpad, triées
      # par con_id : sway les numérote dans l'ordre de création.
      list_windows() {
        swaymsg -t get_tree | jq -c --argjson ignore "$ignore" '
          [ .. | objects
            | select(.type == "workspace" and .name != "__i3_scratch")
            | .name as $ws
            | (.nodes[], .floating_nodes[]) | .. | objects
            | select((.type == "con" or .type == "floating_con")
                     and (.pid // 0) > 0 and ((.nodes // []) | length) == 0)
            | { ws: $ws, id, pid, title: (.name // ""),
                app: (.app_id // .window_properties.class // ""),
                floating: (.type == "floating_con") }
            | select(.app as $a | $ignore | index($a) | not) ]
          | sort_by(.id)'
      }

      # Shell lancé par la fenêtre (kitty -> fish). Kitty a aussi des
      # enfants `kitten` : on ne garde que les shells.
      term_shell() {
        local pid=$1 c
        local -a children
        read -ra children < <(cat /proc/"$pid"/task/*/children 2>/dev/null)
        for c in "''${children[@]}"; do
          case "$(cat /proc/"$c"/comm 2>/dev/null)" in
            bash | zsh | fish | sh | dash | nu)
              echo "$c"
              return 0
              ;;
          esac
        done
        return 1
      }

      # Dossier du shell, pas celui du terminal lui-même, resté sur $HOME.
      shell_cwd() {
        local sh
        if sh=$(term_shell "$1"); then
          readlink /proc/"$sh"/cwd
        else
          readlink /proc/"$1"/cwd
        fi
      }

      # Contenu d'une fenêtre kitty, en JSON (null sans shell) : le programme
      # au premier plan du shell s'il est dans `resume`, sinon le scrollback.
      # Les deux s'excluent : Claude Code repris réaffiche lui-même sa
      # conversation, la doubler du scrollback n'apporterait rien.
      term_info() {
        local pid=$1 sh st tpgid name sid fg=null cwd file=""
        local -a f
        sh=$(term_shell "$pid") || {
          echo null
          return 0
        }
        cwd=$(readlink /proc/"$sh"/cwd)

        # Groupe au premier plan du terminal (champ tpgid de stat, après le
        # nom entre parenthèses) : le shell lui-même quand il attend.
        st=$(<"/proc/$sh/stat")
        read -ra f <<<"''${st##*) }"
        tpgid=''${f[5]}
        if [ "$tpgid" -gt 0 ] && [ "$tpgid" != "$sh" ] && [ -r /proc/"$tpgid"/cmdline ]; then
          fg=$(jq -Rs 'split("\u0000") | map(select(. != ""))' /proc/"$tpgid"/cmdline)
          name=$(jq -r '.[0] // "" | split("/") | last' <<<"$fg")
          if jq -e --arg n "$name" 'index($n) != null' <<<"$resume" >/dev/null; then
            cwd=$(readlink /proc/"$tpgid"/cwd)
            # Claude Code note l'id de la conversation de chaque processus :
            # `--resume <id>` plutôt que `-c`, qui prendrait la dernière du
            # dossier (fausse si deux Claude y tournaient). Les autres
            # arguments, prompt initial compris, ne sont pas rejoués.
            if [ "$name" = claude ]; then
              sid=$(jq -r '.sessionId // empty' \
                "''${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$tpgid.json" 2>/dev/null || true)
              [ -z "$sid" ] || fg=$(jq -nc --arg s "$sid" '["claude", "--resume", $s]')
            fi
          else
            fg=null
          fi
        fi

        # Lignes vides du bas de l'écran retirées (séquences ANSI ignorées).
        if [ "$fg" = null ] && [ -S "''${XDG_RUNTIME_DIR:-}/kitty-$pid" ]; then
          file="$snapdir/$pid.ansi"
          if kitten @ --to "unix:$XDG_RUNTIME_DIR/kitty-$pid" get-text --extent all --ansi 2>/dev/null |
            awk '{ l = $0; gsub(/\033\[[0-9;:?]*[a-zA-Z]/, "", l)
                   if (l ~ /^[[:space:]]*$/) { buf = buf $0 "\n" }
                   else { printf "%s", buf; buf = ""; print } }' >"$file"; then
            [ -s "$file" ] || file=""
          else
            file=""
          fi
        fi

        jq -nc --arg shell "$(cat /proc/"$sh"/comm)" --arg cwd "$cwd" \
          --argjson fg "$fg" --arg sb "$file" \
          '{ shell: $shell, cwd: $cwd, fg: $fg,
             scrollback: (if $sb == "" then null else $sb end) }'
      }

      find_desktop() {
        local app=$1 d f b
        local -a dirs
        IFS=: read -ra dirs <<<"''${XDG_DATA_HOME:-$HOME/.local/share}:''${XDG_DATA_DIRS:-}"
        for d in "''${dirs[@]}"; do
          for f in "$d"/applications/*.desktop; do
            [ -e "$f" ] || continue
            b=$(basename "$f" .desktop)
            if [ "''${b,,}" = "''${app,,}" ] || grep -qixF "StartupWMClass=$app" "$f"; then
              echo "$f"
              return 0
            fi
          done
        done
        return 1
      }

      save() {
        local windows groups pid cmd app term
        windows=$(list_windows)
        if [ "$(jq length <<<"$windows")" -eq 0 ]; then
          notify ${icons.warning} "Session non sauvegardée" "Aucune fenêtre ouverte."
          exit 1
        fi

        rm -rf "$snapdir"
        mkdir -p "$snapdir"

        groups='[]'
        for pid in $(jq -r '[.[].pid] | unique[]' <<<"$windows"); do
          [ -r /proc/"$pid"/cmdline ] || continue
          app=$(jq -r --argjson p "$pid" 'map(select(.pid == $p))[0].app' <<<"$windows")
          term=null
          [ "$app" != kitty ] || term=$(term_info "$pid")
          # Chrome et les apps Electron réécrivent leur cmdline en une seule
          # chaîne séparée par des espaces : les arguments ne sont plus
          # récupérables, on ne garde que le binaire (leur .desktop ou leur
          # wrapper remet les bons flags).
          cmd=$(jq -Rs 'split("\u0000") | map(select(. != ""))
            | if length == 1 and (.[0] | test(" ")) then [.[0] | split(" ")[0]] else . end' \
            /proc/"$pid"/cmdline)
          groups=$(jq -c --argjson pid "$pid" --argjson cmd "$cmd" \
            --arg cwd "$(shell_cwd "$pid")" --arg app "$app" --argjson term "$term" \
            '. + [{ pid: $pid, cmd: $cmd, cwd: ($term.cwd // $cwd), app: $app }
                  + if $term then { term: $term } else {} end]' <<<"$groups")
        done

        mkdir -p "$(dirname "$state")"
        jq -n --argjson g "$groups" --argjson w "$windows" '
          { saved: (now | todate),
            groups: ($g | sort_by(.pid)),
            windows: [ $w[] | select(.pid as $p | $g | any(.pid == $p))
                       | { pid, app, title, ws, floating } ] }' >"$state.tmp"
        mv "$state.tmp" "$state"

        notify ${icons.save} "Session sauvegardée" \
          "$(jq length <<<"$windows") fenêtres, $(jq length <<<"$groups") applications."
      }

      # Commande de shell relançant le contenu d'un terminal : scrollback
      # réaffiché, séparateur, puis programme repris. Arguments échappés
      # par le shell cible lui-même (fish ne lit pas le %q de bash).
      term_script() {
        local term=$1 sh sb
        local -a fg
        sh=$(jq -r .shell <<<"$term")
        sb=$(jq -r '.scrollback // empty' <<<"$term")
        mapfile -t fg < <(jq -r '.fg // [] | .[]' <<<"$term")
        if [ -n "$sb" ] && [ -r "$sb" ]; then
          printf "command cat '%s'\n" "$sb"
          printf '%s\n' "printf '\\033[2m── session restaurée ──\\033[0m\\n'"
        fi
        if [ "''${#fg[@]}" -gt 0 ]; then
          if [ "$sh" = fish ]; then
            # shellcheck disable=SC2016 # $argv est pour fish
            fish -c 'string escape -- $argv' "''${fg[@]}" | paste -sd' '
          else
            printf '%q ' "''${fg[@]}"
            echo
          fi
        fi
      }

      # Relance un groupe, affiche le pid du processus lancé ("" si inconnu).
      launch() {
        local group=$1 app cwd launcher name desktop term sh script
        local -a cmd argv
        app=$(jq -r .app <<<"$group")
        cwd=$(jq -r .cwd <<<"$group")
        mapfile -t cmd < <(jq -r '.cmd[]' <<<"$group")

        launcher=$(jq -r --arg a "$app" '.[$a] // empty' <<<"$launchers")
        if [ -n "$launcher" ]; then
          argv=(sh -c "$launcher")
        else
          # Nom nu plutôt que le chemin store sauvegardé : il peut avoir été
          # ramassé par le GC depuis. `.firefox-wrapped` -> `firefox`.
          name=$(basename "''${cmd[0]}")
          name=''${name#.}
          name=''${name%-wrapped}
          if command -v "$name" >/dev/null; then
            argv=("$name" "''${cmd[@]:1}")
            # kitty sur un script de reprise, dans le shell d'origine. fish :
            # -C, exécuté après sa config, puis reste interactif. Les autres :
            # -c puis exec d'un shell interactif.
            if [ "$name" = kitty ] && term=$(jq -ce '.term // empty' <<<"$group") &&
              sh=$(command -v "$(jq -r .shell <<<"$term")"); then
              script="$snapdir/$(jq -r .pid <<<"$group").$(basename "$sh")"
              term_script "$term" >"$script"
              if [ -s "$script" ]; then
                if [ "$(basename "$sh")" = fish ]; then
                  argv=(kitty "$sh" -C "source '$script'")
                else
                  argv=(kitty "$sh" -c ". '$script'; exec '$sh'")
                fi
              fi
            fi
          elif desktop=$(find_desktop "$app"); then
            argv=(gio launch "$desktop")
          else
            return 1
          fi
        fi

        # setsid sans -f : le sous-shell n'est pas chef de groupe, setsid
        # s'exécute donc en place et $! est bien le pid de l'app.
        (
          cd "$cwd" 2>/dev/null || cd "$HOME"
          # Hérité de ce script bash : sans ça, le shell d'un terminal relancé
          # part à SHLVL=3 au lieu de 1 (profondeur affichée dans le prompt).
          unset SHLVL
          exec setsid "''${argv[@]}" </dev/null >/dev/null 2>&1
        ) &
        echo "$!"
      }

      restore() {
        local force=$1 used pending pidmap group oldpid newpid alive cur moves move ws id app late
        local -a failed=() skipped=() newpids=()
        if [ ! -r "$state" ]; then
          notify ${icons.warning} "Pas de session" "Rien à restaurer ($state absent)."
          exit 1
        fi

        # Une restauration par session sway : la relancer doublerait toutes
        # les fenêtres. Le marqueur vit dans XDG_RUNTIME_DIR, vidé à la
        # déconnexion.
        local marker
        marker="''${XDG_RUNTIME_DIR:-/tmp}/sway-session-restored-$(basename "''${SWAYSOCK:-sway}")"
        if [ -e "$marker" ] && [ "$force" != --force ]; then
          notify ${icons.warning} "Session déjà restaurée" "Relancer avec « sway-session restore --force » pour recommencer."
          exit 1
        fi
        touch "$marker"

        # Fenêtres déjà là avant la restauration : jamais déplacées.
        cur=$(list_windows)
        used=$(jq -c 'map(.id)' <<<"$cur")
        pending=$(jq -c .windows "$state")

        pidmap='{}'
        while IFS= read -r group; do
          oldpid=$(jq -r .pid <<<"$group")
          app=$(jq -r .app <<<"$group")
          # App mono-processus (navigateur, Discord…) déjà ouverte : la
          # relancer ne ferait qu'ajouter une fenêtre vide à l'instance en
          # place. Les apps à plusieurs processus (kitty) sont relancées.
          if jq -e --arg a "$app" 'any(.[]; .app == $a)' <<<"$cur" >/dev/null &&
            jq -e --arg a "$app" '[.groups[] | select(.app == $a)] | length == 1' "$state" >/dev/null; then
            skipped+=("$app")
            pending=$(jq -c --argjson p "$oldpid" 'map(select(.pid != $p))' <<<"$pending")
            continue
          fi
          if newpid=$(launch "$group"); then
            newpids+=("$newpid")
          else
            failed+=("$(jq -r .app <<<"$group")")
            newpid=null
            pending=$(jq -c --argjson p "$oldpid" 'map(select(.pid != $p))' <<<"$pending")
          fi
          pidmap=$(jq -c --arg o "$oldpid" --argjson n "$newpid" '.[$o] = $n' <<<"$pidmap")
        done < <(jq -c '.groups[]' "$state")

        local settle=$((SECONDS + ${toString cfg.settle}))
        local deadline=$((SECONDS + ${toString cfg.timeout}))
        while [ "$(jq length <<<"$pending")" -gt 0 ] && [ "$SECONDS" -lt "$deadline" ]; do
          sleep 0.5
          alive=$(for p in "''${newpids[@]}"; do kill -0 "$p" 2>/dev/null && echo "$p"; done | jq -sc .)
          cur=$(list_windows)
          late=false
          [ "$SECONDS" -lt "$settle" ] || late=true

          # Candidates d'une place : les fenêtres du pid relancé, sinon (pid
          # inconnu ou mort) celles de même app qui n'appartiennent à aucun
          # autre processus relancé encore vivant. Deux passes gloutonnes dans
          # l'ordre sauvegardé : d'abord à titre identique, puis la première
          # candidate, seulement si la place est la seule de son processus ou
          # après `settle` (les titres ont eu le temps de se fixer).
          moves=$(jq -c --argjson cur "$cur" --argjson used "$used" \
            --argjson map "$pidmap" --argjson alive "$alive" --argjson late "$late" '
            . as $pending
            | [ $cur[] | select(.id as $id | $used | index($id) | not) ] as $new
            | reduce ((0, 1) as $pass | range(0; $pending | length) | [$pass, .]) as [$pass, $i]
                ({ taken: [], moves: [] };
                . as $acc
                | $pending[$i] as $w
                | $map[$w.pid | tostring] as $np
                | [ $new[] | select(.id as $id | $acc.taken | index($id) | not) ] as $free
                | ( [ $free[] | select($np != null and .pid == $np) ]
                    | if length > 0 or ($np != null and ($alive | index($np)))
                      then .
                      else [ $free[] | select(.app == $w.app
                               and (.pid as $p | $alive | index($p) | not)) ] end ) as $cs
                | ([ $pending[] | select(.pid == $w.pid) ] | length == 1) as $alone
                | ( if $pass == 0 then [ $cs[] | select(.title == $w.title) ][0]
                    elif $alone or $late then $cs[0]
                    else null end ) as $c
                | if $c and ($acc.moves | any(.i == $i) | not) then
                    .taken += [$c.id]
                    | .moves += [{ i: $i, id: $c.id, ws: $w.ws, floating: $w.floating }]
                  else . end)
            | .moves' <<<"$pending")

          while IFS= read -r move; do
            [ -n "$move" ] || continue
            id=$(jq -r .id <<<"$move")
            ws=$(jq -r '.ws | gsub("\""; "\\\"")' <<<"$move")
            swaymsg "[con_id=$id] move container to workspace \"$ws\"" >/dev/null
            if [ "$(jq -r .floating <<<"$move")" = true ]; then
              swaymsg "[con_id=$id] floating enable" >/dev/null
            fi
          done < <(jq -c '.[]' <<<"$moves")

          used=$(jq -c --argjson m "$moves" '. + ($m | map(.id))' <<<"$used")
          pending=$(jq -c --argjson m "$moves" \
            '[ to_entries[] | select(.key as $k | $m | any(.i == $k) | not) | .value ]' <<<"$pending")
        done

        local body
        body="$(jq '.windows | length' "$state") fenêtres sauvegardées le $(jq -r .saved "$state")."
        if [ "$(jq length <<<"$pending")" -gt 0 ]; then
          body+=$'\n'"Non replacées : $(jq -r 'map(.app) | unique | join(", ")' <<<"$pending")."
        fi
        if [ "''${#failed[@]}" -gt 0 ]; then
          body+=$'\n'"Introuvables : ''${failed[*]}."
        fi
        if [ "''${#skipped[@]}" -gt 0 ]; then
          body+=$'\n'"Déjà ouvertes, laissées telles quelles : ''${skipped[*]}."
        fi
        notify ${icons.restore} "Session restaurée" "$body"
      }

      case "''${1:-}" in
        save) save ;;
        restore) restore "''${2:-}" ;;
        *)
          echo "usage: sway-session save|restore [--force]" >&2
          exit 1
          ;;
      esac
    '';
  };
in
{
  options = {
    userSettings.windowManager.sway.session = {
      enable = lib.mkEnableOption "sauvegarde/restauration des fenêtres sway ($mod+F5 / $mod+Shift+F5)";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
      ignore = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "pavucontrol" ];
        description = "app_id (ou classe X11) jamais sauvegardés.";
      };
      launchers = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          discord = "discord --start-minimized";
        };
        description = ''
          Commande (sh -c) à lancer pour un app_id donné, à la place de celle
          relevée dans /proc. Pour une app que ni son nom de binaire ni son
          .desktop ne permettent de relancer.
        '';
      };
      resume = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "claude"
          "nvim"
          "vim"
          "hx"
          "nano"
          "htop"
          "btop"
          "yazi"
          "lazygit"
          "man"
          "less"
        ];
        description = ''
          Programmes relancés avec leurs arguments s'ils tournaient au premier
          plan d'un terminal kitty au moment du save. Liste fermée : relancer
          n'importe quoi (un `make deploy`, un `rm`) serait dangereux. Claude
          Code est repris sur sa conversation (`--resume <id>`).
        '';
      };
      timeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60;
        description = "Secondes d'attente des fenêtres à la restauration (navigateurs lents au démarrage).";
      };
      settle = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = ''
          Secondes pendant lesquelles les fenêtres d'un même processus
          (N fenêtres Firefox) ne sont placées que si leur titre correspond à
          celui sauvegardé. Au-delà, placées dans l'ordre.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Binds $mod+F5 / $mod+Shift+F5 dans sway-config, comme flameshot et
    # wf-recorder.
    home.packages = [ sway-session ];

    # Socket de contrôle par fenêtre kitty, pour lire son scrollback au save.
    # socket-only : pilotable par les processus de l'utilisateur via le
    # fichier (droits de XDG_RUNTIME_DIR), pas par les séquences d'échappement
    # qu'afficherait un programme. Nom = pid de kitty, celui de la fenêtre.
    programs.kitty.settings = lib.mkIf kitty {
      allow_remote_control = "socket-only";
      listen_on = "unix:\${XDG_RUNTIME_DIR}/kitty-{kitty_pid}";
    };
  };
}
