{
  config,
  lib,
  pkgs-unstable,
  inputs,
  ...
}:

let
  cfg = config.userSettings.shell.fish;

  # Thème bat des previews fzf (cf. fzf_wrapper.fish).
  #
  # modules/user/bat ne fixe QUE theme-dark/theme-light et laisse bat détecter
  # la polarité du terminal (OSC 11) à chaque appel. Cette détection exige un
  # tty : dans une preview fzf la sortie est un tube, la détection échoue, et
  # bat ne retombe PAS sur theme-dark — il prend son thème par défaut (Monokai
  # Extended). D'où des previews qui ne ressemblaient pas au rendu final, lui
  # affiché avec un tty. COLORFGBG est ignoré par bat et `--theme=auto:system`
  # est macOS-only : seule BAT_THEME court-circuite la détection.
  #
  # On la résout donc au build depuis la polarité stylix, comme le module
  # vscode. Uniquement dans les previews : un `set -gx BAT_THEME` global
  # figerait la polarité pour TOUS les appels bat interactifs, où la détection
  # marche très bien.
  themes = import ../../../themes lib inputs;
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
      pkgs = import ../../../../lib/mk-pkgs-option.nix { inherit lib config; };
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
        (builtins.readFile ./fzf_wrapper.fish)
        (builtins.readFile ./.fish)
      ];
    };

    # fzf-fish est chargé par l'autoload vendor de fish (le paquet n'installe
    # QUE share/fish/vendor_{functions,completions,conf}.d ; les anciens ajouts
    # manuels à fish_function_path pointaient vers des chemins inexistants).
    # unstable pour suivre le fzf unstable épinglé dans modules/user/shell.
    home.packages = with pkgs-unstable; [
      fishPlugins.fzf-fish
    ];
  };
}
