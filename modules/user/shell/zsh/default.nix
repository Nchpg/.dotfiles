{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.shell.zsh;
in
{
  options = {
    userSettings.shell.zsh = {
      enable = lib.mkEnableOption "Enable zsh";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
    };
  };
  config = lib.mkIf cfg.enable {
    programs.zsh = {
      enable = true;
      package = cfg.pkgs.zsh;
      enableCompletion = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      history = {
        ignoreDups = true;
        extended = true;
      };
      initContent = builtins.concatStringsSep "\n" [
        (builtins.readFile ../common-posix)
        (builtins.readFile ./.zshrc)
      ];
    };
  };
}
