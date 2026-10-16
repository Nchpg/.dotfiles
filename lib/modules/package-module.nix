{
  config,
  lib,
  dir,
  description,
  package ? baseNameOf (toString dir),
  defaultPkgs ? config.userSettings.defaultPkgs,
}:
let
  path = (import ./option-path.nix lib).ofUserDir dir;
  cfg = lib.getAttrFromPath path config.userSettings;
in
{
  options.userSettings = lib.setAttrByPath path {
    enable = lib.mkEnableOption description;
    pkgs = import ./pkgs-option.nix {
      inherit lib config;
      default = defaultPkgs;
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.${package} ];
  };
}
