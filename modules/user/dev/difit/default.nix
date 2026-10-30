{
  config,
  lib,
  pkgs-unstable,
  myLib,
  ...
}:

let
  cfg = config.userSettings.dev.difit;

  difitTarball = myLib.packaging.fetchPinned cfg.pkgs ./pinned.json;

  # Absent de nixpkgs : tarball npm épinglé, file:// requis par npx.
  difit-wrapper = cfg.pkgs.writeShellScriptBin "difit" ''
    exec ${cfg.pkgs.nodejs_22}/bin/npx --yes file://${difitTarball} "$@"
  '';
in
{
  options.userSettings.dev.difit = {
    enable = lib.mkEnableOption "difit (revue de diff git dans le navigateur)";
    pkgs = myLib.mkPkgsOption {
      inherit lib config;
      default = pkgs-unstable;
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ difit-wrapper ];
  };
}
