{ pkgs-stable, ... }:

{
  # Commande `rebuild` : enrobe le script ./rebuild.sh du dépôt.
  # Par défaut, profil et host sont déduits du hostname courant ($(hostname) =
  # "${profile}-${host}"), donc sans rien changer :
  #   rebuild                  → ./rebuild.sh --profile personal --host gram
  #   rebuild -p work          → ./rebuild.sh --profile work     --host gram
  #   rebuild -H portable      → ./rebuild.sh --profile personal --host portable
  #   rebuild -p work -H srv   → ./rebuild.sh --profile work     --host srv
  # rebuild.sh garde toute sa logique (bump claude-code, check git + confirmation,
  # --show-trace, swaymsg reload).
  environment.systemPackages = [
    (pkgs-stable.writeShellScriptBin "rebuild" ''
      set -euo pipefail
      flake="''${MY_FLAKE:-$HOME/.dotfiles}"

      host_name="$(hostname)"
      profile="''${host_name%%-*}"   # avant le 1er '-'  → "personal"
      host="''${host_name#*-}"       # après le 1er '-'  → "gram"

      while [ $# -gt 0 ]; do
        case "$1" in
          -p|--profile) profile="$2"; shift 2 ;;
          -H|--host)    host="$2";    shift 2 ;;
          -h|--help)
            echo "usage: rebuild [-p PROFILE] [-H HOST]"
            echo "  défaut déduit du hostname : --profile $profile --host $host"
            exit 0 ;;
          *) echo "argument inconnu : $1" >&2; exit 1 ;;
        esac
      done

      exec "$flake/rebuild.sh" --profile "$profile" --host "$host"
    '')
  ];
}
