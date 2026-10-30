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
    }
    # Tabs : blocs base01 sur fond base00, tab actif en pastille base0A.
    // lib.optionalAttrs config.userSettings.stylix.enable {
      custom =
        let
          c = config.lib.stylix.colors.withHashtag;
        in
        {
          panel_bg = c.base00; # fond de la barre et texte du tab actif
          surface0 = c.base01; # fond des tabs inactifs
          overlay0 = c.base05; # texte des tabs inactifs
          overlay1 = c.base05;
          accent = c.base0A; # tab actif
        };
    };
    terminal.default_shell = paneShell;
    # ctrl+b est pris par Claude Code (passer une commande en arrière-plan).
    # Raccourcis directs sur alt : libre dans sway (mod = Super).
    keys = {
      prefix = "ctrl+space";
      new_tab = "alt+n";
      new_workspace = "alt+shift+n";
      # alt+left/right ne sautent plus de mot dans fish et Claude Code : ctrl+left/right le font.
      next_tab = [
        "alt+tab"
        "alt+right"
      ];
      previous_tab = [
        "alt+shift+tab"
        "alt+left"
      ];
      next_workspace = "alt+down";
      previous_workspace = "alt+up";
      toggle_sidebar = "alt+a";
      zoom = "alt+z";
      # alt+1…9 ; en AZERTY, kitty traduit alt+& … alt+ç (cf. modules/user/terminal/kitty).
      indexed.tabs = "alt";
    };
    ui = {
      status_indicators = "dots";
      toast.delivery = "system";
      hide_tab_bar_when_single_tab = true;
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
