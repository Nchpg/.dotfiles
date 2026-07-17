{
  lib,
  config,
  pkgs-stable,
  inputs,
  ...
}:

let
  cfg = config.systemSettings.stylix;

  # API des thèmes (noms auto-découverts, bloc stylix commun) — partagée avec
  # modules/user/stylix, cf. modules/themes/default.nix.
  themes = import ../../themes lib;
  themesEnum = lib.types.enum themes.names;

  # Thème actif = la variante sélectionnée. C'est la SOURCE DE VÉRITÉ lue par
  # GDM/console ici, et par le user nchpg (cf. modules/user/stylix).
  activeTheme = if cfg.variant == "light" then cfg.lightTheme else cfg.darkTheme;
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

      # Commande `theme {dark|light|toggle}` : rebuilde la cible du flake de
      # l'autre variante via la commande `rebuild` (cf. modules/system/rebuild),
      # qui gère déjà check git, reload sway et restart waybar. Aucun fichier
      # modifié : la variante courante est celle de la cible qui a construit CE
      # système (cfg.variant, injectée par le flake), l'état vit dans la
      # génération active. Si les deux variantes sont déjà dans le store (arbre
      # inchangé, CI passée), la bascule est quasi immédiate.
      environment.systemPackages = [
        (cfg.pkgs.writeShellScriptBin "theme" ''
          set -euo pipefail
          current="${cfg.variant}"

          want="''${1:-}"
          if [ "$want" = "toggle" ]; then
            if [ "$current" = "dark" ]; then want=light; else want=dark; fi
          fi

          case "$want" in
            dark|light) ;;
            *) echo "usage: theme {dark|light|toggle}   (variante actuelle : $current)" >&2; exit 1 ;;
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
