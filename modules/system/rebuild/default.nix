{ pkgs-stable, target, ... }:

{
  # Commande `rebuild` : enrobe le script ./rebuild.sh du dépôt.
  # Profil, host et variante par défaut sont ceux de la config qui a construit
  # ce système (specialArg `target`, injectés à la génération du script — plus
  # robuste que de parser le hostname, qui casse si un profil contient un
  # tiret). La variante par défaut = celle du système courant : un `rebuild`
  # seul reste donc en dark ou light, c'est ce qui rend le thème persistant
  # sans aucun fichier d'état (cf. modules/system/stylix, commande `theme`).
  #   rebuild                  → ./rebuild.sh --profile personal --host gram --variant <courante>
  #   rebuild -p work          → idem avec --profile work
  #   rebuild -H portable      → idem avec --host portable
  #   rebuild -V light         → idem avec --variant light (utilisé par `theme`)
  #   rebuild -u               → idem + bump de l'input claude-code avant build
  #   rebuild -y               → pas de confirmation si le working tree est sale
  # rebuild.sh garde toute sa logique (check git + confirmation, swaymsg reload).
  environment.systemPackages = [
    # Diff des paquets entre générations, affiché par rebuild.sh après le switch.
    pkgs-stable.nvd

    (pkgs-stable.writeShellScriptBin "rebuild" ''
      set -euo pipefail
      flake="''${MY_FLAKE:-$HOME/.dotfiles}"

      profile="${target.profile}"
      host="${target.host}"
      variant="${target.variant}"
      extra=()

      while [ $# -gt 0 ]; do
        case "$1" in
          -p|--profile) profile="$2"; shift 2 ;;
          -H|--host)    host="$2";    shift 2 ;;
          -V|--variant) variant="$2"; shift 2 ;;
          -u|--update)  extra+=(--update); shift ;;
          -y|--yes)     extra+=(--yes);    shift ;;
          -h|--help)
            echo "usage: rebuild [-p PROFILE] [-H HOST] [-V dark|light] [-u|--update] [-y|--yes]"
            echo "  défaut (cible de ce système) : --profile $profile --host $host --variant $variant"
            echo "  -V : variante de thème (la commande \`theme\` s'en sert pour toggler)"
            echo "  -u : met à jour l'input claude-code avant le rebuild"
            echo "  -y : pas de confirmation si le working tree est sale"
            exit 0 ;;
          *) echo "argument inconnu : $1" >&2; exit 1 ;;
        esac
      done

      exec "$flake/rebuild.sh" --profile "$profile" --host "$host" --variant "$variant" ''${extra[@]+"''${extra[@]}"}
    '')
  ];
}
