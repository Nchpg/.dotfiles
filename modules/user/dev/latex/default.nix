{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.dev.latex;
in
{
  options.userSettings.dev.latex = {
    enable = lib.mkEnableOption "LaTeX (texliveMedium + paquets du CV)";
    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      (cfg.pkgs.texliveMedium.withPackages (
        ps: with ps; [
          enumitem
          titlesec
          eurosym
          parskip
        ]
      ))
    ];
  };
}
