{
  config,
  lib,
  pkgs-unstable,
  myLib,
  ...
}:

let
  cfg = config.userSettings.agents.gemini;

  # Google a renommé Gemini CLI en Antigravity (paquet antigravity-cli,
  # binaire `agy`) : wrapper pour garder la commande `gemini`.
  gemini-wrapper = cfg.pkgs.writeShellScriptBin "gemini" ''
    exec ${cfg.pkgs.antigravity-cli}/bin/agy "$@"
  '';
in
{
  options.userSettings.agents.gemini = {
    enable = lib.mkEnableOption "Gemini (antigravity-cli)";
    pkgs = myLib.mkPkgsOption {
      inherit lib config;
      default = pkgs-unstable;
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ gemini-wrapper ];
  };
}
