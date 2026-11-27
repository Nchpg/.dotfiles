{
  config,
  lib,
  myLib,
  themes,
  ...
}:

let
  cfg = config.userSettings.tui.lgControl;
  c = (myLib.theme.schemeColors { inherit config themes; }).withHashtag;

  lg-control = cfg.pkgs.writeShellApplication {
    name = "lg-control";
    runtimeInputs = [
      cfg.pkgs.coreutils
      cfg.pkgs.gnugrep
      cfg.pkgs.power-profiles-daemon
      cfg.pkgs.gum
      cfg.pkgs.iw
    ];
    text = ''
      SYS=/sys/devices/platform/lg-laptop

      ${myLib.theme.mkGumEnv { colors = myLib.theme.schemeColors { inherit config themes; }; }}

      fan_label() {
        case "$1" in
          0) printf 'Optimal' ;;
          1) printf 'Silencieux' ;;
          2) printf 'Performance' ;;
          *) printf 'inconnu' ;;
        esac
      }

      read_attr() { cat "$1" 2>/dev/null || true; }

      # Mode performance-max : profil performance et plancher de puissance (cf. intelGraphics.powerLimit).
      MAX=/var/lib/power-limit/performance-max
      FLOOR=/run/power-limit/floor

      profile_label() {
        if [ "$1" = performance ] && [ -e "$FLOOR" ]; then printf 'performance-max'; else printf '%s' "''${1:-?}"; fi
      }

      # Plafond de puissance (PL1) que pose thermald selon la température, et en performance-max le plancher qui
      # l'empêche de descendre plus bas.
      power_label() {
        local uw floor
        uw=$(read_attr /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw)
        floor=$(read_attr "$FLOOR")
        if [ -z "$uw" ]; then printf '?'; return; fi
        printf '%s W' "$((uw / 1000000))"
        if [ -n "$floor" ]; then printf ' (min %s W)' "$((floor / 1000000))"; fi
      }

      # Économie d'énergie du Wi-Fi, coupée en performance-max : l'état réel de chaque carte, lu sur son pilote.
      wifi_label() {
        local wireless state
        local -a states=()
        for wireless in /sys/class/net/*/wireless; do
          [ -e "$wireless" ] || continue
          state=$(iw dev "$(basename "$(dirname "$wireless")")" get power_save 2>/dev/null || true)
          case "$state" in
            *on) states+=("économie d'énergie activée") ;;
            *off) states+=("économie d'énergie coupée") ;;
            *) states+=("?") ;;
          esac
        done
        if [ "''${#states[@]}" -eq 0 ]; then printf 'aucune carte'; return; fi
        local IFS=,
        printf '%s' "''${states[*]}"
      }

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
        if [ -w "$MAX" ]; then profs+=("performance-max"); fi
        local cur sel
        cur=$(profile_label "$(powerprofilesctl get 2>/dev/null || true)")
        sel=$(gum choose --header "Profil d'alimentation (actuel : $cur)" \
          "''${profs[@]}") || return 0
        [ -n "$sel" ] || return 0
        if [ "$sel" = performance-max ]; then
          printf '1\n' > "$MAX"
          sel=performance
        elif [ -w "$MAX" ]; then
          printf '0\n' > "$MAX"
        fi
        powerprofilesctl set "$sel" 2>/dev/null || true
        # Le temps que la limite de puissance suive, avant de la réafficher.
        sleep 0.5
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
        printf '  Ventilateur     %s (%s)\n  Profil          %s\n  Puissance max   %s\n  Wi-Fi           %s\n\n' \
          "''${fan:-?}" "$(fan_label "''${fan:-x}")" "$(profile_label "$prof")" "$(power_label)" "$(wifi_label)"
        choice=$(gum choose "Ventilateur" "Profil d'alimentation" "Quitter") || break
        case "$choice" in
          "Ventilateur") choose_fan ;;
          "Profil d'alimentation") choose_profile ;;
          *) break ;;
        esac
      done
    '';
  };

  # gum ne quitte pas sur q : mappé côté kitty comme les autres TUIs.
  kittyQuit = ''-o "map q close_window" -o confirm_os_window_close=0'';
in
{
  options.userSettings.tui.lgControl = {
    enable = lib.mkEnableOption "TUI de contrôle LG (ventilateur, profil alim)";
    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (myLib.desktop.mkFloatingTuiLauncher {
        name = "lg-control";
        inherit config;
        exec = "${lg-control}/bin/lg-control";
        kittyExtraOpts = kittyQuit;
        keybind = "$mod+Shift+p";
        title = "lg-control";
        width = 900;
        height = 500;
      })
      { home.packages = [ lg-control ]; }
    ]
  );
}
