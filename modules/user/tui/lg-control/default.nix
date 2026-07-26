{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.tui.lgControl;
  term = config.userSettings.terminal.default;
  c = config.lib.stylix.colors.withHashtag;

  # Ventilateur + profil d'alimentation via menu gum. Écriture de fan_mode
  # sans root grâce à la règle udev du module système lg-laptop. Limite
  # batterie gérée en dur (déclaratif), pas ici.
  lg-control = cfg.pkgs.writeShellApplication {
    name = "lg-control";
    runtimeInputs = [
      cfg.pkgs.coreutils
      cfg.pkgs.gnugrep
      cfg.pkgs.power-profiles-daemon
      cfg.pkgs.gum
    ];
    text = ''
      SYS=/sys/devices/platform/lg-laptop

      # Thème Stylix pour les menus gum.
      export GUM_CHOOSE_HEADER_FOREGROUND="${c.base0A}"
      export GUM_CHOOSE_CURSOR_FOREGROUND="${c.base0D}"
      export GUM_CHOOSE_SELECTED_FOREGROUND="${c.base0D}"
      export GUM_CHOOSE_ITEM_FOREGROUND="${c.base05}"

      fan_label() {
        case "$1" in
          0) printf 'Optimal' ;;
          1) printf 'Silencieux' ;;
          2) printf 'Performance' ;;
          *) printf 'inconnu' ;;
        esac
      }

      read_attr() { cat "$1" 2>/dev/null || true; }

      choose_fan() {
        local cur sel val
        cur=$(read_attr "$SYS/fan_mode")
        sel=$(gum choose --header "Ventilateur (actuel : ''${cur:-?})" \
          "0 — Optimal" "1 — Silencieux" "2 — Performance") || return 0
        val=''${sel%% *}
        if [ -n "$val" ]; then printf '%s\n' "$val" > "$SYS/fan_mode" 2>/dev/null || true; fi
      }

      choose_profile() {
        local -a profs
        mapfile -t profs < <(powerprofilesctl list 2>/dev/null \
          | grep -oP '^\s*\*?\s*\K[a-z-]+(?=:)')
        if [ "''${#profs[@]}" -eq 0 ]; then return 0; fi
        local cur sel
        cur=$(powerprofilesctl get 2>/dev/null || true)
        sel=$(gum choose --header "Profil d'alimentation (actuel : ''${cur:-?})" \
          "''${profs[@]}") || return 0
        if [ -n "$sel" ]; then powerprofilesctl set "$sel" 2>/dev/null || true; fi
      }

      if [ ! -d "$SYS" ]; then
        gum style --foreground "${c.base08}" "Driver lg-laptop introuvable — pas un PC LG compatible ?"
        exit 1
      fi

      while true; do
        clear
        fan=$(read_attr "$SYS/fan_mode")
        prof=$(powerprofilesctl get 2>/dev/null || true)
        gum style --bold --foreground "${c.base0D}" "  LG Power Control"
        printf '  Ventilateur : %s (%s)    Profil : %s\n\n' \
          "''${fan:-?}" "$(fan_label "''${fan:-x}")" "''${prof:-?}"
        choice=$(gum choose "Ventilateur" "Profil d'alimentation" "Quitter") || break
        case "$choice" in
          "Ventilateur") choose_fan ;;
          "Profil d'alimentation") choose_profile ;;
          *) break ;;
        esac
      done
    '';
  };

  # gum ne quitte qu'avec Esc/Ctrl-C/"Quitter", jamais q : mappé côté kitty
  # pour unifier la sortie de tous les TUIs.
  kittyQuit = ''-o "map q close_window" -o confirm_os_window_close=0'';
  termCmd = myLib.mkTerminalCmd {
    inherit lib term;
    title = "lg-control";
    exec = "${lg-control}/bin/lg-control";
    kittyExtraOpts = kittyQuit;
  };
in
{
  options.userSettings.tui.lgControl = {
    enable = lib.mkEnableOption "TUI de contrôle LG (ventilateur, profil alim)";
    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (myLib.mkFloatingTuiLauncher {
        name = "lg-control";
        scriptBody = "exec ${termCmd}";
        keybind = "$mod+Shift+p";
        title = "lg-control";
        width = 900;
        height = 500;
      })
      { home.packages = [ lg-control ]; }
    ]
  );
}
