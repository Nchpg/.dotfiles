{
  config,
  lib,
  myLib,
  ...
}:

# Distribution TeX pour LaTeX Workshop (VS Code : compile + aperçu pdf auto),
# avec les paquets absents de texliveMedium utilisés par le CV.
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
