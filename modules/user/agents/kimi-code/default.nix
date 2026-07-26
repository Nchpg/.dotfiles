{
  config,
  lib,
  pkgs-unstable,
  myLib,
  ...
}:

let
  cfg = config.userSettings.agents.kimiCode;

  # Version + hash épinglés automatiquement par update.sh
  pinned = builtins.fromJSON (builtins.readFile ./pinned.json);

  # Tarball npm vérifié par Nix (FOD) : un hash mismatch fait échouer l'éval.
  kimiTarball = cfg.pkgs.fetchurl {
    url = "https://registry.npmjs.org/@moonshot-ai/kimi-code/-/kimi-code-${pinned.version}.tgz";
    sha256 = pinned.sha256;
  };

  # npx + Node.js nixpkgs plutôt que le binaire SEA précompilé upstream, dont
  # le runtime Node embarqué crashe en SIGILL sur CPU hybride (Meteor Lake).
  # file:// requis : un chemin nu fait échouer npx (tente de l'exécuter direct).
  kimi-wrapper = cfg.pkgs.writeShellScriptBin "kimi" ''
    exec ${cfg.pkgs.nodejs_22}/bin/npx --yes file://${kimiTarball} "$@"
  '';

  kimi-code-wrapper = cfg.pkgs.writeShellScriptBin "kimi-code" ''
    exec ${cfg.pkgs.nodejs_22}/bin/npx --yes file://${kimiTarball} "$@"
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
      kimi-code-wrapper
    ];
  };
}
