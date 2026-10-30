{
  config,
  lib,
  pkgs-unstable,
  myLib,
  ...
}:

let
  cfg = config.userSettings.agents.herdr;

  pinned = lib.importJSON ./pinned.json;

  # Absent de nixpkgs : binaire release statique (static-pie), rien à patcher.
  herdr = cfg.pkgs.stdenvNoCC.mkDerivation {
    pname = "herdr";
    version = pinned.version;

    src = myLib.packaging.fetchPinned cfg.pkgs ./pinned.json;

    dontUnpack = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 $src $out/bin/herdr
      runHook postInstall
    '';

    meta = with lib; {
      description = "herdr — multiplexeur de terminal pour agents de code";
      homepage = "https://github.com/herdrdev/herdr";
      license = licenses.asl20;
      platforms = [ "x86_64-linux" ];
      mainProgram = "herdr";
    };
  };
in
{
  options.userSettings.agents.herdr = {
    enable = lib.mkEnableOption "herdr (runtime/multiplexeur pour agents de code)";
    pkgs = myLib.mkPkgsOption {
      inherit lib config;
      default = pkgs-unstable;
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ herdr ];

    # Lien en lecture seule : onboarding = false évite que herdr tente de le réécrire.
    xdg.configFile."herdr/config.toml".source =
      (cfg.pkgs.formats.toml { }).generate "herdr-config.toml"
        {
          onboarding = false;
          theme = {
            name = "gruvbox";
            auto_switch = false;
          };
          terminal.default_shell = lib.getExe config.programs.${config.userSettings.shell.default}.package;
        };
  };
}
