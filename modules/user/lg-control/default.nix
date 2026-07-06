{ config, lib, ... }:

let
  cfg = config.userSettings.lgControl;
  term = config.userSettings.terminal.default;
  c = config.lib.stylix.colors.withHashtag;

  # TUI pour piloter le driver LG : ventilateur + profil d'alimentation
  # (power-profiles-daemon). Titre stylé + état courant, puis menu gum
  # (flèches + Entrée) avec sous-menus. Couleurs Stylix. L'écriture de fan_mode
  # marche sans root grâce à la règle udev du module système lg-laptop.
  # La limite batterie est gérée en dur (déclaratif), pas ici.
  lg-control = cfg.pkgs.writeShellApplication {
    name = "lg-control";
    runtimeInputs = [
      cfg.pkgs.coreutils
      cfg.pkgs.gnugrep
      cfg.pkgs.ncurses
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

  # kitty mappe q vers la fermeture de la fenêtre pour unifier la sortie de tous
  # les TUIs (gum ne quitte qu'avec Esc / Ctrl-C / l'entrée « Quitter », jamais
  # avec q). Esc reste géré nativement par gum (annule / revient en arrière).
  # confirm_os_window_close=0 évite le prompt de confirmation à la fermeture.
  kittyQuit = ''-o "map q close_window" -o confirm_os_window_close=0'';
  termCmd =
    if term == "alacritty"
    then "${term} --title lg-control -e ${lg-control}/bin/lg-control"
    else if term == "kitty"
    then "${term} ${kittyQuit} --title lg-control ${lg-control}/bin/lg-control"
    else "${term} --title lg-control ${lg-control}/bin/lg-control";
in {
  options.userSettings.lgControl = {
    enable = lib.mkEnableOption "TUI de contrôle LG (ventilateur, profil alim)";
    pkgs = lib.mkOption {
      type = lib.types.pkgs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ lg-control ];

    # Launcher partagé entre le bind sway et un éventuel clic swaybar (DRY).
    home.file.".config/sway/launchers/lg-control" = {
      text = ''
        #!/bin/sh
        exec ${termCmd}
      '';
      executable = true;
    };

    home.file.".config/sway/conf.d/lg-control.conf".text = ''
      bindsym $mod+Shift+p exec ~/.config/sway/launchers/lg-control
      for_window [title="lg-control"] floating enable, resize set 900 500, border pixel 2
    '';
  };
}
