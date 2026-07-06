{ config, lib, osConfig, ... }:

let
  cfg = osConfig.systemSettings.window-manager.sway;

  # Edit config template terminal
  templateContent = builtins.readFile ./sway-config/config.template;

  # Commande pour lancer le terminal directement dans tmux.
  # alacritty exige -e ; kitty et foot acceptent le programme directement.
  term = config.userSettings.terminal.default;
  # TMUX_TMPDIR aligné sur celui des shells (home-manager fixe $XDG_RUNTIME_DIR)
  # pour viser le même serveur tmux. sway exec passe par sh -c → $XDG_RUNTIME_DIR
  # est bien expansé, et il est toujours défini dans une session sway/wayland.
  tmuxCmd = "env TMUX_TMPDIR=$XDG_RUNTIME_DIR tmux new-session -A -s main";
  tmuxLaunch =
    if term == "alacritty"
    then "${term} -e ${tmuxCmd}"
    else "${term} ${tmuxCmd}";

  # Binding Ctrl+Return → terminal dans tmux, seulement si tmux est activé.
  tmuxBind =
    lib.optionalString config.userSettings.tmux.enable
      "bindsym Control+Return exec ${tmuxLaunch}";

  # Barre : si waybar est activé (module dédié), il fournit sa propre barre via
  # systemd → on n'émet PAS de bloc `bar {}` natif (sinon deux barres). Sinon on
  # garde la swaybar maison (sway-bar.sh).
  useWaybar = config.userSettings.waybar.enable;
  swaybarBlock = ''
    bar {
        position top

        status_command bash ~/.config/sway/sway-bar.sh
        tray_output *
        tray_padding 4

        # Pas d'onglet de mode (ex. le "displays" rouge) affiché dans la barre.
        binding_mode_indicator no

        colors {
            statusline #ffffff
            background #323232
        }
    }'';
  barBlock = if useWaybar then "" else swaybarBlock;

  finalConfigContent = lib.replaceStrings
    ["@terminal@" "@tmuxBind@" "@bar@"]
    [config.userSettings.terminal.default tmuxBind barBlock]
    templateContent;
in {
  config = lib.mkIf cfg.enable {
    home.file.".config/sway/config" = {
      text = finalConfigContent;
    };

    home.file.".config/sway/brightness.sh" = {
      source = ./sway-config/brightness.sh;
      executable = true;
    };

    home.file.".config/sway/sway-bar.sh" = {
      source = ./sway-config/sway-bar.sh;
      executable = true;
    };

    home.file.".config/sway/wallpaper.png".source = ./sway-config/wallpaper.png;

    # Cible de session graphique pour l'intégration systemd. Démarrée au lancement
    # de sway (cf. config.template), elle active graphical-session.target via BindsTo,
    # ce qui démarre automatiquement les services Wayland liés (cliphist, etc.) et
    # les arrête proprement à la sortie de sway.
    systemd.user.targets.sway-session = {
      Unit = {
        Description = "sway compositor session";
        Documentation = [ "man:systemd.special(7)" ];
        BindsTo = [ "graphical-session.target" ];
        Wants = [ "graphical-session-pre.target" ];
        After = [ "graphical-session-pre.target" ];
      };
    };

    # Capture d'écran (flameshot + grim/slurp/wl-clipboard) : module dédié
    # modules/user/flameshot. Les binds Print/Shift+Print, le daemon et les
    # règles for_window restent dans sway-config/config.template.
    home.packages = with cfg.pkgs; [

      # Sway bar dependencies
      acpi # Power battery
      alsa-utils # Sound
      brightnessctl # Brightness (remplace `light`, retiré en nixpkgs 26.05)
      playerctl # Audio player

      # Lock screen
      swaylock-effects
    ];

    stylix.targets.sway.enable = true;
  };
}
