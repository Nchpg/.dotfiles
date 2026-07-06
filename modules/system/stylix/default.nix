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

  themesEnum = lib.types.enum (
    builtins.attrNames (
      lib.filterAttrs (_name: type: type == "directory") (builtins.readDir ../../themes)
    )
  );

  # Thème actif = la variante sélectionnée. C'est la SOURCE DE VÉRITÉ lue par
  # GDM/console ici, et par le user nchpg (cf. modules/user/stylix).
  activeTheme = if cfg.variant == "light" then cfg.lightTheme else cfg.darkTheme;
  theme = import (../../themes + ("/" + activeTheme));
in
{
  # Module Stylix NIVEAU SYSTÈME : thémise ce que le module home-manager ne
  # peut pas atteindre (il tourne avant/à côté de la session user) :
  #   - GDM (écran de login) via le target `gnome` → « GNOME and GDM »
  #   - la console / TTY
  #
  # Bascule dark/light : on change `variant` (à la main ou via la commande
  # `theme dark|light|toggle`) puis on rebuild. Comme c'est une valeur de la
  # config, le thème choisi est PERSISTANT — il survit au reboot, sans aucune
  # entrée de boot supplémentaire.
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
          Variante active (interrupteur de bascule). Change-la puis rebuild ;
          le choix est persistant (reboot inclus). La commande
          `theme dark|light|toggle` fait ce changement + rebuild automatiquement.
        '';
      };

      darkTheme = lib.mkOption {
        type = themesEnum;
        default = "gruvbox-dark-custom";
        description = "Thème utilisé quand variant = \"dark\".";
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

  config = lib.mkIf cfg.enable {
    # Expose le thème actif (consommé par modules/user/stylix via systemSettings).
    systemSettings.stylix.theme = activeTheme;

    # Commande `theme {dark|light|toggle}` : flippe `variant` dans la config
    # puis délègue le rebuild à la commande `rebuild` (cf. modules/system/rebuild),
    # qui gère déjà check git, reload sway et restart waybar — pas de logique
    # dupliquée ici. C'est un vrai binaire (pas un alias) → marche pareil en
    # bash/zsh/fish. Le choix est persistant (écrit dans la config → survit au
    # reboot). $MY_FLAKE est fourni par home-manager (sessionVariables).
    environment.systemPackages = [
      (cfg.pkgs.writeShellScriptBin "theme" ''
        set -euo pipefail
        flake="''${MY_FLAKE:-$HOME/.dotfiles}"
        # Profil de CE système (specialArg target) : sur une machine work-*,
        # `theme` édite bien profiles/work/, pas personal/.
        file="$flake/profiles/${target.profile}/default.nix"

        target="''${1:-}"
        if [ "$target" = "toggle" ]; then
          if grep -q 'variant = "dark"' "$file"; then target=light; else target=dark; fi
        fi

        case "$target" in
          dark)  sed -i 's/variant = "light"/variant = "dark"/' "$file" ;;
          light) sed -i 's/variant = "dark"/variant = "light"/' "$file" ;;
          *) echo "usage: theme {dark|light|toggle}" >&2; exit 1 ;;
        esac

        echo "→ variant = $target ; rebuild en cours…"
        # -y : le sed ci-dessus vient de modifier un fichier tracké, la
        # confirmation de rebuild.sh serait systématique et sans intérêt ici.
        exec rebuild -y
      '')
    ];

    stylix = {
      enable = true;
      autoEnable = false; # on n'active que ce qu'on veut

      # On gère nous-mêmes le module Stylix home-manager (importé dans
      # profiles/default.nix) et le suivi du thème (défaut de userSettings.stylix
      # = systemSettings.stylix.theme). On coupe donc l'auto-import de Stylix,
      # sinon il force son scheme dans CHAQUE user en read-only (followSystem)
      # → conflit avec guest/root qui ont leur propre thème.
      homeManagerIntegration.autoImport = false;
      inherit (theme) polarity;
      base16Scheme = theme;
      image = cfg.pkgs.fetchurl {
        url = theme.backgroundUrl;
        sha256 = theme.backgroundSha256 or theme.backgroundUrlSha256;
      };

      targets = {
        gnome.enable = true; # ⇒ thémise GDM (login screen)
        console.enable = true; # ⇒ thémise les TTY
      };

      # Mêmes polices que le module user, pour un rendu cohérent sur GDM.
      # /!\ les polices doivent être installées dans
      #     modules/system/fonts (fonts.packages).
      fonts = {
        monospace = {
          name = "FiraCode Nerd Font";
          package = cfg.pkgs.nerd-fonts.fira-code;
        };
        serif = {
          name = "Fira Sans";
          package = cfg.pkgs.fira-sans;
        };
        sansSerif = {
          name = "Fira Sans";
          package = cfg.pkgs.fira-sans;
        };
        emoji = {
          name = "Twitter Color Emoji";
          package = cfg.pkgs.twitter-color-emoji;
        };
        sizes = {
          terminal = 16;
          applications = 10;
          desktop = 10;
        };
      };
    };
  };
}
