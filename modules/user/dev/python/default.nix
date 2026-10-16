{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.dev.python;
in
{
  options.userSettings.dev.python = {
    enable = lib.mkEnableOption "Python + uv globaux (hors devshell)";
    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      cfg.pkgs.python313
      cfg.pkgs.uv
    ];

    # uv préférerait ses interpréteurs non-Nix.
    xdg.configFile."uv/uv.toml".text = ''
      python-preference = "system"
    '';
  };
}
