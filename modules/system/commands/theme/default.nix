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
in
{
  config = lib.mkIf cfg.enable {
    # Entrée du catalogue de `dots` (cf. ../default.nix) : seulement avec
    # Stylix, comme la commande elle-même.
    systemSettings.commands.theme = {
      desc = "change de thème ou de variante dark/light";
      order = 3;
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
    };

    environment.systemPackages = [
      (cfg.pkgs.writeShellScriptBin "theme" ''
        set -euo pipefail
        current="${cfg.variant}"

        want="''${1:-}"

        # Sans argument : galerie servie en local (pas file://) pour que le
        # bouton "appliquer" puisse réécrire le profil.
        if [ -z "$want" ]; then
          # Pas de mkFlakeGuard : aucun script du dépôt n'est exécuté ici, ce
          # sont ces deux fichiers qu'il faut pouvoir écrire (contrôlés juste
          # en dessous).
          ${myLib.flakeVar}
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
