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

  # Fenêtre kitty de herdr titrée « <hôte>: <workspace> · <tab> » (cf. ui.window_title) :
  # le wrapper de notifications s'en sert pour savoir ce que l'utilisateur regarde.
  windowTitle = "{hostname}: {workspace} · {tab}";

  # herdr appelle `notify-send --app-name Herdr "<agent> finished|needs attention" "<workspace> · <n> · <tab>"`
  # depuis chaque client qui n'affiche pas l'agent : avec 3 fenêtres, 2 notifs.
  # On ajoute le logo de l'agent, on se tait si la fenêtre focalisée montre déjà
  # ce tab, et on ne laisse passer qu'une copie par 3 s.
  notifySend = cfg.pkgs.writeShellApplication {
    name = "notify-send";
    runtimeInputs = with cfg.pkgs; [
      coreutils
      jq
      sway
      util-linux
    ];
    text = ''
      args=("$@") title="" body=""
      for i in "''${!args[@]}"; do
        case ''${args[i]} in
          *" finished" | *" needs attention")
            title=''${args[i]}
            body=''${args[i + 1]:-}
            break
            ;;
        esac
      done

      if [ -n "$title" ]; then
        workspace=''${body%% · *}
        tab=''${body##* · }
        focused=$(swaymsg -t get_tree 2>/dev/null | jq -r '.. | objects | select(.focused == true) | .name // empty' || true)
        [[ $focused == *": $workspace · $tab" ]] && exit 0

        dir=''${XDG_RUNTIME_DIR:-/tmp}/herdr-notify
        mkdir -p "$dir"
        stamp=$dir/$(printf '%s\n%s' "$title" "$body" | md5sum | cut -d' ' -f1)
        exec 9>"$dir/lock"
        flock 9
        if [ -f "$stamp" ] && (($(date +%s) - $(stat -c %Y "$stamp") < 3)); then
          exit 0
        fi
        touch "$stamp"
        flock -u 9

        logo=${agentLogos}/''${title%% *}.svg
        [ -f "$logo" ] && set -- --icon="$logo" "$@"
      fi
      exec ${cfg.pkgs.libnotify}/bin/notify-send "$@"
    '';
  };

  # Absent de nixpkgs : compilé depuis les sources de la release (paquet nix de l'amont),
  # pour y ajouter l'action toggle_tab_bar. fetchTarball et pas fetchFromGitHub : son
  # nix/package.nix est importé, ce qui ferait de l'import-from-derivation.
  # HERDR_NEW_WORKSPACE_CWD : le client ouvre lui-même un workspace local neuf, sans
  # déplacer les autres fenêtres (un focus par la CLI les recentrerait toutes). Sidebar
  # fermée, et rien n'est dessiné avant que ce workspace soit focalisé (3 s au plus).
  herdrUnwrapped = myLib.packaging.mkGuardedPatch {
    package = sidebarPeek;
    patch = ./startup-workspace.patch;
    files = {
      "src/client/mod.rs" = "918298d730dc9fb8dcd2ef00018e204d592697e4bb0acd6f1b68a59a7bf0604e";
      "src/client/shell/composition.rs" =
        "007992bb1dc3989fa9a0146f757a502e9082664727d3cca94e6ccd70f51f58e0";
      "src/client/shell/state.rs" = "bbecf709e8e01ebc32becf41b6d532a09c348c3ba4b66c2a0ee3948d73b02362";
    };
    where = "modules/user/agents/herdr/default.nix";
  };

  # Alt+up/down montre aussi la sidebar repliée pendant 0,5 s (sidebar-peek.patch).
  sidebarPeek =
    # Une release qui touche un de ces fichiers fait échouer le build : rebaser ou retirer le patch.
    # sidebar-peek.patch s'applique par-dessus toggle-tab-bar.patch (actions.rs en commun).
    myLib.packaging.mkGuardedPatch {
      package = toggleTabBar;
      patch = ./sidebar-peek.patch;
      files = {
        "src/client/mod.rs" = "918298d730dc9fb8dcd2ef00018e204d592697e4bb0acd6f1b68a59a7bf0604e";
        "src/client/shell/actions.rs" = "3ce241364f1a35c20926c27b400b576e954f46040e0144f3f5f7e5bc37ed2256";
        "src/client/shell/state.rs" = "bbecf709e8e01ebc32becf41b6d532a09c348c3ba4b66c2a0ee3948d73b02362";
      };
      where = "modules/user/agents/herdr/default.nix";
    };

  # Action toggle_tab_bar : affiche ou masque la barre des tabs d'un workspace à un seul tab.
  toggleTabBar =
    let
      src = builtins.fetchTarball {
        url = "https://github.com/herdrdev/herdr/archive/refs/tags/v${pinned.version}.tar.gz";
        sha256 = pinned.hash;
      };
    in
    myLib.packaging.mkGuardedPatch {
      package = cfg.pkgs.callPackage "${src}/nix/package.nix" { };
      patch = ./toggle-tab-bar.patch;
      files = {
        "src/client/shell/actions.rs" = "3ce241364f1a35c20926c27b400b576e954f46040e0144f3f5f7e5bc37ed2256";
        "src/config/keybinds.rs" = "4c56cc268ae9c54ca834d18cb3dfda938a17467cc0057179611f10113ff874b2";
        "src/config/model.rs" = "22a0e0ea19728d63dca866ea8669ca558e516d8d4ccac346a262aba4ec6ad6b2";
        "src/input/keybind_help.rs" = "b2b061038953772c4b49ecff58356bb26decdddaa5610e3063035fecfedc0183";
        "src/input/keybindings.rs" = "c6d01acf8fb18812662ee64d7d570ccfac16d23e902aa3378c896d3c5b58f876";
        "src/main.rs" = "0c7be66cb1c0247d1bfebb68eae6d5fcdf40b8a6931d19d4554b1376becb9c45";
      };
      where = "modules/user/agents/herdr/default.nix";
    };

  # mod+entrée : une fenêtre sur un workspace neuf dans ~. Les workspaces restent ouverts :
  # à partir de 10 en local, une notification le signale sans bloquer l'ouverture.
  herdrNewWindow = cfg.pkgs.writeShellScript "herdr-new-window" ''
    n=$(${lib.getExe herdr} workspace list 2>/dev/null \
      | ${lib.getExe cfg.pkgs.jq} '.result.workspaces | length' 2>/dev/null || echo 0)
    n=$((''${n:-0} + 1))
    if [ "$n" -ge 10 ]; then
      ${cfg.pkgs.libnotify}/bin/notify-send --app-name Herdr "herdr" "$n workspaces ouverts" &
    fi
    HERDR_NEW_WORKSPACE_CWD=$HOME exec ${lib.getExe herdr}
  '';

  herdr = cfg.pkgs.stdenvNoCC.mkDerivation {
    pname = "herdr";
    version = pinned.version;

    dontUnpack = true;
    dontBuild = true;

    nativeBuildInputs = [ cfg.pkgs.makeWrapper ];

    installPhase = ''
      runHook preInstall
      install -Dm755 ${lib.getExe herdrUnwrapped} $out/libexec/herdr
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
  # Un tab sans nom porte sa position (« 3 ») : on le renomme « <hôte>: <dossier> »
  # au lancement de son premier shell. Le nom ne suit pas les cd.
  paneShell = cfg.pkgs.writeShellScript "herdr-shell" ''
    unset SHLVL
    if [ -n "''${HERDR_TAB_ID:-}" ]; then
      label=$(${lib.getExe herdr} tab get "$HERDR_TAB_ID" 2>/dev/null \
        | ${lib.getExe cfg.pkgs.jq} -r '.result.tab.label // empty')
      case $label in
        "" | *[!0-9]*) ;;
        *) ${lib.getExe herdr} tab rename "$HERDR_TAB_ID" "$HOSTNAME: ''${PWD/#"$HOME"/\~}" >/dev/null 2>&1 ;;
      esac
    fi
    exec -a "$0" ${lib.getExe config.programs.${config.userSettings.shell.default}.package} "$@"
  '';

  # alt+left/right : pane voisin, ou tab précédent/suivant (en boucle) au bord.
  # Le focus est celui du serveur, commun à toutes les fenêtres.
  focusPaneOrTab = cfg.pkgs.writeShellScript "herdr-focus-pane-or-tab" ''
    dir=$1
    herdr=${lib.getExe herdr}
    jq=${lib.getExe cfg.pkgs.jq}
    snap=$($herdr api snapshot)
    pane=$($jq -r '.result.snapshot.focused_pane_id' <<<"$snap")
    if $herdr pane neighbor --direction "$dir" --pane "$pane" \
      | $jq -e '.result.neighbor.neighbor_pane_id' >/dev/null; then
      exec $herdr pane focus --direction "$dir" --pane "$pane"
    fi
    step=1 back=left
    [ "$dir" = left ] && step=-1 back=right
    tab=$($jq -r --argjson step "$step" '
      .result.snapshot as $s
      | [$s.tabs[] | select(.workspace_id == $s.focused_workspace_id) | .tab_id] as $t
      | ($t | index($s.focused_tab_id)) as $i
      | $t[($i + $step) % ($t | length)]
    ' <<<"$snap")
    $herdr tab focus "$tab" >/dev/null
    # On entre par le bord : le pane le plus à gauche en allant à droite, et inversement.
    pane=$($jq -r --arg tab "$tab" '.result.snapshot.layouts[] | select(.tab_id == $tab) | .focused_pane_id' <<<"$snap")
    for _ in 1 2 3 4 5 6 7 8; do
      next=$($herdr pane neighbor --direction "$back" --pane "$pane" \
        | $jq -r '.result.neighbor.neighbor_pane_id // empty')
      [ -n "$next" ] || break
      $herdr pane focus --direction "$back" --pane "$pane" >/dev/null
      pane=$next
    done
  '';

  configFile = (cfg.pkgs.formats.toml { }).generate "herdr-config.toml" {
    onboarding = false;
    theme = {
      name = "gruvbox";
      auto_switch = false;
    }
    # Comme sway : tab et panneau actifs en gris clair, panneaux inactifs discrets.
    # herdr n'a pas de couleur de bordure à part : chaque token sert aussi ailleurs.
    // lib.optionalAttrs config.userSettings.stylix.enable {
      custom =
        let
          c = config.lib.stylix.colors.withHashtag;
        in
        {
          panel_bg = c.base00; # fond de la barre et texte du tab actif
          surface0 = c.base01; # fond des tabs inactifs
          # Bordure des panneaux inactifs, et texte secondaire de la sidebar :
          # base02 la rendrait illisible.
          overlay0 = c.base03;
          overlay1 = c.base05; # texte des tabs inactifs
          accent = c.base04; # tab actif, bordure du panneau actif, séparateurs
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
      next_tab = "alt+tab";
      previous_tab = "alt+shift+tab";
      next_workspace = "alt+down";
      previous_workspace = "alt+up";
      toggle_sidebar = "alt+a";
      # Action ajoutée par toggle-tab-bar.patch : côté client, donc aussi sur think.
      toggle_tab_bar = "alt+t";
      command = [
        {
          key = "alt+left";
          type = "shell";
          command = "${focusPaneOrTab} left";
        }
        {
          key = "alt+right";
          type = "shell";
          command = "${focusPaneOrTab} right";
        }
      ];
      workspace_picker = [
        "prefix+w"
        "alt+w"
      ];
      zoom = "alt+z";
      # Panneaux à la vim, en gardant les prefix+… par défaut.
      split_vertical = [
        "prefix+v"
        "alt+v"
      ];
      split_horizontal = [
        "prefix+minus"
        "alt+shift+v"
      ];
      close_pane = [
        "prefix+x"
        "alt+x"
      ];
      focus_pane_left = [
        "prefix+h"
        "alt+h"
      ];
      focus_pane_down = [
        "prefix+j"
        "alt+j"
      ];
      focus_pane_up = [
        "prefix+k"
        "alt+k"
      ];
      focus_pane_right = [
        "prefix+l"
        "alt+l"
      ];
      swap_pane_left = [
        "prefix+shift+h"
        "alt+shift+h"
        "alt+shift+left"
      ];
      swap_pane_down = [
        "prefix+shift+j"
        "alt+shift+j"
        "alt+shift+down"
      ];
      swap_pane_up = [
        "prefix+shift+k"
        "alt+shift+k"
        "alt+shift+up"
      ];
      swap_pane_right = [
        "prefix+shift+l"
        "alt+shift+l"
        "alt+shift+right"
      ];
      # alt+1…9 ; en AZERTY, kitty traduit alt+& … alt+ç (cf. modules/user/terminal/kitty).
      indexed.tabs = "alt";
    };
    ui = {
      status_indicators = "symbols";
      window_title = windowTitle;
      toast.delivery = "system";
      sound.enabled = false;
      # alt+t l'affiche pour un tab seul (toggle_tab_bar) : elle porte l'indicateur de zoom.
      hide_tab_bar_when_single_tab = true;
      # waybar ferme le haut de l'écran, les tabs le bas.
      tab_bar_position = "bottom";
      # Le tab naît avec sa position pour nom, que herdr-shell remplace par « <hôte>: <dossier> ».
      prompt_new_tab_name = false;
      tab_bar_right = [ { type = "zoom"; } ];
      pane_scrollbars = false;
      # alt+a cache toute la sidebar au lieu de la réduire à une colonne.
      sidebar_collapsed_mode = "hidden";
      # Défaut : machine · workspace · tab sur une ligne, tronqué à 26 colonnes.
      sidebar.agents.rows = [
        [
          "state_icon"
          "workspace"
          "tab"
        ]
        [
          "machine"
          "agent"
        ]
      ];
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
    machines = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "think" ];
      description = "Hôtes SSH ajoutés aux machines de herdr (herdr doit y être installé). Ajout seulement : en retirer un ne le supprime pas de herdr.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ herdr ];

    # Suite de herdr-shell : un tab nommé « <hôte>: <dossier> » suit les cd.
    # Un nom donné à la main ne commence pas par l'hôte et reste tel quel.
    programs.fish.interactiveShellInit = lib.mkAfter ''
      if set -q HERDR_TAB_ID
          function __herdr_tab_follow_pwd --on-variable PWD
              set -l label (${lib.getExe herdr} tab get $HERDR_TAB_ID 2>/dev/null \
                  | ${lib.getExe cfg.pkgs.jq} -r '.result.tab.label // empty')
              string match -q -- "$hostname: *" $label; or return
              ${lib.getExe herdr} tab rename $HERDR_TAB_ID "$hostname: "(string replace -r -- "^$HOME" "~" $PWD) >/dev/null 2>&1
          end
      end
    '';

    # herdr se tait pour l'onglet actif d'un client, même si sa fenêtre est derrière
    # une autre : Claude notifie aussi lui-même, avec les mêmes titre et corps que
    # herdr pour que le wrapper filtre (onglet affiché par la fenêtre focalisée) et dédoublonne.
    userSettings.agents.claude.settings.hooks =
      let
        claudeNotify = cfg.pkgs.writeShellApplication {
          name = "claude-herdr-notify";
          runtimeInputs = [
            herdr
            cfg.pkgs.jq
          ];
          text = ''
            [ -n "''${HERDR_TAB_ID:-}" ] || exit 0
            ws=$(herdr workspace get "$HERDR_WORKSPACE_ID" | jq -r '.result.workspace.label')
            tab=$(herdr tab get "$HERDR_TAB_ID" | jq -r '.result.tab | "\(.number) · \(.label)"')
            exec ${lib.getExe notifySend} --app-name Herdr "claude $1" "$ws · $tab" >/dev/null 2>&1
          '';
        };
        hook = state: [
          {
            type = "command";
            command = "${lib.getExe claudeNotify} '${state}'";
          }
        ];
      in
      lib.mkIf (config.userSettings.agents.claude.enable && config.userSettings.windowManager.sway.enable)
        {
          Stop = [ { hooks = hook "finished"; } ];
          Notification = [
            {
              matcher = "permission_prompt|elicitation_dialog";
              hooks = hook "needs attention";
            }
          ];
        };

    # herdr-new-window rattache la session persistante sur un workspace neuf (startup-workspace.patch).
    home.file.".config/sway/conf.d/herdr.conf" =
      lib.mkIf config.userSettings.windowManager.sway.enable
        {
          text = ''
            bindsym $mod+Return exec ${
              myLib.desktop.mkTerminalCmd {
                inherit config;
                exec = toString herdrNewWindow;
                # En points : 1.5 pt = 2 px en haut et en bas. waybar (30 px) + 58 lignes
                # de 27 px remplissent alors l'écran, sans bande vide autour de herdr.
                kittyExtraOpts = "-o 'window_padding_width=1.5 4'";
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

    # Le catalogue de herdr (ids opaques) n'est pas écrivable en Nix : on ajoute au login
    # les hôtes absents. Pas dans l'activation : il faut l'agent SSH de la session.
    systemd.user.services.herdr-machines = lib.mkIf (cfg.machines != [ ]) {
      Unit = {
        Description = "Ajoute les machines SSH déclarées à herdr";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe (
          cfg.pkgs.writeShellApplication {
            name = "herdr-machines";
            runtimeInputs = [
              herdr
              cfg.pkgs.jq
              # Celui de la config SSH (avec GSSAPI si l'AFS est activé).
              config.programs.ssh.package
            ];
            text = ''
              known=$(herdr machine list --json)
              hosts=(${lib.escapeShellArgs cfg.machines})
              for host in "''${hosts[@]}"; do
                if ! jq -e --arg h "$host" 'any(.. | strings; . == $h)' <<<"$known" >/dev/null; then
                  herdr machine add "$host" --remote-session default
                fi
              done
            '';
          }
        );
      };
    };
  };
}
