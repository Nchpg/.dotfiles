{
  lib,
  config,
  pkgs-stable,
  ...
}:

# `dots` : point d'entrée unique pour les commandes du dépôt (rebuild, update,
# theme, genclean, secrets). Sans argument, un menu gum : on choisit la
# commande, puis un des usages courants (avec son explication), ou on tape ses
# propres arguments. `dots <commande> …` relaie tel quel, `dots help` liste
# tout avec les exemples.
#
# Le catalogue ci-dessous n'est QUE de la doc : chaque commande garde son
# propre parsing et son `--help`. Une commande absente de ce système (`theme`
# sans Stylix) est masquée à l'exécution, pas ici.
let
  # `<…>` dans un exemple = valeur demandée à l'exécution (gum input).
  commands = [
    {
      name = "rebuild";
      desc = "reconstruit et active le système";
      examples = [
        [
          "rebuild"
          "rebuild de la cible de ce système"
        ]
        [
          "rebuild -u"
          "update (au choix) puis rebuild"
        ]
        [
          "rebuild -y"
          "sans confirmation (working tree sale…)"
        ]
        [
          "rebuild -V <dark|light>"
          "rebuild dans une variante de thème"
        ]
      ];
    }
    {
      name = "update";
      desc = "met à jour modules et inputs du flake (sans rebuild)";
      examples = [
        [
          "update -c"
          "liste ce qui a une mise à jour, ne modifie rien"
        ]
        [
          "update"
          "vérifie tout, puis coche quoi mettre à jour"
        ]
        [
          "update -y"
          "applique la sélection par défaut sans question"
        ]
        [
          "update <nom>"
          "restreint aux modules/inputs contenant ce nom"
        ]
      ];
    }
    {
      name = "theme";
      desc = "change de thème ou de variante dark/light";
      examples = [
        [
          "theme"
          "ouvre la galerie des thèmes dans le navigateur"
        ]
        [
          "theme toggle"
          "bascule dark ↔ light puis rebuild"
        ]
        [
          "theme dark"
          "passe en sombre puis rebuild"
        ]
        [
          "theme light"
          "passe en clair puis rebuild"
        ]
      ];
    }
    {
      name = "genclean";
      desc = "nettoie les générations, GC, optimise le store";
      examples = [
        [
          "genclean"
          "nettoyage interactif (chaque étape est demandée)"
        ]
      ];
    }
    {
      name = "secrets";
      desc = "édite et audite les secrets sops (dépôt privé)";
      examples = [
        [
          "secrets list"
          "liste les secrets (aucun déchiffrement)"
        ]
        [
          "secrets show <clé>"
          "affiche une valeur, ex. gh/token"
        ]
        [
          "secrets edit <clé>"
          "édite ou crée un secret, puis synchronise"
        ]
        [
          "secrets policy"
          "régénère les règles sops, rescelle, synchronise"
        ]
        [
          "secrets status"
          "dépôt privé en phase avec le lock ?"
        ]
        [
          "secrets sync"
          "commit + push du dépôt privé, mise à jour du lock"
        ]
      ];
    }
    {
      # Pas une commande du PATH : le script du dépôt, ~/.dotfiles/init.sh.
      name = "init";
      desc = "prépare cette machine : clés, secrets, hooks, inscription";
      examples = [
        [
          "init"
          "vérifie et rattrape ce qui manque (sans risque si déjà prête)"
        ]
      ];
    }
  ];

  # Une ligne par entrée, champs séparés par des tabulations :
  #   cmd  <nom>  <description>
  #   ex   <nom>  <ligne de commande>  <explication>
  catalog = lib.concatMapStrings (
    c:
    "cmd\t${c.name}\t${c.desc}\n"
    + lib.concatMapStrings (
      e: "ex\t${c.name}\t${builtins.elemAt e 0}\t${builtins.elemAt e 1}\n"
    ) c.examples
  ) commands;

  colors = lib.optionalString config.stylix.enable (
    let
      c = config.lib.stylix.colors;
    in
    ''
      export GUM_CHOOSE_CURSOR_FOREGROUND="#${c.base0D}"
      export GUM_CHOOSE_HEADER_FOREGROUND="#${c.base03}"
      export GUM_CHOOSE_SELECTED_FOREGROUND="#${c.base0B}"
      export GUM_INPUT_PROMPT_FOREGROUND="#${c.base0D}"
      export GUM_INPUT_HEADER_FOREGROUND="#${c.base03}"
      export DOTS_OK="#${c.base0B}" DOTS_WARN="#${c.base0A}"
    ''
  );
in
{
  environment.systemPackages = [
    (pkgs-stable.writeShellApplication {
      name = "dots";
      runtimeInputs = [
        pkgs-stable.gum
        pkgs-stable.git
      ];
      text = ''
        ${colors}
        catalog=$(cat <<'CATALOG'
        ${catalog}CATALOG
        )

        flake="''${MY_FLAKE:-$HOME/.dotfiles}"

        # Commandes réellement disponibles ici, dans l'ordre du catalogue.
        # `init` n'est pas dans le PATH : c'est le script du dépôt.
        names=()
        while IFS=$'\t' read -r kind name _; do
          [ "$kind" = cmd ] || continue
          if [ "$name" = init ]; then
            if [ -x "$flake/init.sh" ]; then names+=(init); fi
          elif command -v "$name" > /dev/null; then
            names+=("$name")
          fi
        done <<< "$catalog"

        # Lance une commande du catalogue (init -> le script du dépôt).
        run() {
          if [ "$1" = init ]; then
            shift
            exec "$flake/init.sh" "$@"
          fi
          exec "$@"
        }

        # LES HOOKS GIT du dépôt de config (.githooks) : ce sont eux qui tiennent
        # le dépôt de secrets en phase au pull et au push. Actifs seulement si
        # le clone le demande (core.hooksPath, réglage local, jamais poussé) :
        # un clone fait à la main sans ./init.sh les a donc éteints.
        hooksOn() { [ "$(git -C "$flake" config --get core.hooksPath 2> /dev/null)" = .githooks ]; }
        hooksStatus() {
          [ -d "$flake/.githooks" ] || return 0
          if hooksOn; then
            echo "✓ hooks git actifs : secrets synchronisés au pull et au push"
          else
            echo "⚠ hooks git INACTIFS dans $flake : secrets non synchronisés au pull/push"
          fi
        }

        # printf compte les octets : « <clé> » décalait la colonne. ''${#} compte
        # les caractères.
        pad() { printf '%s%*s' "$1" $(($2 - ''${#1})) ""; }

        known() {
          local n
          for n in "''${names[@]}"; do [ "$n" = "$1" ] && return 0; done
          return 1
        }

        usage() {
          echo "usage: dots                   menu interactif"
          echo "       dots <commande> [args] lance la commande"
          echo "       dots help               cette aide"
          while IFS=$'\t' read -r kind name a b; do
            known "$name" || continue
            if [ "$kind" = cmd ]; then
              printf '\n  %s — %s\n' "$name" "$a"
            else
              printf '    %s %s\n' "$(pad "$a" 26)" "$b"
            fi
          done <<< "$catalog"
          echo
          echo "Chaque commande a aussi son propre --help (theme : sans argument = galerie)."
          echo
          hooksStatus
          if [ -d "$flake/.githooks" ] && ! hooksOn; then
            echo "  pour les activer : git -C $flake config core.hooksPath .githooks"
          fi
        }

        case "''${1:-}" in
          "") ;;
          -h | --help | help) usage; exit 0 ;;
          *)
            if known "$1"; then run "$@"; fi
            echo "dots : commande inconnue « $1 »" >&2
            echo "  dots help pour la liste" >&2
            exit 1
            ;;
        esac

        # Pas de terminal (pipe, script) : rien à choisir, on affiche l'aide.
        if [ ! -t 0 ] || [ ! -t 1 ]; then usage; exit 0; fi

        # Échap / Ctrl-C dans gum = abandon silencieux, pas une erreur. Le
        # `|| bye` reste à l'appel : dans pick(), il ne quittait que le
        # sous-shell de `$(…)` et le menu continuait avec une valeur vide.
        pick() { gum choose --label-delimiter=$'\t' "$@"; }

        # gum écrit « nothing selected » sur stderr en partant, et on ne peut pas
        # le faire taire : c'est aussi là qu'il dessine le menu. On efface la
        # ligne après coup.
        bye() { printf '\e[1A\e[2K' >&2; exit 0; }

        # 0. Les hooks : l'état en une ligne, et l'activation proposée s'ils
        # sont éteints (Oui par défaut : sans eux, push et pull ne
        # s'occupent plus des secrets).
        if [ -d "$flake/.githooks" ]; then
          if hooksOn; then
            gum style --foreground "''${DOTS_OK:-2}" "$(hooksStatus)"
          else
            gum style --foreground "''${DOTS_WARN:-3}" "$(hooksStatus)"
            if gum confirm "Activer les hooks git maintenant ?"; then
              git -C "$flake" config core.hooksPath .githooks
              gum style --foreground "''${DOTS_OK:-2}" "$(hooksStatus)"
            fi
          fi
          echo
        fi

        # 1. La commande.
        opts=()
        while IFS=$'\t' read -r kind name desc _; do
          if [ "$kind" != cmd ] || ! known "$name"; then continue; fi
          opts+=("$(printf '%-10s %s' "$name" "$desc")"$'\t'"$name")
        done <<< "$catalog"
        cmd=$(pick --header "Quelle commande ?" "''${opts[@]}") || bye

        # 2. L'usage, parmi les exemples, ou des arguments libres.
        opts=()
        while IFS=$'\t' read -r kind name line expl; do
          if [ "$kind" != ex ] || [ "$name" != "$cmd" ]; then continue; fi
          opts+=("$(pad "$line" 26) $expl"$'\t'"$line")
        done <<< "$catalog"
        opts+=("✎ autre… (arguments libres)"$'\t'"__custom__")
        line=$(pick --header "$cmd — quel usage ?" "''${opts[@]}") || bye

        if [ "$line" = __custom__ ]; then
          line=$(gum input --header "Arguments ($cmd --help pour la liste)" --value "$cmd ") || bye
        fi

        # 3. Les valeurs à compléter : chaque <…> est demandé une fois.
        while [[ "$line" =~ \<([^>]+)\> ]]; do
          hole="''${BASH_REMATCH[0]}"
          value=$(gum input --header "$line" --placeholder "''${BASH_REMATCH[1]}") || bye
          [ -n "$value" ] || { echo "dots : valeur vide, abandon." >&2; exit 1; }
          line="''${line/"$hole"/"$value"}"
        done

        read -ra argv <<< "$line"
        known "''${argv[0]:-}" || { echo "dots : commande inconnue « ''${argv[0]:-} »" >&2; exit 1; }

        echo "→ $line"
        run "''${argv[@]}"
      '';
    })
  ];
}
