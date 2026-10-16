{
  config,
  lib,
  pkgs-unstable,
  myLib,
  ...
}:

let
  cfg = config.userSettings.agents.kimiCode;

  kimiTarball = myLib.packaging.fetchPinned cfg.pkgs ./pinned.json;

  # npx plutôt que le binaire SEA (SIGILL sur Meteor Lake) ; file:// requis, un chemin nu fait échouer npx.
  kimi-wrapper = cfg.pkgs.writeShellScriptBin "kimi" ''
    exec ${cfg.pkgs.nodejs_22}/bin/npx --yes file://${kimiTarball} "$@"
  '';

  kimi-code-link = cfg.pkgs.runCommand "kimi-code" { } ''
    mkdir -p $out/bin
    ln -s ${kimi-wrapper}/bin/kimi $out/bin/kimi-code
  '';
in
{
  options.userSettings.agents.kimiCode = {
    enable = lib.mkEnableOption "Kimi Code CLI";
    pkgs = myLib.mkPkgsOption {
      inherit lib config;
      default = pkgs-unstable;
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      kimi-wrapper
      kimi-code-link
    ];
  };
}
