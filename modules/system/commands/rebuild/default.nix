{
  pkgs-stable,
  target,
  myLib,
  ...
}:

{
  # Enrobe ./rebuild.sh. Profil/host/variante par défaut = ceux de la config
  # qui a construit ce système (specialArg `target`, plus robuste que parser
  # le hostname). Variante par défaut = celle du système courant : `rebuild`
  # seul reste dans la même dark/light, sans fichier d'état (cf. `theme`).
  environment.systemPackages = [
    # Diff des paquets entre générations, affiché par rebuild.sh après le switch.
    pkgs-stable.nvd

    (pkgs-stable.writeShellScriptBin "rebuild" ''
      set -euo pipefail

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

      ${myLib.mkFlakeGuard {
        name = "rebuild";
        scriptName = "rebuild.sh";
      }}

      exec "$flake/rebuild.sh" --profile "$profile" --host "$host" --variant "$variant" ''${extra[@]+"''${extra[@]}"}
    '')
  ];
}
