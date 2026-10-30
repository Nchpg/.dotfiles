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

  # Logos des agents (lobe-icons), un <nom>.svg par agent : version couleur si elle
  # existe, sinon le monochrome recoloré (currentColor rendrait noir sur fond sombre).
  # Taille fixe : le 1em d'origine sortirait minuscule.
  agentLogos =
    let
      mono =
        if config.userSettings.stylix.enable then
          config.lib.stylix.colors.withHashtag.base05
        else
          "#d5c4a1";
    in
    cfg.pkgs.runCommand "herdr-agent-logos"
      {
        src = cfg.pkgs.fetchurl {
          url = "https://registry.npmjs.org/@lobehub/icons-static-svg/-/icons-static-svg-1.99.0.tgz";
          hash = "sha256-YB1bKNHupSwngVbEEInB0isFv8HtioI8HvtMNyplIBM=";
        };
      }
      ''
        tar xzf $src
        mkdir $out
        for f in package/icons/*.svg; do
          name=$(basename "$f" .svg)
          case $name in *-text) continue ;; *-color) continue ;; esac
          [ -f "package/icons/$name-color.svg" ] && f=package/icons/$name-color.svg
          sed -e 's/currentColor/${mono}/g' -e 's/height="1em"/height="128"/' -e 's/width="1em"/width="128"/' \
            "$f" > "$out/$name.svg"
        done
      '';

  # herdr appelle `notify-send --app-name Herdr "<agent> finished|needs attention"`
  # sans icône : on met le logo de l'agent.
  notifySend = cfg.pkgs.writeShellScriptBin "notify-send" ''
    for arg; do
      case $arg in
        *" finished" | *" needs attention")
          logo=${agentLogos}/''${arg%% *}.svg
          [ -f "$logo" ] && set -- --icon="$logo" "$@"
          break
          ;;
      esac
    done
    exec ${cfg.pkgs.libnotify}/bin/notify-send "$@"
  '';

  # Absent de nixpkgs : binaire release statique (static-pie), rien à patcher.
  herdr = cfg.pkgs.stdenvNoCC.mkDerivation {
    pname = "herdr";
    version = pinned.version;

    src = myLib.packaging.fetchPinned cfg.pkgs ./pinned.json;

    dontUnpack = true;
    dontBuild = true;

    nativeBuildInputs = [ cfg.pkgs.makeWrapper ];

    installPhase = ''
      runHook preInstall
      install -Dm755 $src $out/libexec/herdr
      makeWrapper $out/libexec/herdr $out/bin/herdr \
        --prefix PATH : ${notifySend}/bin
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
