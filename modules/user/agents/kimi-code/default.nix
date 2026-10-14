{
  config,
  lib,
  pkgs-unstable,
  myLib,
  ...
}:

let
  cfg = config.userSettings.agents.kimiCode;

  # Tarball npm vérifié par Nix (FOD) : un hash mismatch fait échouer l'éval.
  # URL + hash épinglés automatiquement par update.sh.
  kimiTarball = myLib.fetchPinned cfg.pkgs ./pinned.json;

  # npx + Node.js nixpkgs plutôt que le binaire SEA précompilé upstream, dont
  # le runtime Node embarqué crashe en SIGILL sur CPU hybride (Meteor Lake).
  # file:// requis : un chemin nu fait échouer npx (tente de l'exécuter direct).
  kimi-wrapper = cfg.pkgs.writeShellScriptBin "kimi" ''
    exec ${cfg.pkgs.nodejs_22}/bin/npx --yes file://${kimiTarball} "$@"
  '';

  # `kimi-code` : même commande sous l'autre nom, simple lien vers `kimi`.
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
