{
  lib,
  config,
  pkgs-stable,
  inputs,
  target,
  ...
}:

let
  cfg = config.systemSettings.stylix;

  # API des thèmes (noms auto-découverts, bloc stylix commun) — partagée avec
  # modules/user/stylix, cf. modules/themes/default.nix.
  themes = import ../../themes lib inputs;
  themesEnum = lib.types.enum themes.names;

  # Thème actif = la variante sélectionnée. C'est la SOURCE DE VÉRITÉ lue par
  # GDM/console ici, et par le user nchpg (cf. modules/user/stylix).
  activeTheme = if cfg.variant == "light" then cfg.lightTheme else cfg.darkTheme;

  # Galerie ouverte par `theme` sans argument. Construite au build depuis le
  # même `pathByName` qui alimente l'enum des thèmes — ce qui est affiché est
  # donc exactement ce qui est sélectionnable.
  gallery = import ../../themes/gallery {
    inherit themes;
    pkgs = cfg.pkgs;
  };
  firefox = "${cfg.pkgs.firefox}/bin/firefox";

  # Fichier que la galerie réécrit quand on applique un thème : le profil de
  # CETTE cible, donc celui qui déclare réellement darkTheme/lightTheme.
  profileFile = "profiles/${target.profile}/default.nix";

  # Favoris de la galerie : versionnés dans le dépôt, écrits par le serveur.
  # N'entrent pas dans la config construite (aucun rebuild à faire après un
  # changement de favori) — c'est de la sélection personnelle, pas de l'état
  # système. Exposés côté Nix via themes.favorites si un module veut s'en
  # servir un jour.
  favoritesFile = "modules/themes/gallery/favorites.json";

  # Pose `flake` (le clone, via $MY_FLAKE) et échoue proprement s'il manque —
  # même garde que `rebuild` et `genclean`. Sentinelle rebuild.sh (et non
  # flake.nix) : la garde teste -x, et c'est de toute façon le script auquel
  # cette commande délègue au final.
  flakeGuard = import ../../../lib/mk-flake-guard.nix {
    name = "theme";
    scriptName = "rebuild.sh";
  };
in
{
  # Module Stylix NIVEAU SYSTÈME : thémise ce que le module home-manager ne
  # peut pas atteindre (il tourne avant/à côté de la session user) :
  #   - GDM (écran de login) via le target `gnome` → « GNOME and GDM »
  #   - la console / TTY
  #
  # Bascule dark/light : `variant` est injecté par la CIBLE du flake
  # (personal-gram = dark, personal-gram-light = light) — la commande
  # `theme dark|light|toggle` rebuilde simplement l'autre cible, sans
  # modifier aucun fichier. PERSISTANT : systemd-boot démarre la dernière
  # génération activée, et `rebuild` seul reste sur la variante courante
  # (sa cible par défaut vient du système qui tourne).
  imports = [ inputs.stylix.nixosModules.stylix ];

  options = {
    systemSettings.stylix = {
      enable = lib.mkEnableOption "thème Stylix système (GDM, console)";

      variant = lib.mkOption {
        type = lib.types.enum [
          "dark"
          "light"
        ];
        default = "dark";
        description = ''
          Variante active. Ne PAS la définir dans un profil : elle est
          injectée par la cible du flake (personal-gram-light → "light").
          Bascule via la commande `theme dark|light|toggle`.
        '';
      };

      darkTheme = lib.mkOption {
        type = themesEnum;
        default = "gruvbox-dark-custom";
        description = "Thème utilisé quand variant = \"dark\".";
      };

      wallpaper = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum themes.wallpaperNames);
        default = null;
        description = ''
          Fond d'écran (GDM) à la place de celui du thème actif — un nom de
          modules/themes/wallpapers.nix. null = le fond par défaut du thème.
        '';
      };

      lightTheme = lib.mkOption {
        type = themesEnum;
        default = "gruvbox-light-hard";
        description = "Thème utilisé quand variant = \"light\".";
      };

      theme = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        description = ''
          Thème base16 effectivement actif (calculé depuis `variant`). Lu par
          le module user pour que nchpg suive le thème système. Lecture seule.
        '';
      };

      pkgs = lib.mkOption {
        type = lib.types.pkgs;
        default = pkgs-stable;
        description = "Pkgs to use";
      };
    };
  };

  config = lib.mkMerge [
    {
      # Expose le thème actif (consommé par modules/user/stylix via
      # systemSettings). Hors du mkIf : le calcul ne dépend pas de `enable`,
      # et l'option étant readOnly sans default, un profil sans stylix
      # système casserait l'éval du module user sinon.
      systemSettings.stylix.theme = activeTheme;
    }

    (lib.mkIf cfg.enable {

      # Commande `theme` :
      #   sans argument      → ouvre la galerie (aperçu de TOUS les thèmes
      #                        sélectionnables, nom cliquable à recopier dans
      #                        darkTheme/lightTheme).
      #   dark|light|toggle  → rebuilde la cible du flake de l'autre variante
      #                        via la commande `rebuild` (cf.
      #                        modules/system/rebuild), qui gère déjà check
      #                        git, reload sway et restart waybar.
      #
      # La bascule ne modifie AUCUN fichier : la variante courante est celle de
      # la cible qui a construit CE système (cfg.variant, injectée par le
      # flake), l'état vit dans la génération active. Si les deux variantes
      # sont déjà dans le store (arbre inchangé, CI passée), c'est quasi
      # immédiat.
      environment.systemPackages = [
        (cfg.pkgs.writeShellScriptBin "theme" ''
          set -euo pipefail
          current="${cfg.variant}"

          want="''${1:-}"

          # Sans argument : la galerie. La page est déjà construite dans le
          # store (cf. modules/themes/gallery) ; on la SERT en local plutôt
          # que de l'ouvrir en file:// pour que le bouton « appliquer » puisse
          # réécrire le profil — une page file:// n'a pas ce droit.
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

            # Le rebuild vit ICI, dans le terminal, et pas dans le handler HTTP :
            # il a besoin de sudo, et une requête web n'est pas le bon endroit
            # pour déclencher une élévation de privilèges.
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

      stylix = {
        enable = true;
        autoEnable = false; # on n'active que ce qu'on veut

        # On gère nous-mêmes le module Stylix home-manager (importé dans
        # profiles/default.nix) et le suivi du thème (défaut de userSettings.stylix
        # = systemSettings.stylix.theme). On coupe donc l'auto-import de Stylix,
        # sinon il forcerait son scheme dans CHAQUE user en read-only (followSystem),
        # court-circuitant notre option userSettings.stylix.theme.
        homeManagerIntegration.autoImport = false;

        # Réactivé MALGRÉ autoEnable = false (dont il tire son défaut), parce
        # que le target gnome en dépend entièrement : les extensions n'existent
        # pas sur l'écran de login, donc la SEULE façon de thémiser GDM est de
        # remplacer gnome-shell-theme.gresource dans le paquet gnome-shell —
        # ce que stylix fait via un overlay nixpkgs gardé par cette option.
        # Sans elle, targets.gnome.enable ci-dessous ne posait plus que les
        # réglages dconf curseur/icônes et GDM restait au thème Adwaita sombre.
        #
        # COÛT, mesuré sur cette config : gnome-shell est recompilé depuis les
        # sources (+ gnome-session et gnome-browser-connector qui en dépendent),
        # et ~190 Mio de dépendances de build (mutter-dev, gtk4-dev, meson…)
        # entrent dans le store. Les deux variantes produisent des gnome-shell
        # DIFFÉRENTS : la première bascule dark↔light après chaque `rebuild -u`
        # ou changement de thème repaye cette compilation (le toggle ne
        # redevient immédiat qu'une fois les deux variantes dans le store).
        # Effet de bord : le patch stylix retire l'indicateur « Dark Mode » des
        # quick settings de GNOME Shell (session de secours).
        overlays.enable = true;

        targets = {
          gnome.enable = true; # ⇒ thémise GDM (login screen)
          console.enable = true; # ⇒ thémise les TTY
        };

        # Polices partagées avec le module user (rendu cohérent sur GDM) et
        # installées par modules/system/fonts — source unique :
        # modules/themes/fonts.nix.
        fonts = (import ../../themes/fonts.nix cfg.pkgs).stylix;
      }
      # Scheme base16 + polarité + wallpaper du thème actif (bloc commun avec le
      # module user, cf. modules/themes/default.nix).
      // themes.stylixSettings {
        inherit (cfg) pkgs wallpaper;
        theme = activeTheme;
      };
    })
  ];
}
