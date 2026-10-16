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

  # bat sans tty (previews fzf) prend Monokai : thème résolu au build.
  batPreviewTheme =
    {
      dark = "gruvbox-dark";
      light = "gruvbox-light";
    }
    .${themes.polarity config.userSettings.stylix.theme};

  # Via parseScheme et non config.lib.stylix.colors : doit marcher sans stylix (root).
  schemeColors = [
    "base02" # sélection
    "base03" # commentaires et suggestions
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

      # Copie universelle de fish_complete_path (reste de fisher) gonflée par `set -a` (1,1 s de démarrage) : supprimée.
      shellInit = lib.mkBefore ''
        set -qU fish_complete_path; and set -eU fish_complete_path
      '';

      interactiveShellInit = builtins.concatStringsSep "\n" [
        "set -g __bat_preview_theme ${batPreviewTheme}"
        colorsFish
        (builtins.readFile ./fzf_wrapper.fish)
        (builtins.readFile ./secrets_status.fish)
        (builtins.readFile ./.fish)
      ];
    };

    home.packages = with pkgs-unstable; [
      fishPlugins.fzf-fish
    ];
  };
}
