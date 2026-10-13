{
  config,
  lib,
  pkgs-unstable,
  myLib,
  themes,
  ...
}:

let
  cfg = config.userSettings.shell.fish;

  # bat détecte la polarité du terminal (OSC 11) à chaque appel, mais ça exige
  # un tty : dans une preview fzf (sortie = tube), la détection échoue et bat
  # prend son thème par défaut (Monokai) au lieu de retomber sur theme-dark.
  # Résolu au build depuis la polarité stylix, uniquement dans les previews
  # (un `set -gx BAT_THEME` global figerait la polarité partout ailleurs).
  batPreviewTheme =
    {
      dark = "gruvbox-dark";
      light = "gruvbox-light";
    }
    .${themes.polarity config.userSettings.stylix.theme};

  # Slots du scheme injectés dans colors.fish (@stylix_baseXX@), même procédé
  # que modules/user/editors/neovim. Lus via parseScheme et pas
  # `config.lib.stylix.colors` : ces couleurs doivent exister même pour un
  # user sans stylix (root en console), et userSettings.stylix.theme a une
  # valeur dans tous les cas.
  schemeColors = [
    "base02" # fond de sélection / de correspondance
    "base03" # gris des commentaires et des suggestions
  ];
  scheme = themes.parseScheme config.userSettings.stylix.theme;
  colorsFish = lib.replaceStrings (map (name: "@stylix_${name}@") schemeColors) (map (
    name: scheme.${name}
  ) schemeColors) (builtins.readFile ./colors.fish);
in
{
  options = {
    userSettings.shell.fish = {
      enable = lib.mkEnableOption "Enable  fish";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
    };
  };
  config = lib.mkIf cfg.enable {
    programs.fish = {
      enable = true;
      package = cfg.pkgs.fish;

      # Une copie UNIVERSELLE de fish_complete_path (reste de fisher) est
      # réécrite et allongée par chaque `set`/`set -a` non scopé (complétions
      # HM, kitty...) : 8500 entrées, 1,1 s de démarrage. La globale définie
      # par fish suffit ; on supprime l'universelle si elle réapparaît.
      shellInit = lib.mkBefore ''
        set -qU fish_complete_path; and set -eU fish_complete_path
      '';

      interactiveShellInit = builtins.concatStringsSep "\n" [
        (builtins.readFile ../common)
        config.userSettings.shell.devShellAliases
        "set -g __bat_preview_theme ${batPreviewTheme}"
        colorsFish
        (builtins.readFile ./fzf_wrapper.fish)
        (builtins.readFile ./secrets_status.fish)
        (builtins.readFile ./.fish)
      ];
    };

    # Chargé par l'autoload vendor de fish. unstable pour suivre le fzf
    # unstable épinglé dans modules/user/shell.
    home.packages = with pkgs-unstable; [
      fishPlugins.fzf-fish
    ];
  };
}
