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

  # Le serveur hérite du SHLVL de qui l'a lancé : le prompt fish afficherait 2.
  # exec -a garde le « - » d'un shell de login.
  paneShell = cfg.pkgs.writeShellScript "herdr-shell" ''
    unset SHLVL
    exec -a "$0" ${lib.getExe config.programs.${config.userSettings.shell.default}.package} "$@"
  '';

  configFile = (cfg.pkgs.formats.toml { }).generate "herdr-config.toml" {
    onboarding = false;
    theme = {
      name = "gruvbox";
      auto_switch = false;
    };
    terminal.default_shell = paneShell;
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

    # Sans argument, herdr crée ou rattache la session persistante.
    home.file.".config/sway/conf.d/herdr.conf" =
      lib.mkIf config.userSettings.windowManager.sway.enable
        {
          text = ''
            bindsym Control+Return exec ${
              myLib.desktop.mkTerminalCmd {
                inherit config;
                exec = lib.getExe herdr;
              }
            }
          '';
        };

    # Copie et pas lien : les settings de herdr restent modifiables jusqu'au prochain rebuild.
    home.activation.herdrConfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      target=${config.xdg.configHome}/herdr/config.toml
      if ! cmp -s ${configFile} "$target"; then
        run rm -f "$target"
        run install -Dm644 ${configFile} "$target"
        # Sans serveur lancé, rien à recharger.
        run ${lib.getExe herdr} server reload-config >/dev/null 2>&1 || true
      fi
    '';
  };
}
