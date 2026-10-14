{
  lib,
  config,
  pkgs-stable,
  myLib,
  ...
}:

# `dots` : point d'entrée unique pour les commandes du dépôt (rebuild, update,
# theme, genclean, secrets). Sans argument, un menu gum : on choisit la
# commande, puis un des usages courants (avec son explication), ou on tape ses
# propres arguments. `dots <commande> …` relaie tel quel, `dots help` liste
# tout avec les exemples.
#
# Le catalogue est déclaré par les commandes elles-mêmes (option
# systemSettings.commands, cf. ../default.nix) : une commande absente de ce
# système (`theme` sans Stylix) n'y est simplement pas.
let
  # Le catalogue : ce que chaque module de commande a déclaré (cf.
  # ../default.nix), dans l'ordre de `order`.
  commands = lib.sort (a: b: a.order < b.order) (
    lib.mapAttrsToList (name: c: c // { inherit name; }) config.systemSettings.commands
  );

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
in
{
  # Pas une commande du PATH : le script du dépôt, ~/.dotfiles/init.sh. Inscrit
  # ici, faute de module à lui.
  systemSettings.commands.init = {
    desc = "prépare cette machine : clés, secrets, hooks, inscription";
    order = 6;
    examples = [
      [
        "init"
        "vérifie et rattrape ce qui manque (sans risque si déjà prête)"
      ]
    ];
  };

  environment.systemPackages = [
    (pkgs-stable.writeShellApplication {
      name = "dots";
      runtimeInputs = [
        pkgs-stable.gum
        pkgs-stable.git
      ];
      text = ''
        # Palette gum, la même que `update` & co (cf. lib/mk-gum-env.nix).
        ${myLib.mkGumEnv {
          colors = if config.stylix.enable then config.lib.stylix.colors else null;
        }}
        catalog=$(cat <<'CATALOG'
        ${catalog}CATALOG
        )

        ${myLib.flakeVar}

        # Couleurs, confirm et hooks git : les bibliothèques du dépôt
        # (scripts/lib), une seule implémentation avec rebuild.sh et init.sh.
        # Sans clone, rien de tout ça n'a d'objet : hooks ignorés.
        hooks=0
        if [ -f "$flake/scripts/lib/hooks.sh" ]; then
          # shellcheck source=/dev/null
          . "$flake/scripts/lib/ui.sh"
          # shellcheck source=/dev/null
          . "$flake/scripts/lib/hooks.sh"
          if hooks_present "$flake"; then hooks=1; fi
        fi

        # Commandes du catalogue, dans son ordre. `init` n'est pas dans le
        # PATH : c'est le script du dépôt, proposé seulement s'il est là.
        names=()
        while IFS=$'\t' read -r kind name _; do
          [ "$kind" = cmd ] || continue
          if [ "$name" != init ] || [ -x "$flake/init.sh" ]; then names+=("$name"); fi
        done <<< "$catalog"

        # Lance une commande du catalogue (init -> le script du dépôt).
        run() {
          if [ "$1" = init ]; then
            shift
            exec "$flake/init.sh" "$@"
          fi
          exec "$@"
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
          if [ "$hooks" = 1 ]; then
            echo
            hooks_status "$flake"
            if ! hooks_on "$flake"; then
              echo "  pour les activer : git -C $flake config core.hooksPath .githooks"
            fi
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
        if [ "$hooks" = 1 ]; then
          if hooks_on "$flake"; then hooks_status "$flake"; else hooks_offer "$flake"; fi
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
