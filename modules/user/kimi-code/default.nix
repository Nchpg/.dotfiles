{
  config,
  lib,
  pkgs-unstable,
  ...
}:

let
  cfg = config.userSettings.kimiCode;

  # Charge la version + le hash épinglés automatiquement par update.sh
  pinned = builtins.fromJSON (builtins.readFile ./pinned.json);

  # Tarball npm exact que npx va installer, récupéré ET vérifié par Nix (FOD) :
  # un hash mismatch fait échouer l'éval plutôt que de laisser passer un
  # contenu différent de celui audité au moment du bump. Avant, pinned.sha256
  # était le checksum du binaire natif SEA (cf. plus bas) — un artefact
  # totalement différent de ce que npx installe réellement depuis le registre
  # npm, donc jamais vérifié en pratique malgré les apparences.
  kimiTarball = pkgs-unstable.fetchurl {
    url = "https://registry.npmjs.org/@moonshot-ai/kimi-code/-/kimi-code-${pinned.version}.tgz";
    sha256 = pinned.sha256;
  };

  # Wrapper qui utilise npx du Node.js nixpkgs pour exécuter le paquet npm
  # @moonshot-ai/kimi-code, depuis le tarball pré-vérifié ci-dessus (le
  # préfixe file:// est nécessaire : un chemin nu fait échouer npx, qui tente
  # de l'exécuter directement au lieu de le traiter comme un paquet).
  #
  # Le binaire pré-compilé (SEA) de Kimi Code embarque son propre runtime
  # Node.js, qui crashe en SIGILL sur les CPU hybrides récents (Meteor Lake,
  # etc.). En passant par npx + le Node.js de nixpkgs, on s'appuie sur un
  # runtime compilé pour le système → plus de crash.
  kimi-wrapper = pkgs-unstable.writeShellScriptBin "kimi" ''
    exec ${pkgs-unstable.nodejs_22}/bin/npx --yes file://${kimiTarball} "$@"
  '';

  kimi-code-wrapper = pkgs-unstable.writeShellScriptBin "kimi-code" ''
    exec ${pkgs-unstable.nodejs_22}/bin/npx --yes file://${kimiTarball} "$@"
  '';
in
{
  options.userSettings.kimiCode = {
    enable = lib.mkEnableOption "Kimi Code CLI";
    pkgs = import ../../../lib/mk-pkgs-option.nix { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      kimi-wrapper
      kimi-code-wrapper
    ];
  };
}
