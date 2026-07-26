{
  lib,
  config,
  target,
  myLib,
  themes,
  ...
}:

let
  cfg = config.systemSettings.stylix;

  gallery = themes.galleryFor cfg.pkgs;
  firefox = "${cfg.pkgs.firefox}/bin/firefox";

  # Fichier réécrit par la galerie quand on applique un thème : le profil de
  # CETTE cible, qui déclare réellement darkTheme/lightTheme.
  profileFile = "profiles/${target.profile}/default.nix";

  # Versionnés dans le dépôt, écrits par le serveur de galerie ; pas dans la
  # config construite (sélection personnelle, pas état système).
  favoritesFile = "themes/gallery/favorites.json";

  flakeGuard = myLib.mkFlakeGuard {
    name = "theme";
    scriptName = "rebuild.sh";
  };
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (cfg.pkgs.writeShellScriptBin "theme" ''
        set -euo pipefail
        current="${cfg.variant}"

        want="''${1:-}"

        # Sans argument : galerie servie en local (pas file://) pour que le
        # bouton "appliquer" puisse réécrire le profil.
        if [ -z "$want" ]; then
          ${flakeGuard}
          profile="$flake/${profileFile}"
          favorites="$flake/${favoritesFile}"
          for f in "$profile" "$favorites"; do
            if [ ! -w "$f" ]; then
              echo "theme : $f introuvable ou non modifiable." >&2
              exit 1
            fi
          done

          echo "Galerie des thèmes (variante actuelle : $current)"
          set +e
          THEME_BROWSER=${firefox} ${gallery.server} "$profile" "$favorites"
          rc=$?
          set -e
          # 2 = fermé sans rien appliquer : pas une erreur.
          [ "$rc" = 2 ] && exit 0
          [ "$rc" = 0 ] || exit "$rc"

          # Le rebuild vit ici (terminal) et pas dans le handler HTTP : il a
          # besoin de sudo.
          echo
          printf 'Rebuild maintenant ? [y/N] '
          read -r reply || reply=""
          case "$reply" in
            [yYoO]) exec rebuild ;;
            *) echo "Config modifiée. Lance \`rebuild\` quand tu veux l'appliquer." ;;
          esac
          exit 0
        fi

        if [ "$want" = "toggle" ]; then
          if [ "$current" = "dark" ]; then want=light; else want=dark; fi
        fi

        case "$want" in
          dark|light) ;;
          *)
            echo "usage: theme [dark|light|toggle]   (variante actuelle : $current)" >&2
            echo "       sans argument : ouvre la galerie des thèmes" >&2
            exit 1
            ;;
        esac

        if [ "$want" = "$current" ]; then
          echo "Déjà en $want — rien à faire."
          exit 0
        fi

        echo "→ bascule $current → $want…"
        exec rebuild --variant "$want"
      '')
    ];
  };
}
