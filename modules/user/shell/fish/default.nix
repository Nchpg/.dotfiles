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

      interactiveShellInit = builtins.concatStringsSep "\n" [
        (builtins.readFile ../common)
        config.userSettings.shell.devShellAliases
        "set -g __bat_preview_theme ${batPreviewTheme}"
        (builtins.readFile ./colors.fish)
        (builtins.readFile ./fzf_wrapper.fish)
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
